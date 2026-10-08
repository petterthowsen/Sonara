//! Arpeggiator (spec 027 REQ-020 to REQ-023): play the held notes one at a time, on a grid.
//!
//! The held notes are turned into a sequence (order, octaves, reverse, ping-pong) whenever the
//! held set or those parameters change; a step only reads the next entry. The position carries
//! over a rebuild, so adding or releasing a note doesn't restart the pattern (REQ-022).
//!
//! Each step is a generated note whose parent is the held note it came from, so it has that
//! note's clip/live origin and transport stop ends clip arpeggios only (REQ-007).

use super::clock::{rate_to_beats, StepClock, RATE_CHOICES, RATE_DEFAULT};
use super::host::{NoteCx, NoteProcessor, NoteState};
use crate::audio::devices::param_table::{linear, slot_table, spec, Kind, ParamSpec, ParamTable};
use crate::audio::devices::ParamId;
use crate::audio::dsp::Rng;
use crate::audio::midi_types::{is_clip_note, NoteEvent, SoundingNoteId, DEFAULT_RELEASE};
use crate::audio::transport::Transport;

pub const MODE: ParamId = 0;
pub const REVERSE: ParamId = 1;
pub const PING_PONG: ParamId = 2;
pub const REPEAT_ENDS: ParamId = 3;
pub const OCTAVES: ParamId = 4;
pub const RATE: ParamId = 10;
pub const GATE: ParamId = 11;
pub const SWING: ParamId = 12;
pub const LATCH: ParamId = 20;

const MODES: &[&str] = &["Up", "Converge", "As Played", "Random"];
const MODE_CONVERGE: u8 = 1;
const MODE_AS_PLAYED: u8 = 2;
const MODE_RANDOM: u8 = 3;

const SPECS: [ParamSpec; 9] = [
    spec(MODE, "Mode", "Pattern", "", Kind::Enum(MODES), 0.0),
    spec(REVERSE, "Reverse", "Pattern", "", Kind::Bool, 0.0),
    spec(PING_PONG, "Ping-Pong", "Pattern", "", Kind::Bool, 0.0),
    spec(REPEAT_ENDS, "Repeat Ends", "Pattern", "", Kind::Bool, 0.0),
    spec(OCTAVES, "Octaves", "Pattern", "oct", linear(1.0, 4.0), 1.0),
    spec(
        RATE,
        "Rate",
        "Timing",
        "",
        Kind::Enum(RATE_CHOICES),
        RATE_DEFAULT,
    ),
    spec(GATE, "Gate", "Timing", "%", linear(10.0, 200.0), 100.0),
    spec(SWING, "Swing", "Timing", "%", linear(0.0, 75.0), 0.0),
    spec(LATCH, "Latch", "Hold", "", Kind::Bool, 0.0),
];
const SLOTS: [u8; 21] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

/// Held keys the sequence is built from (the host holds at most this many input notes).
const MAX_HELD: usize = 128;
/// 128 keys × 4 octaves × 2 for ping-pong.
const MAX_SEQUENCE: usize = MAX_HELD * 4 * 2;

#[derive(Clone, Copy)]
struct Held {
    id: SoundingNoteId,
    key: u8,
    velocity: f32,
    /// False once released while latched.
    down: bool,
}

#[derive(Clone, Copy)]
struct Entry {
    key: u8,
    parent: SoundingNoteId,
    velocity: f32,
}

pub struct Arpeggiator {
    mode: u8,
    reverse: bool,
    ping_pong: bool,
    repeat_ends: bool,
    octaves: i32,
    gate: f32,
    latch: bool,

    clock: StepClock,
    rng: Rng,

    held: Vec<Held>,
    /// Indices into `held` in base order; scratch for `rebuild`.
    order: Vec<usize>,
    scratch: Vec<usize>,
    seq: Vec<Entry>,
    dirty: bool,
    /// Next sequence index to play.
    pos: usize,
    last_index: Option<usize>,
    last_key: Option<u8>,
    /// A chord started at this sample; step 1 plays once every note at the same frame is in.
    pending_start: Option<u64>,
    /// The arpeggio is running (a latched chord keeps it going with no key down).
    running: bool,
}

impl Arpeggiator {
    fn rebuild(&mut self) {
        self.dirty = false;
        self.seq.clear();
        self.order.clear();
        let n = self.held.len();
        if n == 0 {
            self.pos = 0;
            self.last_index = None;
            return;
        }
        self.order.extend(0..n);
        if self.mode != MODE_AS_PLAYED {
            let held = &self.held;
            self.order.sort_unstable_by_key(|&i| (held[i].key, i));
        }
        if self.mode == MODE_CONVERGE {
            // lowest, highest, second lowest, second highest, … into the scratch, then back.
            self.scratch.clear();
            let (mut lo, mut hi) = (0, n);
            while lo < hi {
                self.scratch.push(self.order[lo]);
                lo += 1;
                if lo < hi {
                    hi -= 1;
                    self.scratch.push(self.order[hi]);
                }
            }
            self.order.clear();
            self.order.extend_from_slice(&self.scratch);
        }
        for octave in 0..self.octaves.clamp(1, 4) {
            for &i in &self.order {
                let held = self.held[i];
                let key = held.key as i32 + 12 * octave;
                if key <= 127 {
                    self.seq.push(Entry {
                        key: key as u8,
                        parent: held.id,
                        velocity: held.velocity,
                    });
                }
            }
        }
        if self.reverse {
            self.seq.reverse();
        }
        if self.ping_pong && self.seq.len() > 1 {
            let m = self.seq.len();
            // Back down without repeating the end notes, or repeating them.
            let (from, to) = if self.repeat_ends { (m, 0) } else { (m - 1, 1) };
            for i in (to..from).rev() {
                let entry = self.seq[i];
                self.seq.push(entry);
            }
        }
        if self.pos >= self.seq.len() {
            self.pos = 0;
        }
    }

    fn ensure_built(&mut self) {
        if self.dirty {
            self.rebuild();
        }
    }

    /// Play the next step at sample `at`.
    fn play_step(&mut self, cx: &mut NoteCx, at: u64) {
        self.ensure_built();
        let len = self.seq.len();
        if len == 0 {
            return;
        }
        let index = if self.mode == MODE_RANDOM {
            match self.last_index {
                Some(prev) if len > 1 && prev < len => {
                    // Uniform over every index but the previous one.
                    let r = (self.rng.next_f32() * (len - 1) as f32) as usize;
                    let r = r.min(len - 2);
                    if r >= prev {
                        r + 1
                    } else {
                        r
                    }
                }
                _ => ((self.rng.next_f32() * len as f32) as usize).min(len - 1),
            }
        } else {
            self.pos % len
        };
        self.last_index = Some(index);
        self.pos = index + 1;
        let entry = self.seq[index];
        let length = ((self.gate * self.clock.step_samples() as f32) as u64).max(1);
        if let Some(id) = cx.emit_on(entry.key as i32, entry.velocity, at, entry.parent) {
            cx.end_note_at(id, entry.key, at + length, DEFAULT_RELEASE, entry.parent);
            self.last_key = Some(entry.key);
        }
    }

    fn start_pending(&mut self, cx: &mut NoteCx, until: u64) {
        if let Some(at) = self.pending_start {
            if until > at {
                self.pending_start = None;
                if !self.seq.is_empty() {
                    self.clock.start_at(cx.now(), at);
                    self.play_step(cx, at);
                }
            }
        }
    }

    fn forget_all(&mut self) {
        self.held.clear();
        self.seq.clear();
        self.pos = 0;
        self.last_index = None;
        self.last_key = None;
        self.pending_start = None;
        self.running = false;
        self.dirty = false;
    }
}

impl NoteProcessor for Arpeggiator {
    fn new(sample_rate: f32) -> Self {
        Self {
            mode: 0,
            reverse: false,
            ping_pong: false,
            repeat_ends: false,
            octaves: 1,
            gate: 1.0,
            latch: false,
            clock: StepClock::new(sample_rate),
            rng: Rng::new(0xA49E_6610),
            held: Vec::with_capacity(MAX_HELD),
            order: Vec::with_capacity(MAX_HELD),
            scratch: Vec::with_capacity(MAX_HELD),
            seq: Vec::with_capacity(MAX_SEQUENCE),
            dirty: false,
            pos: 0,
            last_index: None,
            last_key: None,
            pending_start: None,
            running: false,
        }
    }

    fn device_id() -> &'static str {
        "sonara.builtin.arpeggiator"
    }

    fn device_name() -> &'static str {
        "Arpeggiator"
    }

    fn table() -> &'static ParamTable {
        &TABLE
    }

    fn apply(&mut self, id: ParamId, real: f32) {
        match id {
            MODE => {
                self.mode = real as u8;
                self.dirty = true;
            }
            REVERSE => {
                self.reverse = real >= 0.5;
                self.dirty = true;
            }
            PING_PONG => {
                self.ping_pong = real >= 0.5;
                self.dirty = true;
            }
            REPEAT_ENDS => {
                self.repeat_ends = real >= 0.5;
                self.dirty = true;
            }
            OCTAVES => {
                self.octaves = real.round() as i32;
                self.dirty = true;
            }
            RATE => self.clock.set_rate_beats(rate_to_beats(real as usize)),
            GATE => self.gate = real / 100.0,
            SWING => self.clock.set_swing(real / 100.0),
            LATCH => {
                let latch = real >= 0.5;
                if self.latch && !latch {
                    // Latch off releases the latched notes that aren't physically held.
                    self.held.retain(|h| h.down);
                    if self.held.is_empty() {
                        self.running = false;
                    }
                    self.dirty = true;
                }
                self.latch = latch;
            }
            _ => {}
        }
    }

    fn note(&mut self, cx: &mut NoteCx, event: &NoteEvent, at: u64) {
        match *event {
            NoteEvent::On {
                note_id,
                key,
                velocity,
            } => {
                if self.held.len() >= MAX_HELD {
                    return;
                }
                // The first key of a chord starts the pattern at once. A latched chord that is
                // replaced keeps the running pattern on its grid instead.
                let all_released = !self.held.is_empty() && self.held.iter().all(|h| !h.down);
                let fresh = self.held.is_empty();
                if self.latch && all_released {
                    self.held.clear();
                    self.pos = 0;
                    self.last_index = None;
                }
                self.held.push(Held {
                    id: note_id,
                    key,
                    velocity,
                    down: true,
                });
                self.dirty = true;
                if fresh && !self.running {
                    self.running = true;
                    self.pending_start = Some(at);
                } else if fresh {
                    self.running = true;
                }
            }
            NoteEvent::Off {
                note_id, release, ..
            } => {
                let Some(i) = self.held.iter().position(|h| h.id == note_id) else {
                    return;
                };
                if self.latch {
                    self.held[i].down = false;
                } else {
                    // The step it started ends with the key, so a legato clip note (or a loop
                    // wrap) followed at once by the next note never overlaps with it.
                    cx.release_children(note_id, at, release);
                    self.held.remove(i);
                    if self.held.is_empty() {
                        self.running = false;
                        self.pending_start = None;
                    }
                }
                self.dirty = true;
            }
            NoteEvent::Expression { .. } => {}
        }
    }

    fn run_until(&mut self, cx: &mut NoteCx, until: u64) {
        self.ensure_built();
        self.start_pending(cx, until);
        // A chord still arriving at its start frame: step 1 starts the clock, so don't ask the
        // clock (still anchored to the last arpeggio) for steps before then.
        if self.seq.is_empty() || !self.running || self.pending_start.is_some() {
            return;
        }
        while let Some(step) = self.clock.next(cx.now(), until) {
            self.play_step(cx, step.at);
        }
    }

    fn reset(&mut self) {
        self.forget_all();
        self.clock.reset();
    }

    fn discontinuity(&mut self, _cx: &mut NoteCx) {
        self.held.retain(|h| !is_clip_note(h.id));
        if self.held.is_empty() {
            self.forget_all();
            self.clock.reset();
        } else {
            self.dirty = true;
        }
    }

    fn set_transport(&mut self, transport: &Transport) {
        self.clock.set_transport(transport);
    }

    fn set_sample_rate(&mut self, sample_rate: f32) {
        self.clock.set_sample_rate(sample_rate);
    }

    const HAS_STATE: bool = true;

    fn state(&self, out: &mut NoteState) {
        out.key = self.last_key.unwrap_or(0xFF);
        out.held.extend(self.held.iter().map(|h| h.key));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::devices::note_fx::NoteFxHost;
    use crate::audio::devices::AudioDevice;
    use crate::audio::midi_types::CLIP_ID_START;

    const SR: f32 = 48_000.0;
    const BLOCK: usize = 500;

    fn device() -> NoteFxHost<Arpeggiator> {
        let mut d = NoteFxHost::<Arpeggiator>::new(SR);
        d.set_transport(&Transport {
            tempo: 120.0,
            ..Transport::default()
        });
        d
    }

    fn set(d: &mut NoteFxHost<Arpeggiator>, id: ParamId, real: f32) {
        d.set_parameter(id, TABLE.spec(id).unwrap().to_norm(real));
    }

    fn press(d: &mut NoteFxHost<Arpeggiator>, id: u32, key: u8, frame: usize) {
        d.send_note_event(
            &NoteEvent::On {
                note_id: id,
                key,
                velocity: 0.8,
            },
            frame,
        );
    }

    fn release(d: &mut NoteFxHost<Arpeggiator>, id: u32, key: u8, frame: usize) {
        d.send_note_event(
            &NoteEvent::Off {
                note_id: id,
                key,
                release: 0.5,
            },
            frame,
        );
    }

    /// Absolute `(sample, is_on, key)` of everything the device emits over `blocks` blocks
    /// starting at block `from`.
    fn collect(
        d: &mut NoteFxHost<Arpeggiator>,
        from: usize,
        blocks: usize,
    ) -> Vec<(usize, bool, u8)> {
        let mut out = Vec::new();
        for b in from..from + blocks {
            for n in d.process_notes(BLOCK) {
                let at = b * BLOCK + n.frame;
                match n.event {
                    NoteEvent::On { key, .. } => out.push((at, true, key)),
                    NoteEvent::Off { key, .. } => out.push((at, false, key)),
                    _ => {}
                }
            }
        }
        out
    }

    /// Like `collect`, with the transport playing from beat 0 at 120 BPM.
    fn collect_playing(d: &mut NoteFxHost<Arpeggiator>, blocks: usize) -> Vec<(usize, bool, u8)> {
        let mut out = Vec::new();
        for b in 0..blocks {
            d.set_transport(&Transport {
                tempo: 120.0,
                playing: true,
                song_pos_beats: (b * BLOCK) as f64 / SR as f64 * 2.0,
                ..Transport::default()
            });
            for n in d.process_notes(BLOCK) {
                let at = b * BLOCK + n.frame;
                match n.event {
                    NoteEvent::On { key, .. } => out.push((at, true, key)),
                    NoteEvent::Off { key, .. } => out.push((at, false, key)),
                    _ => {}
                }
            }
        }
        out
    }

    fn on_keys(events: &[(usize, bool, u8)]) -> Vec<u8> {
        events.iter().filter(|e| e.1).map(|e| e.2).collect()
    }

    /// Hold `keys` (pressed together at frame 0) and read the first `steps` keys played.
    fn sequence(
        configure: impl Fn(&mut NoteFxHost<Arpeggiator>),
        keys: &[u8],
        steps: usize,
    ) -> Vec<u8> {
        let mut d = device();
        configure(&mut d);
        for (i, &k) in keys.iter().enumerate() {
            press(&mut d, 1 + i as u32, k, 0);
        }
        // 120 BPM 1/16 = 6000 frames = 12 blocks per step.
        let events = collect(&mut d, 0, 12 * steps + 1);
        let mut played = on_keys(&events);
        played.truncate(steps);
        played
    }

    #[test]
    fn up_two_octaves() {
        let seq = sequence(|d| set(d, OCTAVES, 2.0), &[60, 64, 67], 7);
        assert_eq!(seq, vec![60, 64, 67, 72, 76, 79, 60]);
    }

    #[test]
    fn up_two_octaves_reverse() {
        let seq = sequence(
            |d| {
                set(d, OCTAVES, 2.0);
                set(d, REVERSE, 1.0);
            },
            &[60, 64, 67],
            7,
        );
        assert_eq!(seq, vec![79, 76, 72, 67, 64, 60, 79]);
    }

    #[test]
    fn ping_pong_without_and_with_repeated_ends() {
        let seq = sequence(|d| set(d, PING_PONG, 1.0), &[60, 64, 67], 6);
        assert_eq!(seq, vec![60, 64, 67, 64, 60, 64]);
        let seq = sequence(
            |d| {
                set(d, PING_PONG, 1.0);
                set(d, REPEAT_ENDS, 1.0);
            },
            &[60, 64, 67],
            7,
        );
        assert_eq!(seq, vec![60, 64, 67, 67, 64, 60, 60]);
    }

    #[test]
    fn converge_and_as_played() {
        let seq = sequence(|d| set(d, MODE, 1.0), &[60, 64, 67], 4);
        assert_eq!(seq, vec![60, 67, 64, 60]);
        let seq = sequence(|d| set(d, MODE, 2.0), &[67, 60, 64], 4);
        assert_eq!(seq, vec![67, 60, 64, 67]);
    }

    #[test]
    fn random_never_repeats_a_note_in_a_row() {
        let seq = sequence(|d| set(d, MODE, 3.0), &[60, 64, 67], 40);
        assert_eq!(seq.len(), 40);
        assert!(seq.windows(2).all(|w| w[0] != w[1]), "{seq:?}");
        assert!(seq.iter().any(|&k| k == 60) && seq.iter().any(|&k| k == 67));
    }

    #[test]
    fn steps_are_6000_frames_apart_and_last_the_gate() {
        let mut d = device();
        set(&mut d, GATE, 50.0);
        press(&mut d, 1, 60, 0);
        let events = collect(&mut d, 0, 60);
        let ons: Vec<usize> = events.iter().filter(|e| e.1).map(|e| e.0).collect();
        let offs: Vec<usize> = events.iter().filter(|e| !e.1).map(|e| e.0).collect();
        assert_eq!(&ons[..4], &[0, 6000, 12_000, 18_000]);
        assert_eq!(&offs[..3], &[3000, 9000, 15_000]);
    }

    #[test]
    fn swing_moves_every_second_step_later() {
        let mut d = device();
        set(&mut d, SWING, 50.0);
        press(&mut d, 1, 60, 0);
        let events = collect(&mut d, 0, 60);
        let ons: Vec<usize> = events.iter().filter(|e| e.1).map(|e| e.0).collect();
        assert_eq!(&ons[..4], &[0, 6000 + 1500, 12_000, 18_000 + 1500]);
    }

    #[test]
    fn gate_over_100_percent_overlaps_steps() {
        let mut d = device();
        set(&mut d, GATE, 150.0);
        press(&mut d, 1, 60, 0);
        let events = collect(&mut d, 0, 60);
        let offs: Vec<usize> = events.iter().filter(|e| !e.1).map(|e| e.0).collect();
        assert_eq!(offs[0], 9000);
    }

    #[test]
    fn step_one_plays_at_the_note_offset_then_continues_on_the_grid() {
        let mut d = device();
        press(&mut d, 1, 60, 100);
        let events = collect_playing(&mut d, 60);
        let ons: Vec<usize> = events.iter().filter(|e| e.1).map(|e| e.0).collect();
        assert_eq!(ons[0], 100);
        // Well over half a step before the 6000 grid point: it keeps its place.
        assert_eq!(ons[1], 6000);
    }

    #[test]
    fn adding_a_note_mid_pattern_does_not_restart_it() {
        let mut d = device();
        for (i, k) in [60u8, 64, 67].iter().enumerate() {
            press(&mut d, 1 + i as u32, *k, 0);
        }
        let first = collect(&mut d, 0, 12 * 2 + 1);
        assert_eq!(on_keys(&first), vec![60, 64, 67]);
        press(&mut d, 4, 72, 0);
        let next = collect(&mut d, 25, 12 * 2);
        // Continues at position 3 of the new set, not back at 60.
        assert_eq!(on_keys(&next)[0], 72);
    }

    #[test]
    fn a_released_key_ends_its_step_before_the_next_note_starts() {
        let mut d = device();
        press(&mut d, 1, 60, 0);
        collect(&mut d, 0, 2);
        // Legato hand-over at one frame, as at a loop wrap: off 60, on 64.
        release(&mut d, 1, 60, 100);
        press(&mut d, 2, 64, 100);
        let events = collect(&mut d, 2, 1);
        let off = events
            .iter()
            .position(|e| !e.1 && e.2 == 60)
            .expect("60 ends");
        let on = events
            .iter()
            .position(|e| e.1 && e.2 == 64)
            .expect("64 starts");
        assert!(off < on, "{events:?}");
    }

    #[test]
    fn releasing_every_key_stops_the_arpeggio() {
        let mut d = device();
        press(&mut d, 1, 60, 0);
        collect(&mut d, 0, 13);
        release(&mut d, 1, 60, 0);
        let rest = collect(&mut d, 13, 60);
        assert!(on_keys(&rest).is_empty());
    }

    #[test]
    fn a_chord_pressed_after_idling_starts_with_one_step_and_no_catch_up() {
        let mut d = device();
        press(&mut d, 1, 60, 0);
        collect(&mut d, 0, 30);
        release(&mut d, 1, 60, 0);
        collect(&mut d, 30, 10);
        // Idle, then a three-note chord (as a Chord device delivers it) at one frame.
        collect(&mut d, 40, 100);
        for (i, k) in [60u8, 64, 67].iter().enumerate() {
            press(&mut d, 10 + i as u32, *k, 123);
        }
        let events = collect(&mut d, 140, 13);
        let ons: Vec<(usize, u8)> = events.iter().filter(|e| e.1).map(|e| (e.0, e.2)).collect();
        assert_eq!(ons, vec![(140 * BLOCK + 123, 60), (140 * BLOCK + 6123, 64)]);
        // Every note-off comes after its note-on (nothing left hanging).
        for (i, on) in events.iter().enumerate().filter(|(_, e)| e.1) {
            assert!(
                !events[..i]
                    .iter()
                    .any(|e| !e.1 && e.2 == on.2 && e.0 == on.0),
                "{events:?}"
            );
        }
    }

    #[test]
    fn latch_keeps_the_chord_until_a_new_one_is_pressed() {
        let mut d = device();
        set(&mut d, LATCH, 1.0);
        press(&mut d, 1, 60, 0);
        press(&mut d, 2, 64, 0);
        release(&mut d, 1, 60, 10);
        release(&mut d, 2, 64, 10);
        let running = collect(&mut d, 0, 12 * 4);
        let keys = on_keys(&running);
        assert!(keys.len() >= 4, "the pattern stopped: {keys:?}");
        assert!(keys.iter().all(|&k| k == 60 || k == 64));
        // A new chord replaces the latched one.
        press(&mut d, 3, 67, 0);
        let after = collect(&mut d, 48, 12 * 4);
        let keys = on_keys(&after);
        assert!(!keys.is_empty());
        assert!(keys.iter().all(|&k| k == 67), "{keys:?}");
    }

    #[test]
    fn turning_latch_off_stops_a_latched_arpeggio() {
        let mut d = device();
        set(&mut d, LATCH, 1.0);
        press(&mut d, 1, 60, 0);
        release(&mut d, 1, 60, 10);
        collect(&mut d, 0, 13);
        set(&mut d, LATCH, 0.0);
        let rest = collect(&mut d, 13, 60);
        assert!(on_keys(&rest).is_empty());
    }

    #[test]
    fn a_loop_wrap_on_the_last_frame_of_a_block_does_not_repeat_the_first_step() {
        // A two-beat loop at 120 BPM wraps at sample 48000. A tick event sits on the frame
        // before its tick is reached, so the wrap (and the restarted clip note) is frame 499 of
        // block 95, while block 96's transport starts at the loop start and realigns the grid as
        // after a seek.
        let mut d = device();
        let clip = CLIP_ID_START;
        press(&mut d, clip, 60, 0);
        let mut out = Vec::new();
        for b in 0..120usize {
            let pos = if b < 96 { b * BLOCK } else { (b - 96) * BLOCK };
            d.set_transport(&Transport {
                tempo: 120.0,
                playing: true,
                song_pos_beats: pos as f64 / SR as f64 * 2.0,
                ..Transport::default()
            });
            if b == 95 {
                release(&mut d, clip, 60, BLOCK - 1);
                press(&mut d, clip + 1, 64, BLOCK - 1);
            }
            for n in d.process_notes(BLOCK) {
                if let NoteEvent::On { key, .. } = n.event {
                    out.push((b * BLOCK + n.frame, key));
                }
            }
        }
        let after_wrap: Vec<_> = out.iter().filter(|e| e.0 >= 47_000).copied().collect();
        assert_eq!(after_wrap[0], (47_999, 64));
        // The next step is the loop's second 1/16, not the loop start again.
        assert_eq!(after_wrap[1], (48_000 + 6_000, 64));
    }

    #[test]
    fn stopping_the_transport_ends_a_clip_arpeggio_but_not_a_held_key() {
        let mut d = device();
        press(&mut d, 1, 48, 0);
        press(&mut d, CLIP_ID_START + 5, 72, 0);
        collect(&mut d, 0, 13);
        release(&mut d, CLIP_ID_START + 5, 72, 0);
        d.note_discontinuity();
        let after = collect(&mut d, 13, 40);
        let keys = on_keys(&after);
        assert!(!keys.is_empty());
        assert!(keys.iter().all(|&k| k == 48), "{keys:?}");
    }

    #[test]
    fn the_note_state_stream_lists_held_keys_and_the_sounding_key() {
        let mut d = device();
        d.subscribe_data("note_state").unwrap();
        press(&mut d, 1, 67, 0);
        press(&mut d, 2, 60, 0);
        collect(&mut d, 0, 1);
        let (kind, bytes) = d.poll_device_data().unwrap();
        assert_eq!(kind, "note_state");
        // step none, sounding 60 (lowest, Up), no branch, two held keys ascending.
        assert_eq!(bytes, vec![0xFF, 60, 0xFF, 2, 60, 67]);
    }
}

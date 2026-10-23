//! The metronome (spec 053): clicks scheduled on the audio callback and mixed into the hardware
//! output after the master, like the browser preview. It is outside the channel graph, so it
//! skips master's devices and fader and never reaches the offline render (ADR 0026).
//!
//! `EngineState::metronome` owns two preallocated drum hosts (Kick for Beep, Snare for Wood), a
//! fixed-size pattern table and a small queue of triggers that are waiting for their frame.
//! `render` reads the block's tick events, queues a trigger for every step that lands on one
//! (plus the master's output delay, so the click lines up with the audio), feeds the due ones to
//! the active host and adds both hosts' output to the master's hardware pair.
//!
//! Audio-thread contract: `render` never allocates, locks, waits or logs. Everything it touches
//! is sized in `new` / `prepare` on the command thread.

pub mod pattern;
pub mod sound;

pub use pattern::{Pattern, PatternError, PatternTable, StepCursor};
pub use sound::{MetronomeSound, SoundKind};

use crate::audio::devices::{create_drum, AudioDevice};
use crate::audio::midi_types::NoteEvent;
use crate::audio::project::ProjectSettings;
use crate::audio::state::EngineState;
use crate::audio::time_signature_map::TimeSignatureMap;
use crate::audio::types::{ChannelId, Tick, HARDWARE_OUTPUT_BASE};

/// Triggers that can wait for their frame at once (the master's delay can push a click a few
/// blocks out; a full queue drops the new trigger).
const PENDING_CAPACITY: usize = 16;

/// The master channel's id.
const MASTER_ID: ChannelId = 1;

/// What the metronome needs to know about one block, borrowed from the engine state.
pub struct BlockTiming<'a> {
    /// Every tick crossed this block and its frame (`process_audio`; empty while stopped).
    pub tick_events: &'a [(Tick, usize)],
    /// Indices into `tick_events` of the first event after each loop wrap.
    pub loop_wraps: &'a [usize],
    pub sig_map: &'a TimeSignatureMap,
    pub settings: &'a ProjectSettings,
    pub playing: bool,
}

/// The metronome, part of `EngineState`.
pub struct Metronome {
    /// Beep (Kick) and Wood (Snare), indexed by [`SoundKind::index`].
    hosts: [Box<dyn AudioDevice>; 2],
    /// The note a level-4 click plays on each host.
    base_notes: [u8; 2],
    sound: MetronomeSound,
    enabled: bool,
    patterns: PatternTable,
    /// `(frames until the click, level)`, oldest first.
    pending: [(u32, u8); PENDING_CAPACITY],
    pending_len: usize,
    /// Interleaved stereo scratch for one host's block.
    scratch: Vec<f32>,
    /// Tests: absolute output frame, level and key of every click handed to a host.
    #[cfg(test)]
    pub(crate) triggers: Vec<(u64, u8, u8)>,
    #[cfg(test)]
    frames_rendered: u64,
}

impl Metronome {
    /// Build both hosts for `sample_rate` and blocks of up to `max_frames`. Command thread only.
    pub fn new(sample_rate: f32, max_frames: usize) -> Self {
        let host = |kind: SoundKind| {
            create_drum(kind.device_id(), sample_rate, max_frames)
                .expect("the kick and snare are built-in drums")
        };
        let mut metronome = Self {
            hosts: [host(SoundKind::Beep), host(SoundKind::Wood)],
            base_notes: [0; 2],
            sound: MetronomeSound::default(),
            enabled: false,
            patterns: PatternTable::default(),
            pending: [(0, 0); PENDING_CAPACITY],
            pending_len: 0,
            scratch: vec![0.0; max_frames.max(1) * 2],
            #[cfg(test)]
            triggers: Vec::new(),
            #[cfg(test)]
            frames_rendered: 0,
        };
        // Both hosts start configured, so a switch to the other sound needs no extra step.
        let sound = metronome.sound;
        for kind in [SoundKind::Beep, SoundKind::Wood] {
            metronome.base_notes[kind.index()] =
                sound::apply(metronome.hosts[kind.index()].as_mut(), kind, &sound);
            metronome.hosts[kind.index()].reset();
        }
        metronome
    }

    /// Re-prepare for a new device sample rate or block size (the stream is stopped).
    pub fn prepare(&mut self, sample_rate: f32, max_frames: usize) {
        for host in self.hosts.iter_mut() {
            host.prepare(sample_rate, max_frames);
        }
        self.scratch.resize(max_frames.max(1) * 2, 0.0);
        self.pending_len = 0;
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }

    pub fn sound(&self) -> &MetronomeSound {
        &self.sound
    }

    pub fn patterns(&self) -> &PatternTable {
        &self.patterns
    }

    /// Turn scheduling on or off. Off clears the triggers that still wait; a click that already
    /// sounds rings out.
    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
        if !enabled {
            self.pending_len = 0;
        }
    }

    /// Apply the sound knobs (clamped) to the chosen host and make it the active one. The other
    /// host keeps rendering its tail, so a switch never cuts a click.
    pub fn set_sound(&mut self, sound: MetronomeSound) {
        let sound = sound.clamped();
        let index = sound.kind.index();
        self.base_notes[index] = sound::apply(self.hosts[index].as_mut(), sound.kind, &sound);
        self.sound = sound;
    }

    /// Store a pattern for `num/den` (validated); empty `levels` remove it.
    pub fn set_pattern(
        &mut self,
        num: u16,
        den: u16,
        resolution: u8,
        levels: &[u8],
    ) -> Result<(), PatternError> {
        if levels.is_empty() {
            self.patterns.remove(num, den);
            return Ok(());
        }
        self.patterns.set(num, den, resolution, levels)
    }

    pub fn clear_patterns(&mut self) {
        self.patterns.clear();
    }

    /// Queue one click of `level` (1 to 4) at the start of the next block, playing or not.
    pub fn audition(&mut self, level: u8) {
        self.push_pending(0, level.clamp(1, 4));
    }

    fn push_pending(&mut self, frames: u32, level: u8) {
        if self.pending_len < PENDING_CAPACITY {
            self.pending[self.pending_len] = (frames, level);
            self.pending_len += 1;
        }
    }

    /// Queue the clicks for the steps crossed in this block. Each monotonic run of tick events
    /// (the block start and every loop wrap) restarts the step cursor with one signature lookup;
    /// inside a run the ticks step by one, so equality with the cursor's tick can't skip a step.
    fn schedule(&mut self, block: &BlockTiming, delay: u32) {
        let mut cursor: Option<StepCursor> = None;
        let mut next_wrap = 0usize;
        for (i, &(tick, frame)) in block.tick_events.iter().enumerate() {
            let wrapped = block.loop_wraps.get(next_wrap) == Some(&i);
            if wrapped {
                next_wrap += 1;
            }
            if cursor.is_none() || wrapped {
                cursor = Some(StepCursor::at_or_after(
                    tick,
                    block.sig_map,
                    block.settings,
                    &self.patterns,
                ));
            }
            let Some(step) = cursor.as_mut() else {
                continue;
            };
            if tick == step.tick {
                let level = step.level;
                step.advance(block.sig_map, block.settings, &self.patterns);
                if level > 0 {
                    self.push_pending(frame as u32 + delay, level);
                }
            }
        }
    }

    /// Hand the triggers that fall inside this block to the active host; the rest move closer.
    fn dispatch(&mut self, frames: usize) {
        let index = self.sound.kind.index();
        let mut kept = 0;
        for i in 0..self.pending_len {
            let (frames_left, level) = self.pending[i];
            if (frames_left as usize) < frames {
                let key = sound::note_for_level(
                    self.base_notes[index],
                    self.sound.emphasis_pitch_st,
                    level,
                );
                let velocity = sound::velocity_for_level(&self.sound, level);
                self.hosts[index].send_note_event(
                    &NoteEvent::On {
                        note_id: 0,
                        key,
                        velocity,
                    },
                    frames_left as usize,
                );
                #[cfg(test)]
                self.triggers
                    .push((self.frames_rendered + frames_left as u64, level, key));
            } else {
                self.pending[kept] = (frames_left - frames as u32, level);
                kept += 1;
            }
        }
        self.pending_len = kept;
    }

    /// Schedule this block's clicks and add the hosts' output into `data` (interleaved,
    /// `channels` wide) on hardware pair `pair`, after the master. `delay` is master's output
    /// delay in frames (`latency.hw_delay`).
    pub fn render(
        &mut self,
        block: &BlockTiming,
        data: &mut [f32],
        channels: usize,
        pair: usize,
        delay: u32,
    ) {
        let channels = channels.max(1);
        let frames = (data.len() / channels).min(self.scratch.len() / 2);
        if frames == 0 {
            return;
        }
        if self.enabled && block.playing {
            self.schedule(block, delay);
        }
        self.dispatch(frames);

        let pairs = (channels / 2).max(1);
        let first = if pair < pairs { pair * 2 } else { 0 };
        for host in self.hosts.iter_mut() {
            if host.is_sleeping() {
                continue;
            }
            host.process_block(&[], &mut self.scratch[..frames * 2], frames);
            for frame in 0..frames {
                let (left, right) = (self.scratch[frame * 2], self.scratch[frame * 2 + 1]);
                let base = frame * channels;
                if channels >= 2 {
                    data[base + first] = (data[base + first] + left).clamp(-1.0, 1.0);
                    data[base + first + 1] = (data[base + first + 1] + right).clamp(-1.0, 1.0);
                } else {
                    data[base] = (data[base] + (left + right) * 0.5).clamp(-1.0, 1.0);
                }
            }
        }
        #[cfg(test)]
        {
            self.frames_rendered += frames as u64;
        }
    }
}

/// Render the metronome for the block `process_audio` just prepared, into the interleaved
/// hardware buffer `data`: reads the tick events from `render_scratch`, the output pair and
/// delay from the master channel. Called by the live callback after the master and the preview.
pub fn render_block(state: &mut EngineState, data: &mut [f32], channels: usize) {
    let (pair, delay) = match state.channels.get(&MASTER_ID) {
        Some(master) => (
            master
                .output_channel_id
                .filter(|&id| id >= HARDWARE_OUTPUT_BASE)
                .map_or(0, |id| (id - HARDWARE_OUTPUT_BASE) as usize),
            master.latency.hw_delay,
        ),
        None => (0, 0),
    };
    let playing = state.get_is_playing();
    let EngineState {
        metronome,
        render_scratch,
        time_signature_map,
        settings,
        ..
    } = state;
    let block = BlockTiming {
        tick_events: &render_scratch.tick_events,
        loop_wraps: &render_scratch.loop_wraps,
        sig_map: time_signature_map,
        settings,
        playing,
    };
    metronome.render(&block, data, channels, pair, delay);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::commands::{process_command, AudioCommand, CommandEffects};
    use crate::audio::processing::{frames_before_tick, process_audio};
    use crate::audio::tempo_map::TempoMap;
    use std::time::Instant;

    const SR: f32 = 48_000.0;

    fn command(state: &mut EngineState, cmd: AudioCommand) {
        let mut effects = CommandEffects::default();
        process_command(state, cmd, 64, &mut effects);
    }

    /// A playing state at `tick` with the metronome on, as `Play` leaves it.
    fn playing_state(tick: Tick) -> EngineState {
        let mut state = EngineState::default();
        state.device_sample_rate = SR;
        state.set_current_tick(tick);
        command(&mut state, AudioCommand::SetMetronomeEnabled(true));
        command(&mut state, AudioCommand::Play);
        state
    }

    /// One live block without channels: `process_audio`, then the metronome into a silent buffer.
    fn run_block(state: &mut EngineState, frames: usize) -> Vec<f32> {
        let mut data = vec![0.0f32; frames * 2];
        process_audio(state, frames, SR, Instant::now());
        render_block(state, &mut data, 2);
        data
    }

    /// Run blocks of `block` frames until at least `total` frames passed; the left channel.
    fn run(state: &mut EngineState, block: usize, total: usize) -> Vec<f32> {
        let mut left = Vec::new();
        while left.len() < total {
            let data = run_block(state, block);
            left.extend(data.chunks(2).map(|f| f[0]));
        }
        left
    }

    fn frames_of(state: &EngineState) -> Vec<u64> {
        state.metronome.triggers.iter().map(|t| t.0).collect()
    }

    fn levels_of(state: &EngineState) -> Vec<u8> {
        state.metronome.triggers.iter().map(|t| t.1).collect()
    }

    /// First frame at or after `from` where the signal leaves silence.
    fn onset(samples: &[f32], from: usize) -> usize {
        from + samples[from..]
            .iter()
            .position(|s| s.abs() > 1e-4)
            .expect("a click")
    }

    #[test]
    fn clicks_on_exact_frames_across_block_sizes() {
        for block in [64usize, 256, 1024] {
            let mut state = playing_state(0);
            let out = run(&mut state, block, 80_000);
            assert_eq!(
                frames_of(&state)[..4],
                [0, 23_999, 47_999, 71_999],
                "block size {block}"
            );
            assert_eq!(
                levels_of(&state)[..4],
                [4, 2, 2, 2],
                "accent on the downbeat"
            );
            // The audio starts where the trigger log says (the voice's first samples are tiny).
            // A beat tick completes on the last frame of its 24 000 (the same frame clip MIDI
            // gets), so the clicks sit at 23 999, 47 999 and 71 999.
            for frame in [0usize, 23_999, 47_999, 71_999] {
                let start = onset(&out, frame);
                assert!(
                    start - frame <= 3,
                    "block {block}: click at {frame} starts at {start}"
                );
                // And the quiet before it is exact silence once the previous click has died.
                if frame > 0 {
                    assert!(out[frame - 1].abs() < 1e-3);
                }
            }
        }
    }

    #[test]
    fn seek_while_playing_neither_misses_nor_doubles_a_click() {
        let mut state = playing_state(0);
        run(&mut state, 256, 1024);
        // Seek exactly onto beat 3: its click plays once, at frame 0 of the next block.
        state.set_current_tick(1920);
        state.set_fractional_tick_accumulator(0.0);
        state.request_playhead_midi_dispatch();
        let before = state.metronome.triggers.len();
        let frames = state.metronome.frames_rendered;
        run(&mut state, 256, 512);
        let new = &state.metronome.triggers[before..];
        assert_eq!(new.len(), 1);
        assert_eq!(new[0].0, frames);
        assert_eq!(new[0].1, 2);
    }

    #[test]
    fn loop_wrap_replays_downbeat() {
        // Loop bar 2 (ticks 3840..7680 = 96 000 frames at 120 BPM), starting inside it.
        let mut state = playing_state(3840);
        state.loop_region = Some((3840, 7680));
        run(&mut state, 500, 280_000);
        let downbeats: Vec<u64> = state
            .metronome
            .triggers
            .iter()
            .filter(|t| t.1 == 4)
            .map(|t| t.0)
            .collect();
        assert_eq!(downbeats.len(), 3, "{downbeats:?}");
        // The first is the playhead tick itself (frame 0); each wrap's loop-start tick completes
        // on the last frame of the loop's 96 000.
        assert_eq!(downbeats, [0, 95_999, 191_999]);
        // Four beats a loop, no extra or missing clicks between the downbeats.
        let in_first_loop = frames_of(&state).iter().filter(|&&f| f < 95_999).count();
        assert_eq!(in_first_loop, 4);
    }

    #[test]
    fn signature_change_uses_the_bar_pattern() {
        // 4/4 for bar 1, 3/4 from bar 2 with its own pattern: accent, off, soft.
        let mut state = playing_state(0);
        state.time_signature_map = TimeSignatureMap::from_changes(vec![(2, 3, 4)]);
        command(
            &mut state,
            AudioCommand::SetMetronomePattern {
                num: 3,
                den: 4,
                resolution: 4,
                levels: vec![3, 0, 1],
            },
        );
        run(&mut state, 1024, 8 * 24_000 + 1);
        // Bar 1: 4 2 2 2 (default 4/4); bar 2: 3 _ 1 (its own pattern); bar 3 repeats bar 2.
        assert_eq!(levels_of(&state), [4, 2, 2, 2, 3, 1, 3]);
        assert_eq!(frames_of(&state)[4], 4 * 24_000 - 1, "the bar-2 downbeat");
        assert_eq!(
            frames_of(&state)[5],
            6 * 24_000 - 1,
            "its third beat; the second is Off"
        );
    }

    #[test]
    fn tempo_ramp_clicks_on_beat_ticks() {
        // 100 BPM ramping to 200 over four beats, then held.
        let mut state = playing_state(0);
        state.tempo_map = TempoMap::from_points(vec![(0, 100.0), (3840, 200.0)]);
        let total = 120_000;
        run(&mut state, 333, total);
        let logged = frames_of(&state);
        assert!(logged.len() >= 6, "{logged:?}");

        // Where `frames_before_tick` puts each beat tick on a fresh run of the same song.
        let mut probe = EngineState::default();
        probe.device_sample_rate = SR;
        probe.tempo_map = state.tempo_map.clone();
        let (mut rates, mut events) = (Vec::new(), Vec::new());
        for (i, &frame) in logged.iter().enumerate() {
            let tick = 960 * i as Tick;
            if tick == 0 {
                assert_eq!(frame, 0);
                continue;
            }
            let expected = frames_before_tick(&probe, tick, total, SR, &mut rates, &mut events);
            assert_eq!(frame as usize, expected, "beat {i} at tick {tick}");
        }
    }

    #[test]
    fn silent_when_stopped_or_disabled_and_tail_rings() {
        // Stopped: tick events are empty, so nothing triggers; enabled makes no difference.
        let mut state = EngineState::default();
        state.device_sample_rate = SR;
        command(&mut state, AudioCommand::SetMetronomeEnabled(true));
        let out = run(&mut state, 512, 50_000);
        assert!(state.metronome.triggers.is_empty());
        assert!(out.iter().all(|&s| s == 0.0));
        // The transport flag alone gates scheduling, whatever the tick list holds.
        let events = [(0 as Tick, 0usize)];
        let settings = ProjectSettings::default();
        let map = TimeSignatureMap::default();
        let mut block = BlockTiming {
            tick_events: &events,
            loop_wraps: &[],
            sig_map: &map,
            settings: &settings,
            playing: false,
        };
        let mut data = vec![0.0f32; 512 * 2];
        state.metronome.render(&block, &mut data, 2, 0, 0);
        assert!(state.metronome.triggers.is_empty());

        // Playing: the click at frame 0 sounds; disabling then keeps the tail ringing without a
        // hard cut and schedules nothing more.
        block.playing = true;
        let start = state.metronome.frames_rendered;
        state.metronome.render(&block, &mut data, 2, 0, 0);
        assert_eq!(frames_of(&state), [start]);
        let first: Vec<f32> = data.chunks(2).map(|f| f[0]).collect();
        let slope = first
            .windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0, f32::max);
        state.metronome.set_enabled(false);
        let mut next = vec![0.0f32; 512 * 2];
        let empty = BlockTiming {
            tick_events: &events,
            ..block
        };
        state.metronome.render(&empty, &mut next, 2, 0, 0);
        assert_eq!(
            state.metronome.triggers.len(),
            1,
            "no new trigger after disable"
        );
        let second: Vec<f32> = next.chunks(2).map(|f| f[0]).collect();
        assert!(second.iter().any(|s| s.abs() > 1e-3), "the click rings out");
        let seam = (second[0] - first[first.len() - 1]).abs();
        assert!(
            seam <= slope * 1.5 + 1e-4,
            "seam {seam} vs click slope {slope}"
        );
    }

    #[test]
    fn disable_clears_waiting_triggers() {
        let mut m = Metronome::new(SR, 512);
        let settings = ProjectSettings::default();
        let map = TimeSignatureMap::default();
        m.set_enabled(true);
        let events = [(0 as Tick, 0usize)];
        let block = BlockTiming {
            tick_events: &events,
            loop_wraps: &[],
            sig_map: &map,
            settings: &settings,
            playing: true,
        };
        let mut data = vec![0.0f32; 256 * 2];
        // A 5000-frame delay keeps the click waiting.
        m.render(&block, &mut data, 2, 0, 5000);
        assert!(m.triggers.is_empty());
        m.set_enabled(false);
        let idle = BlockTiming {
            tick_events: &[],
            ..block
        };
        for _ in 0..40 {
            m.render(&idle, &mut data, 2, 0, 5000);
        }
        assert!(m.triggers.is_empty());
    }

    #[test]
    fn audition_plays_while_stopped_and_even_when_disabled() {
        let mut state = EngineState::default();
        state.device_sample_rate = SR;
        state.metronome.audition(4);
        state.metronome.audition(1);
        let out = run(&mut state, 256, 1024);
        assert_eq!(state.metronome.triggers.len(), 2);
        assert_eq!(state.metronome.triggers[0].0, 0);
        assert!(out.iter().any(|s| s.abs() > 1e-3));
        // Quarter levels differ in key (pitch) and the first is the louder.
        assert!(state.metronome.triggers[0].2 > state.metronome.triggers[1].2);
    }

    #[test]
    fn delayed_by_master_hw_delay() {
        let settings = ProjectSettings::default();
        let map = TimeSignatureMap::default();
        let events = [(0 as Tick, 100usize)];
        for delay in [0u32, 150, 700] {
            let mut m = Metronome::new(SR, 512);
            m.set_enabled(true);
            let block = BlockTiming {
                tick_events: &events,
                loop_wraps: &[],
                sig_map: &map,
                settings: &settings,
                playing: true,
            };
            let idle = BlockTiming {
                tick_events: &[],
                ..block
            };
            let mut out = Vec::new();
            let mut data = vec![0.0f32; 256 * 2];
            m.render(&block, &mut data, 2, 0, delay);
            out.extend(data.chunks(2).map(|f| f[0]));
            for _ in 0..4 {
                data.fill(0.0);
                m.render(&idle, &mut data, 2, 0, delay);
                out.extend(data.chunks(2).map(|f| f[0]));
            }
            let expected = 100 + delay as usize;
            assert_eq!(
                m.triggers,
                vec![(expected as u64, 4, m.triggers[0].2)],
                "delay {delay}"
            );
            let start = onset(&out, 0);
            assert!(
                (expected..=expected + 3).contains(&start),
                "delay {delay}: onset {start}"
            );
        }
    }

    #[test]
    fn mixes_into_the_requested_pair_and_adds_to_the_buffer() {
        let mut m = Metronome::new(SR, 512);
        m.audition(4);
        let settings = ProjectSettings::default();
        let map = TimeSignatureMap::default();
        let block = BlockTiming {
            tick_events: &[],
            loop_wraps: &[],
            sig_map: &map,
            settings: &settings,
            playing: false,
        };
        // Four hardware channels, pair 1 (channels 3/4), with 0.1 already there.
        let mut data = vec![0.1f32; 512 * 4];
        m.render(&block, &mut data, 4, 1, 0);
        let pair0_changed = data.chunks(4).any(|f| f[0] != 0.1 || f[1] != 0.1);
        let pair1_changed = data.chunks(4).any(|f| f[2] != 0.1 && f[3] != 0.1);
        assert!(!pair0_changed);
        assert!(pair1_changed);
        // A pair the device doesn't have falls back to 1/2.
        let mut m = Metronome::new(SR, 512);
        m.audition(4);
        let mut data = vec![0.0f32; 512 * 2];
        m.render(&block, &mut data, 2, 7, 0);
        assert!(data.iter().any(|s| s.abs() > 1e-3));
    }

    #[test]
    fn sound_switch_lets_the_old_click_ring() {
        let mut state = EngineState::default();
        state.device_sample_rate = SR;
        state.metronome.audition(4);
        let first = run(&mut state, 256, 256);
        assert!(first.iter().any(|s| s.abs() > 1e-3));
        state.metronome.set_sound(MetronomeSound {
            kind: SoundKind::Wood,
            ..MetronomeSound::default()
        });
        let tail = run(&mut state, 256, 256);
        assert!(
            tail.iter().any(|s| s.abs() > 1e-4),
            "the Beep tail keeps sounding after the switch"
        );
        // And a trigger now plays on the Wood host.
        state.metronome.audition(4);
        let wood = run(&mut state, 256, 256);
        assert!(wood.iter().any(|s| s.abs() > 1e-3));
    }

    #[test]
    fn pending_queue_drops_when_full() {
        let mut m = Metronome::new(SR, 512);
        for _ in 0..40 {
            m.audition(4);
        }
        assert_eq!(m.pending_len, PENDING_CAPACITY);
    }
}

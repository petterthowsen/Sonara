//! `StepClock` (spec 027 REQ-021, REQ-026): when the steps of a clocked note effect fall.
//!
//! - WHILE the transport plays, steps sit on the transport's grid of `rate` quarter-note beats,
//!   found from the block's `song_pos_beats`, `tempo` and `tempo_inc`, so they follow tempo
//!   changes. The grid is re-read every block, so nothing drifts.
//! - WHILE it is stopped, steps free-run at the project tempo from an anchor set by
//!   [`StepClock::start_at`].
//!
//! Rates are the tempo-sync divisions from 1/1 down ([`RATE_CHOICES`]).
//!
//! Odd step indices are delayed by `swing × rate / 2`. All times are absolute samples, in the
//! same count the note-effect host uses.

use crate::audio::dsp::tempo_sync::{index_of, sync_beats, SYNC_CHOICES};
use crate::audio::transport::Transport;

/// The Rate enum of the clocked effects: the sync divisions from `1/1` onwards, without Off.
pub const RATE_CHOICES: &[&str] = SYNC_CHOICES.split_at(RATE_FIRST).1;
const RATE_FIRST: usize = 7;

/// Default Rate index: 1/16.
pub const RATE_DEFAULT: f32 = (index_of("1/16") - RATE_FIRST) as f32;

/// A Rate choice index in quarter-note beats.
pub fn rate_to_beats(choice: usize) -> f64 {
    sync_beats(choice + RATE_FIRST).unwrap_or(0.25)
}

/// Moves of the song position smaller than this (beats) are continuity, not a seek.
const SEEK_TOLERANCE_BEATS: f64 = 0.02;
/// Guards `ceil` against grid points that are a rounding error away.
const GRID_EPSILON: f64 = 1e-6;

/// One step start.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Step {
    /// Absolute sample the step starts at.
    pub at: u64,
    /// Grid index (`floor(beat / rate)` while playing, counted from the anchor while stopped).
    pub index: i64,
}

pub struct StepClock {
    sample_rate: f64,
    rate_beats: f64,
    swing: f64,
    transport: Transport,

    /// Start sample of the block last seen, and the transport it had (continuity check).
    block_now: Option<u64>,
    last_playing: bool,
    last_pos: f64,
    last_tempo: f64,
    last_inc: f64,
    /// Rate or sample rate changed: realign at the next block.
    dirty: bool,

    /// Index of the next step to hand out.
    next_k: i64,
    /// Absolute sample of the last step played (handed out or started with `start_at`).
    last_step: Option<u64>,
    /// Free-running: unswung start sample of step `next_k`.
    free_base: f64,
    free_active: bool,
}

impl StepClock {
    pub fn new(sample_rate: f32) -> Self {
        Self {
            sample_rate: sample_rate as f64,
            rate_beats: 0.25,
            swing: 0.0,
            transport: Transport {
                tempo: 120.0,
                ..Transport::default()
            },
            block_now: None,
            last_playing: false,
            last_pos: 0.0,
            last_tempo: 120.0,
            last_inc: 0.0,
            dirty: false,
            next_k: 0,
            last_step: None,
            free_base: 0.0,
            free_active: false,
        }
    }

    pub fn set_transport(&mut self, transport: &Transport) {
        self.transport = *transport;
    }

    pub fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate as f64;
        self.dirty = true;
    }

    /// Step length in quarter-note beats.
    pub fn set_rate_beats(&mut self, beats: f64) {
        if (beats - self.rate_beats).abs() > f64::EPSILON {
            self.rate_beats = beats.max(1e-3);
            self.dirty = true;
        }
    }

    /// 0..=0.75: the fraction of half a step odd steps are delayed by.
    pub fn set_swing(&mut self, swing: f32) {
        self.swing = swing as f64;
    }

    /// Forget all state: the next block realigns, and a stopped clock waits for `start_at`.
    pub fn reset(&mut self) {
        self.block_now = None;
        self.last_step = None;
        self.free_active = false;
        self.dirty = false;
    }

    /// The step length in samples at the current tempo.
    pub fn step_samples(&self) -> f64 {
        self.rate_beats * 60.0 / self.transport.tempo.max(1.0) * self.sample_rate
    }

    /// Beats advanced over `n` samples from a block start with tempo `tempo` and ramp `inc`.
    fn beats_over(&self, tempo: f64, inc: f64, n: f64) -> f64 {
        (tempo * n + 0.5 * inc * n * n) / (60.0 * self.sample_rate)
    }

    /// Samples after the block start at which the block reaches `delta` beats past its start.
    fn samples_for(&self, delta: f64) -> f64 {
        if delta <= 0.0 {
            return 0.0;
        }
        let t = &self.transport;
        let b = t.tempo.max(1.0) / (60.0 * self.sample_rate);
        let a = t.tempo_inc / (2.0 * 60.0 * self.sample_rate);
        if a.abs() < 1e-18 {
            return delta / b;
        }
        let disc = b * b + 4.0 * a * delta;
        if disc <= 0.0 {
            return delta / b;
        }
        (-b + disc.sqrt()) / (2.0 * a)
    }

    fn swing_beats(&self, k: i64) -> f64 {
        if k.rem_euclid(2) == 1 {
            self.swing * self.rate_beats * 0.5
        } else {
            0.0
        }
    }

    /// First grid index at or after `beat`.
    fn index_at_or_after(&self, beat: f64) -> i64 {
        (beat / self.rate_beats - GRID_EPSILON).ceil() as i64
    }

    /// Absolute start sample of grid step `k` while playing.
    fn playing_step_at(&self, now: u64, k: i64) -> u64 {
        let beat = k as f64 * self.rate_beats + self.swing_beats(k);
        let delta = beat - self.transport.song_pos_beats;
        now + self.samples_for(delta).round() as u64
    }

    /// Per-block bookkeeping, done on the first query of each block.
    fn begin_block(&mut self, now: u64) {
        if self.block_now == Some(now) {
            return;
        }
        let t = self.transport;
        let continuous = match self.block_now {
            Some(prev) if now > prev => {
                let expected = self.last_pos
                    + self.beats_over(self.last_tempo, self.last_inc, (now - prev) as f64);
                (t.song_pos_beats - expected).abs() <= SEEK_TOLERANCE_BEATS
            }
            _ => false,
        };
        let mode_changed = self.block_now.is_some() && t.playing != self.last_playing;
        if t.playing {
            if !continuous || mode_changed || self.dirty {
                self.next_k = self.index_at_or_after(t.song_pos_beats);
                // A loop wrap inside the last block looks like a seek here, and the step the
                // wrap restarted on may already have played a sample or so ago: don't repeat it.
                if let Some(last) = self.last_step {
                    let grid = self.playing_step_at(now, self.next_k);
                    if (grid.saturating_sub(last) as f64) < self.step_samples() * 0.5 {
                        self.next_k += 1;
                    }
                }
            }
        } else if mode_changed {
            self.free_base = now as f64 + self.step_samples();
            self.next_k = 1;
            self.free_active = true;
        } else if self.dirty && self.free_active {
            // Keep the phase: the next step is the first one on the new spacing after now.
            let step = self.step_samples().max(1.0);
            let ahead = ((now as f64 - self.free_base) / step).ceil().max(0.0);
            self.free_base += ahead * step;
            self.next_k += ahead as i64;
        }
        self.dirty = false;
        self.block_now = Some(now);
        self.last_playing = t.playing;
        self.last_pos = t.song_pos_beats;
        self.last_tempo = t.tempo;
        self.last_inc = t.tempo_inc;
    }

    /// A step was played at `at`, out of the grid (an arpeggio or sequence starting on its
    /// first key). WHILE playing, the next step stays on the grid, except that a grid point
    /// less than half a step after `at` is skipped so there is no double hit. WHILE stopped,
    /// the next step comes a full step after `at`. `now` is the block start.
    pub fn start_at(&mut self, now: u64, at: u64) {
        self.begin_block(now);
        let t = self.transport;
        if t.playing {
            let beat = t.song_pos_beats + self.beats_over(t.tempo, t.tempo_inc, (at - now) as f64);
            let mut k = self.index_at_or_after(beat);
            let grid = self.playing_step_at(now, k);
            let half = self.step_samples() * 0.5;
            if ((grid.saturating_sub(at)) as f64) < half {
                k += 1;
            }
            self.next_k = k;
        } else {
            self.free_base = at as f64 + self.step_samples();
            self.next_k = 1;
            self.free_active = true;
        }
        self.last_step = Some(at);
    }

    /// Swung start sample of free-running step `next_k`.
    fn free_step_at(&self) -> u64 {
        (self.free_base
            + self.swing_beats(self.next_k) * 60.0 / self.transport.tempo.max(1.0)
                * self.sample_rate)
            .round() as u64
    }

    /// Align to the grid without playing a step now: the next step is the first grid point at
    /// or after `at` (the Step Sequencer's start while playing). Does nothing while stopped.
    #[allow(dead_code)] // The Step Sequencer (wave 3) uses it.
    pub fn sync_to_grid(&mut self, now: u64, at: u64) {
        self.begin_block(now);
        let t = self.transport;
        if t.playing {
            let beat = t.song_pos_beats + self.beats_over(t.tempo, t.tempo_inc, (at - now) as f64);
            self.next_k = self.index_at_or_after(beat);
        }
    }

    /// Whether the clock is stepping on the transport's grid (the transport plays).
    #[allow(dead_code)]
    pub fn on_grid(&self) -> bool {
        self.transport.playing
    }

    /// The next step starting before `until` (the block starts at `now`), or None.
    pub fn next(&mut self, now: u64, until: u64) -> Option<Step> {
        self.begin_block(now);
        let at = if self.transport.playing {
            self.playing_step_at(now, self.next_k)
        } else if self.free_active {
            // Never hand out a step from before the block (a stale anchor): skip ahead to the
            // first step at or after `now`, keeping the phase.
            let step = self.step_samples().max(1.0);
            if self.free_base + step <= now as f64 {
                let behind = ((now as f64 - self.free_base) / step).floor();
                self.free_base += behind * step;
                self.next_k += behind as i64;
            }
            if self.free_step_at() < now {
                self.free_base += step;
                self.next_k += 1;
            }
            self.free_step_at()
        } else {
            return None;
        };
        if at >= until {
            return None;
        }
        let step = Step {
            at,
            index: self.next_k,
        };
        self.next_k += 1;
        self.last_step = Some(at);
        if !self.transport.playing {
            self.free_base += self.step_samples();
        }
        Some(step)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::tempo_map::TempoMap;
    use crate::audio::time_signature_map::TimeSignatureMap;
    use crate::audio::types::ProjectSettings;

    const SR: f32 = 48_000.0;
    const BLOCK: u64 = 256;

    fn transport_at(map: &TempoMap, tick: f64, playing: bool) -> Transport {
        Transport::at(
            map,
            &TimeSignatureMap::default(),
            &ProjectSettings::default(),
            tick,
            SR,
            playing,
        )
    }

    /// Run the clock over `blocks` blocks of the stopped transport and collect step starts.
    fn run_stopped(clock: &mut StepClock, blocks: u64) -> Vec<Step> {
        let map = TempoMap::default();
        let mut steps = Vec::new();
        for b in 0..blocks {
            clock.set_transport(&transport_at(&map, 0.0, false));
            let now = b * BLOCK;
            while let Some(step) = clock.next(now, now + BLOCK) {
                steps.push(step);
            }
        }
        steps
    }

    #[test]
    fn sixteenth_steps_at_120_bpm_are_6000_frames_apart() {
        let mut clock = StepClock::new(SR);
        clock.set_rate_beats(0.25);
        let map = TempoMap::default();
        clock.set_transport(&transport_at(&map, 0.0, false));
        clock.start_at(0, 100);
        let steps = run_stopped_from(&mut clock);
        let ats: Vec<u64> = steps.iter().take(5).map(|s| s.at).collect();
        assert_eq!(ats, vec![6100, 12_100, 18_100, 24_100, 30_100]);
    }

    /// Run a clock that already started over 200 stopped blocks.
    fn run_stopped_from(clock: &mut StepClock) -> Vec<Step> {
        let map = TempoMap::default();
        let mut steps = Vec::new();
        for b in 0..200u64 {
            clock.set_transport(&transport_at(&map, 0.0, false));
            let now = b * BLOCK;
            while let Some(step) = clock.next(now, now + BLOCK) {
                steps.push(step);
            }
        }
        steps
    }

    #[test]
    fn swing_delays_odd_steps_by_a_fraction_of_half_a_step() {
        let mut clock = StepClock::new(SR);
        clock.set_rate_beats(0.25);
        clock.set_swing(0.5);
        let map = TempoMap::default();
        clock.set_transport(&transport_at(&map, 0.0, false));
        clock.start_at(0, 0);
        let steps = run_stopped_from(&mut clock);
        // Step 0 played at the anchor; steps 1, 2, 3 follow.
        assert_eq!(steps[0].index, 1);
        assert_eq!(steps[0].at, 6000 + 1500);
        assert_eq!(steps[1].at, 12_000);
        assert_eq!(steps[2].at, 18_000 + 1500);
    }

    #[test]
    fn playing_steps_sit_on_multiples_of_240_ticks() {
        let mut clock = StepClock::new(SR);
        clock.set_rate_beats(0.25);
        let map = TempoMap::default();
        let ppq = ProjectSettings::default().ppq as f64;
        let ticks_per_sample = 120.0 * ppq / (60.0 * SR as f64);
        let mut steps = Vec::new();
        for b in 0..400u64 {
            let now = b * BLOCK;
            clock.set_transport(&transport_at(&map, now as f64 * ticks_per_sample, true));
            while let Some(step) = clock.next(now, now + BLOCK) {
                steps.push(step);
            }
        }
        assert!(steps.len() > 8);
        for step in &steps {
            let tick = step.at as f64 * ticks_per_sample;
            let nearest = (tick / 240.0).round() * 240.0;
            // One sample is 0.04 ticks.
            assert!(
                (tick - nearest).abs() < 0.1,
                "step at {} = tick {tick}",
                step.at
            );
        }
        let first = steps[0].at;
        assert_eq!(first, 0);
        assert_eq!(steps[1].at, 6000);
    }

    #[test]
    fn a_tempo_ramp_keeps_the_grid_within_a_frame_over_four_bars() {
        // 60 → 120 BPM over the first four beats, then 120.
        let map = TempoMap::from_points(vec![(0, 60.0), (3840, 120.0), (15360, 120.0)]);
        let ppq = ProjectSettings::default().ppq as f64;
        let mut clock = StepClock::new(SR);
        clock.set_rate_beats(0.25);
        // Walk the transport along the ramp with an exact integrator.
        let mut tick = 0.0f64;
        let mut now = 0u64;
        let mut steps = Vec::new();
        while tick < 4.0 * 4.0 * ppq {
            let t = transport_at(&map, tick, true);
            clock.set_transport(&t);
            while let Some(step) = clock.next(now, now + BLOCK) {
                steps.push(step);
            }
            // The next block's start: advance by integrating the map sample by sample.
            for _ in 0..BLOCK {
                let bpm = map.bpm_at(tick, 120.0);
                tick += bpm * ppq / (60.0 * SR as f64);
            }
            now += BLOCK;
        }
        // Analytic position: during the ramp T(b) = 60 + 15 b, t(b) = 4 ln(T/60) seconds.
        for step in steps.iter().take_while(|s| s.index <= 16) {
            let beat = step.index as f64 * 0.25;
            let seconds = if beat <= 4.0 {
                4.0 * (1.0 + 0.25 * beat).ln()
            } else {
                4.0 * 2f64.ln() + (beat - 4.0) * 0.5
            };
            let expected = seconds * SR as f64;
            assert!(
                (step.at as f64 - expected).abs() <= 1.5,
                "step {} at {} expected {expected}",
                step.index,
                step.at
            );
        }
        assert!(steps.len() > 40);
    }

    #[test]
    fn a_start_just_before_a_grid_point_skips_that_point() {
        let mut clock = StepClock::new(SR);
        clock.set_rate_beats(0.25);
        let map = TempoMap::default();
        // Block starts on the grid at tick 0; the anchor is 5 frames before the 6000 point.
        clock.set_transport(&transport_at(&map, 0.0, true));
        clock.start_at(0, 5995);
        let first = clock.next(0, 20_000).unwrap();
        assert_eq!(first.at, 12_000, "the point at 6000 should be skipped");

        // A start well before the point keeps it.
        let mut clock = StepClock::new(SR);
        clock.set_rate_beats(0.25);
        clock.set_transport(&transport_at(&map, 0.0, true));
        clock.start_at(0, 100);
        assert_eq!(clock.next(0, 20_000).unwrap().at, 6000);
    }

    #[test]
    fn an_idle_stopped_clock_gives_no_steps() {
        let mut clock = StepClock::new(SR);
        assert!(run_stopped(&mut clock, 50).is_empty());
    }

    #[test]
    fn a_stale_free_running_anchor_gives_no_steps_in_the_past() {
        let mut clock = StepClock::new(SR);
        let map = TempoMap::default();
        clock.set_transport(&transport_at(&map, 0.0, false));
        clock.start_at(0, 0);
        // Asked again long after its anchor, it skips to the first step not before the block.
        let now = 100 * BLOCK;
        let step = clock.next(now, now + 6000).unwrap();
        assert!(step.at >= now, "{step:?}");
        assert_eq!(step.at % 6000, 0, "phase kept");
    }
}

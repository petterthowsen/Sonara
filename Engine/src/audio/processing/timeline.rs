//! Tick timeline: turns per-frame tick rates into the ticks crossed inside a buffer, with loop
//! wrapping.

use crate::audio::state::EngineState;
use crate::audio::tempo_map::fill_tick_rates;
use crate::audio::types::*;

/// Frames the transport can play from the current playhead (at most `max_frames`) before
/// `target`'s MIDI would be dispatched. Runs the same tick arithmetic as `process_audio`, so
/// stopping after that many frames plays everything before `target` and nothing at it. The
/// offline renderer uses it to end a range exactly; it allocates into the given scratch.
pub fn frames_before_tick(
    state: &EngineState,
    target: Tick,
    max_frames: usize,
    sample_rate: f32,
    rates: &mut Vec<f64>,
    events: &mut Vec<(Tick, usize)>,
) -> usize {
    let start_tick = state.get_current_tick();
    if start_tick >= target {
        return 0;
    }
    let acc = state.get_fractional_tick_accumulator();
    fill_tick_rates(
        &state.tempo_map,
        &state.settings,
        start_tick as f64 + acc,
        max_frames,
        sample_rate,
        rates,
    );
    // The start tick itself is below `target`, so whether it's re-emitted doesn't matter.
    collect_tick_events(start_tick, acc, max_frames, rates, false, events);
    events
        .iter()
        .find(|&&(tick, _)| tick >= target)
        .map_or(max_frames, |&(_, frame)| frame)
}

/// Tick rate for `frame_idx`, holding the last rate for frames past the preallocated slice.
pub(super) fn frame_rate_at(rates: &[f64], frame_idx: usize) -> f64 {
    rates
        .get(frame_idx)
        .or_else(|| rates.last())
        .copied()
        .unwrap_or(0.0)
}

/// Record each newly crossed tick and its sample offset inside this buffer.
///
/// The playhead tick is only emitted after play/seek (`emit_start_tick`). Later buffers must
/// not emit it again: it was already the last tick of the previous buffer, and re-firing it
/// double-triggers note on/off at buffer boundaries.
fn collect_tick_events(
    start_tick: Tick,
    acc: f64,
    frame_count: usize,
    tick_rates: &[f64],
    emit_start_tick: bool,
    tick_events: &mut Vec<(Tick, usize)>,
) -> (Tick, f64) {
    collect_tick_events_looped(
        start_tick,
        acc,
        frame_count,
        tick_rates,
        emit_start_tick,
        None,
        tick_events,
        &mut Vec::new(),
    )
}

/// Advance `tick` by `inc`, folding a crossing of the loop end back to the loop start. A
/// playhead already at or past the loop end plays on without wrapping. Returns the new tick
/// and whether it wrapped. `process_audio` and the per-frame clip render both use this, so
/// they always agree on where the loop wraps.
pub(super) fn advance_tick(
    tick: Tick,
    inc: Tick,
    loop_region: Option<(Tick, Tick)>,
) -> (Tick, bool) {
    let next = tick + inc;
    match loop_region {
        Some((start, end)) if tick < end && next >= end => (start + (next - end), true),
        _ => (next, false),
    }
}

/// `collect_tick_events` that also wraps at `loop_region`. The first event after each wrap
/// is the loop start; its index in `tick_events` goes into `loop_wraps` (extras past the
/// vec's capacity are dropped, so nothing allocates).
pub(super) fn collect_tick_events_looped(
    start_tick: Tick,
    mut acc: f64,
    frame_count: usize,
    tick_rates: &[f64],
    emit_start_tick: bool,
    loop_region: Option<(Tick, Tick)>,
    tick_events: &mut Vec<(Tick, usize)>,
    loop_wraps: &mut Vec<usize>,
) -> (Tick, f64) {
    tick_events.clear();
    loop_wraps.clear();
    if emit_start_tick {
        tick_events.push((start_tick, 0));
    }
    let mut tick_cursor = start_tick;
    for frame_idx in 0..frame_count {
        acc += frame_rate_at(tick_rates, frame_idx);
        while acc >= 1.0 {
            acc -= 1.0;
            let (next, wrapped) = advance_tick(tick_cursor, 1, loop_region);
            tick_cursor = next;
            if wrapped && loop_wraps.len() < loop_wraps.capacity() {
                loop_wraps.push(tick_events.len());
            }
            tick_events.push((tick_cursor, frame_idx));
        }
    }
    (tick_cursor, acc)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::commands::AudioCommand;
    use crate::audio::project::ProjectSettings;
    use crate::audio::tempo_map::TempoMap;

    fn looped_ticks(
        start: Tick,
        frames: usize,
        loop_region: Option<(Tick, Tick)>,
    ) -> (Vec<Tick>, Vec<usize>, Tick) {
        let mut events = Vec::with_capacity(64);
        let mut wraps = Vec::with_capacity(8);
        let (end, _) = collect_tick_events_looped(
            start,
            0.0,
            frames,
            &[1.0],
            true,
            loop_region,
            &mut events,
            &mut wraps,
        );
        (events.iter().map(|e| e.0).collect(), wraps, end)
    }

    #[test]
    fn loop_wraps_on_the_exact_frame_and_never_reaches_the_end() {
        let (ticks, wraps, end) = looped_ticks(0, 8, Some((0, 4)));
        assert_eq!(ticks, vec![0, 1, 2, 3, 0, 1, 2, 3, 0]);
        assert_eq!(wraps, vec![4, 8]);
        assert_eq!(end, 0);
    }

    #[test]
    fn loop_wrap_events_carry_the_frame_of_the_wrap() {
        let mut events = Vec::with_capacity(64);
        let mut wraps = Vec::with_capacity(8);
        collect_tick_events_looped(
            0,
            0.0,
            8,
            &[1.0],
            false,
            Some((2, 5)),
            &mut events,
            &mut wraps,
        );
        // Tick 5 is reached on frame 4 and folds to the loop start
        assert_eq!(events[wraps[0]], (2, 4));
    }

    #[test]
    fn playhead_past_the_loop_end_plays_on_and_loop_off_never_wraps() {
        let (ticks, wraps, _) = looped_ticks(10, 3, Some((0, 4)));
        assert_eq!(ticks, vec![10, 11, 12, 13]);
        assert!(wraps.is_empty());

        let (ticks, wraps, _) = looped_ticks(0, 6, None);
        assert_eq!(ticks, vec![0, 1, 2, 3, 4, 5, 6]);
        assert!(wraps.is_empty());
    }

    #[test]
    fn advance_tick_keeps_the_overshoot_after_a_multi_tick_step() {
        assert_eq!(advance_tick(3, 1, Some((0, 5))), (4, false));
        assert_eq!(advance_tick(3, 4, Some((1, 5))), (3, true));
    }

    #[test]
    fn set_loop_command_enables_and_clears_the_region() {
        let mut state = EngineState::default();
        let apply = |state: &mut EngineState, enabled, start, end| {
            crate::audio::commands::process_command(
                state,
                AudioCommand::SetLoop {
                    enabled,
                    start,
                    end,
                },
                64,
                &mut crate::audio::commands::CommandEffects::default(),
            );
        };
        apply(&mut state, true, 960, 1920);
        assert_eq!(state.loop_region, Some((960, 1920)));
        apply(&mut state, false, 960, 1920);
        assert_eq!(state.loop_region, None);
        apply(&mut state, true, 960, 960);
        assert_eq!(state.loop_region, None);
    }

    #[test]
    fn consecutive_buffers_do_not_redispatch_the_boundary_tick() {
        // 0.04 ticks/sample × 256 frames = 10.24 ticks, matching 120 BPM / 960 PPQ / 48 kHz.
        let frames = 256;
        let rates = vec![0.04; frames];
        let mut events = Vec::new();

        let (tick1, acc1) = collect_tick_events(0, 0.0, frames, &rates, true, &mut events);
        let first: Vec<Tick> = events.iter().map(|(t, _)| *t).collect();
        assert_eq!(first.first().copied(), Some(0));
        assert_eq!(*first.last().unwrap(), tick1);

        let (tick2, _acc2) = collect_tick_events(tick1, acc1, frames, &rates, false, &mut events);
        let second: Vec<Tick> = events.iter().map(|(t, _)| *t).collect();
        assert!(
            !second.contains(&tick1),
            "boundary tick {tick1} was dispatched again"
        );
        assert!(tick2 > tick1);
        assert_eq!(second.first().copied(), Some(tick1 + 1));
    }

    #[test]
    fn playhead_tick_is_only_emitted_when_requested() {
        let mut events = Vec::new();
        collect_tick_events(7680, 0.0, 1, &[0.04], false, &mut events);
        assert!(events.is_empty());

        collect_tick_events(7680, 0.0, 1, &[0.04], true, &mut events);
        assert_eq!(events[0], (7680, 0));
    }

    /// Run buffers of `chunk` frames through the tempo map until the playhead reaches
    /// `target_tick`, returning the frames used and every emitted tick.
    fn frames_to_reach(
        map: &TempoMap,
        settings: &ProjectSettings,
        target_tick: Tick,
    ) -> (usize, Vec<Tick>) {
        let chunk = 256;
        let (mut tick, mut acc, mut frames, mut first) = (0, 0.0, 0, true);
        let (mut rates, mut events, mut ticks) = (Vec::new(), Vec::new(), Vec::new());
        while tick < target_tick {
            fill_tick_rates(
                map,
                settings,
                tick as f64 + acc,
                chunk,
                48_000.0,
                &mut rates,
            );
            (tick, acc) = collect_tick_events(tick, acc, chunk, &rates, first, &mut events);
            first = false;
            ticks.extend(events.iter().map(|(t, _)| *t));
            frames += chunk;
        }
        (frames, ticks)
    }

    #[test]
    fn constant_60_bpm_beat_takes_48000_frames() {
        let settings = ProjectSettings {
            tempo: 60.0,
            ..ProjectSettings::default()
        };
        let (frames, _) = frames_to_reach(&TempoMap::default(), &settings, 960);
        assert!((frames as i64 - 48_000).abs() <= 256, "{frames}");
    }

    #[test]
    fn ramp_duration_matches_integral() {
        let map = TempoMap::from_points(vec![(0, 120.0), (3840, 60.0)]);
        let (frames, _) = frames_to_reach(&map, &ProjectSettings::default(), 3840);
        // 4 ln 2 s at 48 kHz = 133 084.6 frames, rounded up to whole 256-frame buffers
        assert!((frames as i64 - 133_084).abs() <= 256 + 4, "{frames}");
    }

    #[test]
    fn ramp_ticks_are_contiguous() {
        let map = TempoMap::from_points(vec![(0, 120.0), (3840, 60.0)]);
        let (_, ticks) = frames_to_reach(&map, &ProjectSettings::default(), 3840);
        assert!(ticks.windows(2).all(|w| w[1] == w[0] + 1));
    }
}

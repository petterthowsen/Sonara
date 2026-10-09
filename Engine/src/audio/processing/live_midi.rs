//! Live MIDI scheduling: places each channel's queued live input inside the current buffer.

use std::time::Instant;

use crate::audio::state::EngineState;

/// Drain each channel's live MIDI queue into `scheduled_midi_events` with frame offsets.
///
/// Live input plays with a fixed latency of one buffer: an event that arrived `dt` before
/// this callback fired lands `dt` before the end of this buffer. This keeps the spacing
/// between events instead of snapping them all to frame 0. Events older than one buffer
/// (held up on the way in) play at frame 0.
pub(super) fn schedule_live_midi_events(
    state: &mut EngineState,
    callback_start: Instant,
    frame_count: usize,
    sample_rate: f32,
) {
    let last_frame = frame_count.saturating_sub(1);

    for channel in state.channels.values_mut() {
        channel.scheduled_midi_events.clear();

        // Queue order is arrival order, so offsets come out ascending and need no sort
        while let Some(mut event) = channel.midi_queue.pop() {
            let age_frames = callback_start
                .saturating_duration_since(event.received_at)
                .as_secs_f64()
                * sample_rate as f64;
            let frame_offset = (frame_count as f64 - age_frames).round().max(0.0) as usize;
            event.frame_offset = frame_offset.min(last_frame);
            channel.scheduled_midi_events.push(event);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::channel::Channel;
    use crate::audio::midi_types::MidiEvent;
    use std::time::Duration;

    /// Build a state with one channel holding note-ons that arrived `ages_ms` before `now`.
    fn state_with_events(now: Instant, ages_ms: &[u64]) -> EngineState {
        let mut state = EngineState::default();
        let channel = Channel::new(2, "Synth".to_string(), 1024, 48_000.0);
        for &age in ages_ms {
            let received_at = now - Duration::from_millis(age);
            channel
                .midi_queue
                .push(MidiEvent::note_on(0, 60, 100, received_at));
        }
        state.channels.insert(2, channel);
        state
    }

    /// Offsets of the events scheduled on the test channel.
    fn scheduled_offsets(state: &EngineState) -> Vec<usize> {
        state.channels[&2]
            .scheduled_midi_events
            .iter()
            .map(|e| e.frame_offset)
            .collect()
    }

    #[test]
    fn live_midi_keeps_spacing_within_buffer() {
        let now = Instant::now();
        // 480 frames = 10 ms at 48 kHz
        let mut state = state_with_events(now, &[10, 5, 1]);
        schedule_live_midi_events(&mut state, now, 480, 48_000.0);
        assert_eq!(scheduled_offsets(&state), vec![0, 240, 432]);
    }

    #[test]
    fn stale_and_just_arrived_live_midi_are_clamped() {
        let now = Instant::now();
        let mut state = state_with_events(now, &[50, 0]);
        schedule_live_midi_events(&mut state, now, 480, 48_000.0);
        assert_eq!(scheduled_offsets(&state), vec![0, 479]);
    }
}

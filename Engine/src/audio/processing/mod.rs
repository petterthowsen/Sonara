//! Per-buffer audio processing: live MIDI, automation, transport, clip MIDI and audio clips.

mod clip_audio;
mod clip_midi;
mod live_midi;
mod timeline;

use std::time::Instant;

pub use timeline::frames_before_tick;

use clip_audio::{render_audio_clips, BufferSpan};
use clip_midi::dispatch_clip_midi;
use live_midi::schedule_live_midi_events;
use timeline::collect_tick_events_looped;

use super::devices::apply_transport;
use super::rt_debug;
use super::state::EngineState;
use super::tempo_map::fill_tick_rates;
use super::transport::Transport;

/// Process audio for one buffer. `callback_start` is when the audio callback fired and is
/// used to place live MIDI within the buffer.
pub fn process_audio(
    state: &mut EngineState,
    frames: usize,
    sample_rate: f32,
    callback_start: Instant,
) {
    // Always schedule incoming MIDI events (even when not playing)
    // This allows live MIDI input to play instruments without transport running
    rt_debug::section("live MIDI scheduling", || {
        schedule_live_midi_events(&mut state.channels, callback_start, frames, sample_rate)
    });

    // Resolve automation before the transport check, so a seek while stopped still applies
    // (REQ-008). When the tick has not moved the per-lane dedup makes this nearly free.
    let automation_tick = state.get_current_tick();
    rt_debug::section("automation", || {
        super::automation::apply_automation(&mut state.tracks, &mut state.channels, automation_tick)
    });

    let is_playing = state.get_is_playing();
    let start_tick = state.get_current_tick();
    let acc = state.get_fractional_tick_accumulator();
    let start_acc = acc;

    // Devices see the transport every block, playing or not
    let transport = Transport::at(
        &state.tempo_map,
        &state.time_signature_map,
        &state.settings,
        start_tick as f64 + acc,
        sample_rate,
        is_playing,
    );
    for channel in state.channels.values_mut() {
        apply_transport(&mut channel.devices, &transport);
    }

    // Only advance playhead and process clips when playing
    if !is_playing {
        return;
    }

    // Per-frame tick rates from the tempo map. Uses the real device rate, not the project's.
    // Frames past the preallocated capacity reuse the last rate rather than allocating.
    let mut tick_rates = std::mem::take(&mut state.render_scratch.frame_tick_rates);
    let rate_frames = frames.min(tick_rates.capacity());
    fill_tick_rates(
        &state.tempo_map,
        &state.settings,
        start_tick as f64 + acc,
        rate_frames,
        sample_rate,
        &mut tick_rates,
    );

    // Precompute tick boundaries within this buffer with frame offsets
    // Reuse preallocated scratch lists so the audio thread doesn't allocate
    let mut tick_events = std::mem::take(&mut state.render_scratch.tick_events);
    let mut note_events = std::mem::take(&mut state.render_scratch.note_events);
    let emit_playhead = state.take_playhead_midi_dispatch();
    let loop_region = state.loop_region;
    let mut loop_wraps = std::mem::take(&mut state.render_scratch.loop_wraps);
    let (tick_cursor, acc) = rt_debug::section("tick events", || {
        collect_tick_events_looped(
            start_tick,
            acc,
            frames,
            &tick_rates,
            emit_playhead,
            loop_region,
            &mut tick_events,
            &mut loop_wraps,
        )
    });

    // Update global tick and carry fractional forward
    state.set_current_tick(tick_cursor);
    state.set_fractional_tick_accumulator(acc);

    // Dispatch MIDI for each tick event at its exact frame offset
    rt_debug::section("clip MIDI", || {
        dispatch_clip_midi(
            &state.tracks,
            &state.clips,
            &mut state.channels,
            &tick_events,
            &loop_wraps,
            &mut note_events,
        )
    });
    state.render_scratch.tick_events = tick_events;
    state.render_scratch.loop_wraps = loop_wraps;
    state.render_scratch.note_events = note_events;

    // Generate audio clip content per frame while advancing a local tick cursor
    rt_debug::section("audio clip render", || {
        render_audio_clips(
            &mut state.tracks,
            &state.clips,
            &mut state.channels,
            &state.settings,
            &state.tempo_map,
            state.device_sample_rate,
            &tick_rates,
            BufferSpan {
                start_tick,
                start_acc,
                frames,
                loop_region,
                sample_rate,
            },
        )
    });
    state.render_scratch.frame_tick_rates = tick_rates;
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::audio::channel::Channel;

    use crate::audio::devices::{DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue};

    /// Device that records the last transport it was given.
    struct TransportRecorder {
        seen: std::sync::Arc<std::sync::Mutex<Option<Transport>>>,
    }

    impl crate::audio::devices::AudioDevice for TransportRecorder {
        fn process_block(&mut self, _inputs: &[f32], _outputs: &mut [f32], _sample_count: usize) {}
        fn set_parameter(&mut self, _param_id: ParamId, _value: ParamValue) {}
        fn get_parameter(&self, _param_id: ParamId) -> Option<ParamValue> {
            None
        }
        fn set_transport(&mut self, transport: &Transport) {
            *self.seen.lock().unwrap() = Some(*transport);
        }
        fn device_id(&self) -> &str {
            "test.transport"
        }
        fn device_name(&self) -> &str {
            "Transport"
        }
        fn device_category(&self) -> DeviceCategory {
            DeviceCategory::Effect
        }
        fn device_variant(&self) -> DeviceVariant {
            DeviceVariant::BuiltIn
        }
        fn parameters(&self) -> Vec<ParamInfo> {
            Vec::new()
        }
        fn reset(&mut self) {}
        fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
            self
        }
    }

    #[test]
    fn devices_in_containers_receive_transport() {
        use crate::audio::devices::{ChainDevice, DeviceContainer};
        let seen = std::sync::Arc::new(std::sync::Mutex::new(None));
        let mut chain = ChainDevice::new(64);
        chain.insert_child(0, Box::new(TransportRecorder { seen: seen.clone() }));
        let mut state = EngineState::default();
        let mut channel = Channel::new(2, "Fx".to_string(), 64, 48_000.0);
        channel.devices.push(Box::new(chain));
        state.channels.insert(2, channel);
        state.set_current_tick(1920);

        // Stopped: the transport still arrives, with playing = false
        process_audio(&mut state, 64, 48_000.0, Instant::now());
        let t = seen.lock().unwrap().expect("transport delivered");
        assert!(!t.playing);
        assert!((t.song_pos_beats - 2.0).abs() < 1e-9);
        assert!((t.song_pos_seconds - 1.0).abs() < 1e-9);
    }
}

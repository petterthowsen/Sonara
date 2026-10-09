//! Fixtures shared by the mixing tests.

use crate::audio::channel::{Channel, PanMode, Send};
use crate::audio::devices::{
    AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue,
};
use crate::audio::mixing::mix_and_output;
use crate::audio::state::EngineState;
use crate::audio::types::*;
use crossbeam::channel::unbounded;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

pub(super) const SAMPLE_RATE: f32 = 48_000.0;

pub(super) const BUFFER_SIZE: usize = 4;

/// Samples of gain smoothing that settle a fader to its target (the 5 ms smoothing constant
/// is 240 samples at 48 kHz, so this leaves well under 1e-6 of the step).
pub(super) const GAIN_SETTLE_SAMPLES: usize = 4096;

/// Effect that adds a constant level to its input and counts how often it runs.
pub(super) struct TestDevice {
    pub(super) level: f32,
    pub(super) calls: Arc<AtomicUsize>,
}

impl AudioDevice for TestDevice {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        self.calls.fetch_add(1, Ordering::Relaxed);
        for i in 0..sample_count * 2 {
            outputs[i] = inputs[i] + self.level;
        }
    }
    fn set_parameter(&mut self, _param_id: ParamId, _value: ParamValue) {}
    fn get_parameter(&self, _param_id: ParamId) -> Option<ParamValue> {
        None
    }
    fn device_id(&self) -> &str {
        "test.device"
    }
    fn device_name(&self) -> &str {
        "Test Device"
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

/// Add a `TestDevice` to a channel and return its call counter.
pub(super) fn add_test_device(channel: &mut Channel, level: f32) -> Arc<AtomicUsize> {
    let calls = Arc::new(AtomicUsize::new(0));
    channel.devices.push(Box::new(TestDevice {
        level,
        calls: calls.clone(),
    }));
    calls
}

/// Channel with balance pan and a settled fader.
pub(super) fn test_channel(id: ChannelId, output: Option<ChannelId>, volume_db: f32) -> Channel {
    let mut channel = Channel::new(id, format!("Channel {id}"), BUFFER_SIZE, SAMPLE_RATE);
    channel.output_channel_id = output;
    channel.volume_db = volume_db;
    channel.pan_mode = PanMode::StereoBalance;
    for _ in 0..GAIN_SETTLE_SAMPLES {
        let _ = channel.get_smoothed_gain();
    }
    channel
}

/// Engine state holding the given channels.
pub(super) fn state_with(channels: Vec<Channel>) -> EngineState {
    let mut state = EngineState::default();
    state.device_sample_rate = SAMPLE_RATE;
    for channel in channels {
        state.channels.insert(channel.id, channel);
    }
    state
}

/// Mix one buffer and return the interleaved stereo output.
pub(super) fn mix(state: &mut EngineState) -> Vec<f32> {
    let (status_tx, _status_rx) = unbounded();
    let mut output = vec![0.0f32; BUFFER_SIZE * 2];
    mix_and_output(state, &mut output, 2, BUFFER_SIZE, &status_tx);
    output
}

/// Master (0 dB) → bus (-6 dB) ← track (-6 dB, 0.5 input).
pub(super) fn track_bus_master_state() -> EngineState {
    let mut track = test_channel(3, Some(2), -6.0);
    track.buffer_left.fill(0.5);
    track.buffer_right.fill(0.5);
    state_with(vec![
        test_channel(1, Some(1000), 0.0),
        test_channel(2, Some(1), -6.0),
        track,
    ])
}

/// Post-fader send from `source` into `target` at 0 dB.
pub(super) fn send_to(target_channel_id: ChannelId, pre_fader: bool) -> Send {
    Send {
        target_channel_id,
        amount_db: 0.0,
        pre_fader,
        muted: false,
    }
}

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

/// What the fake plugins did, in order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum AsyncEvent {
    Begin(ChannelId),
    Finish(ChannelId),
}

pub(super) type AsyncLog = Arc<std::sync::Mutex<Vec<AsyncEvent>>>;

/// Stand-in for a subprocess plugin: begins blocks asynchronously, logs `Begin`/`Finish`,
/// and outputs its input times `gain`. Disabled, it passes dry input like the adapter. With
/// `sleep_on_silence`, it goes to sleep after a block without activity.
pub(super) struct FakePlugin {
    pub(super) id: ChannelId,
    pub(super) gain: f32,
    pub(super) log: AsyncLog,
    pub(super) enabled: bool,
    pub(super) sleeping: bool,
    pub(super) sleep_on_silence: bool,
    /// Time `begin_block` spends before returning, as the start of a slow block.
    pub(super) begin_cost: std::time::Duration,
}

impl FakePlugin {
    pub(super) fn new(id: ChannelId, gain: f32, log: &AsyncLog) -> Self {
        Self {
            id,
            gain,
            log: Arc::clone(log),
            enabled: true,
            sleeping: false,
            sleep_on_silence: false,
            begin_cost: std::time::Duration::ZERO,
        }
    }
}

impl AudioDevice for FakePlugin {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        assert!(self.begin_block(inputs, sample_count));
        self.finish_block(inputs, outputs, sample_count);
    }
    fn begin_block(&mut self, _inputs: &[f32], _sample_count: usize) -> bool {
        self.log.lock().unwrap().push(AsyncEvent::Begin(self.id));
        std::thread::sleep(self.begin_cost);
        true
    }
    fn finish_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        self.log.lock().unwrap().push(AsyncEvent::Finish(self.id));
        let gain = if self.enabled { self.gain } else { 1.0 };
        for i in 0..sample_count * 2 {
            outputs[i] = inputs[i] * gain;
        }
    }
    fn is_sleeping(&self) -> bool {
        self.sleeping
    }
    fn update_sleep_state(&mut self, has_audio_activity: bool) -> bool {
        let sleeping = self.sleep_on_silence && !has_audio_activity;
        let changed = sleeping != self.sleeping;
        self.sleeping = sleeping;
        changed
    }
    fn set_parameter(&mut self, _param_id: ParamId, _value: ParamValue) {}
    fn get_parameter(&self, _param_id: ParamId) -> Option<ParamValue> {
        None
    }
    fn device_id(&self) -> &str {
        "test.fake_plugin"
    }
    fn device_name(&self) -> &str {
        "Fake Plugin"
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
    fn is_enabled(&self) -> bool {
        self.enabled
    }
    fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }
    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

/// Device that writes 0.4 to the main out and 0.8 to extra bus 0, counting its blocks.
#[derive(Default)]
pub(super) struct TestAuxDevice {
    pub(super) calls: Arc<AtomicUsize>,
}

impl AudioDevice for TestAuxDevice {
    fn process_block(&mut self, _inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        self.calls.fetch_add(1, Ordering::Relaxed);
        let n = (sample_count * 2).min(outputs.len());
        outputs[..n].fill(0.4);
    }
    fn extra_output_bus_count(&self) -> usize {
        1
    }
    fn process_block_with_extra(
        &mut self,
        inputs: &[f32],
        outputs: &mut [f32],
        extra_outs: &mut [Vec<f32>],
        sample_count: usize,
    ) {
        self.process_block(inputs, outputs, sample_count);
        if let Some(extra) = extra_outs.first_mut() {
            let n = (sample_count * 2).min(extra.len());
            extra[..n].fill(0.8);
        }
    }
    fn set_parameter(&mut self, _param_id: ParamId, _value: ParamValue) {}
    fn get_parameter(&self, _param_id: ParamId) -> Option<ParamValue> {
        None
    }
    fn device_id(&self) -> &str {
        "test.aux"
    }
    fn device_name(&self) -> &str {
        "Aux"
    }
    fn device_category(&self) -> DeviceCategory {
        DeviceCategory::Instrument
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

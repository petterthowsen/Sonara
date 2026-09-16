//! Parameter automation: lanes of points evaluated on the audio callback.
//!
//! A lane owns a sorted-by-tick list of points and resolves to one normalized `0.0..=1.0` value
//! per buffer. Automation never writes a base value: the resolved value is applied as an override
//! (see `Channel::automation_volume` / `automation_pan`) or, for device parameters, pushed through
//! `AudioDevice::set_parameter_at` after the lane has captured the device's pre-automation value.
//!
//! Real-time contract: `AutomationLane::value_at` allocates nothing and never scans the full point
//! list. It keeps a cursor that walks forward with the playhead and binary-searches only when the
//! tick jumps backwards (seek, loop).

use std::fmt;

use tracing::warn;

use super::commands::EngineState;
use super::devices::DevicePath;
use super::types::{Channel, Tick, TrackId};

/// Identifier for a point within a lane. Allocated by Godot, mirroring `NoteId`.
pub type AutomationPointId = u64;

/// Identifier for a lane within a track. Allocated by Godot.
pub type AutomationLaneId = String;

/// Channel volume range used when normalizing `channel/volume` (matches `Channel::volume_db`).
pub const VOLUME_DB_MIN: f32 = -60.0;
/// Upper end of the channel volume range.
pub const VOLUME_DB_MAX: f32 = 12.0;

/// Exponent range for a point's `tension`. Shared with the GDScript evaluator: the two sides must
/// change this together or the drawn curve stops matching what is heard.
///
/// The warped ramp is `t.powf(exp2(tension * TENSION_RANGE))`, so tension `0.0` is exactly linear,
/// positive tension eases in (below the linear ramp) and negative eases out.
pub const TENSION_RANGE: f32 = 2.0;

/// Convert a normalized `0.0..=1.0` value to channel volume in dB.
pub fn normalized_to_db(normalized: f32) -> f32 {
    VOLUME_DB_MIN + normalized.clamp(0.0, 1.0) * (VOLUME_DB_MAX - VOLUME_DB_MIN)
}

/// Convert channel volume in dB to a normalized `0.0..=1.0` value.
pub fn db_to_normalized(db: f32) -> f32 {
    ((db - VOLUME_DB_MIN) / (VOLUME_DB_MAX - VOLUME_DB_MIN)).clamp(0.0, 1.0)
}

/// Convert a normalized `0.0..=1.0` value to a pan position in `-1.0..=1.0`.
pub fn normalized_to_pan(normalized: f32) -> f32 {
    normalized.clamp(0.0, 1.0) * 2.0 - 1.0
}

/// Convert a pan position in `-1.0..=1.0` to a normalized `0.0..=1.0` value.
pub fn pan_to_normalized(pan: f32) -> f32 {
    ((pan.clamp(-1.0, 1.0)) + 1.0) * 0.5
}

/// A resolved value within this of the last applied one is not re-applied. Keeps a moving lane
/// from flooding the plugin IPC ring, and a constant one from waking a sleeping device (REQ-011).
const APPLY_EPSILON: f32 = 1e-4;

/// Shape of the segment that starts at a point.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CurveKind {
    /// Ramp to the next point, warped by the point's `tension`.
    #[default]
    Linear,
    /// Hold this point's value until the next point's tick.
    Step,
}

impl CurveKind {
    /// Parse the wire spelling (`linear` / `step`). Unknown names fall back to `Linear`.
    pub fn parse(s: &str) -> CurveKind {
        match s {
            "step" | "Step" | "STEP" => CurveKind::Step,
            _ => CurveKind::Linear,
        }
    }

    /// Wire spelling, matching `CurveKind::parse`.
    pub fn as_str(&self) -> &'static str {
        match self {
            CurveKind::Linear => "linear",
            CurveKind::Step => "step",
        }
    }
}

impl fmt::Display for CurveKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One automation point. `value` is always normalized `0.0..=1.0`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AutomationPoint {
    pub id: AutomationPointId,
    pub tick: Tick,
    pub value: f32,
    /// Shape of the segment starting at this point.
    pub curve: CurveKind,
    /// `-1.0..=1.0`; `0.0` is an exactly linear ramp.
    pub tension: f32,
}

impl AutomationPoint {
    pub fn new(
        id: AutomationPointId,
        tick: Tick,
        value: f32,
        curve: CurveKind,
        tension: f32,
    ) -> Self {
        Self {
            id,
            tick,
            value: value.clamp(0.0, 1.0),
            curve,
            tension: tension.clamp(-1.0, 1.0),
        }
    }
}

/// What a lane drives on the track's linked channel.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AutomationTarget {
    /// The channel fader (`channel/volume`).
    ChannelVolume,
    /// The channel pan (`channel/pan`).
    ChannelPan,
    /// A send amount by index into `Channel::send_channels` (`channel/send/{index}`).
    SendAmount { index: usize },
    /// One parameter of one device in the chain (`device/{i0}/{i1}/param/{id}`).
    DeviceParam {
        device_path: DevicePath,
        param_id: u32,
    },
}

impl AutomationTarget {
    /// Parse the target string used by OSC, the `.sonara` file and the AI assistant.
    ///
    /// `channel/volume`, `channel/pan`, `channel/send/{index}`,
    /// `device/{i0}[/{i1}…]/param/{param_id}`.
    pub fn parse(s: &str) -> Option<AutomationTarget> {
        let parts: Vec<&str> = s.split('/').filter(|p| !p.is_empty()).collect();
        match parts.as_slice() {
            ["channel", "volume"] => Some(AutomationTarget::ChannelVolume),
            ["channel", "pan"] => Some(AutomationTarget::ChannelPan),
            ["channel", "send", index] => index
                .parse::<usize>()
                .ok()
                .map(|index| AutomationTarget::SendAmount { index }),
            ["device", rest @ ..] => {
                // rest = i0 [i1 …] "param" param_id
                let param_pos = rest.len().checked_sub(2)?;
                if rest[param_pos] != "param" || param_pos == 0 {
                    return None;
                }
                let param_id = rest[param_pos + 1].parse::<u32>().ok()?;
                let mut indices = Vec::with_capacity(param_pos);
                for index in &rest[..param_pos] {
                    indices.push(index.parse::<usize>().ok()?);
                }
                Some(AutomationTarget::DeviceParam {
                    device_path: DevicePath::from_indices(indices),
                    param_id,
                })
            }
            _ => None,
        }
    }
}

impl fmt::Display for AutomationTarget {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AutomationTarget::ChannelVolume => write!(f, "channel/volume"),
            AutomationTarget::ChannelPan => write!(f, "channel/pan"),
            AutomationTarget::SendAmount { index } => write!(f, "channel/send/{}", index),
            AutomationTarget::DeviceParam {
                device_path,
                param_id,
            } => write!(f, "device/{}/param/{}", device_path, param_id),
        }
    }
}

/// A lane of automation points driving one target on the track's linked channel.
#[derive(Debug, Clone)]
pub struct AutomationLane {
    pub id: AutomationLaneId,
    pub target: AutomationTarget,
    /// Always sorted by tick. Only the command thread inserts, removes or reorders.
    pub points: Vec<AutomationPoint>,
    pub bypassed: bool,

    /// Index of the point starting the segment last evaluated. Written only by the audio callback.
    cursor: usize,
    /// Last value actually applied, so an unchanged value is not re-applied (REQ-011).
    pub last_applied: Option<f32>,
    /// The target's pre-automation value, captured the first time this lane drives it and written
    /// back when the lane stops driving it (bypass, delete, or an unresolvable target).
    pub captured_base: Option<f32>,
    /// Set once an unresolvable target has been logged, so it is not logged per buffer.
    pub warned_unresolvable: bool,
}

impl AutomationLane {
    pub fn new(id: AutomationLaneId, target: AutomationTarget) -> Self {
        Self {
            id,
            target,
            points: Vec::new(),
            bypassed: false,
            cursor: 0,
            last_applied: None,
            captured_base: None,
            warned_unresolvable: false,
        }
    }

    /// True when this lane has nothing to drive its target with.
    pub fn is_inert(&self) -> bool {
        self.bypassed || self.points.is_empty()
    }

    /// Insert a point, keeping the sorted-by-tick invariant. Returns false when `point.id` is
    /// already present. Runs on the command thread.
    pub fn insert_point(&mut self, point: AutomationPoint) -> bool {
        if self.points.iter().any(|p| p.id == point.id) {
            return false;
        }
        let index = self
            .points
            .partition_point(|p| p.tick <= point.tick)
            .min(self.points.len());
        self.points.insert(index, point);
        self.reset_cursor();
        true
    }

    /// Move or reshape an existing point, keeping the sorted-by-tick invariant. Returns false when
    /// no point has that id. Runs on the command thread.
    pub fn update_point(&mut self, point: AutomationPoint) -> bool {
        let Some(index) = self.points.iter().position(|p| p.id == point.id) else {
            return false;
        };
        self.points.remove(index);
        let insert_at = self
            .points
            .partition_point(|p| p.tick <= point.tick)
            .min(self.points.len());
        self.points.insert(insert_at, point);
        self.reset_cursor();
        true
    }

    /// Remove one point. Returns false when no point has that id. Runs on the command thread.
    pub fn remove_point(&mut self, point_id: AutomationPointId) -> bool {
        let Some(index) = self.points.iter().position(|p| p.id == point_id) else {
            return false;
        };
        self.points.remove(index);
        self.reset_cursor();
        true
    }

    /// Remove every point, keeping the lane. Runs on the command thread.
    pub fn clear_points(&mut self) {
        self.points.clear();
        self.reset_cursor();
    }

    /// The cursor indexes `points`, so any structural edit invalidates it.
    fn reset_cursor(&mut self) {
        self.cursor = 0;
    }

    /// Resolve the lane's normalized value at `tick`, or `None` when it has no points.
    ///
    /// Real-time safe: no allocation, and the cursor keeps this O(1) amortized while the playhead
    /// moves forward.
    pub fn value_at(&mut self, tick: Tick) -> Option<f32> {
        self.value_at_with_steps(tick).0
    }

    /// `value_at` plus the number of point comparisons the cursor walk needed. The count exists so
    /// the real-time-safety test can assert the walk stays bounded (REQ-010).
    pub fn value_at_with_steps(&mut self, tick: Tick) -> (Option<f32>, usize) {
        if self.points.is_empty() {
            return (None, 0);
        }
        let mut steps = 0;

        if self.cursor >= self.points.len() {
            self.cursor = self.points.len() - 1;
        }

        if tick < self.points[self.cursor].tick {
            // Backwards jump (seek or loop): re-seek in O(log n).
            let index = self.points.partition_point(|p| p.tick <= tick);
            self.cursor = index.saturating_sub(1);
            steps = self.points.len().max(2).ilog2() as usize + 1;
        } else {
            // Forward walk: advance past every point the playhead has passed.
            while self.cursor + 1 < self.points.len() && self.points[self.cursor + 1].tick <= tick {
                self.cursor += 1;
                steps += 1;
            }
            steps += 1;
        }

        (Some(self.value_at_cursor(tick)), steps)
    }

    /// Evaluate the segment starting at `cursor`, holding outside the point range (REQ-006).
    fn value_at_cursor(&self, tick: Tick) -> f32 {
        let left = &self.points[self.cursor];
        if tick <= left.tick {
            // Before the first point: hold its value.
            return left.value;
        }
        let Some(right) = self.points.get(self.cursor + 1) else {
            // After the last point: hold its value.
            return left.value;
        };
        evaluate_segment(left, right, tick)
    }
}

/// Resolve every lane on every track at `tick` and apply it to its target.
///
/// Runs on the audio callback once per buffer, before the transport's `is_playing` check, so a
/// seek while stopped still resolves (REQ-008). Real-time safe: no allocation, no I/O, and each
/// lane costs one cursor step.
pub fn apply_automation(state: &mut EngineState, tick: Tick) {
    // Disjoint field borrows: lanes live on tracks, targets live on channels.
    let tracks = &mut state.tracks;
    let channels = &mut state.channels;

    for track in tracks.values_mut() {
        if track.automation_lanes.is_empty() {
            continue;
        }
        let track_id = track.id;
        let Some(channel) = channels.get_mut(&track.channel_id) else {
            // The track's channel is gone: nothing to restore to and nothing to drive.
            for lane in &mut track.automation_lanes {
                lane.last_applied = None;
                warn_unresolvable(lane, track_id);
            }
            continue;
        };

        for lane in &mut track.automation_lanes {
            // A bypassed or empty lane hands the parameter back to its base value (REQ-007, 009).
            let value = if lane.is_inert() {
                None
            } else {
                lane.value_at(tick)
            };
            let Some(value) = value else {
                release_lane(lane, channel);
                continue;
            };
            if !apply_lane_value(lane, channel, value.clamp(0.0, 1.0)) {
                // The target stopped resolving (a removed device, a removed send): hand back
                // whatever base the lane captured and say so once, not once per buffer.
                release_lane(lane, channel);
                warn_unresolvable(lane, track_id);
            }
        }
    }
}

/// Apply one resolved value, skipping the work when it has not meaningfully changed (REQ-011).
///
/// Returns false when the target does not resolve, leaving the lane for the caller to release.
fn apply_lane_value(lane: &mut AutomationLane, channel: &mut Channel, value: f32) -> bool {
    if let Some(previous) = lane.last_applied {
        if (previous - value).abs() <= APPLY_EPSILON {
            return true;
        }
    }

    // Split the borrow so the target can be read while the lane's own fields are written.
    let AutomationLane {
        target,
        captured_base,
        last_applied,
        warned_unresolvable,
        ..
    } = lane;

    match target {
        AutomationTarget::ChannelVolume => {
            channel.automation_volume = Some(value);
        }
        AutomationTarget::ChannelPan => {
            channel.automation_pan = Some(value);
        }
        AutomationTarget::SendAmount { index } => {
            let Some(send) = channel.send_channels.get_mut(*index) else {
                return false;
            };
            if captured_base.is_none() {
                *captured_base = Some(db_to_normalized(send.amount_db));
            }
            send.amount_db = normalized_to_db(value);
        }
        AutomationTarget::DeviceParam {
            device_path,
            param_id,
        } => {
            let Some(device) = channel.device_at_path_mut(device_path) else {
                return false;
            };
            if captured_base.is_none() {
                *captured_base = device.get_parameter(*param_id);
            }
            device.set_parameter_at(*param_id, value, 0);
            // The value really changed (the dedup above proved it), so waking the device is
            // justified; a constant lane leaves a sleeping device asleep.
            device.mark_activity();
        }
    }

    *warned_unresolvable = false;
    *last_applied = Some(value);
    true
}

/// Hand a target back to its base value: clear the channel override, or write back the value the
/// lane captured before it took over (REQ-004).
///
/// Called from the audio callback when a lane goes inert, and from the command thread on bypass
/// and delete. Safe to call on a lane that is not currently driving anything.
pub fn release_lane(lane: &mut AutomationLane, channel: &mut Channel) {
    let AutomationLane {
        target,
        captured_base,
        last_applied,
        ..
    } = lane;

    match target {
        AutomationTarget::ChannelVolume => channel.automation_volume = None,
        AutomationTarget::ChannelPan => channel.automation_pan = None,
        AutomationTarget::SendAmount { index } => {
            if let Some(base) = captured_base.take() {
                if let Some(send) = channel.send_channels.get_mut(*index) {
                    send.amount_db = normalized_to_db(base);
                }
            }
        }
        AutomationTarget::DeviceParam {
            device_path,
            param_id,
        } => {
            if let Some(base) = captured_base.take() {
                // A removed device has nothing to restore to; the base lives on in the project.
                if let Some(device) = channel.device_at_path_mut(device_path) {
                    device.set_parameter_at(*param_id, base, 0);
                    device.mark_activity();
                }
            }
        }
    }

    *last_applied = None;
}

/// Release the lane with `lane_id` on `track_id`, if both exist. For the command thread, which
/// has an `EngineState` rather than a lane and its channel.
pub fn release_track_lane(state: &mut EngineState, track_id: TrackId, lane_id: &str) {
    let tracks = &mut state.tracks;
    let channels = &mut state.channels;
    let Some(track) = tracks.get_mut(&track_id) else {
        return;
    };
    let Some(channel) = channels.get_mut(&track.channel_id) else {
        return;
    };
    if let Some(lane) = track.automation_lane_mut(lane_id) {
        release_lane(lane, channel);
    }
}

/// Log an unresolvable target once per lane rather than once per buffer (REQ-024).
fn warn_unresolvable(lane: &mut AutomationLane, track_id: TrackId) {
    if lane.warned_unresolvable {
        return;
    }
    lane.warned_unresolvable = true;
    warn!(
        "Automation lane {} on track {} cannot resolve target {} - leaving the parameter at its base value",
        lane.id, track_id, lane.target
    );
}

/// Value of the segment between `left` and `right` at `tick`.
pub fn evaluate_segment(left: &AutomationPoint, right: &AutomationPoint, tick: Tick) -> f32 {
    if tick <= left.tick {
        return left.value;
    }
    if tick >= right.tick {
        return right.value;
    }
    match left.curve {
        CurveKind::Step => left.value,
        CurveKind::Linear => {
            let span = (right.tick - left.tick) as f32;
            let t = (tick - left.tick) as f32 / span;
            let warped = apply_tension(t, left.tension);
            left.value + (right.value - left.value) * warped
        }
    }
}

/// Warp a `0.0..=1.0` ramp position by `tension`. Tension `0.0` returns `t` unchanged, so a
/// linear segment evaluates to exactly its midpoint halfway through.
pub fn apply_tension(t: f32, tension: f32) -> f32 {
    if tension == 0.0 {
        return t;
    }
    let exponent = (tension.clamp(-1.0, 1.0) * TENSION_RANGE).exp2();
    t.powf(exponent)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::devices::{
        AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue,
    };
    use crate::audio::types::{Channel, PanMode, Send, Track};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    const BUFFER_SIZE: usize = 128;
    const SAMPLE_RATE: f32 = 48_000.0;

    /// A device that records what automation does to it: every `set_parameter_at` value, and how
    /// many times it was woken.
    struct TestDevice {
        value: f32,
        sets: Arc<AtomicUsize>,
        wakes: Arc<AtomicUsize>,
    }

    impl AudioDevice for TestDevice {
        fn process_block(&mut self, _inputs: &[f32], _outputs: &mut [f32], _sample_count: usize) {}
        fn set_parameter(&mut self, _param_id: ParamId, value: ParamValue) {
            self.value = value;
            self.sets.fetch_add(1, Ordering::Relaxed);
        }
        fn get_parameter(&self, _param_id: ParamId) -> Option<ParamValue> {
            Some(self.value)
        }
        fn device_id(&self) -> &str {
            "test.automation.device"
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
        fn mark_activity(&mut self) {
            self.wakes.fetch_add(1, Ordering::Relaxed);
        }
        fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
            self
        }
    }

    /// Counters for the device added to `channel`: (parameter sets, wakes).
    fn add_test_device(channel: &mut Channel, value: f32) -> (Arc<AtomicUsize>, Arc<AtomicUsize>) {
        let sets = Arc::new(AtomicUsize::new(0));
        let wakes = Arc::new(AtomicUsize::new(0));
        channel.devices.push(Box::new(TestDevice {
            value,
            sets: sets.clone(),
            wakes: wakes.clone(),
        }));
        (sets, wakes)
    }

    /// An `EngineState` with track 1 routed to channel 2, which carries one send and one device.
    fn state_with_track() -> (EngineState, Arc<AtomicUsize>, Arc<AtomicUsize>) {
        let mut state = EngineState::default();
        state.device_sample_rate = SAMPLE_RATE;

        let mut channel = Channel::new(2, "Synth".to_string(), BUFFER_SIZE, SAMPLE_RATE);
        channel.volume_db = 0.0;
        channel.pan = 0.0;
        channel.pan_mode = PanMode::StereoBalance;
        channel.send_channels.push(Send {
            target_channel_id: 3,
            amount_db: -12.0,
            pre_fader: false,
            muted: false,
        });
        let (sets, wakes) = add_test_device(&mut channel, 0.3);
        state.channels.insert(channel.id, channel);
        state.tracks.insert(1, Track::new(1, 2));
        (state, sets, wakes)
    }

    /// Put a two-point ramp lane for `target` on track 1.
    fn add_lane(
        state: &mut EngineState,
        lane_id: &str,
        target: AutomationTarget,
        points: &[(Tick, f32)],
    ) {
        let mut lane = AutomationLane::new(lane_id.to_string(), target);
        for (index, (tick, value)) in points.iter().enumerate() {
            assert!(lane.insert_point(point(index as u64 + 1, *tick, *value)));
        }
        state
            .tracks
            .get_mut(&1)
            .expect("track 1")
            .automation_lanes
            .push(lane);
    }

    fn device_target() -> AutomationTarget {
        AutomationTarget::DeviceParam {
            device_path: DevicePath::root(0),
            param_id: 5,
        }
    }

    fn point(id: AutomationPointId, tick: Tick, value: f32) -> AutomationPoint {
        AutomationPoint::new(id, tick, value, CurveKind::Linear, 0.0)
    }

    #[test]
    fn automation_target_roundtrip() {
        let cases = [
            ("channel/volume", AutomationTarget::ChannelVolume),
            ("channel/pan", AutomationTarget::ChannelPan),
            ("channel/send/2", AutomationTarget::SendAmount { index: 2 }),
            (
                "device/0/param/7",
                AutomationTarget::DeviceParam {
                    device_path: DevicePath::from_indices(vec![0]),
                    param_id: 7,
                },
            ),
            (
                "device/0/1/param/7",
                AutomationTarget::DeviceParam {
                    device_path: DevicePath::from_indices(vec![0, 1]),
                    param_id: 7,
                },
            ),
            (
                "device/3/1/2/param/128",
                AutomationTarget::DeviceParam {
                    device_path: DevicePath::from_indices(vec![3, 1, 2]),
                    param_id: 128,
                },
            ),
        ];

        for (text, expected) in cases {
            let parsed = AutomationTarget::parse(text).expect("target should parse");
            assert_eq!(parsed, expected, "parsing {}", text);
            assert_eq!(parsed.to_string(), text, "re-printing {}", text);
        }

        // Unparseable targets are rejected rather than guessed at.
        for bad in [
            "",
            "channel",
            "channel/gain",
            "channel/send/x",
            "device/param/7",
            "device/0/param",
            "device/0/param/x",
            "device/0/1/7",
        ] {
            assert!(
                AutomationTarget::parse(bad).is_none(),
                "{} should not parse",
                bad
            );
        }
    }

    #[test]
    fn automation_curve_shapes() {
        // Linear, tension 0.0: exactly the midpoint halfway through (REQ-005).
        let a = point(1, 0, 0.0);
        let b = point(2, 960, 1.0);
        for (tick, expected) in [(0, 0.0), (240, 0.25), (480, 0.5), (720, 0.75), (960, 1.0)] {
            let value = evaluate_segment(&a, &b, tick);
            assert!(
                (value - expected).abs() < 1e-6,
                "linear at {} = {} (expected {})",
                tick,
                value,
                expected
            );
        }
        assert_eq!(evaluate_segment(&a, &b, 480), 0.5);

        // Step: hold the left value until the next point's tick.
        let step_a = AutomationPoint::new(1, 0, 0.2, CurveKind::Step, 0.0);
        let step_b = point(2, 960, 0.9);
        for tick in [0, 240, 480, 959] {
            assert_eq!(
                evaluate_segment(&step_a, &step_b, tick),
                0.2,
                "step at {}",
                tick
            );
        }
        assert_eq!(evaluate_segment(&step_a, &step_b, 960), 0.9);

        // Tension: positive eases in (below the ramp), negative eases out (above it), and both
        // still pin the endpoints.
        let eased_in = AutomationPoint::new(1, 0, 0.0, CurveKind::Linear, 0.5);
        let eased_out = AutomationPoint::new(1, 0, 0.0, CurveKind::Linear, -0.5);
        assert!(evaluate_segment(&eased_in, &b, 480) < 0.5);
        assert!(evaluate_segment(&eased_out, &b, 480) > 0.5);
        for shaped in [&eased_in, &eased_out] {
            assert_eq!(evaluate_segment(shaped, &b, 0), 0.0);
            assert_eq!(evaluate_segment(shaped, &b, 960), 1.0);
            for tick in [240, 480, 720] {
                let value = evaluate_segment(shaped, &b, tick);
                assert!(
                    (0.0..=1.0).contains(&value),
                    "tension at {} = {}",
                    tick,
                    value
                );
            }
        }
        // The exact warp, so the GDScript evaluator has a value to match (REQ-005).
        let value = evaluate_segment(&eased_in, &b, 480);
        assert!(
            (value - 0.25).abs() < 1e-5,
            "tension +0.5 midpoint = {}",
            value
        );
    }

    #[test]
    fn automation_holds_outside_points() {
        let mut lane = AutomationLane::new("lane1".to_string(), AutomationTarget::ChannelVolume);
        assert!(lane.insert_point(point(1, 1920, 0.3)));
        assert!(lane.insert_point(point(2, 3840, 0.8)));

        assert_eq!(lane.value_at(0), Some(0.3));
        assert_eq!(lane.value_at(1919), Some(0.3));
        assert_eq!(lane.value_at(1920), Some(0.3));
        assert_eq!(lane.value_at(2880), Some(0.55));
        assert_eq!(lane.value_at(3840), Some(0.8));
        assert_eq!(lane.value_at(100_000), Some(0.8));
    }

    #[test]
    fn automation_empty_lane_is_inert() {
        let mut lane = AutomationLane::new("lane1".to_string(), AutomationTarget::ChannelVolume);
        assert!(lane.is_inert());
        assert_eq!(lane.value_at(0), None);
        assert_eq!(lane.value_at(960), None);

        assert!(lane.insert_point(point(1, 0, 0.5)));
        assert!(!lane.is_inert());
        lane.bypassed = true;
        assert!(lane.is_inert());

        lane.bypassed = false;
        lane.clear_points();
        assert!(lane.is_inert());
        assert_eq!(lane.value_at(480), None);
    }

    #[test]
    fn automation_points_stay_sorted() {
        let mut lane = AutomationLane::new("lane1".to_string(), AutomationTarget::ChannelPan);
        assert!(lane.insert_point(point(3, 1920, 0.3)));
        assert!(lane.insert_point(point(1, 0, 0.1)));
        assert!(lane.insert_point(point(2, 960, 0.2)));
        assert!(
            !lane.insert_point(point(2, 100, 0.9)),
            "a duplicate point id is rejected"
        );
        assert_eq!(
            lane.points.iter().map(|p| p.tick).collect::<Vec<_>>(),
            vec![0, 960, 1920]
        );

        // Moving a point past its neighbours keeps the list sorted.
        assert!(lane.update_point(point(1, 2880, 0.4)));
        assert_eq!(
            lane.points.iter().map(|p| p.id).collect::<Vec<_>>(),
            vec![2, 3, 1]
        );
        assert!(!lane.update_point(point(99, 0, 0.0)));

        assert!(lane.remove_point(3));
        assert!(!lane.remove_point(3));
        assert_eq!(lane.points.len(), 2);
    }

    #[test]
    fn automation_cursor_is_bounded() {
        let mut lane = AutomationLane::new("lane1".to_string(), AutomationTarget::ChannelVolume);
        let count = 10_000;
        for i in 0..count {
            let value = (i % 2) as f32;
            assert!(lane.insert_point(point(i as u64, i as Tick * 10, value)));
        }

        // Walking forward across the whole lane: each step compares a bounded number of points,
        // and the total stays linear in the number of points passed rather than scanning the list.
        let mut total_steps = 0;
        let mut max_steps = 0;
        let mut tick = 0;
        while tick < count as Tick * 10 {
            let (value, steps) = lane.value_at_with_steps(tick);
            assert!(value.is_some());
            total_steps += steps;
            max_steps = max_steps.max(steps);
            tick += 5;
        }
        assert!(
            max_steps <= 2,
            "a forward step should compare at most one new point, got {}",
            max_steps
        );
        let visits = (count as Tick * 10 / 5) as usize;
        assert!(
            total_steps <= visits + count,
            "forward walk did {} comparisons over {} visits",
            total_steps,
            visits
        );

        // A backwards seek re-seeks in O(log n), not by rescanning.
        let (value, steps) = lane.value_at_with_steps(0);
        assert_eq!(value, Some(0.0));
        let log_n = (count as f64).log2().ceil() as usize + 2;
        assert!(
            steps <= log_n,
            "backwards seek took {} comparisons, expected <= {}",
            steps,
            log_n
        );
    }

    #[test]
    fn automation_overrides_base_but_preserves_it() {
        use super::super::types::{Channel, PanMode};

        let mut channel = Channel::new(2, "Synth".to_string(), 128, 48_000.0);
        channel.volume_db = 0.0;
        channel.pan = 0.0;
        channel.pan_mode = PanMode::StereoCombined;
        let base_gain = channel.get_gain();
        assert!((base_gain - 1.0).abs() < 1e-6);
        let base_coefficients = channel.get_pan_coefficients();

        // A volume ramp drives the resolved gain without touching `volume_db`.
        let mut lane = AutomationLane::new("lane1".to_string(), AutomationTarget::ChannelVolume);
        assert!(lane.insert_point(point(1, 0, 0.0)));
        assert!(lane.insert_point(point(2, 1920, 1.0)));

        for (tick, expected_db) in [(0, VOLUME_DB_MIN), (960, -24.0), (1920, VOLUME_DB_MAX)] {
            channel.automation_volume = lane.value_at(tick);
            let expected = if expected_db <= -60.0 {
                0.0
            } else {
                10.0_f32.powf(expected_db / 20.0)
            };
            assert!(
                (channel.get_gain() - expected).abs() < 1e-5,
                "gain at tick {} = {} (expected {})",
                tick,
                channel.get_gain(),
                expected
            );
            assert_eq!(channel.volume_db, 0.0, "the base value must not be written");
        }

        // Clearing the override (bypass, delete) returns the channel to its base value.
        channel.automation_volume = None;
        assert!((channel.get_gain() - base_gain).abs() < 1e-6);

        // Pan behaves the same way: the override wins, `pan` is untouched.
        channel.automation_pan = Some(1.0);
        let panned = channel.get_pan_coefficients();
        assert!(panned.right_to_right > base_coefficients.right_to_right);
        assert_eq!(channel.pan, 0.0, "the base pan must not be written");
        channel.automation_pan = None;
        assert!(
            (channel.get_pan_coefficients().right_to_right - base_coefficients.right_to_right)
                .abs()
                < 1e-6
        );
    }

    #[test]
    fn automation_normalization_helpers() {
        assert_eq!(normalized_to_db(0.0), VOLUME_DB_MIN);
        assert_eq!(normalized_to_db(1.0), VOLUME_DB_MAX);
        assert!((db_to_normalized(normalized_to_db(0.37)) - 0.37).abs() < 1e-6);
        assert!((db_to_normalized(0.0) - (60.0 / 72.0)).abs() < 1e-6);

        assert_eq!(normalized_to_pan(0.0), -1.0);
        assert_eq!(normalized_to_pan(0.5), 0.0);
        assert_eq!(normalized_to_pan(1.0), 1.0);
        assert!((pan_to_normalized(normalized_to_pan(0.75)) - 0.75).abs() < 1e-6);
    }

    #[test]
    fn automation_resolves_each_target() {
        let (mut state, sets, _wakes) = state_with_track();
        add_lane(
            &mut state,
            "volume",
            AutomationTarget::ChannelVolume,
            &[(0, 0.25), (960, 0.75)],
        );
        add_lane(
            &mut state,
            "pan",
            AutomationTarget::ChannelPan,
            &[(0, 0.0), (960, 1.0)],
        );
        add_lane(
            &mut state,
            "send",
            AutomationTarget::SendAmount { index: 0 },
            &[(0, 0.0), (960, 1.0)],
        );
        add_lane(
            &mut state,
            "device",
            device_target(),
            &[(0, 0.1), (960, 0.9)],
        );

        apply_automation(&mut state, 480);

        let channel = state.channels.get(&2).expect("channel 2");
        assert_eq!(channel.automation_volume, Some(0.5));
        assert_eq!(channel.automation_pan, Some(0.5));
        assert!((channel.send_channels[0].amount_db - normalized_to_db(0.5)).abs() < 1e-4);
        let device_value = channel
            .device_at_path(&DevicePath::root(0))
            .unwrap()
            .get_parameter(5)
            .expect("the device reports its parameter");
        assert!(
            (device_value - 0.5).abs() < 1e-5,
            "device param = {}",
            device_value
        );
        assert!(sets.load(Ordering::Relaxed) >= 1);

        // Every base value is untouched (REQ-004).
        assert_eq!(channel.volume_db, 0.0);
        assert_eq!(channel.pan, 0.0);
        let lanes = &state.tracks[&1].automation_lanes;
        let send_lane = lanes.iter().find(|l| l.id == "send").unwrap();
        assert_eq!(send_lane.captured_base, Some(db_to_normalized(-12.0)));
        let device_lane = lanes.iter().find(|l| l.id == "device").unwrap();
        assert_eq!(device_lane.captured_base, Some(0.3));
    }

    #[test]
    fn automation_applies_while_stopped() {
        // `process_audio` resolves before its `is_playing` check, so `apply_automation` must work
        // with the transport stopped (REQ-008).
        let (mut state, _sets, _wakes) = state_with_track();
        assert!(!state.get_is_playing());
        add_lane(
            &mut state,
            "volume",
            AutomationTarget::ChannelVolume,
            &[(0, 0.2), (9600, 0.8)],
        );

        apply_automation(&mut state, 9600);
        assert_eq!(state.channels[&2].automation_volume, Some(0.8));

        // A backwards seek while stopped resolves at the new position.
        apply_automation(&mut state, 0);
        assert_eq!(state.channels[&2].automation_volume, Some(0.2));
    }

    #[test]
    fn automation_restores_base_on_bypass_and_delete() {
        for release_by_bypass in [true, false] {
            let (mut state, _sets, _wakes) = state_with_track();
            add_lane(
                &mut state,
                "device",
                device_target(),
                &[(0, 0.9), (960, 0.9)],
            );
            add_lane(
                &mut state,
                "volume",
                AutomationTarget::ChannelVolume,
                &[(0, 0.1), (960, 0.1)],
            );

            apply_automation(&mut state, 0);
            assert_eq!(
                state.channels[&2]
                    .device_at_path(&DevicePath::root(0))
                    .unwrap()
                    .get_parameter(5),
                Some(0.9)
            );
            assert_eq!(state.channels[&2].automation_volume, Some(0.1));

            if release_by_bypass {
                for lane in &mut state.tracks.get_mut(&1).unwrap().automation_lanes {
                    lane.bypassed = true;
                }
                apply_automation(&mut state, 0);
            } else {
                release_track_lane(&mut state, 1, "device");
                release_track_lane(&mut state, 1, "volume");
            }

            // The device is back at the value it had before automation took over, and the channel
            // override is gone so `get_gain()` reads `volume_db` again.
            let channel = state.channels.get(&2).unwrap();
            assert_eq!(
                channel
                    .device_at_path(&DevicePath::root(0))
                    .unwrap()
                    .get_parameter(5),
                Some(0.3),
                "bypass={}",
                release_by_bypass
            );
            assert_eq!(channel.automation_volume, None);
            assert!((channel.get_gain() - 1.0).abs() < 1e-6);
            // Every point survives (REQ-009).
            assert!(state.tracks[&1]
                .automation_lanes
                .iter()
                .all(|l| l.points.len() == 2));
        }
    }

    #[test]
    fn automation_drops_unresolvable_lane_safely() {
        let (mut state, _sets, _wakes) = state_with_track();
        add_lane(
            &mut state,
            "device",
            device_target(),
            &[(0, 0.1), (960, 0.9)],
        );

        apply_automation(&mut state, 0);
        assert_eq!(
            state.tracks[&1].automation_lanes[0].captured_base,
            Some(0.3)
        );

        // The device is removed under the lane's feet.
        state.channels.get_mut(&2).unwrap().devices.clear();
        for tick in [240, 480, 720] {
            apply_automation(&mut state, tick);
        }

        let lane = &state.tracks[&1].automation_lanes[0];
        assert!(
            lane.warned_unresolvable,
            "the lane logs once, not per buffer"
        );
        assert_eq!(
            lane.captured_base, None,
            "there is nothing left to restore to"
        );
        assert_eq!(lane.last_applied, None);
        assert_eq!(lane.points.len(), 2, "the points are kept");
    }

    #[test]
    fn automation_dedups_unchanged_values() {
        let (mut state, sets, wakes) = state_with_track();
        add_lane(
            &mut state,
            "device",
            device_target(),
            &[(0, 0.5), (96_000, 0.5)],
        );

        // A constant lane over 100 buffers applies once and wakes the device once.
        for buffer in 0..100 {
            apply_automation(&mut state, buffer * 64);
        }
        assert_eq!(sets.load(Ordering::Relaxed), 1);
        assert_eq!(wakes.load(Ordering::Relaxed), 1);

        // A real change gets through, and wakes the device exactly once more.
        state.tracks.get_mut(&1).unwrap().automation_lanes[0].update_point(point(2, 96_000, 1.0));
        apply_automation(&mut state, 48_000);
        assert_eq!(sets.load(Ordering::Relaxed), 2);
        assert_eq!(wakes.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn automation_volume_step_settles_within_the_fader_smoothing() {
        // T-010's finding, pinned as a test: a step-shaped volume lane is not gated by the fader
        // smoothing, it is fast-faded. The one-pole in `Channel::get_smoothed_gain` has tau = 5 ms,
        // so a full-scale step reaches 90% in ~11.5 ms and 99% in ~23 ms. At 120 BPM a sixteenth
        // note is 125 ms, so the ramp is a small fraction of the shortest musically useful step.
        // The smoothing stays as it is — it is what prevents zipper noise on a moving lane.
        let mut channel = Channel::new(2, "Synth".to_string(), BUFFER_SIZE, SAMPLE_RATE);
        channel.volume_db = 0.0;
        channel.automation_volume = Some(1.0);
        for _ in 0..(SAMPLE_RATE as usize) {
            let _ = channel.get_smoothed_gain();
        }
        let top = channel.get_smoothed_gain();

        // Step down to silence and count how long the fader takes to follow.
        channel.automation_volume = Some(0.0);
        let mut samples_to_90 = None;
        let mut samples_to_99 = None;
        for sample in 0..(SAMPLE_RATE as usize) {
            let gain = channel.get_smoothed_gain();
            if samples_to_90.is_none() && gain <= top * 0.1 {
                samples_to_90 = Some(sample);
            }
            if gain <= top * 0.01 {
                samples_to_99 = Some(sample);
                break;
            }
        }

        let ms = |samples: usize| samples as f32 * 1000.0 / SAMPLE_RATE;
        let to_90 = ms(samples_to_90.expect("the fader reaches 90% of the step"));
        let to_99 = ms(samples_to_99.expect("the fader reaches 99% of the step"));
        assert!(
            (10.0..14.0).contains(&to_90),
            "90% of a volume step took {} ms",
            to_90
        );
        assert!(
            (20.0..28.0).contains(&to_99),
            "99% of a volume step took {} ms",
            to_99
        );
    }

    #[test]
    fn automation_empty_lane_leaves_base_alone() {
        // REQ-007: an enabled but empty lane must not drive its parameter.
        let (mut state, sets, _wakes) = state_with_track();
        add_lane(&mut state, "volume", AutomationTarget::ChannelVolume, &[]);
        add_lane(&mut state, "device", device_target(), &[]);

        apply_automation(&mut state, 480);

        let channel = state.channels.get(&2).unwrap();
        assert_eq!(channel.automation_volume, None);
        assert_eq!(channel.volume_db, 0.0);
        assert_eq!(
            channel
                .device_at_path(&DevicePath::root(0))
                .unwrap()
                .get_parameter(5),
            Some(0.3)
        );
        assert_eq!(sets.load(Ordering::Relaxed), 0);
    }
}

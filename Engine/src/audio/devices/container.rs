//! Nested device containers: path addressing, child lists, and serial chain processing.

use super::{has_audio_signal, AudioDevice};
use std::fmt;

/// Ordered indices from a channel's top-level device list down to a nested child.
///
/// `[0]` is the first device on the channel. `[0, 2]` is child 2 of that device.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub struct DevicePath(pub Vec<usize>);

impl DevicePath {
    /// A path containing a single top-level index.
    pub fn root(index: usize) -> Self {
        Self(vec![index])
    }

    /// Build a path from an index list.
    pub fn from_indices(indices: Vec<usize>) -> Self {
        Self(indices)
    }

    /// Indices from the channel root down to this device.
    pub fn indices(&self) -> &[usize] {
        &self.0
    }

    /// True when this path addresses a top-level channel device (one index).
    pub fn is_root(&self) -> bool {
        self.0.len() == 1
    }

    /// True when this path is the channel itself (no device).
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// Parent container path. Empty for a top-level device.
    pub fn parent(&self) -> DevicePath {
        if self.0.is_empty() {
            Self(Vec::new())
        } else {
            let mut parent = self.0.clone();
            parent.pop();
            Self(parent)
        }
    }

    /// Last index in this path (position within the parent list).
    pub fn leaf_index(&self) -> Option<usize> {
        self.0.last().copied()
    }

    /// Append `index` as a child of this path.
    pub fn join(&self, index: usize) -> DevicePath {
        let mut next = self.0.clone();
        next.push(index);
        Self(next)
    }

    /// OSC address prefix `/channel/{id}/device/{i0}/child/{i1}` with no trailing action.
    pub fn to_osc_prefix(&self, channel_id: usize) -> String {
        if self.0.is_empty() {
            return format!("/channel/{}", channel_id);
        }
        let mut addr = format!("/channel/{}/device/{}", channel_id, self.0[0]);
        for index in self.0.iter().skip(1) {
            addr.push_str(&format!("/child/{}", index));
        }
        addr
    }

    /// OSC address `/channel/{id}/device/.../{action}`.
    pub fn to_osc_addr(&self, channel_id: usize, action: &str) -> String {
        if action.is_empty() {
            self.to_osc_prefix(channel_id)
        } else {
            format!("{}/{}", self.to_osc_prefix(channel_id), action)
        }
    }

    /// Unique CLAP subprocess key so nested plugins do not collide.
    pub fn to_process_key(&self, channel_id: u32) -> String {
        format!(
            "ch{}_dev{}",
            channel_id,
            self.0
                .iter()
                .map(|i| i.to_string())
                .collect::<Vec<_>>()
                .join("_")
        )
    }

    /// Window-manager key `plugin_{channel}_{i0}_{i1}`.
    pub fn to_window_key(&self, channel_id: usize) -> String {
        format!(
            "plugin_{}_{}",
            channel_id,
            self.0
                .iter()
                .map(|i| i.to_string())
                .collect::<Vec<_>>()
                .join("_")
        )
    }

    /// Parse a window-manager key produced by [`Self::to_window_key`].
    pub fn from_window_key(key: &str) -> Option<(usize, DevicePath)> {
        let rest = key.strip_prefix("plugin_")?;
        let mut parts = rest.split('_');
        let channel_id = parts.next()?.parse().ok()?;
        let indices: Vec<usize> = parts.filter_map(|p| p.parse().ok()).collect();
        if indices.is_empty() {
            return None;
        }
        Some((channel_id, Self(indices)))
    }
}

impl From<usize> for DevicePath {
    fn from(index: usize) -> Self {
        Self::root(index)
    }
}

impl fmt::Display for DevicePath {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.0.is_empty() {
            write!(f, "/")
        } else {
            let joined = self
                .0
                .iter()
                .map(|i| i.to_string())
                .collect::<Vec<_>>()
                .join("/");
            write!(f, "{}", joined)
        }
    }
}

/// Parse `/channel/{id}/device/{i0}/child/{i1}/.../{action...}` into channel, path, and action.
pub fn parse_osc_device_addr(parts: &[&str]) -> Option<(usize, DevicePath, Vec<String>)> {
    if parts.len() < 4 || parts[0] != "channel" || parts[2] != "device" {
        return None;
    }
    let channel_id = parts[1].parse().ok()?;
    let first = parts[3].parse::<usize>().ok()?;
    let mut indices = vec![first];
    let mut i = 4;
    while i + 1 < parts.len() && parts[i] == "child" {
        let idx = parts[i + 1].parse::<usize>().ok()?;
        indices.push(idx);
        i += 2;
    }
    let action = parts[i..].iter().map(|s| (*s).to_string()).collect();
    Some((channel_id, DevicePath(indices), action))
}

/// Nested device list owned by a container (Chain, Layer, later Drum Machine).
pub trait DeviceContainer {
    /// Number of direct children.
    fn child_count(&self) -> usize;

    /// Immutable child at `index`.
    fn child(&self, index: usize) -> Option<&dyn AudioDevice>;

    /// Mutable child at `index`.
    fn child_mut(&mut self, index: usize) -> Option<&mut dyn AudioDevice>;

    /// Insert `device` at `index`, clamping to the end of the list.
    fn insert_child(&mut self, index: usize, device: Box<dyn AudioDevice>);

    /// Remove and return the child at `index`.
    fn remove_child(&mut self, index: usize) -> Option<Box<dyn AudioDevice>>;

    /// Move a child from `from` to `to` within this container.
    fn move_child(&mut self, from: usize, to: usize);
}

/// Look up a device by path in a top-level list.
pub fn device_at_path<'a>(
    devices: &'a [Box<dyn AudioDevice>],
    path: &DevicePath,
) -> Option<&'a dyn AudioDevice> {
    let indices = path.indices();
    if indices.is_empty() {
        return None;
    }
    let mut current: &dyn AudioDevice = devices.get(indices[0])?.as_ref();
    for &index in &indices[1..] {
        current = current.as_container()?.child(index)?;
    }
    Some(current)
}

/// Look up a mutable device by path in a top-level list.
pub fn device_at_path_mut<'a>(
    devices: &'a mut [Box<dyn AudioDevice>],
    path: &DevicePath,
) -> Option<&'a mut dyn AudioDevice> {
    let indices = path.indices();
    if indices.is_empty() {
        return None;
    }
    if indices.len() == 1 {
        return devices
            .get_mut(indices[0])
            .map(|d| d.as_mut() as &mut dyn AudioDevice);
    }
    let parent = container_at_path_mut(devices, &path.parent())?;
    parent.child_mut(indices[indices.len() - 1])
}

/// Look up a container at `path` (the device itself must implement [`DeviceContainer`]).
pub fn container_at_path_mut<'a>(
    devices: &'a mut [Box<dyn AudioDevice>],
    path: &DevicePath,
) -> Option<&'a mut dyn DeviceContainer> {
    device_at_path_mut(devices, path)?.as_container_mut()
}

/// Insert `device` into the list identified by `parent_path` (empty = channel root).
///
/// Returns the full path of the inserted device.
pub fn insert_device(
    devices: &mut Vec<Box<dyn AudioDevice>>,
    parent_path: &DevicePath,
    position: usize,
    device: Box<dyn AudioDevice>,
) -> Result<DevicePath, String> {
    if parent_path.is_empty() {
        let index = position.min(devices.len());
        devices.insert(index, device);
        return Ok(DevicePath::root(index));
    }
    let container = container_at_path_mut(devices, parent_path)
        .ok_or_else(|| format!("No container at path {}", parent_path))?;
    let index = position.min(container.child_count());
    container.insert_child(index, device);
    Ok(parent_path.join(index))
}

/// Remove the device at `path` from a top-level list.
pub fn remove_device(
    devices: &mut Vec<Box<dyn AudioDevice>>,
    path: &DevicePath,
) -> Option<Box<dyn AudioDevice>> {
    let indices = path.indices();
    if indices.is_empty() {
        return None;
    }
    if indices.len() == 1 {
        if indices[0] < devices.len() {
            return Some(devices.remove(indices[0]));
        }
        return None;
    }
    let parent = container_at_path_mut(devices, &path.parent())?;
    parent.remove_child(indices[indices.len() - 1])
}

/// Move a child within the list identified by `parent_path` (empty = channel root).
pub fn move_device(
    devices: &mut Vec<Box<dyn AudioDevice>>,
    parent_path: &DevicePath,
    from: usize,
    to: usize,
) -> Result<(), String> {
    if parent_path.is_empty() {
        if from >= devices.len() || to >= devices.len() {
            return Err(format!(
                "Invalid move {} -> {} (count {})",
                from,
                to,
                devices.len()
            ));
        }
        let device = devices.remove(from);
        devices.insert(to, device);
        return Ok(());
    }
    let container = container_at_path_mut(devices, parent_path)
        .ok_or_else(|| format!("No container at path {}", parent_path))?;
    if from >= container.child_count() || to >= container.child_count() {
        return Err(format!(
            "Invalid move {} -> {} (count {})",
            from,
            to,
            container.child_count()
        ));
    }
    container.move_child(from, to);
    Ok(())
}

/// Visit every device in `devices` (depth-first), including nested container children.
pub fn visit_devices_mut(
    devices: &mut [Box<dyn AudioDevice>],
    visit: &mut impl FnMut(&DevicePath, &mut dyn AudioDevice),
) {
    visit_range_mut(devices, &DevicePath::default(), visit);
}

/// Recursively visit devices under `prefix`.
fn visit_range_mut(
    devices: &mut [Box<dyn AudioDevice>],
    prefix: &DevicePath,
    visit: &mut impl FnMut(&DevicePath, &mut dyn AudioDevice),
) {
    for i in 0..devices.len() {
        let path = prefix.join(i);
        visit(&path, devices[i].as_mut());
        visit_children_of(devices[i].as_mut(), &path, visit);
    }
}

/// Visit children of a single device if it is a container.
fn visit_children_of(
    device: &mut dyn AudioDevice,
    path: &DevicePath,
    visit: &mut impl FnMut(&DevicePath, &mut dyn AudioDevice),
) {
    let Some(container) = device.as_container_mut() else {
        return;
    };
    let count = container.child_count();
    for i in 0..count {
        let child_path = path.join(i);
        if let Some(child) = container.child_mut(i) {
            visit(&child_path, child);
            visit_children_of(child, &child_path, visit);
        }
    }
}

/// Serial ping-pong processing of a device list on interleaved stereo buffers.
///
/// `buf_a` must already hold the interleaved input. Returns `true` when the
/// final output lives in `buf_b` (last processed index was even).
pub fn process_serial_chain(
    devices: &mut [Box<dyn AudioDevice>],
    buf_a: &mut [f32],
    buf_b: &mut [f32],
    sample_count: usize,
    has_input_activity: bool,
) -> (bool, Vec<(usize, bool)>) {
    if devices.is_empty() {
        return (false, Vec::new());
    }

    let interleaved_count = sample_count * 2;
    let mut sleep_changes = Vec::new();

    for (idx, device) in devices.iter_mut().enumerate() {
        let (input, output) = if idx % 2 == 0 {
            (&buf_a[..], &mut buf_b[..])
        } else {
            (&buf_b[..], &mut buf_a[..])
        };

        if device.is_sleeping() {
            let copy_len = interleaved_count.min(input.len()).min(output.len());
            output[..copy_len].copy_from_slice(&input[..copy_len]);
            continue;
        }

        device.process_block(input, output, sample_count);

        let has_output_activity = has_audio_signal(&output[..interleaved_count.min(output.len())]);
        if device.update_sleep_state(has_input_activity || has_output_activity) {
            sleep_changes.push((idx, device.is_sleeping()));
        }
    }

    let result_in_b = (devices.len() - 1) % 2 == 0;
    (result_in_b, sleep_changes)
}

/// Copy interleaved input to output (used for bypass / empty chain).
pub fn copy_interleaved(inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
    let copy_len = (sample_count * 2).min(inputs.len()).min(outputs.len());
    outputs[..copy_len].copy_from_slice(&inputs[..copy_len]);
}

/// Apply linear gain to an interleaved stereo buffer in place.
pub fn apply_gain(buffer: &mut [f32], sample_count: usize, gain: f32) {
    let count = (sample_count * 2).min(buffer.len());
    for sample in &mut buffer[..count] {
        *sample *= gain;
    }
}

/// Map a normalized 0–1 parameter to linear gain in `[0, 2]` (0.5 = unity).
pub fn normalized_to_gain(normalized: f32) -> f32 {
    normalized.clamp(0.0, 1.0) * 2.0
}

/// Map linear gain in `[0, 2]` back to a normalized 0–1 parameter.
pub fn gain_to_normalized(gain: f32) -> f32 {
    (gain / 2.0).clamp(0.0, 1.0)
}

/// Shared insert/remove/move helpers used by Chain and Layer child lists.
pub fn insert_into_vec<T>(list: &mut Vec<T>, index: usize, item: T) {
    let index = index.min(list.len());
    list.insert(index, item);
}

/// Remove a child from a vec-backed child list.
pub fn remove_from_vec<T>(list: &mut Vec<T>, index: usize) -> Option<T> {
    if index < list.len() {
        Some(list.remove(index))
    } else {
        None
    }
}

/// Move an item inside a vec-backed child list.
pub fn move_in_vec<T>(list: &mut Vec<T>, from: usize, to: usize) {
    if from >= list.len() || to >= list.len() || from == to {
        return;
    }
    let item = list.remove(from);
    list.insert(to, item);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::devices::{
        DeviceCategory, DeviceVariant, MidiPort, ParamId, ParamInfo, ParamValue, PortFlow,
    };

    struct GainDevice {
        gain: f32,
        midi_count: usize,
    }

    impl GainDevice {
        fn new(gain: f32) -> Self {
            Self {
                gain,
                midi_count: 0,
            }
        }
    }

    impl AudioDevice for GainDevice {
        fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
            let count = (sample_count * 2).min(inputs.len()).min(outputs.len());
            for i in 0..count {
                outputs[i] = inputs[i] * self.gain;
            }
        }

        fn send_midi_event(&mut self, _note: u8, _velocity: u8, _is_on: bool, _frame: usize) {
            self.midi_count += 1;
        }

        fn set_parameter(&mut self, _id: ParamId, _value: ParamValue) {}

        fn get_parameter(&self, _id: ParamId) -> Option<ParamValue> {
            None
        }

        fn device_id(&self) -> &str {
            "test.gain"
        }

        fn device_name(&self) -> &str {
            "Gain"
        }

        fn device_category(&self) -> DeviceCategory {
            DeviceCategory::Effect
        }

        fn device_variant(&self) -> DeviceVariant {
            DeviceVariant::BuiltIn
        }

        fn midi_ports(&self) -> Vec<MidiPort> {
            vec![MidiPort {
                id: 0,
                name: "MIDI In".to_string(),
                flow: PortFlow::Input,
            }]
        }

        fn parameters(&self) -> Vec<ParamInfo> {
            Vec::new()
        }

        fn reset(&mut self) {}

        fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
            self
        }
    }

    struct TestChain {
        children: Vec<Box<dyn AudioDevice>>,
    }

    impl DeviceContainer for TestChain {
        fn child_count(&self) -> usize {
            self.children.len()
        }

        fn child(&self, index: usize) -> Option<&dyn AudioDevice> {
            self.children.get(index).map(|d| d.as_ref())
        }

        fn child_mut(&mut self, index: usize) -> Option<&mut dyn AudioDevice> {
            self.children.get_mut(index).map(|d| d.as_mut() as _)
        }

        fn insert_child(&mut self, index: usize, device: Box<dyn AudioDevice>) {
            insert_into_vec(&mut self.children, index, device);
        }

        fn remove_child(&mut self, index: usize) -> Option<Box<dyn AudioDevice>> {
            remove_from_vec(&mut self.children, index)
        }

        fn move_child(&mut self, from: usize, to: usize) {
            move_in_vec(&mut self.children, from, to);
        }
    }

    impl AudioDevice for TestChain {
        fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
            copy_interleaved(inputs, outputs, sample_count);
        }

        fn set_parameter(&mut self, _id: ParamId, _value: ParamValue) {}

        fn get_parameter(&self, _id: ParamId) -> Option<ParamValue> {
            None
        }

        fn device_id(&self) -> &str {
            "test.chain"
        }

        fn device_name(&self) -> &str {
            "Chain"
        }

        fn device_category(&self) -> DeviceCategory {
            DeviceCategory::Utility
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

        fn as_container(&self) -> Option<&dyn DeviceContainer> {
            Some(self)
        }

        fn as_container_mut(&mut self) -> Option<&mut dyn DeviceContainer> {
            Some(self)
        }
    }

    #[test]
    fn osc_path_round_trip() {
        let path = DevicePath::from_indices(vec![0, 2, 1]);
        assert_eq!(path.to_osc_prefix(5), "/channel/5/device/0/child/2/child/1");
        assert_eq!(
            path.to_osc_addr(5, "param/3"),
            "/channel/5/device/0/child/2/child/1/param/3"
        );
        let addr = path.to_osc_addr(5, "enable");
        let parts: Vec<&str> = addr.trim_start_matches('/').split('/').collect();
        let (channel, parsed, action) = parse_osc_device_addr(&parts).unwrap();
        assert_eq!(channel, 5);
        assert_eq!(parsed, path);
        assert_eq!(action, vec!["enable"]);
    }

    #[test]
    fn top_level_osc_stays_flat() {
        let path = DevicePath::root(3);
        assert_eq!(
            path.to_osc_addr(2, "param/1"),
            "/channel/2/device/3/param/1"
        );
        let parts = ["channel", "2", "device", "3", "param", "1"];
        let (channel, parsed, action) = parse_osc_device_addr(&parts).unwrap();
        assert_eq!(channel, 2);
        assert_eq!(parsed, path);
        assert_eq!(action, vec!["param", "1"]);
    }

    #[test]
    fn window_key_round_trip() {
        let path = DevicePath::from_indices(vec![1, 0]);
        let key = path.to_window_key(4);
        assert_eq!(key, "plugin_4_1_0");
        let (channel, parsed) = DevicePath::from_window_key(&key).unwrap();
        assert_eq!(channel, 4);
        assert_eq!(parsed, path);
    }

    #[test]
    fn path_walk_and_insert() {
        let mut devices: Vec<Box<dyn AudioDevice>> = vec![Box::new(TestChain {
            children: vec![Box::new(GainDevice::new(0.5))],
        })];
        let nested = device_at_path(&devices, &DevicePath::from_indices(vec![0, 0]));
        assert_eq!(nested.unwrap().device_id(), "test.gain");

        insert_device(
            &mut devices,
            &DevicePath::root(0),
            1,
            Box::new(GainDevice::new(2.0)),
        )
        .unwrap();
        assert_eq!(
            device_at_path(&devices, &DevicePath::from_indices(vec![0, 1]))
                .unwrap()
                .device_id(),
            "test.gain"
        );

        remove_device(&mut devices, &DevicePath::from_indices(vec![0, 0])).unwrap();
        let container = devices[0].as_container().unwrap();
        assert_eq!(container.child_count(), 1);
    }

    #[test]
    fn serial_chain_applies_gains_in_order() {
        let mut devices: Vec<Box<dyn AudioDevice>> = vec![
            Box::new(GainDevice::new(0.5)),
            Box::new(GainDevice::new(4.0)),
        ];
        let mut buf_a = vec![1.0f32; 8];
        let mut buf_b = vec![0.0f32; 8];
        let (result_in_b, _) = process_serial_chain(&mut devices, &mut buf_a, &mut buf_b, 4, true);
        let out = if result_in_b { &buf_b } else { &buf_a };
        for sample in &out[..8] {
            assert!((sample - 2.0).abs() < 1e-6, "got {}", sample);
        }
    }

    #[test]
    fn empty_serial_chain_keeps_input() {
        let mut devices: Vec<Box<dyn AudioDevice>> = Vec::new();
        let mut buf_a = vec![0.25f32; 4];
        let mut buf_b = vec![0.0f32; 4];
        let (result_in_b, changes) =
            process_serial_chain(&mut devices, &mut buf_a, &mut buf_b, 2, false);
        assert!(!result_in_b);
        assert!(changes.is_empty());
        assert_eq!(buf_a[0], 0.25);
    }
}

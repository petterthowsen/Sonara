//! The MIDI pre-pass (spec 049): notes that a MIDI Send forwards from one channel to others.
//!
//! A MIDI Send's targets are channels, and delivering to them has to happen *before* the
//! target renders, in the same block, at the same frames. The render runs on the channel pool
//! (ADR 0020), where a send that emitted while its channel rendered could reach a target that is
//! already rendering or done. So cross-channel MIDI moves in a serial pre-pass at the top of
//! [`mix_and_output`](super::mix_and_output):
//!
//! 1. Walk the senders in [`MidiSendOrder`]: every sender comes after anything that sends to it.
//! 2. For each sender channel run its live MIDI and note phase (`dispatch_notes`) early and mark
//!    the channel `notes_dispatched`, so the render doesn't run it again.
//! 3. Copy each send's outbox into scratch and deliver it to every effective target with
//!    `send_note_event_to_devices` (CC through `send_cc_to_devices`) at the same frame.
//!
//! The pre-pass is note-only work over the senders, so output stays sample-identical at any
//! pool size, and a project without a MIDI Send has an empty order and pays nothing.
//!
//! The order and each send's *effective* targets are built by [`rebuild_midi_sends`] on the
//! command thread, like `sidechain::rebuild_taps`. The engine has no mixer nesting, so Godot
//! resolves children mode and sends a concrete target list; the rebuild drops invalid ids and
//! refuses any edge that would close a loop.

use std::collections::HashMap;

use tracing::warn;

use crate::audio::channel::Channel;
use crate::audio::commands::{CommandEffects, EngineStatus};
use crate::audio::devices::note_fx::midi_send::{TargetList, TimedCc};
use crate::audio::devices::note_fx::{NoteBuffer, TimedNote};
use crate::audio::devices::DevicePath;
use crate::audio::state::EngineState;
use crate::audio::types::{ChannelId, HARDWARE_OUTPUT_BASE};

/// One MIDI Send in the top-level chain of `channel_id`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SendRef {
    pub channel_id: ChannelId,
    pub device_index: usize,
}

/// The MIDI Sends of the project in pre-pass order: sender channels topologically (a channel
/// after every channel that sends to it, ties by id), a channel's sends by chain position.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct MidiSendOrder {
    pub sends: Vec<SendRef>,
}

/// What a rebuild hands back to the caller.
#[derive(Default)]
pub struct MidiSendRebuild {
    /// The replaced order, to drop after the state lock is released.
    pub old: MidiSendOrder,
    /// `MidiSendBlocked` statuses for sends whose blocked set changed.
    pub statuses: Vec<EngineStatus>,
}

impl MidiSendRebuild {
    /// For commands that run under the lock: queue the old order for dropping and the statuses
    /// for sending once the lock is released.
    pub fn finish(self, effects: &mut CommandEffects) {
        effects.discard(self.old);
        effects.statuses.extend(self.statuses);
    }
}

/// A target a MIDI Send may forward to: any existing user channel except the sender itself.
/// Not master (1), not a hardware output (1000 and up), not the unset id 0.
fn is_valid_target(
    channels: &HashMap<ChannelId, Channel>,
    sender: ChannelId,
    target: ChannelId,
) -> bool {
    target != sender
        && (2..HARDWARE_OUTPUT_BASE).contains(&target)
        && channels.contains_key(&target)
}

/// True when `to` can be reached from `from` along the accepted edges (or they are the same).
fn reaches(edges: &HashMap<ChannelId, Vec<ChannelId>>, from: ChannelId, to: ChannelId) -> bool {
    let mut stack = vec![from];
    let mut seen: Vec<ChannelId> = Vec::new();
    while let Some(node) = stack.pop() {
        if node == to {
            return true;
        }
        if seen.contains(&node) {
            continue;
        }
        seen.push(node);
        if let Some(next) = edges.get(&node) {
            stack.extend(next.iter().copied());
        }
    }
    false
}

/// Whether a device with `device_id` may be added below `parent_path`. A MIDI Send forwards in
/// the pre-pass, which only sees a channel's top-level chain (empty parent path): containers and
/// slots run their note phase during the render, so a nested send would emit too late.
pub fn placement_allowed(device_id: &str, parent_path: &DevicePath) -> bool {
    device_id != crate::audio::devices::note_fx::midi_send::DEVICE_ID || parent_path.is_empty()
}

struct Found {
    send: SendRef,
    requested: Vec<ChannelId>,
}

/// Rebuild the sender order and every send's effective and blocked targets from the project.
///
/// Scans the top-level chains (a MIDI Send lives nowhere else), drops invalid target ids (the
/// sender itself, master, hardware outputs, ids with no channel), adds edges in a fixed order
/// (sender id, device index, target id) and skips any edge whose target can already reach the
/// sender, since it would close a loop (REQ-014). Targets a send loses are sent note-offs for
/// what it forwarded (REQ-010). Command thread, under the state lock.
pub fn rebuild_midi_sends(state: &mut EngineState) -> MidiSendRebuild {
    let mut channel_ids: Vec<ChannelId> = state.channels.keys().copied().collect();
    channel_ids.sort_unstable();

    let mut found: Vec<Found> = Vec::new();
    for id in &channel_ids {
        let Some(channel) = state.channels.get_mut(id) else {
            continue;
        };
        for (device_index, device) in channel.devices.iter_mut().enumerate() {
            if let Some(send) = device.as_midi_send_mut() {
                let mut requested = send.requested().to_vec();
                requested.sort_unstable();
                requested.dedup();
                found.push(Found {
                    send: SendRef {
                        channel_id: *id,
                        device_index,
                    },
                    requested,
                });
            }
        }
    }

    // Accept edges in the fixed order.
    let mut edges: HashMap<ChannelId, Vec<ChannelId>> = HashMap::new();
    let mut effective: Vec<Vec<ChannelId>> = Vec::with_capacity(found.len());
    let mut blocked: Vec<Vec<ChannelId>> = Vec::with_capacity(found.len());
    for f in &found {
        let sender = f.send.channel_id;
        let mut accepted = Vec::new();
        let mut refused = Vec::new();
        for &target in &f.requested {
            if !is_valid_target(&state.channels, sender, target) {
                continue;
            }
            if reaches(&edges, target, sender) {
                refused.push(target);
                continue;
            }
            edges.entry(sender).or_default().push(target);
            accepted.push(target);
        }
        effective.push(accepted);
        blocked.push(refused);
    }

    // Write them into the devices; release the notes a send held on targets it lost.
    let mut statuses = Vec::new();
    let mut releases: Vec<(ChannelId, Vec<TimedNote>)> = Vec::new();
    for ((f, accepted), refused) in found.iter().zip(&effective).zip(&blocked) {
        let Some(send) = state
            .channels
            .get_mut(&f.send.channel_id)
            .and_then(|c| c.devices.get_mut(f.send.device_index))
            .and_then(|d| d.as_midi_send_mut())
        else {
            continue;
        };
        let lost: Vec<ChannelId> = send
            .effective()
            .iter()
            .copied()
            .filter(|t| !accepted.contains(t))
            .collect();
        if !lost.is_empty() {
            let mut offs = Vec::new();
            send.target_releases(&mut offs);
            for target in lost {
                releases.push((target, offs.clone()));
            }
        }
        send.set_effective(accepted);
        if send.blocked() != refused.as_slice() {
            send.set_blocked(refused);
            if !refused.is_empty() {
                warn!(
                    "MIDI Send on channel {} would loop back to its sender through {:?}; ignored",
                    f.send.channel_id, refused
                );
            }
            statuses.push(EngineStatus::MidiSendBlocked {
                channel_id: f.send.channel_id,
                device_path: DevicePath::root(f.send.device_index),
                ids: refused.clone(),
            });
        }
    }
    deliver_releases(&mut state.channels, &releases);

    // Topological order over the sender channels (Kahn, ties by id).
    let mut sender_channels: Vec<ChannelId> = found.iter().map(|f| f.send.channel_id).collect();
    sender_channels.dedup(); // `found` is sorted by channel id
    let mut indegree: HashMap<ChannelId, usize> = sender_channels.iter().map(|&c| (c, 0)).collect();
    for (&from, targets) in &edges {
        if !indegree.contains_key(&from) {
            continue;
        }
        for target in targets {
            if let Some(n) = indegree.get_mut(target) {
                *n += 1;
            }
        }
    }
    let mut sends = Vec::with_capacity(found.len());
    let mut remaining = sender_channels.clone();
    while !remaining.is_empty() {
        let Some(pos) = remaining.iter().position(|c| indegree[c] == 0) else {
            // Unreachable: loops are refused above. Fall back to id order rather than lose sends.
            sends.extend(found.iter().map(|f| f.send));
            break;
        };
        let channel = remaining.remove(pos);
        sends.extend(
            found
                .iter()
                .filter(|f| f.send.channel_id == channel)
                .map(|f| f.send),
        );
        for target in edges.get(&channel).into_iter().flatten() {
            if let Some(n) = indegree.get_mut(target) {
                *n = n.saturating_sub(1);
            }
        }
    }

    let order = MidiSendOrder { sends };
    let old = if order == state.midi_sends {
        MidiSendOrder::default()
    } else {
        std::mem::replace(&mut state.midi_sends, order)
    };
    MidiSendRebuild { old, statuses }
}

/// Send each `(target, offs)` pair's note-offs to that target channel, at frame 0.
fn deliver_releases(
    channels: &mut HashMap<ChannelId, Channel>,
    releases: &[(ChannelId, Vec<TimedNote>)],
) {
    for (target, offs) in releases {
        if let Some(channel) = channels.get_mut(target) {
            for off in offs {
                channel.send_note_event_to_devices(&off.event, off.frame);
            }
        }
    }
}

/// Command thread, before the MIDI Send at `path` on `channel_id` is removed: end every note it
/// forwarded on its effective targets (REQ-010). Does nothing for a device that isn't one.
pub fn release_send_targets(state: &mut EngineState, channel_id: ChannelId, path: &DevicePath) {
    let Some(send) = state
        .channels
        .get_mut(&channel_id)
        .and_then(|c| c.device_at_path_mut(path))
        .and_then(|d| d.as_midi_send_mut())
    else {
        return;
    };
    let targets = send.effective_list();
    let mut offs = Vec::new();
    send.take_target_releases(&mut offs);
    if offs.is_empty() {
        return;
    }
    let releases: Vec<(ChannelId, Vec<TimedNote>)> = targets
        .as_slice()
        .iter()
        .map(|&t| (t, offs.clone()))
        .collect();
    deliver_releases(&mut state.channels, &releases);
}

/// Command thread, before `channel_id` (or its device chain) is removed: release every MIDI
/// Send in it.
pub fn release_channel_sends(state: &mut EngineState, channel_id: ChannelId) {
    let count = state
        .channels
        .get(&channel_id)
        .map_or(0, |c| c.devices.len());
    for index in 0..count {
        release_send_targets(state, channel_id, &DevicePath::root(index));
    }
}

/// The pre-pass: run each sender channel's note phase early and deliver its sends' outboxes to
/// their effective targets. Audio thread; allocates nothing.
pub(super) fn forward(
    channels: &mut HashMap<ChannelId, Channel>,
    order: &MidiSendOrder,
    notes: &mut NoteBuffer,
    ccs: &mut Vec<TimedCc>,
    frames: usize,
) {
    let mut dispatched: Option<ChannelId> = None;
    for entry in &order.sends {
        let targets: TargetList = {
            let Some(channel) = channels.get_mut(&entry.channel_id) else {
                continue;
            };
            // A deactivated channel runs no MIDI, in the render or here.
            if !channel.enabled {
                continue;
            }
            if dispatched != Some(entry.channel_id) {
                channel.dispatch_notes(frames);
                channel.notes_dispatched = true;
                dispatched = Some(entry.channel_id);
            }
            let Some(send) = channel
                .devices
                .get_mut(entry.device_index)
                .and_then(|d| d.as_midi_send_mut())
            else {
                continue;
            };
            notes.clear();
            for note in send.outbox() {
                notes.push(*note);
            }
            ccs.clear();
            for cc in send.cc_outbox() {
                if ccs.len() < ccs.capacity() {
                    ccs.push(*cc);
                }
            }
            send.clear_cc_outbox();
            send.effective_list()
        };
        if notes.is_empty() && ccs.is_empty() {
            continue;
        }
        for &target_id in targets.as_slice() {
            let Some(target) = channels.get_mut(&target_id) else {
                continue;
            };
            for note in notes.as_slice() {
                target.send_note_event_to_devices(&note.event, note.frame);
            }
            for cc in ccs.iter() {
                target.send_cc_to_devices(cc.cc, cc.value14, cc.frame);
            }
        }
    }
}

/// End of `mix_and_output`: the next buffer's render dispatches notes again.
pub(super) fn clear_dispatched(channels: &mut HashMap<ChannelId, Channel>, order: &MidiSendOrder) {
    for entry in &order.sends {
        if let Some(channel) = channels.get_mut(&entry.channel_id) {
            channel.notes_dispatched = false;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::clip::{Clip, ClipInstance, ClipNote, ClipType};
    use crate::audio::commands::{process_command, AudioCommand};
    use crate::audio::devices::note_fx::routing::test_devices::Recorder;
    use crate::audio::devices::{create_note_effect, AudioDevice, PolySynthDevice};
    use crate::audio::midi_types::{NoteEvent, SoundingNoteId};
    use crate::audio::mixing::{mix_and_output, ChannelPool};
    use crate::audio::processing::process_audio;
    use crate::audio::track::Track;
    use crate::audio::types::{NoteId, Tick};
    use crossbeam::channel::unbounded;
    use std::sync::{Arc, Mutex};
    use std::time::Instant;

    const BLOCK: usize = 64;
    const SR: f32 = 48_000.0;

    type Log = Arc<Mutex<Vec<(usize, NoteEvent)>>>;

    /// Master plus empty channels `ids`, each routed to master.
    fn project(ids: &[ChannelId]) -> EngineState {
        let mut state = EngineState::default();
        state.device_sample_rate = SR;
        state.ensure_master_channel(BLOCK);
        for &id in ids {
            let mut channel = Channel::new(id, format!("ch{id}"), BLOCK, SR);
            channel.output_channel_id = Some(1);
            state.channels.insert(id, channel);
        }
        state
    }

    /// Append a MIDI Send aimed at `targets` to `channel`'s chain; returns its device index.
    fn add_send(state: &mut EngineState, channel: ChannelId, targets: &[ChannelId]) -> usize {
        let mut send = create_note_effect("sonara.builtin.midi_send", SR, BLOCK).unwrap();
        send.as_midi_send_mut().unwrap().set_requested(targets);
        let devices = &mut state.channels.get_mut(&channel).unwrap().devices;
        devices.push(send);
        devices.len() - 1
    }

    fn add_recorder(state: &mut EngineState, channel: ChannelId) -> Log {
        let (recorder, log) = Recorder::new();
        state
            .channels
            .get_mut(&channel)
            .unwrap()
            .devices
            .push(Box::new(recorder));
        log
    }

    fn add_synth(state: &mut EngineState, channel: ChannelId) {
        let mut synth: Box<dyn AudioDevice> = Box::new(PolySynthDevice::new(SR));
        synth.prepare(SR, BLOCK);
        state
            .channels
            .get_mut(&channel)
            .unwrap()
            .devices
            .push(synth);
    }

    fn rebuild(state: &mut EngineState) -> MidiSendRebuild {
        rebuild_midi_sends(state)
    }

    fn mix(state: &mut EngineState) -> Vec<f32> {
        let (status_tx, _status_rx) = unbounded();
        let mut out = vec![0.0f32; BLOCK * 2];
        mix_and_output(state, &mut out, 2, BLOCK, &status_tx);
        out
    }

    fn command(state: &mut EngineState, cmd: AudioCommand) -> CommandEffects {
        let mut effects = CommandEffects::default();
        process_command(state, cmd, BLOCK, &mut effects);
        effects
    }

    /// Run `blocks` buffers of the transport and clip dispatch, then the mix.
    fn play(state: &mut EngineState, blocks: usize) -> Vec<f32> {
        let mut all = Vec::new();
        for _ in 0..blocks {
            process_audio(state, BLOCK, SR, Instant::now());
            all.extend(mix(state));
        }
        all
    }

    fn start_transport(state: &mut EngineState) {
        state.set_is_playing(true);
        state.request_playhead_midi_dispatch();
    }

    /// A MIDI clip of `notes` (id, key, start, duration) on a new track playing into `channel`.
    fn add_clip(
        state: &mut EngineState,
        track_id: u32,
        channel: ChannelId,
        notes: &[(NoteId, u8, Tick, Tick)],
        instance_len: Tick,
    ) {
        let clip_id = format!("clip{track_id}");
        let mut clip = Clip::new(clip_id.clone(), clip_id.clone(), ClipType::Midi);
        for &(id, note, start_tick, duration_ticks) in notes {
            clip.midi_notes.push(ClipNote {
                id,
                note,
                velocity: 0.8,
                release: crate::audio::DEFAULT_RELEASE,
                start_tick,
                duration_ticks,
            });
            clip.content_length_ticks = clip.content_length_ticks.max(start_tick + duration_ticks);
        }
        state.clips.insert(clip_id.clone(), clip);
        let mut track = Track::new(track_id as _, channel);
        track.clip_instances.push(ClipInstance::new(
            format!("inst{track_id}"),
            clip_id,
            0,
            instance_len,
        ));
        state.tracks.insert(track_id as _, track);
    }

    fn on(id: SoundingNoteId, key: u8) -> NoteEvent {
        NoteEvent::On {
            note_id: id,
            key,
            velocity: 0.8,
        }
    }

    fn off(id: SoundingNoteId, key: u8) -> NoteEvent {
        NoteEvent::Off {
            note_id: id,
            key,
            release: 0.5,
        }
    }

    fn send_note(state: &mut EngineState, channel: ChannelId, event: NoteEvent, frame: usize) {
        state
            .channels
            .get_mut(&channel)
            .unwrap()
            .send_note_event_to_devices(&event, frame);
    }

    fn ons(log: &Log) -> Vec<(usize, NoteEvent)> {
        log.lock()
            .unwrap()
            .iter()
            .copied()
            .filter(|(_, e)| matches!(e, NoteEvent::On { .. }))
            .collect()
    }

    fn offs(log: &Log) -> Vec<(usize, NoteEvent)> {
        log.lock()
            .unwrap()
            .iter()
            .copied()
            .filter(|(_, e)| matches!(e, NoteEvent::Off { .. }))
            .collect()
    }

    /// Ids on the recorder that started and have no note-off yet.
    fn sounding(log: &Log) -> Vec<SoundingNoteId> {
        let mut live: Vec<SoundingNoteId> = Vec::new();
        for (_, event) in log.lock().unwrap().iter() {
            match event {
                NoteEvent::On { note_id, .. } => live.push(*note_id),
                NoteEvent::Off { note_id, .. } => live.retain(|id| id != note_id),
                NoteEvent::Expression { .. } => {}
            }
        }
        live
    }

    #[test]
    fn invalid_targets_dropped() {
        let mut state = project(&[2, 3, 4]);
        // The sender itself, master, unset, two hardware outputs, a missing channel, a
        // duplicate, and two good ones.
        add_send(&mut state, 2, &[2, 1, 0, 1000, 1001, 99, 4, 3, 3]);
        let rebuilt = rebuild(&mut state);
        let send = state.channels.get_mut(&2).unwrap().devices[0]
            .as_midi_send_mut()
            .unwrap();
        assert_eq!(send.effective(), &[3, 4]);
        assert!(send.blocked().is_empty());
        assert!(rebuilt.statuses.is_empty());
        assert_eq!(
            state.midi_sends.sends,
            vec![SendRef {
                channel_id: 2,
                device_index: 0
            }]
        );
    }

    #[test]
    fn loop_edge_is_blocked() {
        let mut state = project(&[2, 3]);
        add_send(&mut state, 2, &[3]);
        add_send(&mut state, 3, &[2]);
        let log_a = add_recorder(&mut state, 2);
        let log_b = add_recorder(&mut state, 3);

        let rebuilt = rebuild(&mut state);
        assert_eq!(rebuilt.statuses.len(), 1);
        assert!(matches!(
            &rebuilt.statuses[0],
            EngineStatus::MidiSendBlocked { channel_id: 3, ids, .. } if ids == &[2]
        ));
        // Nothing changed: no second status.
        assert!(rebuild(&mut state).statuses.is_empty());
        let b = state.channels.get_mut(&3).unwrap().devices[0]
            .as_midi_send_mut()
            .unwrap();
        assert!(b.effective().is_empty());
        assert_eq!(b.blocked(), &[2]);

        // A's events reach B once and are not delivered back to A.
        send_note(&mut state, 2, on(7, 60), 5);
        mix(&mut state);
        assert_eq!(ons(&log_a).len(), 1);
        assert_eq!(ons(&log_b).len(), 1);
        assert_eq!(ons(&log_b)[0].0, 5);
    }

    #[test]
    fn set_targets_closing_loop_emits_blocked() {
        let mut state = project(&[2, 3]);
        add_send(&mut state, 2, &[]);
        add_send(&mut state, 3, &[]);
        let path = DevicePath::root(0);
        let set = |channel_id, targets| AudioCommand::SetMidiSendTargets {
            channel_id,
            device_path: path,
            targets,
        };

        let effects = command(&mut state, set(2, vec![3]));
        assert!(effects.statuses.is_empty());
        let mut effects = command(&mut state, set(3, vec![2]));
        let status = effects.next_status().expect("a blocked status");
        let EngineStatus::MidiSendBlocked {
            channel_id,
            device_path,
            ids,
        } = &status
        else {
            panic!("unexpected status {status:?}");
        };
        assert_eq!((*channel_id, ids.as_slice()), (3, &[2][..]));
        assert_eq!(*device_path, DevicePath::root(0));

        // Clearing the list lifts it, and the empty set is reported.
        let mut effects = command(&mut state, set(3, vec![]));
        let status = effects.next_status().expect("the cleared set");
        assert!(matches!(
            status,
            EngineStatus::MidiSendBlocked { ids, .. } if ids.is_empty()
        ));
    }

    #[test]
    fn senders_are_ordered_before_their_targets() {
        // 4 -> 3 -> 2, and 5 alone: id order would put 2 first.
        let mut state = project(&[2, 3, 4, 5]);
        add_send(&mut state, 4, &[3]);
        add_send(&mut state, 3, &[2]);
        add_send(&mut state, 2, &[]);
        add_send(&mut state, 5, &[]);
        rebuild(&mut state);
        let order: Vec<ChannelId> = state
            .midi_sends
            .sends
            .iter()
            .map(|s| s.channel_id)
            .collect();
        assert_eq!(order, vec![4, 3, 2, 5]);
    }

    #[test]
    fn chain_of_sends_same_block() {
        let mut state = project(&[2, 3, 4]);
        // A (4) -> B (3) -> C (2).
        add_send(&mut state, 4, &[3]);
        add_send(&mut state, 3, &[2]);
        let log = add_recorder(&mut state, 2);
        rebuild(&mut state);

        send_note(&mut state, 4, on(9, 62), 17);
        mix(&mut state);
        let seen = ons(&log);
        assert_eq!(seen.len(), 1, "C hears A in the same block");
        assert_eq!(seen[0].0, 17, "at the same frame");
        assert_eq!(seen[0].1.key(), 62);
    }

    /// Notes at ticks that land off the block grid (25 frames per tick at 120 BPM).
    const NOTES: &[(NoteId, u8, Tick, Tick)] =
        &[(1, 60, 41, 90), (2, 64, 41, 60), (3, 67, 130, 70)];

    fn rendered_direct() -> Vec<f32> {
        let mut state = project(&[2, 3]);
        add_synth(&mut state, 3);
        add_clip(&mut state, 1, 3, NOTES, 400);
        rebuild(&mut state);
        start_transport(&mut state);
        play(&mut state, 140)
    }

    #[test]
    fn forwarded_clip_matches_direct_clip() {
        let direct = rendered_direct();
        assert!(direct.iter().any(|s| s.abs() > 1e-4), "the synth sounds");

        let mut state = project(&[2, 3]);
        add_send(&mut state, 2, &[3]);
        add_synth(&mut state, 3);
        add_clip(&mut state, 1, 2, NOTES, 400);
        rebuild(&mut state);
        start_transport(&mut state);
        let forwarded = play(&mut state, 140);
        let first = direct
            .iter()
            .zip(&forwarded)
            .position(|(a, b)| a.to_bits() != b.to_bits());
        assert_eq!(first, None, "forwarding changed the rendered samples");
    }

    #[test]
    fn chain_of_sends_matches_the_clip_placed_on_the_end() {
        let direct = rendered_direct();
        // A (4) -> B (3) -> C (2), the clip on A; the synth sits on C.
        let mut state = project(&[2, 3, 4]);
        add_send(&mut state, 4, &[3]);
        add_send(&mut state, 3, &[2]);
        add_synth(&mut state, 2);
        add_clip(&mut state, 1, 4, NOTES, 400);
        rebuild(&mut state);
        start_transport(&mut state);
        let chained = play(&mut state, 140);
        let first = direct
            .iter()
            .zip(&chained)
            .position(|(a, b)| a.to_bits() != b.to_bits());
        assert_eq!(first, None, "A -> B -> C changed the rendered samples");
    }

    #[test]
    fn thru_and_consume_decide_the_senders_own_sound() {
        let render = |thru: f32| {
            let mut state = project(&[2, 3]);
            add_send(&mut state, 2, &[3]);
            add_synth(&mut state, 2);
            add_synth(&mut state, 3);
            state.channels.get_mut(&2).unwrap().devices[0].set_parameter(0, thru);
            // Hear the sender alone: mute the target.
            state.channels.get_mut(&3).unwrap().mute = true;
            add_clip(&mut state, 1, 2, NOTES, 400);
            rebuild(&mut state);
            start_transport(&mut state);
            play(&mut state, 100)
        };
        let thru = render(1.0);
        let consume = render(0.0);
        assert!(
            thru.iter().any(|s| s.abs() > 1e-4),
            "Thru: the sender sounds"
        );
        assert!(
            consume.iter().all(|s| s.abs() < 1e-6),
            "Consume: the sender is silent"
        );

        // And the target sounds either way.
        let target = |thru: f32| {
            let mut state = project(&[2, 3]);
            add_send(&mut state, 2, &[3]);
            add_synth(&mut state, 2);
            add_synth(&mut state, 3);
            state.channels.get_mut(&2).unwrap().devices[0].set_parameter(0, thru);
            state.channels.get_mut(&2).unwrap().mute = true;
            add_clip(&mut state, 1, 2, NOTES, 400);
            rebuild(&mut state);
            start_transport(&mut state);
            play(&mut state, 100)
        };
        for thru in [1.0, 0.0] {
            assert!(target(thru).iter().any(|s| s.abs() > 1e-4), "thru {thru}");
        }
    }

    #[test]
    fn same_key_from_two_sources_is_independent() {
        let mut state = project(&[2, 3]);
        add_send(&mut state, 2, &[3]);
        let log = add_recorder(&mut state, 3);
        // B's own clip holds key 60 while A's clip starts and ends the same key.
        add_clip(&mut state, 1, 3, &[(1, 60, 0, 600)], 800);
        add_clip(&mut state, 2, 2, &[(1, 60, 40, 40)], 800);
        rebuild(&mut state);
        start_transport(&mut state);
        play(&mut state, 100); // 100 blocks = 6400 frames = 256 ticks

        let all = ons(&log);
        assert_eq!(all.len(), 2, "B's own note and the forwarded one");
        assert_ne!(all[0].1.note_id(), all[1].1.note_id());
        assert_eq!(offs(&log).len(), 1, "only the forwarded note ended");
        let own = sounding(&log);
        assert_eq!(own.len(), 1, "B's own C3 is still sounding: {own:?}");
    }

    #[test]
    fn retarget_releases_removed_targets() {
        let mut state = project(&[2, 3, 4]);
        add_send(&mut state, 2, &[3, 4]);
        let log_b = add_recorder(&mut state, 3);
        let log_c = add_recorder(&mut state, 4);
        rebuild(&mut state);

        send_note(&mut state, 2, on(9, 60), 0);
        mix(&mut state);
        assert_eq!(sounding(&log_b).len(), 1);
        assert_eq!(sounding(&log_c).len(), 1);

        // Drop C from the list: it is released at once, B keeps its note.
        command(
            &mut state,
            AudioCommand::SetMidiSendTargets {
                channel_id: 2,
                device_path: DevicePath::root(0),
                targets: vec![3],
            },
        );
        mix(&mut state);
        assert!(sounding(&log_c).is_empty(), "C has no sounding note");
        assert_eq!(sounding(&log_b).len(), 1, "B keeps its note");

        // The note-off still reaches B afterwards.
        send_note(&mut state, 2, off(9, 60), 0);
        mix(&mut state);
        assert!(sounding(&log_b).is_empty());
    }

    #[test]
    fn a_target_losing_validity_is_released_by_the_rebuild() {
        let mut state = project(&[2, 3, 4]);
        add_send(&mut state, 2, &[3, 4]);
        let log_c = add_recorder(&mut state, 4);
        rebuild(&mut state);
        send_note(&mut state, 2, on(9, 60), 0);
        mix(&mut state);
        assert_eq!(sounding(&log_c).len(), 1);

        // C is re-nested under a send that closes a loop: here, C now sends back to A.
        add_send(&mut state, 4, &[2]);
        rebuild(&mut state);
        // A's edge to C stays (A comes first), C's to A is blocked: nothing hangs on C.
        assert_eq!(sounding(&log_c).len(), 1);
        // Removing C from the project's channels drops it from the effective list.
        state.channels.remove(&4);
        rebuild(&mut state);
        let send = state.channels.get_mut(&2).unwrap().devices[0]
            .as_midi_send_mut()
            .unwrap();
        assert_eq!(send.effective(), &[3]);
    }

    #[test]
    fn bypass_releases_on_targets() {
        let mut state = project(&[2, 3]);
        add_send(&mut state, 2, &[3]);
        let log = add_recorder(&mut state, 3);
        rebuild(&mut state);
        send_note(&mut state, 2, on(9, 60), 0);
        mix(&mut state);
        assert_eq!(sounding(&log).len(), 1);

        state.channels.get_mut(&2).unwrap().devices[0].set_enabled(false);
        mix(&mut state);
        assert!(sounding(&log).is_empty(), "released one block later");
    }

    #[test]
    fn removing_send_or_sender_releases_targets() {
        // The send is removed.
        let mut state = project(&[2, 3]);
        let index = add_send(&mut state, 2, &[3]);
        let log = add_recorder(&mut state, 3);
        rebuild(&mut state);
        send_note(&mut state, 2, on(9, 60), 0);
        mix(&mut state);
        assert_eq!(sounding(&log).len(), 1);
        release_send_targets(&mut state, 2, &DevicePath::root(index));
        assert!(sounding(&log).is_empty());
        state.channels.get_mut(&2).unwrap().devices.clear();
        let rebuilt = rebuild(&mut state);
        assert!(state.midi_sends.sends.is_empty());
        assert_eq!(
            rebuilt.old.sends.len(),
            1,
            "the old order comes back to drop"
        );

        // The sender channel is removed.
        let mut state = project(&[2, 3]);
        add_send(&mut state, 2, &[3]);
        let log = add_recorder(&mut state, 3);
        rebuild(&mut state);
        send_note(&mut state, 2, on(9, 60), 0);
        mix(&mut state);
        assert_eq!(sounding(&log).len(), 1);
        release_channel_sends(&mut state, 2);
        state.channels.remove(&2);
        rebuild(&mut state);
        assert!(sounding(&log).is_empty());
    }

    /// Release timing for the clip tests below: `(absolute frame, event)` per block.
    fn play_logging(state: &mut EngineState, log: &Log, blocks: usize) -> Vec<(usize, NoteEvent)> {
        let mut seen = Vec::new();
        for block in 0..blocks {
            process_audio(state, BLOCK, SR, Instant::now());
            mix(state);
            for (frame, event) in log.lock().unwrap().drain(..) {
                seen.push((block * BLOCK + frame, event));
            }
        }
        seen
    }

    #[test]
    fn loop_wrap_releases_on_target() {
        let mut state = project(&[2, 3]);
        add_send(&mut state, 2, &[3]);
        let log = add_recorder(&mut state, 3);
        // The note sustains past the loop end at tick 400 (frame 10000).
        add_clip(&mut state, 1, 2, &[(1, 60, 40, 600)], 4000);
        state.loop_region = Some((0, 400));
        rebuild(&mut state);
        start_transport(&mut state);
        let seen = play_logging(&mut state, &log, 200);

        let off_frames: Vec<usize> = seen
            .iter()
            .filter(|(_, e)| matches!(e, NoteEvent::Off { .. }))
            .map(|(f, _)| *f)
            .collect();
        assert!(!off_frames.is_empty(), "{seen:?}");
        assert!(
            off_frames[0].abs_diff(10_000) <= 1,
            "released at the wrap frame, got {}",
            off_frames[0]
        );
        // The note restarts at the loop start and is released again on the next wrap.
        assert!(
            seen.iter()
                .filter(|(_, e)| matches!(e, NoteEvent::On { .. }))
                .count()
                >= 2
        );
    }

    #[test]
    fn stop_releases_forwarded_clip_notes() {
        let mut state = project(&[2, 3]);
        add_send(&mut state, 2, &[3]);
        let log = add_recorder(&mut state, 3);
        add_clip(&mut state, 1, 2, &[(1, 60, 40, 600)], 4000);
        rebuild(&mut state);
        start_transport(&mut state);
        play(&mut state, 40);
        assert_eq!(sounding(&log).len(), 1);

        command(&mut state, AudioCommand::Stop);
        mix(&mut state);
        mix(&mut state);
        assert!(sounding(&log).is_empty(), "stop ended the forwarded note");
        assert_eq!(offs(&log).len(), 1, "once, not twice");
    }

    #[test]
    fn bus_without_note_device_is_silent() {
        let render = |with_clip: bool| {
            let mut state = project(&[2]);
            // A bus holding only an audio effect (a constant level, so the output isn't silent).
            crate::audio::mixing::test_support::add_test_device(
                state.channels.get_mut(&2).unwrap(),
                0.25,
            );
            if with_clip {
                add_clip(&mut state, 1, 2, NOTES, 400);
            }
            rebuild(&mut state);
            start_transport(&mut state);
            play(&mut state, 140)
        };
        let with_clip = render(true);
        let without = render(false);
        assert!(without.iter().any(|s| s.abs() > 1e-4));
        assert_eq!(
            with_clip.iter().map(|s| s.to_bits()).collect::<Vec<_>>(),
            without.iter().map(|s| s.to_bits()).collect::<Vec<_>>(),
            "the clip changed nothing"
        );
    }

    #[test]
    fn nested_midi_send_is_refused() {
        let id = "sonara.builtin.midi_send";
        assert!(placement_allowed(id, &DevicePath::default()));
        assert!(!placement_allowed(id, &DevicePath::root(0)));
        assert!(!placement_allowed(id, &DevicePath::root(0).join(1)));
        // Any other device may go anywhere.
        assert!(placement_allowed(
            "sonara.builtin.transpose",
            &DevicePath::root(0)
        ));
    }

    /// Four synths on channels fed by sends from clip tracks, chained and fanned out.
    fn sends_graph(pool: Option<ChannelPool>) -> EngineState {
        let mut state = project(&[2, 3, 4, 5, 6]);
        add_send(&mut state, 6, &[2, 3]);
        add_send(&mut state, 5, &[6, 4]);
        for id in [2, 3, 4] {
            add_synth(&mut state, id);
        }
        add_synth(&mut state, 5);
        add_clip(&mut state, 1, 5, NOTES, 400);
        add_clip(&mut state, 2, 6, &[(1, 55, 100, 100)], 400);
        rebuild(&mut state);
        start_transport(&mut state);
        state.pool = pool;
        state
    }

    #[test]
    fn pool_output_matches_single_thread_with_sends() {
        let single = play(&mut sends_graph(None), 140);
        assert!(single.iter().any(|s| s.abs() > 1e-3), "the graph sounds");
        let pooled = play(&mut sends_graph(Some(ChannelPool::spawn(4, None))), 140);
        let first = single
            .iter()
            .zip(&pooled)
            .position(|(a, b)| a.to_bits() != b.to_bits());
        assert_eq!(first, None, "4 workers changed the output");
    }
}

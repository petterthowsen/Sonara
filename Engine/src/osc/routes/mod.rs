//! Routing of incoming OSC messages: split the address, then hand the message to the area that
//! owns its first segment. Each area file matches the full address and returns `false` for an
//! address it doesn't know.

mod audio;
mod audiofile;
mod channel;
mod clip;
mod device;
mod device_slots;
mod metronome;
mod plugin;
mod preview;
mod project;
mod render;
mod stage;
mod track;
mod transport;

use anyhow::Result;
use crossbeam::channel::Sender;
use rosc::{OscMessage, OscPacket};
use tracing::warn;

use super::parse::ArgError;
use super::server::OscServer;
use crate::audio::devices::parse_osc_device_addr;
use crate::audio::AudioCommand;
use crate::logging::LogWriters;
use crate::window_manager::WindowManager;

/// What a route handler needs: where to send commands and how to answer Godot directly.
pub(super) struct RouteCtx<'a> {
    /// The address of the message being routed, for warnings.
    pub addr: &'a str,
    /// Where commands for the command thread go.
    pub commands: &'a Sender<AudioCommand>,
    /// The server, to answer Godot directly and reach the AudioFileService.
    pub server: &'a OscServer,
    /// The log files `/project/init` rotates.
    pub log_writers: &'a LogWriters,
    /// The plugin GUI host windows.
    pub windows: &'a mut WindowManager,
}

/// A malformed message (`ArgError`) is logged at WARN and counts as handled, so it is neither
/// reported as an unknown address nor aborts the rest of a bundle. Any other error (a closed
/// command channel) goes on to the caller.
fn warn_on_arg_error(result: Result<bool>) -> Result<bool> {
    match result {
        Err(err) => match err.downcast::<ArgError>() {
            Ok(arg_error) => {
                warn!("{}", arg_error);
                Ok(true)
            }
            Err(err) => Err(err),
        },
        ok => ok,
    }
}

impl OscServer {
    /// Handle an incoming OSC packet
    pub(super) fn handle_packet(
        &self,
        packet: OscPacket,
        command_tx: &Sender<AudioCommand>,
        log_writers: &LogWriters,
        window_manager: &mut WindowManager,
    ) -> Result<()> {
        match packet {
            OscPacket::Message(msg) => {
                self.handle_message(msg, command_tx, log_writers, window_manager)
            }
            OscPacket::Bundle(bundle) => {
                for packet in bundle.content {
                    self.handle_packet(packet, command_tx, log_writers, window_manager)?;
                }
                Ok(())
            }
        }
    }

    /// Handle an individual OSC message
    fn handle_message(
        &self,
        msg: OscMessage,
        command_tx: &Sender<AudioCommand>,
        log_writers: &LogWriters,
        window_manager: &mut WindowManager,
    ) -> Result<()> {
        let addr = msg.addr.as_str();
        let args = &msg.args;

        // Split address into parts for path-based routing
        let parts: Vec<&str> = addr.split('/').filter(|s| !s.is_empty()).collect();

        let mut cx = RouteCtx {
            addr,
            commands: command_tx,
            server: self,
            log_writers,
            windows: window_manager,
        };

        if let Some((channel_id, device_path, action)) = parse_osc_device_addr(&parts) {
            return warn_on_arg_error(
                device::handle_device_message(channel_id, device_path, &action, args, &mut cx)
                    .map(|()| true),
            )
            .map(|_| ());
        }

        // Route based on the first address segment
        let handled = match parts.first().copied() {
            Some("transport") => warn_on_arg_error(transport::route(&parts, args, &mut cx))?,
            Some("project") => warn_on_arg_error(project::route(&parts, args, &mut cx))?,
            Some("channel") => {
                warn_on_arg_error(channel::route(&parts, args, &mut cx))?
                    || warn_on_arg_error(device::route(&parts, args, &mut cx))?
            }
            Some("track") => warn_on_arg_error(track::route(&parts, args, &mut cx))?,
            Some("clip") => warn_on_arg_error(clip::route(&parts, args, &mut cx))?,
            Some("plugin" | "plugins" | "builtin") => {
                warn_on_arg_error(plugin::route(&parts, args, &mut cx))?
            }
            Some("audio" | "engine") => warn_on_arg_error(audio::route(&parts, args, &mut cx))?,
            Some("render") => warn_on_arg_error(render::route(&parts, args, &mut cx))?,
            Some("stage") => warn_on_arg_error(stage::route(&parts, args, &mut cx))?,
            Some("metronome") => warn_on_arg_error(metronome::route(&parts, args, &mut cx))?,
            Some("audiofile") => warn_on_arg_error(audiofile::route(&parts, args, &cx))?,
            Some("preview") => warn_on_arg_error(preview::route(&parts, args, &cx))?,
            _ => false,
        };

        if !handled {
            warn!("Unknown OSC address: {}", addr);
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::io::AudioFileService;
    use crate::audio::types::ParamSetValue;
    use crossbeam::channel::Receiver;
    use rosc::OscType::{Float, Int, Long, String as Str};
    use rosc::{OscBundle, OscType};
    use std::sync::{Arc, Mutex};

    /// A server on an ephemeral port, a command channel to read what the routes sent, and the
    /// other things `handle_message` needs.
    struct Harness {
        server: OscServer,
        tx: Sender<AudioCommand>,
        rx: Receiver<AudioCommand>,
        log_writers: LogWriters,
        windows: WindowManager,
    }

    impl Harness {
        fn new() -> Self {
            let afs = AudioFileService::idle();
            let (tx, rx) = crossbeam::channel::unbounded();
            let file = || Arc::new(Mutex::new(tempfile::tempfile().expect("temp file")));
            Self {
                server: OscServer::new(0, Arc::new(Mutex::new(afs))).expect("bind"),
                tx,
                rx,
                log_writers: LogWriters {
                    dir: std::env::temp_dir(),
                    info: file(),
                    warn: file(),
                    combined: file(),
                },
                windows: WindowManager::detached(),
            }
        }

        /// Send one message through the router; returns the commands it produced.
        fn send(&mut self, addr: &str, args: Vec<OscType>) -> Vec<AudioCommand> {
            let packet = OscPacket::Message(OscMessage {
                addr: addr.to_string(),
                args,
            });
            self.send_packet(packet)
        }

        fn send_packet(&mut self, packet: OscPacket) -> Vec<AudioCommand> {
            self.server
                .handle_packet(packet, &self.tx, &self.log_writers, &mut self.windows)
                .expect("a malformed message is not an error");
            self.rx.try_iter().collect()
        }
    }

    #[test]
    fn engine_quit_sets_the_flag_and_sends_no_command() {
        let mut h = Harness::new();
        assert!(!h.server.quit_requested());
        assert!(h.send("/engine/quit", vec![]).is_empty());
        assert!(h.server.quit_requested());
    }

    #[test]
    fn float_arguments_are_strict_where_they_always_were() {
        let mut h = Harness::new();
        let sent = h.send("/channel/3/volume", vec![Float(-6.0)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetChannelVolume { id: 3, db }] if *db == -6.0
        ));
        // An int fader value was never accepted: dropped (and now logged), not an error.
        assert!(h.send("/channel/3/volume", vec![Int(-6)]).is_empty());
        assert!(h.send("/channel/3/volume", vec![]).is_empty());
        assert!(h.send("/channel/x/volume", vec![Float(0.0)]).is_empty());
    }

    #[test]
    fn send_amount_accepts_float_or_int_and_add_defaults() {
        let mut h = Harness::new();
        let sent = h.send("/channel/2/send/5/amount", vec![Int(-3)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetSendAmount { channel_id: 2, target_channel_id: 5, amount_db }]
                if *amount_db == -3.0
        ));
        // Not a number: still rejected (a Long never worked here).
        assert!(h.send("/channel/2/send/5/amount", vec![Long(1)]).is_empty());
        // `add` with no arguments takes -12 dB, post-fader.
        let sent = h.send("/channel/2/send/5/add", vec![]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::AddSend { amount_db, pre_fader: false, .. }] if *amount_db == -12.0
        ));
        // A mistyped optional value falls back to its default instead of dropping the message.
        let sent = h.send("/channel/2/send/5/add", vec![Str("x".into()), Float(1.0)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::AddSend { amount_db, pre_fader: false, .. }] if *amount_db == -12.0
        ));
        let sent = h.send("/channel/2/send/5/add", vec![Float(-6.0), Int(1)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::AddSend { amount_db, pre_fader: true, .. }] if *amount_db == -6.0
        ));
    }

    #[test]
    fn pan_right_is_optional_and_ignored_when_not_a_float() {
        let mut h = Harness::new();
        let sent = h.send("/channel/2/pan", vec![Float(-0.5)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetChannelPan {
                id: 2,
                pan_right: None,
                ..
            }]
        ));
        let sent = h.send("/channel/2/pan", vec![Float(-0.5), Float(0.5)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetChannelPan { pan_right: Some(r), .. }] if *r == 0.5
        ));
        let sent = h.send("/channel/2/pan", vec![Float(-0.5), Int(1)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetChannelPan {
                pan_right: None,
                ..
            }]
        ));
    }

    /// The 22 arguments (the form before the mic setup) of a `/stage/set` for a 30 x 20 x 12 m room.
    fn stage_set_args() -> Vec<OscType> {
        let mut args = vec![
            Float(30.0),
            Float(20.0),
            Float(12.0),
            Float(15.0),
            Float(14.0),
            Float(1.6),
            Float(2.5),
            Float(-4.0),
            Int(1),
            Int(1),
        ];
        for surface in 0..6 {
            args.push(Float(0.5 + surface as f32 * 0.05));
            args.push(Float(0.1 * surface as f32));
        }
        args
    }

    #[test]
    fn stage_set_reads_the_room() {
        let mut h = Harness::new();
        let sent = h.send("/stage/set", stage_set_args());
        let [AudioCommand::SetStage { room }] = sent.as_slice() else {
            panic!("expected SetStage, got {sent:?}");
        };
        assert_eq!((room.width, room.depth, room.height), (30.0, 20.0, 12.0));
        assert_eq!(
            (room.listener.x, room.listener.y, room.listener.z),
            (15.0, 14.0, 1.6)
        );
        assert_eq!((room.decay_s, room.tail_db), (2.5, -4.0));
        assert!(room.distance_delay);
        assert_eq!(
            room.output_mode,
            crate::audio::stage::OutputMode::ReflectionsOnly
        );
        assert_eq!(room.surfaces[0].gain, 0.5);
        assert_eq!(room.surfaces[5].hf_damping, 0.5);
        assert_eq!(room.surfaces[3].gain, 0.65);
        assert_eq!(room.mic, crate::audio::stage::MicSetup::Pan);

        // A short or mistyped message is dropped.
        let mut short = stage_set_args();
        short.pop();
        assert!(h.send("/stage/set", short).is_empty());
        let mut bad = stage_set_args();
        bad[8] = Float(1.0);
        assert!(h.send("/stage/set", bad).is_empty());
    }

    #[test]
    fn stage_set_reads_the_mic_setup() {
        use crate::audio::stage::MicSetup;
        let mut h = Harness::new();
        // 22 arguments: an older sender means Pan.
        let sent = h.send("/stage/set", stage_set_args());
        let [AudioCommand::SetStage { room }] = sent.as_slice() else {
            panic!("expected SetStage, got {sent:?}");
        };
        assert_eq!(room.mic, MicSetup::Pan);
        // 23 arguments: the last is the setup; an unknown value falls back to Pan.
        for (value, expected) in [
            (6, MicSetup::Decca),
            (2, MicSetup::Blumlein),
            (99, MicSetup::Pan),
        ] {
            let mut args = stage_set_args();
            args.push(Int(value));
            let sent = h.send("/stage/set", args);
            let [AudioCommand::SetStage { room }] = sent.as_slice() else {
                panic!("expected SetStage, got {sent:?}");
            };
            assert_eq!(room.mic, expected);
        }
        // 24 arguments, or a mistyped mic, are refused.
        let mut long = stage_set_args();
        long.push(Int(1));
        long.push(Int(1));
        assert!(h.send("/stage/set", long).is_empty());
        let mut bad = stage_set_args();
        bad.push(Float(1.0));
        assert!(h.send("/stage/set", bad).is_empty());
    }

    #[test]
    fn metronome_enabled_and_audition() {
        let mut h = Harness::new();
        let sent = h.send("/metronome/enabled", vec![Int(1)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetMetronomeEnabled(true)]
        ));
        let sent = h.send("/metronome/enabled", vec![Int(0)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetMetronomeEnabled(false)]
        ));
        assert!(h.send("/metronome/enabled", vec![Float(1.0)]).is_empty());
        assert!(h.send("/metronome/enabled", vec![]).is_empty());

        let sent = h.send("/metronome/audition", vec![Int(3)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::MetronomeAudition(3)]
        ));
        assert!(h.send("/metronome/audition", vec![Int(0)]).is_empty());
        assert!(h.send("/metronome/audition", vec![Int(5)]).is_empty());
        assert!(h.send("/metronome/audition", vec![]).is_empty());
        assert!(h.send("/metronome/other", vec![Int(1)]).is_empty());
    }

    #[test]
    fn metronome_sound_reads_the_knobs() {
        use crate::audio::metronome::SoundKind;
        let mut h = Harness::new();
        let args = vec![
            Int(1),
            Float(1500.0),
            Float(0.1),
            Float(0.25),
            Float(-12.0),
            Float(9.0),
            Int(5),
        ];
        let sent = h.send("/metronome/sound", args.clone());
        let [AudioCommand::SetMetronomeSound(sound)] = sent.as_slice() else {
            panic!("expected one SetMetronomeSound, got {sent:?}");
        };
        assert_eq!(sound.kind, SoundKind::Wood);
        assert_eq!(
            (
                sound.tune_hz,
                sound.decay_s,
                sound.tone,
                sound.level_db,
                sound.emphasis_volume_db,
                sound.emphasis_pitch_st
            ),
            (1500.0, 0.1, 0.25, -12.0, 9.0, 5.0)
        );
        let mut short = args.clone();
        short.pop();
        assert!(h.send("/metronome/sound", short).is_empty());
        let mut bad = args;
        bad[0] = Float(1.0);
        assert!(h.send("/metronome/sound", bad).is_empty());
    }

    #[test]
    fn metronome_pattern_reads_levels_and_an_empty_one_removes() {
        let mut h = Harness::new();
        let mut args = vec![Int(7), Int(8), Int(8)];
        args.extend([4, 0, 2, 0, 2, 0, 1].map(Int));
        let sent = h.send("/metronome/pattern", args);
        let [AudioCommand::SetMetronomePattern {
            num,
            den,
            resolution,
            levels,
        }] = sent.as_slice()
        else {
            panic!("expected one SetMetronomePattern, got {sent:?}");
        };
        assert_eq!((*num, *den, *resolution), (7, 8, 8));
        assert_eq!(levels, &[4, 0, 2, 0, 2, 0, 1]);

        // No levels: the command carries an empty list, which the engine reads as remove.
        let sent = h.send("/metronome/pattern", vec![Int(7), Int(8), Int(8)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetMetronomePattern { levels, .. }] if levels.is_empty()
        ));

        // Malformed messages are dropped: a level above 4, a wrong type, a missing resolution.
        let bad_level = vec![Int(4), Int(4), Int(4), Int(1), Int(5), Int(1), Int(1)];
        assert!(h.send("/metronome/pattern", bad_level).is_empty());
        let bad_type = vec![Int(4), Int(4), Int(4), Int(1), Float(1.0), Int(1), Int(1)];
        assert!(h.send("/metronome/pattern", bad_type).is_empty());
        assert!(h
            .send("/metronome/pattern", vec![Int(4), Int(4)])
            .is_empty());
        assert!(h
            .send("/metronome/pattern", vec![Int(0), Int(4), Int(4), Int(1)])
            .is_empty());
    }

    #[test]
    fn metronome_pattern_with_a_wrong_step_count_is_ignored_by_the_engine() {
        use crate::audio::commands::{process_command, CommandEffects};
        use crate::audio::state::EngineState;
        // The route passes a wrong step count through; applying it warns and changes nothing.
        let mut h = Harness::new();
        let sent = h.send(
            "/metronome/pattern",
            vec![Int(4), Int(4), Int(8), Int(4), Int(1), Int(1)],
        );
        assert_eq!(sent.len(), 1);
        let mut state = EngineState::default();
        let mut effects = CommandEffects::default();
        for cmd in sent {
            process_command(&mut state, cmd, 64, &mut effects);
        }
        assert!(state.metronome.patterns().is_empty());
    }

    #[test]
    fn metronome_clear_sends_the_command() {
        let mut h = Harness::new();
        let sent = h.send("/metronome/clear", vec![]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::ClearMetronomePatterns]
        ));
    }

    #[test]
    fn stage_return_takes_a_channel_id() {
        let mut h = Harness::new();
        let sent = h.send("/stage/return", vec![Int(7)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetStageReturn { id: 7 }]
        ));
        let sent = h.send("/stage/return", vec![Int(0)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetStageReturn { id: 0 }]
        ));
        assert!(h.send("/stage/return", vec![Int(-1)]).is_empty());
        assert!(h.send("/stage/return", vec![]).is_empty());
        assert!(h.send("/stage/other", vec![Int(1)]).is_empty());
    }

    #[test]
    fn channel_stage_reads_the_placement_and_pan_mode_accepts_stage() {
        use crate::audio::stage::SumMode;
        let mut h = Harness::new();
        let args = vec![
            Float(3.0),
            Float(8.0),
            Int(2),
            Float(4.5),
            Float(-30.0),
            Int(1),
            Int(1),
        ];
        let sent = h.send("/channel/5/stage", args);
        let [AudioCommand::SetChannelStage { id: 5, params }] = sent.as_slice() else {
            panic!("expected SetChannelStage, got {sent:?}");
        };
        assert_eq!((params.x, params.y, params.z), (3.0, 8.0, 2.0));
        assert_eq!((params.size, params.rotation_deg), (4.5, -30.0));
        assert_eq!(params.sum_mode, SumMode::Mid);
        assert!(params.has_room);
        assert!(h.send("/channel/5/stage", vec![Float(3.0)]).is_empty());

        let sent = h.send("/channel/5/pan_mode", vec![Int(4)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetChannelPanMode { id: 5, mode: 4 }]
        ));
    }

    #[test]
    fn loop_still_needs_exactly_three_ints() {
        let mut h = Harness::new();
        let sent = h.send("/transport/loop", vec![Int(1), Int(0), Int(3840)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetLoop {
                enabled: true,
                start: 0,
                end: 3840
            }]
        ));
        assert!(h.send("/transport/loop", vec![Int(1), Int(0)]).is_empty());
        assert!(h
            .send("/transport/loop", vec![Int(1), Int(0), Int(3840), Int(1)])
            .is_empty());
    }

    #[test]
    fn aux_out_rejects_negative_indices_and_route_maps_them_to_none() {
        let mut h = Harness::new();
        assert!(h
            .send("/channel/2/aux_out", vec![Int(-1), Int(4)])
            .is_empty());
        let sent = h.send("/channel/2/aux_out", vec![Int(1), Int(4)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetAuxOut {
                id: 2,
                bus_index: 1,
                target_id: 4
            }]
        ));
        let sent = h.send("/channel/2/route", vec![Int(-1)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetChannelRoute {
                id: 2,
                output_id: None
            }]
        ));
    }

    #[test]
    fn device_param_takes_a_float_value_or_an_enum_index() {
        let mut h = Harness::new();
        let sent = h.send("/channel/2/device/1/param/7", vec![Float(0.25)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetDeviceParameter {
                channel_id: 2,
                param_id: 7,
                value: ParamSetValue::Normalized(v),
                ..
            }] if *v == 0.25
        ));
        let sent = h.send("/channel/2/device/1/param/7", vec![Int(3)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetDeviceParameter {
                value: ParamSetValue::Index(3),
                ..
            }]
        ));
        assert!(h
            .send("/channel/2/device/1/param/7", vec![Str("x".into())])
            .is_empty());
    }

    #[test]
    fn sampler_audition_still_accepts_whole_numbers_sent_as_floats() {
        let mut h = Harness::new();
        let sent = h.send(
            "/channel/2/device/0/audition",
            vec![Float(60.0), Int(200), Long(1)],
        );
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::AuditionDevice {
                note: 60,
                velocity: 127,
                is_note_on: true,
                ..
            }]
        ));
        // The Layer slot variant is strict about ints.
        assert!(h
            .send(
                "/channel/2/device/0/slot/1/audition",
                vec![Float(60.0), Int(100), Int(1)],
            )
            .is_empty());
    }

    #[test]
    fn a_malformed_message_does_not_stop_the_rest_of_its_bundle() {
        let mut h = Harness::new();
        let msg = |addr: &str, args: Vec<OscType>| {
            OscPacket::Message(OscMessage {
                addr: addr.to_string(),
                args,
            })
        };
        let bundle = OscPacket::Bundle(OscBundle {
            timetag: (0, 1).into(),
            content: vec![
                msg("/channel/3/volume", vec![Int(1)]),
                msg("/channel/3/mute", vec![Int(1)]),
            ],
        });
        let sent = h.send_packet(bundle);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetChannelMute { id: 3, mute: true }]
        ));
    }

    #[test]
    fn channel_enabled_route_sends_the_command() {
        let mut h = Harness::new();
        let sent = h.send("/channel/3/enabled", vec![Int(0)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetChannelEnabled {
                id: 3,
                enabled: false
            }]
        ));
    }

    #[test]
    fn preview_routes_send_the_preview_commands() {
        let mut h = Harness::new();
        let sent = h.send("/preview/play", vec![Str("/s/kick.wav".into()), Float(0.5)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::BeginPreview { req_id, path, start_s }]
                if req_id.starts_with("preview:") && path == "/s/kick.wav" && *start_s == 0.5
        ));
        let sent = h.send("/preview/seek", vec![Float(1.25)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SeekPreview { pos_s }] if *pos_s == 1.25
        ));
        let sent = h.send("/preview/stop", vec![]);
        assert!(matches!(sent.as_slice(), [AudioCommand::StopPreview]));
        // Missing arguments are dropped, not an error.
        assert!(h
            .send("/preview/play", vec![Str("/s/kick.wav".into())])
            .is_empty());
        assert!(h.send("/preview/seek", vec![]).is_empty());
    }

    #[test]
    fn engine_routes_reach_the_audio_area() {
        let mut h = Harness::new();
        let sent = h.send("/engine/perf/subscribe", vec![]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetPerfSubscription { subscribe: true }]
        ));
        let sent = h.send("/engine/perf/unsubscribe", vec![]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetPerfSubscription { subscribe: false }]
        ));
        let sent = h.send("/engine/threads/set", vec![Int(4)]);
        assert!(matches!(
            sent.as_slice(),
            [AudioCommand::SetProcessingThreads { threads: 4 }]
        ));
        assert!(h.send("/engine/threads/set", vec![Int(-1)]).is_empty());
    }

    #[test]
    fn an_unknown_address_is_ignored() {
        let mut h = Harness::new();
        assert!(h.send("/no/such/route", vec![Int(1)]).is_empty());
        assert!(h.send("/transport/bogus", vec![]).is_empty());
        assert!(h.send("/channel/2/device/0/bogus", vec![]).is_empty());
    }

    /// A tracing writer that keeps what was logged, to check the WARN text.
    #[derive(Clone, Default)]
    struct Captured(Arc<Mutex<Vec<u8>>>);

    impl std::io::Write for Captured {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for Captured {
        type Writer = Captured;
        fn make_writer(&'a self) -> Self::Writer {
            self.clone()
        }
    }

    #[test]
    fn a_malformed_message_logs_a_warn_naming_the_address_and_expected_type() {
        let mut h = Harness::new();
        let captured = Captured::default();
        let subscriber = tracing_subscriber::fmt()
            .with_writer(captured.clone())
            .with_ansi(false)
            .finish();
        tracing::subscriber::with_default(subscriber, || {
            h.send("/channel/3/volume", vec![Int(1)]);
            h.send("/channel/x/mute", vec![Int(1)]);
        });
        let log = String::from_utf8(captured.0.lock().unwrap().clone()).unwrap();
        assert!(
            log.contains("WARN")
                && log.contains("/channel/3/volume: argument 0: expected f, got (i)"),
            "{log}"
        );
        assert!(
            log.contains("/channel/x/mute: path segment 'x': expected usize"),
            "{log}"
        );
    }
}

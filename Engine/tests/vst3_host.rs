//! End to end: a real `plugin_host` process hosts a VST3 plugin over the IPC protocol
//! (spec 028, phase 2). Skips (passes) when no VST3 bundle is installed.
//!
//! Set `VST3_TEST_BUNDLE` to a `.vst3` bundle to test a specific plugin; otherwise the first
//! of a few common instruments found under the default scan paths is used.

use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use engine::audio::devices::clap_host::vst3_discovery;
use engine::audio::ipc::{
    BlockEvent, PluginCommand, PluginFormat, PluginResponse, ProcessManager, EVENT_NOTE_ON,
};
use engine::audio::ipc::{InstanceConnection, REQUEST_TIMEOUT};

const RATE: f32 = 48_000.0;
const FRAMES: usize = 256;

/// `plugin_host` must sit next to the running executable; tests run from `target/debug/deps`.
fn link_plugin_host() {
    let host = PathBuf::from(env!("CARGO_BIN_EXE_plugin_host"));
    let exe = std::env::current_exe().unwrap();
    let link = exe.parent().unwrap().join("plugin_host");
    if !link.exists() {
        let _ = std::os::unix::fs::symlink(&host, &link);
    }
}

fn find_bundle() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("VST3_TEST_BUNDLE") {
        return Some(PathBuf::from(path));
    }
    let home = std::env::var("HOME").unwrap_or_default();
    ["Surge XT.vst3", "sfizz.vst3"]
        .iter()
        .flat_map(|name| {
            [
                Path::new("/usr/lib/vst3").join(name),
                Path::new(&home).join(".vst3").join(name),
            ]
        })
        .find(|path| path.is_dir())
}

/// Publish one block and wait for the host to answer it. Returns the output peak.
fn run_block(connection: &InstanceConnection, events: &[BlockEvent], input_tone: bool) -> f32 {
    let memory = connection.shared_memory();
    let control = memory.control();
    {
        let dst = memory.input_events();
        dst[..events.len()].copy_from_slice(events);
    }
    {
        // Effects get a tone on both planes; instruments ignore the input.
        let plane = memory.input();
        plane.fill(0.0);
        if input_tone {
            let max_frames = memory.layout().max_frames;
            for channel in 0..2 {
                for (i, sample) in plane[channel * max_frames..][..FRAMES]
                    .iter_mut()
                    .enumerate()
                {
                    *sample = (i as f32 * 0.05).sin() * 0.5;
                }
            }
        }
    }
    let transport = memory.transport();
    transport.tempo = 120.0;
    transport.tsig_num = 4;
    transport.tsig_den = 4;
    transport.flags = 1;
    control
        .input_event_count
        .store(events.len() as u32, Ordering::Relaxed);
    control.input_frames.store(FRAMES as u32, Ordering::Relaxed);
    let seq = control.request_seq.load(Ordering::Acquire) + 1;
    control.request_seq.store(seq, Ordering::Release);
    connection.host_shared().ring();

    let deadline = Instant::now() + Duration::from_secs(5);
    while control.done_seq.load(Ordering::Acquire) != seq {
        assert!(
            Instant::now() < deadline,
            "the host never answered block {seq}"
        );
        std::thread::sleep(Duration::from_micros(200));
    }
    assert_eq!(
        control.status.load(Ordering::Relaxed),
        0,
        "process() failed"
    );
    memory
        .output()
        .iter()
        .fold(0.0f32, |peak, sample| peak.max(sample.abs()))
}

#[test]
fn a_vst3_plugin_runs_in_the_host() {
    let Some(bundle) = find_bundle() else {
        eprintln!("no VST3 bundle installed: skipping");
        return;
    };
    link_plugin_host();

    // Discovery goes through moduleinfo.json or a throwaway `plugin_host --scan-vst3`.
    let plugins = vst3_discovery::scan_bundle(&bundle);
    let Some(plugin) = plugins.first() else {
        eprintln!("{} has no audio classes: skipping", bundle.display());
        return;
    };
    eprintln!("testing {} ({})", plugin.name, plugin.id);
    let is_instrument = plugin.category == engine::audio::devices::DeviceCategory::Instrument;

    let manager = ProcessManager::new();
    let connection = manager
        .spawn_instance(
            1,
            "vst3-test",
            bundle.clone(),
            plugin.id.clone(),
            RATE,
            FRAMES,
            PluginFormat::Vst3,
        )
        .expect("the VST3 plugin loads");
    let request = |command| connection.request(command, REQUEST_TIMEOUT).unwrap();

    match request(PluginCommand::Activate { sample_rate: RATE }) {
        PluginResponse::ActivateResult { success: true, .. } => {}
        other => panic!("activation failed: {other:?}"),
    }

    // Parameters: the list is not empty, and a value written reads back.
    let PluginResponse::ParameterInfo { params } = request(PluginCommand::GetParameterInfo) else {
        panic!("no parameter info");
    };
    eprintln!("{} parameters", params.len());
    if let Some(param) = params
        .iter()
        .find(|p| p.is_automation_safe && !p.is_read_only && !p.is_stepped)
    {
        connection
            .send(PluginCommand::SetParameter {
                param_id: param.id,
                value: 0.25,
            })
            .unwrap();
        match request(PluginCommand::GetParameter { param_id: param.id }) {
            PluginResponse::ParameterValue { value, .. } => {
                assert!(
                    (value - 0.25).abs() < 0.02,
                    "{} read back {value}",
                    param.name
                )
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    // Audio: a note makes an instrument sound; blocks always complete.
    let tone = !is_instrument;
    let silence = run_block(&connection, &[], tone);
    let note = [BlockEvent::note(10, 1, 60, 0.8, true)];
    assert_eq!(note[0].kind, EVENT_NOTE_ON);
    let mut peak = run_block(&connection, &note, tone);
    for _ in 0..200 {
        peak = peak.max(run_block(&connection, &[], tone));
    }
    eprintln!("silence peak {silence}, note peak {peak}");
    assert!(peak.is_finite());
    if plugin.name.contains("Surge") {
        // An instrument plays the note; an effect passes the tone.
        assert!(peak > 0.001, "{} produced no sound", plugin.name);
    }

    // State: save, restore and save again gives a state the plugin accepts.
    let PluginResponse::StateSaved { state } = request(PluginCommand::SaveState) else {
        panic!("SaveState failed");
    };
    assert!(
        state.starts_with(b"SVST3\0\0\x01"),
        "state is not a VST3 blob"
    );
    match request(PluginCommand::LoadState {
        state: state.clone(),
    }) {
        PluginResponse::StateLoadResult { success: true, .. } => {}
        other => panic!("LoadState failed: {other:?}"),
    }
    match request(PluginCommand::LoadState {
        state: b"CLAP state".to_vec(),
    }) {
        PluginResponse::StateLoadResult { success: false, .. } => {}
        other => panic!("a foreign blob must be refused: {other:?}"),
    }

    // Reset and re-activation keep the plugin working.
    assert!(matches!(
        request(PluginCommand::Reset),
        PluginResponse::ResetComplete
    ));
    run_block(&connection, &note, tone);

    assert!(matches!(
        request(PluginCommand::Deactivate),
        PluginResponse::DeactivateResult { success: true, .. }
    ));
    assert!(matches!(
        request(PluginCommand::Unload),
        PluginResponse::Unloaded
    ));
}

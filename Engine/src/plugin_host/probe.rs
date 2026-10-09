//! `plugin_host --probe`: load one plugin standalone and report what it does.
//!
//! Runs the same load, activate and process code paths the engine uses (one stereo input, one
//! stereo output, notes as CLAP note events), but in one process with no engine, no Godot and no
//! IPC, so a plugin bug can be reproduced and debugged on its own:
//!
//! ```text
//! plugin_host --probe ~/.clap/Dragonfly.clap --id michaelwillis.dragonfly.room
//! gdb --args target/release/plugin_host --probe ~/.clap/Foo.clap
//! ```
//!
//! It prints the descriptor, extensions, parameters, ports and latency, processes 1 s of silence
//! followed by 1 s with a note (C3, held 0.5 s), and reports per-block timing and output levels.

use std::path::PathBuf;
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};

use clack_extensions::audio_ports::{AudioPortFlags, AudioPortInfoBuffer, PluginAudioPorts};
use clack_extensions::gui::PluginGui;
use clack_extensions::latency::PluginLatency;
use clack_extensions::note_ports::{NotePortInfoBuffer, PluginNotePorts};
use clack_extensions::params::{ParamInfoBuffer, ParamInfoFlags, PluginParams};
use clack_extensions::state::PluginState as ClapState;
use clack_extensions::timer::PluginTimer;
use clack_host::events::event_types::{NoteOffEvent, NoteOnEvent};
use clack_host::events::io::{EventBuffer, InputEvents, OutputEvents};
use clack_host::events::Pckn;
use clack_host::prelude::*;
use clack_host::process::StartedPluginAudioProcessor;

use crate::audio::ipc::HostMessage;
use crate::plugin_host::host::SubprocessHost;
use crate::plugin_host::operations::load_plugin;
use crate::plugin_host::vst3::Vst3Instance;

/// Middle C (C3) = MIDI note 60.
const PROBE_NOTE: u8 = 60;
const PROBE_VELOCITY: f64 = 0.8;

/// What to probe and how.
#[derive(Debug, Clone)]
pub struct ProbeOptions {
    pub path: PathBuf,
    /// Plugin id inside the bundle; the first plugin when None.
    pub plugin_id: Option<String>,
    pub sample_rate: f64,
    pub block_frames: u32,
}

impl ProbeOptions {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            plugin_id: None,
            sample_rate: 48_000.0,
            block_frames: 512,
        }
    }
}

/// Run the probe. Returns the process exit code: 0 when the plugin loaded, activated and
/// processed every block without an error.
pub fn run(options: &ProbeOptions) -> i32 {
    // A `.vst3` bundle takes the VST3 path (spec 028, phase 1); everything else is CLAP.
    let result = if options.path.extension().is_some_and(|ext| ext == "vst3") {
        probe_vst3(options)
    } else {
        probe(options)
    };
    match result {
        Ok(errors) if errors == 0 => {
            println!("\nResult: OK");
            0
        }
        Ok(errors) => {
            println!("\nResult: {} problem(s), see above", errors);
            1
        }
        Err(e) => {
            println!("\nResult: FAILED: {}", e);
            1
        }
    }
}

fn cstr(value: Option<&std::ffi::CStr>) -> String {
    value
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn bytes_str(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes)
        .trim_end_matches('\0')
        .to_string()
}

/// A parameter value without f32-to-f64 noise: at most 4 decimals, trailing zeros dropped.
fn num(value: f64) -> String {
    let text = format!("{:.4}", value);
    text.trim_end_matches('0').trim_end_matches('.').to_string()
}

fn ms(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1000.0
}

fn db(peak: f32) -> String {
    if peak <= 0.0 {
        "-inf dBFS".to_string()
    } else {
        format!("{:.1} dBFS", 20.0 * peak.log10())
    }
}

/// Probe the plugin; returns the number of problems found after it loaded.
fn probe(options: &ProbeOptions) -> Result<u32, String> {
    let mut problems = 0u32;
    println!("Probing {}", options.path.display());

    // SAFETY: loading a plugin runs its code; that's the point of the probe.
    let bundle = unsafe { PluginBundle::load(&options.path) }
        .map_err(|e| format!("Failed to load bundle: {:?}", e))?;
    let factory = bundle
        .get_plugin_factory()
        .ok_or_else(|| "The bundle has no plugin factory".to_string())?;

    println!("\nPlugins in the bundle:");
    let mut chosen = None;
    for descriptor in factory.plugin_descriptors() {
        let id = cstr(descriptor.id());
        let wanted = match &options.plugin_id {
            Some(wanted) => *wanted == id,
            None => chosen.is_none(),
        };
        println!(
            "  {} {} ({})",
            if wanted { "*" } else { " " },
            id,
            cstr(descriptor.name())
        );
        if wanted && chosen.is_none() {
            chosen = Some((
                id,
                cstr(descriptor.name()),
                cstr(descriptor.vendor()),
                cstr(descriptor.version()),
                cstr(descriptor.description()),
                descriptor
                    .features()
                    .map(|f| f.to_string_lossy().into_owned())
                    .collect::<Vec<_>>(),
            ));
        }
    }
    let Some((plugin_id, name, vendor, version, description, features)) = chosen else {
        return Err(match &options.plugin_id {
            Some(id) => format!("Plugin {} is not in the bundle", id),
            None => "The bundle has no plugins".to_string(),
        });
    };

    println!("\nDescriptor:");
    println!("  id:          {}", plugin_id);
    println!("  name:        {}", name);
    println!("  vendor:      {}", vendor);
    println!("  version:     {}", version);
    println!("  description: {}", description);
    println!("  features:    {}", features.join(", "));

    let (event_tx, event_rx) = mpsc::channel::<HostMessage>();
    let load_start = Instant::now();
    let (_bundle, mut instance, shared) = load_plugin(
        &options.path,
        &plugin_id,
        options.sample_rate as f32,
        options.block_frames as usize,
        1,
        event_tx,
    )?;
    println!("\nInstance created in {:.1} ms", ms(load_start.elapsed()));

    print_extensions(&mut instance);
    print_parameters(&mut instance);
    print_ports(&mut instance);
    problems += check_state(&mut instance);

    // Activate like the engine does: min 1 frame, max the block size.
    let config = PluginAudioConfiguration {
        sample_rate: options.sample_rate,
        min_frames_count: 1,
        max_frames_count: options.block_frames,
    };
    let activate_start = Instant::now();
    let stopped = instance
        .activate(|_, _| (), config)
        .map_err(|e| format!("Activation failed: {:?}", e))?;
    let activate_time = activate_start.elapsed();
    let latency = {
        let mut handle = instance.plugin_handle();
        handle
            .get_extension::<PluginLatency>()
            .map(|latency| latency.get(&mut handle))
    };
    println!(
        "\nActivated at {} Hz, max {} frames, in {:.1} ms",
        options.sample_rate,
        options.block_frames,
        ms(activate_time)
    );
    match latency {
        Some(frames) => println!(
            "Latency: {} frames ({:.2} ms)",
            frames,
            frames as f64 * 1000.0 / options.sample_rate
        ),
        None => println!("Latency: no latency extension (0 frames)"),
    }

    let mut started = stopped
        .start_processing()
        .map_err(|e| format!("start_processing failed: {:?}", e))?;
    problems += process_blocks(&mut started, &mut instance, &shared, options);
    let stopped = started.stop_processing();
    instance.deactivate(stopped);
    println!("Deactivated");

    let events: Vec<HostMessage> = event_rx.try_iter().collect();
    if !events.is_empty() {
        println!("\nMessages the plugin sent to the host: {}", events.len());
        for event in events.iter().take(10) {
            println!("  {:?}", event);
        }
    }

    Ok(problems)
}

fn print_extensions(instance: &mut PluginInstance<SubprocessHost>) {
    let handle = instance.plugin_handle();
    let mut found = Vec::new();
    if handle.get_extension::<PluginParams>().is_some() {
        found.push("params");
    }
    if handle.get_extension::<PluginAudioPorts>().is_some() {
        found.push("audio-ports");
    }
    if handle.get_extension::<PluginNotePorts>().is_some() {
        found.push("note-ports");
    }
    if handle.get_extension::<PluginGui>().is_some() {
        found.push("gui");
    }
    if handle.get_extension::<ClapState>().is_some() {
        found.push("state");
    }
    if handle.get_extension::<PluginLatency>().is_some() {
        found.push("latency");
    }
    if handle.get_extension::<PluginTimer>().is_some() {
        found.push("timer-support");
    }
    if handle
        .get_extension::<clack_extensions::render::PluginRender>()
        .is_some()
    {
        found.push("render");
    }
    println!("\nExtensions the host uses: {}", found.join(", "));
}

fn print_parameters(instance: &mut PluginInstance<SubprocessHost>) {
    let mut handle = instance.plugin_handle();
    let Some(params) = handle.get_extension::<PluginParams>() else {
        println!("\nParameters: none (no params extension)");
        return;
    };
    let count = params.count(&mut handle);
    println!("\nParameters: {}", count);
    for index in 0..count {
        let mut buffer = ParamInfoBuffer::new();
        let Some(info) = params.get_info(&mut handle, index, &mut buffer) else {
            println!("  [{:3}] <no info>", index);
            continue;
        };
        let mut flags = Vec::new();
        for (flag, label) in [
            (ParamInfoFlags::IS_AUTOMATABLE, "automatable"),
            (ParamInfoFlags::IS_STEPPED, "stepped"),
            (ParamInfoFlags::IS_HIDDEN, "hidden"),
            (ParamInfoFlags::IS_READONLY, "read-only"),
            (ParamInfoFlags::IS_BYPASS, "bypass"),
            (ParamInfoFlags::IS_MODULATABLE, "modulatable"),
        ] {
            if info.flags.contains(flag) {
                flags.push(label);
            }
        }
        let module = bytes_str(info.module);
        println!(
            "  [{:3}] id {:<10} {}{} range {} .. {} default {} [{}]",
            index,
            info.id.get(),
            if module.is_empty() {
                String::new()
            } else {
                format!("{}/", module)
            },
            bytes_str(info.name),
            num(info.min_value),
            num(info.max_value),
            num(info.default_value),
            flags.join(", ")
        );
    }
}

fn print_ports(instance: &mut PluginInstance<SubprocessHost>) {
    let mut handle = instance.plugin_handle();
    match handle.get_extension::<PluginAudioPorts>() {
        Some(ports) => {
            for is_input in [true, false] {
                let count = ports.count(&mut handle, is_input);
                println!(
                    "\nAudio {} ports: {}",
                    if is_input { "input" } else { "output" },
                    count
                );
                for index in 0..count {
                    let mut buffer = AudioPortInfoBuffer::new();
                    match ports.get(&mut handle, index, is_input, &mut buffer) {
                        Some(info) => println!(
                            "  [{}] {} — {} channel(s){}{}",
                            index,
                            bytes_str(info.name),
                            info.channel_count,
                            if info.flags.contains(AudioPortFlags::IS_MAIN) {
                                ", main"
                            } else {
                                ""
                            },
                            info.port_type
                                .map(|t| format!(", type {}", t.0.to_string_lossy()))
                                .unwrap_or_default()
                        ),
                        None => println!("  [{}] <no info>", index),
                    }
                }
            }
        }
        None => println!("\nAudio ports: no audio-ports extension (host assumes stereo in/out)"),
    }
    if ports_differ_from_engine(&mut handle) {
        println!("  Note: the engine always passes one stereo input and one stereo output port.");
    }

    match handle.get_extension::<PluginNotePorts>() {
        Some(ports) => {
            for is_input in [true, false] {
                let count = ports.count(&mut handle, is_input);
                println!(
                    "\nNote {} ports: {}",
                    if is_input { "input" } else { "output" },
                    count
                );
                for index in 0..count {
                    let mut buffer = NotePortInfoBuffer::new();
                    match ports.get(&mut handle, index, is_input, &mut buffer) {
                        Some(info) => println!(
                            "  [{}] {} — dialects {:?}",
                            index,
                            bytes_str(info.name),
                            info.supported_dialects
                        ),
                        None => println!("  [{}] <no info>", index),
                    }
                }
            }
        }
        None => println!("\nNote ports: none (no note-ports extension)"),
    }
}

/// True when the plugin's audio ports aren't exactly one stereo input and one stereo output,
/// which is what the engine provides.
fn ports_differ_from_engine(handle: &mut PluginMainThreadHandle) -> bool {
    let Some(ports) = handle.get_extension::<PluginAudioPorts>() else {
        return false;
    };
    [true, false].into_iter().any(|is_input| {
        let count = ports.count(handle, is_input);
        count != 1
            || (0..count).any(|index| {
                let mut buffer = AudioPortInfoBuffer::new();
                ports
                    .get(handle, index, is_input, &mut buffer)
                    .is_some_and(|info| info.channel_count != 2)
            })
    })
}

/// Save the plugin's state and load it back, as crash recovery does. Returns problems found.
fn check_state(instance: &mut PluginInstance<SubprocessHost>) -> u32 {
    let mut handle = instance.plugin_handle();
    let Some(state) = handle.get_extension::<ClapState>() else {
        println!("\nState: no state extension (crash recovery re-sends parameter values instead)");
        return 0;
    };
    let mut blob = Vec::new();
    let start = Instant::now();
    if let Err(e) = state.save(&mut handle, &mut blob) {
        println!("\nState: save FAILED: {}", e);
        return 1;
    }
    let save_time = start.elapsed();
    let start = Instant::now();
    let mut reader = std::io::Cursor::new(&blob);
    match state.load(&mut handle, &mut reader) {
        Ok(()) => {
            println!(
                "\nState: saved {} bytes in {:.1} ms, loaded back in {:.1} ms",
                blob.len(),
                ms(save_time),
                ms(start.elapsed())
            );
            0
        }
        Err(e) => {
            println!(
                "\nState: saved {} bytes, loading them back FAILED: {}",
                blob.len(),
                e
            );
            1
        }
    }
}

/// Per-phase measurements.
#[derive(Default)]
struct PhaseStats {
    blocks: u32,
    total: Duration,
    max: Duration,
    peak: f32,
    output_events: usize,
}

impl PhaseStats {
    fn add(&mut self, time: Duration, peak: f32, output_events: usize) {
        self.blocks += 1;
        self.total += time;
        self.max = self.max.max(time);
        self.peak = self.peak.max(peak);
        self.output_events += output_events;
    }

    fn print(&self, label: &str, block: Duration) {
        if self.blocks == 0 {
            return;
        }
        let avg = self.total / self.blocks;
        println!(
            "  {:<8} {:4} blocks  avg {:7.3} ms ({:5.1}%)  max {:7.3} ms ({:5.1}%)  peak {}{}",
            label,
            self.blocks,
            ms(avg),
            100.0 * avg.as_secs_f64() / block.as_secs_f64(),
            ms(self.max),
            100.0 * self.max.as_secs_f64() / block.as_secs_f64(),
            db(self.peak),
            if self.output_events > 0 {
                format!("  {} output events", self.output_events)
            } else {
                String::new()
            }
        );
    }
}

/// Process 1 s of silence, then 1 s with a note held for 0.5 s. Returns problems found.
fn process_blocks(
    started: &mut StartedPluginAudioProcessor<SubprocessHost>,
    instance: &mut PluginInstance<SubprocessHost>,
    shared: &crate::plugin_host::host::SubprocessHostShared,
    options: &ProbeOptions,
) -> u32 {
    let frames = options.block_frames.max(1) as usize;
    let rate = options.sample_rate;
    let block = Duration::from_secs_f64(frames as f64 / rate);
    let second_blocks = (rate / frames as f64).ceil() as u64;
    let note_off_block = second_blocks + second_blocks / 2;

    let mut input = [vec![0.0f32; frames], vec![0.0f32; frames]];
    let mut output = [vec![0.0f32; frames], vec![0.0f32; frames]];
    let mut input_ports = AudioPorts::with_capacity(2, 1);
    let mut output_ports = AudioPorts::with_capacity(2, 1);
    let mut input_events = EventBuffer::with_capacity(4);
    let mut output_events = EventBuffer::with_capacity(64);

    let mut first = None;
    let mut silence = PhaseStats::default();
    let mut note = PhaseStats::default();
    let mut errors = 0u32;
    let mut steady = 0u64;
    let pckn = Pckn::new(0u16, 0u16, PROBE_NOTE as u16, PROBE_NOTE as u32);

    for index in 0..second_blocks * 2 {
        input_events.clear();
        if index == second_blocks {
            input_events.push(&NoteOnEvent::new(0, pckn, PROBE_VELOCITY));
        } else if index == note_off_block {
            input_events.push(&NoteOffEvent::new(0, pckn, 0.0));
        }
        output_events.clear();
        for channel in output.iter_mut() {
            channel.fill(0.0);
        }

        let [in_left, in_right] = &mut input;
        let input_audio = input_ports.with_input_buffers([AudioPortBuffer {
            latency: 0,
            channels: AudioPortBufferType::f32_input_only(
                [
                    InputChannel::constant(&mut in_left[..]),
                    InputChannel::constant(&mut in_right[..]),
                ]
                .into_iter(),
            ),
        }]);
        let [out_left, out_right] = &mut output;
        let mut output_audio = output_ports.with_output_buffers([AudioPortBuffer {
            latency: 0,
            channels: AudioPortBufferType::f32_output_only(
                [&mut out_left[..], &mut out_right[..]].into_iter(),
            ),
        }]);

        let start = Instant::now();
        let result = started.process(
            &input_audio,
            &mut output_audio,
            &InputEvents::from_buffer(&input_events),
            &mut OutputEvents::from_buffer(&mut output_events),
            Some(steady),
            None,
        );
        let time = start.elapsed();
        steady += frames as u64;

        if let Err(e) = result {
            errors += 1;
            if errors <= 3 {
                println!("  process() failed on block {}: {:?}", index, e);
            }
        }
        let peak = output
            .iter()
            .flat_map(|channel| channel.iter())
            .fold(0.0f32, |peak, sample| {
                if sample.is_finite() {
                    peak.max(sample.abs())
                } else {
                    f32::INFINITY
                }
            });
        let events = output_events.len();

        if index == 0 {
            first = Some(time);
        } else if index < second_blocks {
            silence.add(time, peak, events);
        } else {
            note.add(time, peak, events);
        }

        // Main-thread work the plugin may be waiting for, as the host's main loop does.
        for timer_id in shared.tick_timers() {
            let mut handle = instance.plugin_handle();
            if let Some(timer) = handle.get_extension::<PluginTimer>() {
                timer.on_timer(&mut handle, timer_id);
            }
        }
        instance.call_on_main_thread_callback();
    }

    println!(
        "\nProcessing ({} frames per block = {:.2} ms, stereo in/out):",
        frames,
        ms(block)
    );
    if let Some(first) = first {
        println!(
            "  first    block      {:7.3} ms ({:5.1}%)",
            ms(first),
            100.0 * first.as_secs_f64() / block.as_secs_f64()
        );
    }
    silence.print("silence", block);
    note.print("note C3", block);

    let mut problems = errors;
    if errors > 0 {
        println!("  {} block(s) returned an error", errors);
    }
    for (label, stats) in [("silence", &silence), ("note", &note)] {
        if !stats.peak.is_finite() {
            println!("  Output contained NaN or infinity during {}", label);
            problems += 1;
        }
        if stats.max > block {
            println!(
                "  Warning: a {} block took longer than real time ({:.3} ms > {:.3} ms)",
                label,
                ms(stats.max),
                ms(block)
            );
        }
    }
    problems
}

/// Probe a VST3 bundle (spec 028, phase 1): the same output shape as the CLAP probe —
/// descriptor, buses, parameters, latency, then 1 s of silence and 1 s with a C3 note held
/// for 0.5 s, with per-block timing and output levels.
fn probe_vst3(options: &ProbeOptions) -> Result<u32, String> {
    use ::vst3::ComWrapper;
    use ::vst3::Steinberg as sb;
    use ::vst3::Steinberg::Vst as v3;
    use ::vst3::Steinberg::Vst::{IComponentTrait, IEditControllerTrait};

    use crate::plugin_host::vst3::{self, HostContext, Vst3Instance, Vst3Module};

    let mut problems = 0u32;
    println!("Probing {}", options.path.display());

    let load_start = Instant::now();
    // SAFETY: loading a plugin runs its code; that's the point of the probe.
    let module = Arc::new(unsafe { Vst3Module::load(&options.path)? });
    println!(
        "\nModule loaded in {:.1} ms\n  bundle: {}\n  binary: {}",
        ms(load_start.elapsed()),
        module.bundle_path().display(),
        module.binary_path().display()
    );

    let classes = vst3::scan::classes_from_factory(module.factory());
    println!("\nClasses in the bundle:");
    for class in &classes {
        println!("    {:<34} {:<28} {}", class.id, class.category, class.name);
    }
    let audio_modules: Vec<&vst3::ScannedClass> = classes
        .iter()
        .filter(|class| class.category == vst3::moduleinfo::AUDIO_MODULE_CLASS)
        .collect();
    let chosen = match &options.plugin_id {
        Some(wanted) => audio_modules
            .iter()
            .copied()
            .find(|class| class.id.eq_ignore_ascii_case(wanted))
            .ok_or_else(|| format!("Class {} is not in the bundle", wanted))?,
        None => audio_modules
            .first()
            .copied()
            .ok_or("The bundle has no audio module classes")?,
    };
    let class_id = vst3::tuid_from_hex(&chosen.id)
        .ok_or_else(|| "The class id is not 32 hex characters".to_string())?;

    println!("\nDescriptor:");
    println!("  id:           {}", chosen.id);
    println!("  name:         {}", chosen.name);
    println!("  vendor:       {}", chosen.vendor);
    println!("  version:      {}", chosen.version);
    println!("  subcategories: {}", chosen.subcategories);
    println!("  category:     {}", chosen.category);

    let host_context = ComWrapper::new(HostContext);
    let create_start = Instant::now();
    let mut instance = unsafe {
        Vst3Instance::create(
            &module,
            &class_id,
            &host_context,
            options.sample_rate,
            options.block_frames,
        )?
    };
    println!("\nInstance created in {:.1} ms", ms(create_start.elapsed()));

    println!("\nBuses:");
    for (media, media_label) in [
        (v3::MediaTypes_::kAudio as i32, "Audio"),
        (v3::MediaTypes_::kEvent as i32, "Event"),
    ] {
        for (direction, direction_label) in [
            (v3::BusDirections_::kInput as i32, "input"),
            (v3::BusDirections_::kOutput as i32, "output"),
        ] {
            let count = unsafe { instance.component().getBusCount(media, direction) };
            println!("  {} {} buses: {}", media_label, direction_label, count);
            for index in 0..count {
                match instance.bus_info(media, direction, index) {
                    Some(bus) => println!(
                        "    [{}] {} — {} channel(s){}",
                        index,
                        vst3::char16_str(&bus.name),
                        bus.channelCount,
                        if bus.busType == v3::BusTypes_::kMain as i32 {
                            ", main"
                        } else {
                            ""
                        }
                    ),
                    None => println!("    [{}] <no info>", index),
                }
            }
        }
    }
    if instance.audio_input_count() > 1 || instance.audio_output_count() > 1 {
        println!("  Note: the engine activates only the main audio buses.");
    }

    match instance.controller() {
        Some(controller) => {
            let count = unsafe { controller.getParameterCount() };
            println!("\nParameters: {}", count);
            for index in 0..count {
                let mut info: v3::ParameterInfo = unsafe { std::mem::zeroed() };
                if unsafe { controller.getParameterInfo(index, &mut info) } != sb::kResultOk {
                    println!("  [{:3}] <no info>", index);
                    continue;
                }
                use v3::ParameterInfo_::ParameterFlags_ as flags;
                let mut labels = Vec::new();
                for (flag, label) in [
                    (flags::kCanAutomate, "automatable"),
                    (flags::kIsReadOnly, "read-only"),
                    (flags::kIsHidden, "hidden"),
                    (flags::kIsList, "list"),
                    (flags::kIsBypass, "bypass"),
                ] {
                    if info.flags & flag != 0 {
                        labels.push(label);
                    }
                }
                if info.stepCount > 0 {
                    labels.push("stepped");
                }
                let units = vst3::char16_str(&info.units);
                println!(
                    "  [{:3}] id {:<10} {}{} default {} [{}]",
                    index,
                    info.id,
                    vst3::char16_str(&info.title),
                    if units.is_empty() {
                        String::new()
                    } else {
                        format!(" ({})", units)
                    },
                    num(info.defaultNormalizedValue),
                    labels.join(", ")
                );
            }
        }
        None => println!("\nParameters: none (no edit controller)"),
    }

    let latency = instance.latency_samples();
    println!(
        "\nActivated at {} Hz, max {} frames\nLatency: {} frames ({:.2} ms)",
        options.sample_rate,
        options.block_frames,
        latency,
        latency as f64 * 1000.0 / options.sample_rate
    );

    problems += process_blocks_vst3(&mut instance, options);
    drop(instance);
    println!("Deactivated");

    Ok(problems)
}

/// The VST3 processing pass of the probe: 1 s of silence, then a C3 note held for 0.5 s.
/// Mirrors `process_blocks` for the CLAP path, with the preallocated VST3 event list and
/// parameter queues standing in for the CLAP event buffers.
fn process_blocks_vst3(instance: &mut Vst3Instance, options: &ProbeOptions) -> u32 {
    use ::vst3::ComWrapper;
    use ::vst3::Steinberg as sb;
    use ::vst3::Steinberg::Vst as v3;

    use crate::plugin_host::vst3::{EventList, ParameterChanges};

    let frames = options.block_frames.max(1) as usize;
    let rate = options.sample_rate;
    let block = Duration::from_secs_f64(frames as f64 / rate);
    let second_blocks = (rate / frames as f64).ceil() as u64;
    let note_off_block = second_blocks + second_blocks / 2;
    let has_audio_input = instance.audio_input_count() > 0;

    let mut in_left = vec![0.0f32; frames];
    let mut in_right = vec![0.0f32; frames];
    let mut out_left = vec![0.0f32; frames];
    let mut out_right = vec![0.0f32; frames];
    let mut in_channels = [in_left.as_mut_ptr(), in_right.as_mut_ptr()];
    let mut out_channels = [out_left.as_mut_ptr(), out_right.as_mut_ptr()];
    let mut in_bus = v3::AudioBusBuffers {
        numChannels: 2,
        silenceFlags: 0,
        __field0: v3::AudioBusBuffers__type0 {
            channelBuffers32: in_channels.as_mut_ptr(),
        },
    };
    let mut out_bus = v3::AudioBusBuffers {
        numChannels: 2,
        silenceFlags: 0,
        __field0: v3::AudioBusBuffers__type0 {
            channelBuffers32: out_channels.as_mut_ptr(),
        },
    };

    let input_events = ComWrapper::new(EventList::with_capacity(4));
    let output_events = ComWrapper::new(EventList::with_capacity(128));
    let in_changes = ComWrapper::new(ParameterChanges::new(32, 16));
    let out_changes = ComWrapper::new(ParameterChanges::new(32, 16));
    let input_events_ptr = input_events.to_com_ptr::<v3::IEventList>().unwrap();
    let output_events_ptr = output_events.to_com_ptr::<v3::IEventList>().unwrap();
    let in_changes_ptr = in_changes.to_com_ptr::<v3::IParameterChanges>().unwrap();
    let out_changes_ptr = out_changes.to_com_ptr::<v3::IParameterChanges>().unwrap();

    let mut context: v3::ProcessContext = unsafe { std::mem::zeroed() };
    context.sampleRate = rate;
    context.tempo = 120.0;
    context.timeSigNumerator = 4;
    context.timeSigDenominator = 4;
    context.state = (v3::ProcessContext_::StatesAndFlags_::kPlaying
        | v3::ProcessContext_::StatesAndFlags_::kTempoValid
        | v3::ProcessContext_::StatesAndFlags_::kProjectTimeMusicValid
        | v3::ProcessContext_::StatesAndFlags_::kTimeSigValid) as u32;

    // A note on is `kNoteOnEvent` with noteId -1 (spec 028, phase 1).
    let mut note_on: v3::Event = unsafe { std::mem::zeroed() };
    note_on.busIndex = 0;
    note_on.r#type = v3::Event_::EventTypes_::kNoteOnEvent as u16;
    note_on.__field0 = v3::Event__type0 {
        noteOn: v3::NoteOnEvent {
            channel: 0,
            pitch: PROBE_NOTE as i16,
            tuning: 0.0,
            velocity: PROBE_VELOCITY as f32,
            length: 0,
            noteId: -1,
        },
    };
    let mut note_off: v3::Event = unsafe { std::mem::zeroed() };
    note_off.busIndex = 0;
    note_off.r#type = v3::Event_::EventTypes_::kNoteOffEvent as u16;
    note_off.__field0 = v3::Event__type0 {
        noteOff: v3::NoteOffEvent {
            channel: 0,
            pitch: PROBE_NOTE as i16,
            velocity: 0.0,
            noteId: -1,
            tuning: 0.0,
        },
    };

    let mut first = None;
    let mut silence = PhaseStats::default();
    let mut note = PhaseStats::default();
    let mut errors = 0u32;
    let mut steady_samples = 0i64;
    let mut quarter_notes = 0.0f64;

    for index in 0..second_blocks * 2 {
        input_events.clear();
        output_events.clear();
        in_changes.reset();
        out_changes.reset();
        if index == second_blocks {
            input_events.push(&note_on);
        } else if index == note_off_block {
            input_events.push(&note_off);
        }
        out_left.fill(0.0);
        out_right.fill(0.0);
        // Effects don't respond to notes, so the note phase also feeds a 440 Hz tone at
        // -6 dB into the audio input: an effect that passes audio shows up in the levels,
        // an instrument has no audio input to ignore.
        if has_audio_input && index >= second_blocks {
            for (sample, offset) in in_left.iter_mut().zip(steady_samples..) {
                let time = offset as f64 / rate;
                *sample = (time * 440.0 * std::f64::consts::TAU).sin() as f32 * 0.5;
            }
            in_right.copy_from_slice(&in_left);
        }

        context.projectTimeSamples = steady_samples;
        context.projectTimeMusic = quarter_notes;

        let mut data = v3::ProcessData {
            processMode: v3::ProcessModes_::kRealtime as i32,
            symbolicSampleSize: v3::SymbolicSampleSizes_::kSample32 as i32,
            numSamples: frames as i32,
            numInputs: if has_audio_input { 1 } else { 0 },
            numOutputs: 1,
            inputs: if has_audio_input {
                &mut in_bus
            } else {
                std::ptr::null_mut()
            },
            outputs: &mut out_bus,
            inputParameterChanges: in_changes_ptr.as_ptr(),
            outputParameterChanges: out_changes_ptr.as_ptr(),
            inputEvents: input_events_ptr.as_ptr(),
            outputEvents: output_events_ptr.as_ptr(),
            processContext: &mut context,
        };

        let start = Instant::now();
        let result = unsafe { instance.process(&mut data) };
        let time = start.elapsed();
        steady_samples += frames as i64;
        quarter_notes += frames as f64 / rate * 2.0; // 120 bpm

        if result != sb::kResultOk {
            errors += 1;
            if errors <= 3 {
                println!(
                    "  process() failed on block {} with tresult {}",
                    index, result
                );
            }
        }
        let peak = [out_left.as_slice(), out_right.as_slice()]
            .iter()
            .flat_map(|channel| channel.iter())
            .fold(0.0f32, |peak, sample| {
                if sample.is_finite() {
                    peak.max(sample.abs())
                } else {
                    f32::INFINITY
                }
            });
        // Parameter changes the processor produced count as output events too.
        let mut change_points = 0;
        for queue_index in 0..out_changes.len() {
            change_points += out_changes
                .queue(queue_index)
                .map_or(0, |queue| queue.len());
        }
        let events = output_events.len() + change_points;

        if index == 0 {
            first = Some(time);
        } else if index < second_blocks {
            silence.add(time, peak, events);
        } else {
            note.add(time, peak, events);
        }
    }

    println!(
        "\nProcessing ({} frames per block = {:.2} ms, stereo out):",
        frames,
        ms(block)
    );
    if let Some(first) = first {
        println!(
            "  first    block      {:7.3} ms ({:5.1}%)",
            ms(first),
            100.0 * first.as_secs_f64() / block.as_secs_f64()
        );
    }
    silence.print("silence", block);
    note.print("note C3", block);

    let mut problems = errors;
    if errors > 0 {
        println!("  {} block(s) returned an error", errors);
    }
    for (label, stats) in [("silence", &silence), ("note", &note)] {
        if !stats.peak.is_finite() {
            println!("  Output contained NaN or infinity during {}", label);
            problems += 1;
        }
        if stats.max > block {
            println!(
                "  Warning: a {} block took longer than real time ({:.3} ms > {:.3} ms)",
                label,
                ms(stats.max),
                ms(block)
            );
        }
    }
    problems
}

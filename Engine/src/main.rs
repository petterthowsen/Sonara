mod audio;
mod log_forwarder;
mod osc;
mod window_manager;

use anyhow::Result;
use std::fs::{self, File};
use std::io::{self, Write};
use std::sync::{Arc, Mutex};
use tracing::info;
use tracing_subscriber;

use audio::io::audio_file_service::AudioFileService;
use audio::AudioEngine;
use log_forwarder::LogForwarder;
use osc::OscServer;
use window_manager::WindowManager;

// Wrapper to make Arc<Mutex<File>> implement MakeWriter for tracing_subscriber
struct RotatableWriter {
    file: Arc<Mutex<File>>,
}

impl RotatableWriter {
    fn new(file: File) -> Self {
        Self {
            file: Arc::new(Mutex::new(file)),
        }
    }

    fn get_handle(&self) -> Arc<Mutex<File>> {
        self.file.clone()
    }
}

impl Write for RotatableWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.file.lock().unwrap().write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.file.lock().unwrap().flush()
    }
}

impl Clone for RotatableWriter {
    fn clone(&self) -> Self {
        Self {
            file: self.file.clone(),
        }
    }
}

// Implement MakeWriter for our wrapper
impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for RotatableWriter {
    type Writer = Self;

    fn make_writer(&'a self) -> Self::Writer {
        self.clone()
    }
}

fn main() -> Result<()> {
    // Create logs directory if it doesn't exist
    fs::create_dir_all("logs")?;

    // Set up split log writers
    let info_file = File::create("logs/last_info.log")?;
    let warn_file = File::create("logs/last_warn.log")?;
    let combined_file = File::create("logs/last_combined.log")?;

    let info_writer = RotatableWriter::new(info_file);
    let warn_writer = RotatableWriter::new(warn_file);
    let combined_writer = RotatableWriter::new(combined_file);

    let log_handles = osc::server::LogWriters {
        info: info_writer.get_handle(),
        warn: warn_writer.get_handle(),
        combined: combined_writer.get_handle(),
    };

    // Create status channel FIRST so we can pass it to both the log forwarder and the engine
    let (status_tx, status_rx) = crossbeam::channel::unbounded();

    // Set up logging with both file writer AND log forwarder to Godot
    use tracing::Level;
    use tracing_subscriber::filter::{self, LevelFilter};
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;
    use tracing_subscriber::Layer;

    // info-only layer (exactly INFO)
    let info_layer = tracing_subscriber::fmt::layer()
        .with_writer(info_writer)
        .with_ansi(false)
        .with_filter(filter::filter_fn(|meta| meta.level() == &Level::INFO));

    // warn+ layer (WARN and ERROR)
    let warn_layer = tracing_subscriber::fmt::layer()
        .with_writer(warn_writer)
        .with_ansi(false)
        .with_filter(LevelFilter::WARN);

    // combined: INFO and above
    let combined_layer = tracing_subscriber::fmt::layer()
        .with_writer(combined_writer)
        .with_ansi(false)
        .with_filter(LevelFilter::INFO);

    let log_forwarder = LogForwarder::new(status_tx.clone());

    tracing_subscriber::registry()
        .with(info_layer)
        .with(warn_layer)
        .with(combined_layer)
        .with(log_forwarder)
        .init();

    info!("Starting DAW Audio Engine...");

    // Initialize audio engine with our status channel
    let engine = AudioEngine::with_status_channel(status_tx, status_rx)?;
    info!("Audio engine initialized");

    // Get command sender and status receiver for OSC server
    let command_tx = engine.command_sender();
    let status_rx = engine.status_receiver();

    // Create window manager for plugin GUIs
    let mut window_manager = WindowManager::new();
    info!("Window manager initialized");

    // Create AudioFileService (4 worker threads, will use device sample rate once known)
    let audio_file_service = Arc::new(Mutex::new(AudioFileService::new(4, 44100)?));
    info!("AudioFileService initialized with 4 workers");

    // Create OSC server
    let osc_server = OscServer::new(7000, audio_file_service)?;
    info!("OSC server ready on port 7000 (receives from Godot)");
    info!("OSC client sends to port 7001 (Godot listens)");

    info!("DAW Audio Engine is running. Press Ctrl+C to exit.");

    // Run OSC server (this blocks)
    osc_server.run(command_tx, status_rx, log_handles, &mut window_manager)?;

    Ok(())
}

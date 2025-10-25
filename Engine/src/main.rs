mod audio;
mod osc;
mod window_manager;

use anyhow::Result;
use tracing::info;
use tracing_subscriber;
use std::fs::{self, File};
use std::io::{self, Write};
use std::sync::{Arc, Mutex};

use audio::AudioEngine;
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

    // Set up file logging with a rotatable writer
    let log_file = File::create("logs/engine.log")?;
    let log_writer = RotatableWriter::new(log_file);
    let log_handle = log_writer.get_handle();

    // Initialize logging to file (also prints to console via println in code)
    tracing_subscriber::fmt()
        .with_writer(log_writer)
        .with_ansi(false)  // No color codes in file
        .init();

    info!("Starting DAW Audio Engine...");

    // Initialize audio engine
    let engine = AudioEngine::new()?;
    info!("Audio engine initialized");

    // Get command sender and status receiver for OSC server
    let command_tx = engine.command_sender();
    let status_rx = engine.status_receiver();

    // Create window manager for plugin GUIs
    let mut window_manager = WindowManager::new();
    info!("Window manager initialized");

    // Create OSC server
    let osc_server = OscServer::new(7000)?;
    info!("OSC server ready on port 7000 (receives from Godot)");
    info!("OSC client sends to port 7001 (Godot listens)");

    info!("DAW Audio Engine is running. Press Ctrl+C to exit.");

    // Run OSC server (this blocks)
    osc_server.run(command_tx, status_rx, log_handle, &mut window_manager)?;

    Ok(())
}

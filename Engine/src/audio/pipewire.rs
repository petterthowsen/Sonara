//! PipeWire graph awareness (Phase 7 step 7).
//!
//! cpal talks to PipeWire through its ALSA plugin, so the engine can't see the graph it runs in.
//! A monitor thread reads it with PipeWire's own tools every few seconds: `pw-top -b` for the
//! running quantum, rate and error count of the engine's node and its driver, `pw-dump` to find
//! the engine's node by process id, and `pw-metadata` for forced settings. It never writes
//! PipeWire settings: they're system-wide state the user or another tool owns.

use crossbeam::channel::Sender;
use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use tracing::{debug, info};

use super::commands::AudioCommand;
use super::stream::{CallbackCounters, StreamInfo, ALSA_PERIODS, MAX_PERIOD_FRAMES};

/// How often the monitor samples the graph.
const GRAPH_POLL: Duration = Duration::from_secs(3);

/// How long one PipeWire tool may run before it is killed.
const TOOL_TIMEOUT: Duration = Duration::from_secs(3);

/// The PipeWire graph the engine's stream runs in.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GraphInfo {
    /// The driver's running quantum and rate (0 when unknown).
    pub quantum: u32,
    pub rate: u32,
    /// `clock.force-quantum` / `clock.force-rate` from the settings metadata (0 = not forced).
    pub force_quantum: u32,
    pub force_rate: u32,
    /// The engine's node, while it has one.
    pub node_id: Option<u32>,
    /// PipeWire's error (xrun) count for the engine's node and for its driver.
    pub node_errors: u64,
    pub driver_errors: u64,
}

impl GraphInfo {
    /// The quantum in frames at the engine's `rate`: PipeWire resamples a stream whose rate
    /// differs from the graph's, so one graph cycle is that many engine frames.
    pub fn quantum_at(&self, rate: u32) -> u32 {
        if self.rate == 0 || rate == 0 || self.rate == rate {
            return self.quantum;
        }
        (self.quantum as u64 * rate as u64).div_ceil(self.rate as u64) as u32
    }

    /// Same graph apart from the error counters.
    fn same_graph(&self, other: &GraphInfo) -> bool {
        self.quantum == other.quantum
            && self.rate == other.rate
            && self.force_quantum == other.force_quantum
            && self.force_rate == other.force_rate
            && self.node_id == other.node_id
    }
}

/// Period to run at so the ALSA buffer (`ALSA_PERIODS` periods) holds a whole graph cycle: the
/// requested one, unless PipeWire's quantum (in engine frames, see `GraphInfo::quantum_at`) is
/// larger than that buffer.
///
/// The engine's period becomes its node latency, and PipeWire runs the smallest latency any
/// node asks for unless something forces a larger one. The adapted period stays below the
/// quantum, so the engine never holds the quantum up itself: once the forcing goes away, the
/// quantum drops and the engine returns to the requested period.
pub fn required_period(requested: u32, quantum: u32) -> u32 {
    if quantum == 0 || quantum <= requested * ALSA_PERIODS {
        return requested;
    }
    quantum
        .div_ceil(ALSA_PERIODS)
        .next_power_of_two()
        .clamp(requested, MAX_PERIOD_FRAMES)
}

/// Warning for Settings when the graph and the stream disagree, "" when they don't.
pub fn describe_mismatch(graph: &GraphInfo, stream: &StreamInfo, requested_period: u32) -> String {
    let mut parts = Vec::new();
    if graph.quantum_at(stream.sample_rate) > requested_period && requested_period > 0 {
        let mut text = format!(
            "PipeWire runs a {}-frame quantum, larger than the {}-frame buffer",
            graph.quantum, requested_period
        );
        if graph.force_quantum > 0 {
            text.push_str(&format!(
                " (forced with `pw-metadata -n settings 0 clock.force-quantum {}`; `pw-metadata -n settings 0 clock.force-quantum 0` undoes it)",
                graph.force_quantum
            ));
        }
        if stream.period_frames > requested_period {
            text.push_str(&format!(
                ". The engine uses a {}-frame buffer so PipeWire doesn't underrun",
                stream.period_frames
            ));
        } else {
            text.push_str(". Latency follows the quantum");
        }
        text.push('.');
        parts.push(text);
    }
    if graph.rate > 0 && graph.rate != stream.sample_rate {
        let mut text = format!(
            "PipeWire runs at {} Hz and the engine at {} Hz, so PipeWire resamples the engine's output",
            graph.rate, stream.sample_rate
        );
        if graph.force_rate > 0 {
            text.push_str(&format!(
                " (forced with `pw-metadata -n settings 0 clock.force-rate {}`)",
                graph.force_rate
            ));
        }
        text.push('.');
        parts.push(text);
    }
    parts.join(" ")
}

/// Start the monitor thread. It reports graph changes to the command thread as
/// `AudioCommand::PipeWireGraph` and adds PipeWire errors on the engine's node to the xrun
/// counter. It stops by itself when PipeWire's tools aren't installed.
pub fn spawn_monitor(command_tx: Sender<AudioCommand>, counters: Arc<CallbackCounters>) {
    let spawned = thread::Builder::new()
        .name("pipewire-monitor".to_string())
        .spawn(move || run_monitor(command_tx, counters));
    if let Err(e) = spawned {
        tracing::warn!("Can't start the PipeWire monitor: {}", e);
    }
}

fn run_monitor(command_tx: Sender<AudioCommand>, counters: Arc<CallbackCounters>) {
    let pid = std::process::id();
    let mut node_id: Option<u32> = None;
    let mut last: Option<GraphInfo> = None;
    let mut running = true;

    loop {
        thread::sleep(GRAPH_POLL);
        let top = match run_tool("pw-top", &["-b", "-n", "2"]) {
            Ok(Some(text)) => text,
            Ok(None) => {
                // PipeWire isn't running (or not reachable): nothing to check this time.
                if running {
                    info!("PipeWire isn't running; graph checks paused");
                    running = false;
                }
                continue;
            }
            Err(ToolError::Missing) => {
                info!("PipeWire tools (pw-top) not found; graph checks off");
                return;
            }
            Err(ToolError::Failed(e)) => {
                debug!("pw-top failed: {}", e);
                continue;
            }
        };
        if !running {
            info!("PipeWire is running; graph checks resumed");
            running = true;
        }

        let rows = parse_pw_top(&top);
        if node_id.is_none_or(|id| !rows.iter().any(|row| row.id == id)) {
            node_id = run_tool("pw-dump", &[])
                .ok()
                .flatten()
                .and_then(|dump| find_stream_node(&dump, pid));
        }
        let mut graph = GraphInfo {
            node_id,
            ..Default::default()
        };
        if let Some(id) = node_id {
            if let Some((node, driver)) = node_and_driver(&rows, id) {
                graph.node_errors = node.errors;
                if let Some(driver) = driver {
                    graph.quantum = driver.quantum;
                    graph.rate = driver.rate;
                    graph.driver_errors = driver.errors;
                }
            }
        }
        if let Ok(Some(metadata)) = run_tool("pw-metadata", &["-n", "settings", "0"]) {
            graph.force_quantum = metadata_value(&metadata, "clock.force-quantum").unwrap_or(0);
            graph.force_rate = metadata_value(&metadata, "clock.force-rate").unwrap_or(0);
        }

        if let Some(previous) = &last {
            if previous.node_id.is_some()
                && previous.node_id == graph.node_id
                && graph.node_errors > previous.node_errors
            {
                counters
                    .xruns
                    .fetch_add(graph.node_errors - previous.node_errors, Ordering::Relaxed);
            }
        }
        let changed = last
            .as_ref()
            .is_none_or(|previous| !previous.same_graph(&graph));
        last = Some(graph.clone());
        if changed && command_tx.send(AudioCommand::PipeWireGraph(graph)).is_err() {
            return;
        }
    }
}

enum ToolError {
    Missing,
    Failed(String),
}

/// Run a PipeWire tool and return its stdout, None when it exits with an error (PipeWire not
/// running). Killed after `TOOL_TIMEOUT`.
fn run_tool(program: &str, args: &[&str]) -> Result<Option<String>, ToolError> {
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => ToolError::Missing,
            _ => ToolError::Failed(e.to_string()),
        })?;
    let mut stdout = child.stdout.take().expect("stdout is piped");
    // Read on another thread: pw-dump prints more than a pipe holds, so waiting first would
    // deadlock.
    let (tx, rx) = crossbeam::channel::bounded(1);
    thread::spawn(move || {
        let mut text = String::new();
        let _ = stdout.read_to_string(&mut text);
        let _ = tx.send(text);
    });
    let Ok(text) = rx.recv_timeout(TOOL_TIMEOUT) else {
        let _ = child.kill();
        let _ = child.wait();
        return Err(ToolError::Failed(format!("{} timed out", program)));
    };
    let status = child.wait().map_err(|e| ToolError::Failed(e.to_string()))?;
    Ok(status.success().then_some(text))
}

/// One node row of `pw-top -b`.
#[derive(Debug, Clone, PartialEq, Eq)]
struct TopRow {
    id: u32,
    quantum: u32,
    rate: u32,
    errors: u64,
    /// Follows the driver row above it (its name starts with "+").
    follower: bool,
}

/// Parse the last complete iteration of `pw-top -b` output (the first one has no timings).
fn parse_pw_top(text: &str) -> Vec<TopRow> {
    let mut blocks: Vec<Vec<TopRow>> = Vec::new();
    for line in text.lines() {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.first() == Some(&"S") && tokens.get(1) == Some(&"ID") {
            blocks.push(Vec::new());
            continue;
        }
        let (Some(block), true) = (blocks.last_mut(), tokens.len() >= 9) else {
            continue;
        };
        let (Ok(id), Ok(quantum), Ok(rate), Ok(errors)) = (
            tokens[1].parse(),
            tokens[2].parse(),
            tokens[3].parse(),
            tokens[8].parse(),
        ) else {
            continue;
        };
        block.push(TopRow {
            id,
            quantum,
            rate,
            errors,
            follower: tokens[9..].contains(&"+"),
        });
    }
    blocks.pop().unwrap_or_default()
}

/// The row for node `id` and the driver it follows (the last driver row above it).
fn node_and_driver(rows: &[TopRow], id: u32) -> Option<(&TopRow, Option<&TopRow>)> {
    let index = rows.iter().position(|row| row.id == id)?;
    let node = &rows[index];
    if !node.follower {
        return Some((node, Some(node)));
    }
    let driver = rows[..index].iter().rev().find(|row| !row.follower);
    Some((node, driver))
}

/// The id of the playback stream node process `pid` owns, from `pw-dump` JSON. pipewire-alsa
/// puts the process id on the client object; the node points at its client with `client.id`.
fn find_stream_node(dump: &str, pid: u32) -> Option<u32> {
    let objects: Vec<serde_json::Value> = serde_json::from_str(dump).ok()?;
    let props = |object: &serde_json::Value| object.get("info")?.get("props").cloned();
    let number = |value: Option<&serde_json::Value>| match value? {
        serde_json::Value::Number(n) => n.as_u64(),
        serde_json::Value::String(s) => s.parse().ok(),
        _ => None,
    };
    let clients: Vec<u64> = objects
        .iter()
        .filter(|object| {
            object.get("type").and_then(|t| t.as_str()) == Some("PipeWire:Interface:Client")
                && props(object)
                    .is_some_and(|p| number(p.get("application.process.id")) == Some(pid as u64))
        })
        .filter_map(|object| object.get("id")?.as_u64())
        .collect();
    objects.iter().find_map(|object| {
        if object.get("type")?.as_str()? != "PipeWire:Interface:Node" {
            return None;
        }
        let props = props(object)?;
        if props.get("media.class")?.as_str()? != "Stream/Output/Audio" {
            return None;
        }
        let owned = number(props.get("client.id")).is_some_and(|id| clients.contains(&id))
            || number(props.get("application.process.id")) == Some(pid as u64);
        owned
            .then(|| object.get("id")?.as_u64().map(|id| id as u32))
            .flatten()
    })
}

/// A numeric value from `pw-metadata` output (`update: id:0 key:'…' value:'2048' type:''`).
fn metadata_value(text: &str, key: &str) -> Option<u32> {
    let needle = format!("key:'{}' value:'", key);
    text.lines().find_map(|line| {
        let start = line.find(&needle)? + needle.len();
        let end = line[start..].find('\'')? + start;
        line[start..end].trim().parse().ok()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOP: &str = "\
S   ID  QUANT   RATE    WAIT    BUSY   W/Q   B/Q  ERR FORMAT           NAME
C   29      0      0    ---     ---   ---   ---     0                  Dummy-Driver
C   54      0      0    ---     ---   ---   ---     0                  alsa_output.analog-stereo
C  134      0      0    ---     ---   ---   ---     0                  alsa_playback.engine
S   ID  QUANT   RATE    WAIT    BUSY   W/Q   B/Q  ERR FORMAT           NAME
I   29      0      0   0,0us   0,0us  ???   ???     0                  Dummy-Driver
R   54   2048  48000   7,4ms  43,6us  0,17  0,00  3281    S32LE 2 48000 alsa_output.analog-stereo
R  118    512  44100  26,0us  54,7us  0,00  0,00  142    S16LE 2 44100  + Godots
R   82   2048  48000  18,8us   7,4ms  0,00  0,17    3                   + Bitwig Studio
R  134   1024  48000  31,1us  19,3us  0,00  0,00    7    F32LE 2 48000  + alsa_playback.engine
S   55      0      0    ---     ---   ---   ---     0                  alsa_input.analog-stereo
";

    #[test]
    fn pw_top_finds_the_node_and_its_driver() {
        let rows = parse_pw_top(TOP);
        assert_eq!(rows.len(), 6, "only the last iteration: {:?}", rows);
        let (node, driver) = node_and_driver(&rows, 134).unwrap();
        assert_eq!((node.quantum, node.errors, node.follower), (1024, 7, true));
        let driver = driver.unwrap();
        assert_eq!(
            (driver.id, driver.quantum, driver.rate, driver.errors),
            (54, 2048, 48000, 3281)
        );
        assert!(node_and_driver(&rows, 999).is_none());
    }

    #[test]
    fn metadata_values_are_read_by_key() {
        let text = "Found \"settings\" metadata 31\n\
            update: id:0 key:'clock.quantum' value:'1024' type:''\n\
            update: id:0 key:'clock.force-quantum' value:'2048' type:''\n\
            update: id:0 key:'clock.force-rate' value:'0' type:''\n";
        assert_eq!(metadata_value(text, "clock.force-quantum"), Some(2048));
        assert_eq!(metadata_value(text, "clock.force-rate"), Some(0));
        assert_eq!(metadata_value(text, "clock.max-quantum"), None);
    }

    #[test]
    fn stream_node_is_found_by_process_id() {
        // The layout pw-dump shows for a cpal (pipewire-alsa) stream: the process id sits on
        // the client, and the node names its client.
        let dump = r#"[
            {"id": 54, "type": "PipeWire:Interface:Node", "info": {"props": {"media.class": "Audio/Sink"}}},
            {"id": 80, "type": "PipeWire:Interface:Client", "info": {"props": {"application.process.id": 42}}},
            {"id": 81, "type": "PipeWire:Interface:Client", "info": {"props": {"application.process.id": 43}}},
            {"id": 133, "type": "PipeWire:Interface:Node", "info": {"props": {"client.id": 80, "media.class": "Stream/Input/Audio"}}},
            {"id": 134, "type": "PipeWire:Interface:Node", "info": {"props": {"client.id": 80, "media.class": "Stream/Output/Audio"}}},
            {"id": 135, "type": "PipeWire:Interface:Node", "info": {"props": {"client.id": 81, "media.class": "Stream/Output/Audio"}}}
        ]"#;
        assert_eq!(find_stream_node(dump, 42), Some(134));
        assert_eq!(find_stream_node(dump, 43), Some(135));
        assert_eq!(find_stream_node(dump, 44), None);
    }

    #[test]
    fn buffer_grows_only_when_the_quantum_outgrows_it() {
        // The ALSA buffer (4 periods) already holds the quantum: keep the request.
        assert_eq!(required_period(1024, 2048), 1024);
        assert_eq!(required_period(1024, 4096), 1024);
        assert_eq!(required_period(256, 0), 256);
        // Phase 0's crackles: a 1488 quantum against a 256-frame period (1024-frame buffer).
        assert_eq!(required_period(256, 1488), 512);
        assert_eq!(required_period(1024, 8192), 2048);
        assert_eq!(required_period(64, 8192), MAX_PERIOD_FRAMES);
    }

    #[test]
    fn quantum_converts_to_engine_frames() {
        let graph = GraphInfo {
            quantum: 2048,
            rate: 48_000,
            ..Default::default()
        };
        assert_eq!(graph.quantum_at(48_000), 2048);
        assert_eq!(graph.quantum_at(44_100), 1882);
        assert_eq!(graph.quantum_at(96_000), 4096);
        // 1024 frames at 96 kHz would hold 2048 graph frames, but not 4096 engine frames.
        assert_eq!(required_period(1024, graph.quantum_at(96_000)), 1024);
        assert_eq!(required_period(512, graph.quantum_at(96_000)), 1024);
        assert_eq!(GraphInfo::default().quantum_at(44_100), 0);
    }

    #[test]
    fn mismatch_text_names_the_forcing_command() {
        let stream = StreamInfo {
            device: "default".into(),
            is_default_device: true,
            sample_rate: 48_000,
            period_frames: 512,
            channels: 2,
        };
        let graph = GraphInfo {
            quantum: 1488,
            rate: 48_000,
            force_quantum: 1488,
            ..Default::default()
        };
        let text = describe_mismatch(&graph, &stream, 256);
        assert!(text.contains("1488-frame quantum"), "{}", text);
        assert!(text.contains("clock.force-quantum 1488"), "{}", text);
        assert!(text.contains("512-frame buffer"), "{}", text);

        let fine = GraphInfo {
            quantum: 256,
            rate: 48_000,
            ..Default::default()
        };
        assert_eq!(describe_mismatch(&fine, &stream, 256), "");

        let resampled = GraphInfo {
            quantum: 256,
            rate: 44_100,
            ..Default::default()
        };
        assert!(describe_mismatch(&resampled, &stream, 256).contains("44100 Hz"));
    }
}

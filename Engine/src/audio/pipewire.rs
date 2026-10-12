//! PipeWire graph awareness (Phase 7 step 7, spec 041).
//!
//! A monitor thread reads the graph the engine's stream runs in with PipeWire's own tools every
//! few seconds: `pw-top -b` for the running quantum, rate and error count of the engine's node
//! and its driver, `pw-dump` to find the engine's node by process id, and `pw-metadata` for
//! forced settings. It also reports the output stream's health (driver-measured latency and
//! whether the callback thread got realtime scheduling) on every driver.
//!
//! On the PipeWire driver the engine forces its own buffer size and rate (`ForcedClock`), like
//! Bitwig: `clock.force-quantum` and `clock.force-rate` in the `settings` metadata, restored on
//! stop and exit unless another application has changed them since.

use crossbeam::channel::Sender;
use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use tracing::{debug, info, warn};

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

/// ALSA driver only: period to run at so the ALSA buffer (`ALSA_PERIODS` periods) holds a whole
/// graph cycle: the requested one, unless PipeWire's quantum (in engine frames, see
/// `GraphInfo::quantum_at`) is larger than that buffer.
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
/// `forced_by_other`: another application changed the forced quantum or rate after the engine
/// forced its own (spec 041 REQ-010).
pub fn describe_mismatch(
    graph: &GraphInfo,
    stream: &StreamInfo,
    requested_period: u32,
    forced_by_other: bool,
) -> String {
    let mut parts = Vec::new();
    if forced_by_other {
        let mut forced = Vec::new();
        if graph.force_quantum > 0 {
            forced.push(format!("a {}-frame quantum", graph.force_quantum));
        }
        if graph.force_rate > 0 {
            forced.push(format!("{} Hz", graph.force_rate));
        }
        let forced = if forced.is_empty() {
            "its own quantum and rate".to_string()
        } else {
            forced.join(" at ")
        };
        parts.push(format!(
            "Another application forces PipeWire to {}; the engine follows it until you change the buffer size or sample rate.",
            forced
        ));
    }
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

/// Whether the audio callback's thread runs with realtime scheduling.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RealtimeState {
    /// Not known yet (no callback so far, or the promotion is still pending).
    #[default]
    Unknown,
    Granted,
    Denied,
}

impl RealtimeState {
    /// The name `/audio/config` carries.
    pub fn as_str(self) -> &'static str {
        match self {
            RealtimeState::Unknown => "unknown",
            RealtimeState::Granted => "granted",
            RealtimeState::Denied => "denied",
        }
    }
}

/// The callback thread's realtime state from its scheduling `policy` (None when unknown) and
/// whether the driver reported the promotion denied.
pub fn realtime_state(policy: Option<i32>, denied: bool) -> RealtimeState {
    match policy {
        Some(libc::SCHED_FIFO) | Some(libc::SCHED_RR) => RealtimeState::Granted,
        _ if denied => RealtimeState::Denied,
        _ => RealtimeState::Unknown,
    }
}

/// The scheduling policy of thread `tid` in this process, None when it can't be read.
fn scheduling_policy(tid: i32) -> Option<i32> {
    if tid <= 0 {
        return None;
    }
    // SAFETY: sched_getscheduler only reads the policy of the given thread id.
    let policy = unsafe { libc::sched_getscheduler(tid) };
    (policy >= 0).then_some(policy & !libc::SCHED_RESET_ON_FORK)
}

/// `clock.force-quantum` and `clock.force-rate` (0 = not forced).
type Forced = (u32, u32);

const FORCE_QUANTUM_KEY: &str = "clock.force-quantum";
const FORCE_RATE_KEY: &str = "clock.force-rate";

/// Reads and writes the forced values in PipeWire's `settings` metadata. A trait so tests can
/// replace `pw-metadata`.
pub trait MetadataIo: Send {
    /// The forced quantum and rate, None when the metadata can't be read.
    fn read_forced(&mut self) -> Option<Forced>;
    fn write(&mut self, key: &str, value: u32) -> Result<(), String>;
}

/// `MetadataIo` through the `pw-metadata` tool.
struct PwMetadata;

impl MetadataIo for PwMetadata {
    fn read_forced(&mut self) -> Option<Forced> {
        let text = run_tool("pw-metadata", &["-n", "settings", "0"])
            .ok()
            .flatten()?;
        Some((
            metadata_value(&text, FORCE_QUANTUM_KEY).unwrap_or(0),
            metadata_value(&text, FORCE_RATE_KEY).unwrap_or(0),
        ))
    }

    fn write(&mut self, key: &str, value: u32) -> Result<(), String> {
        let value = value.to_string();
        match run_tool("pw-metadata", &["-n", "settings", "0", key, &value]) {
            Ok(Some(_)) => Ok(()),
            Ok(None) => Err(format!("pw-metadata couldn't set {}", key)),
            Err(ToolError::Missing) => Err("pw-metadata isn't installed".to_string()),
            Err(ToolError::Failed(e)) => Err(e),
        }
    }
}

/// The engine's own forcing of PipeWire's quantum and rate (spec 041 REQ-007–010). Lives on the
/// command thread behind a mutex the termination handler shares; never touched by the callback.
pub struct ForcedClock {
    io: Box<dyn MetadataIo>,
    /// The values before the engine forced its own (or before another application's later
    /// change that the engine then overrode): what `restore` writes back.
    saved: Option<Forced>,
    /// What the engine last wrote, None while it forces nothing.
    written: Option<Forced>,
}

impl ForcedClock {
    pub fn new(io: Box<dyn MetadataIo>) -> Self {
        Self {
            io,
            saved: None,
            written: None,
        }
    }

    /// Forcing through the `pw-metadata` tool.
    pub fn system() -> Self {
        Self::new(Box::new(PwMetadata))
    }

    /// Force `quantum` and `rate`, remembering the values to restore the first time (and after
    /// another application changed them).
    pub fn apply(&mut self, quantum: u32, rate: u32) -> Result<(), String> {
        let current = self
            .io
            .read_forced()
            .ok_or_else(|| "can't read PipeWire's settings (pw-metadata)".to_string())?;
        if self.written != Some(current) {
            self.saved = Some(current);
        }
        if current.0 != quantum {
            self.io.write(FORCE_QUANTUM_KEY, quantum)?;
        }
        self.written = Some((quantum, current.1));
        if current.1 != rate {
            self.io.write(FORCE_RATE_KEY, rate)?;
        }
        self.written = Some((quantum, rate));
        if current != (quantum, rate) {
            info!(
                "Forced PipeWire's quantum to {} and rate to {} Hz (were {} and {})",
                quantum, rate, current.0, current.1
            );
        }
        Ok(())
    }

    /// Write back the values from before the engine forced its own, only while both still hold
    /// what the engine wrote: applications force the pair together, so a change to either means
    /// someone else forces now. Forces nothing afterwards.
    pub fn restore(&mut self) {
        let (Some(written), Some(saved)) = (self.written.take(), self.saved.take()) else {
            return;
        };
        let Some(current) = self.io.read_forced() else {
            warn!("Can't read PipeWire's settings to restore the forced quantum and rate");
            return;
        };
        if current != written {
            info!(
                "Leaving PipeWire's forced quantum {} and rate {}: another application set them",
                current.0, current.1
            );
            return;
        }
        let keys = [
            (FORCE_QUANTUM_KEY, written.0, saved.0),
            (FORCE_RATE_KEY, written.1, saved.1),
        ];
        for (key, written, saved) in keys {
            if written != saved {
                match self.io.write(key, saved) {
                    Ok(()) => info!("Restored PipeWire's {} to {}", key, saved),
                    Err(e) => warn!("Couldn't restore PipeWire's {}: {}", key, e),
                }
            }
        }
    }

    /// Whether the graph's forced values are the engine's own (true while it forces nothing).
    pub fn is_ours(&self, graph: &GraphInfo) -> bool {
        self.written
            .is_none_or(|written| written == (graph.force_quantum, graph.force_rate))
    }
}

/// The node name of PipeWire's default sink (`default.audio.sink` in the `default` metadata),
/// None when PipeWire or its tools aren't there.
pub fn default_sink_name() -> Option<String> {
    let text = run_tool("pw-metadata", &["-n", "default", "0"])
        .ok()
        .flatten()?;
    let value = metadata_text(&text, "default.audio.sink")?;
    let json: serde_json::Value = serde_json::from_str(value).ok()?;
    Some(json.get("name")?.as_str()?.to_string())
}

/// Latency changes smaller than this aren't reported (it moves a little every block).
const LATENCY_REPORT_STEP_US: u32 = 500;

/// Start the monitor thread. It reports graph changes to the command thread as
/// `AudioCommand::PipeWireGraph`, output health as `AudioCommand::OutputHealth`, and on the ALSA
/// driver adds PipeWire errors on the engine's node to the xrun counter. Without PipeWire's tools
/// it only reports output health.
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
    let mut tools = true;
    let mut health: Option<(u32, RealtimeState)> = None;

    loop {
        thread::sleep(GRAPH_POLL);

        let latency_us = counters.output_latency_us.load(Ordering::Relaxed);
        let tid = counters.callback_tid.load(Ordering::Relaxed);
        let realtime = realtime_state(
            scheduling_policy(tid),
            counters.realtime_denied.load(Ordering::Relaxed),
        );
        let changed = health.is_none_or(|(last_latency, last_realtime)| {
            last_realtime != realtime || last_latency.abs_diff(latency_us) >= LATENCY_REPORT_STEP_US
        });
        if changed {
            if health.is_none_or(|(_, last_realtime)| last_realtime != realtime) {
                match realtime {
                    RealtimeState::Granted => {
                        info!("Realtime scheduling granted for the audio callback (thread {})", tid)
                    }
                    RealtimeState::Denied => warn!(
                        "Realtime scheduling denied for the audio callback (thread {}); other processes can delay it",
                        tid
                    ),
                    RealtimeState::Unknown => {}
                }
            }
            health = Some((latency_us, realtime));
            let report = AudioCommand::OutputHealth {
                latency_us,
                realtime,
            };
            if command_tx.send(report).is_err() {
                return;
            }
        }

        if !tools {
            continue;
        }
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
                tools = false;
                continue;
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
            graph.force_quantum = metadata_value(&metadata, FORCE_QUANTUM_KEY).unwrap_or(0);
            graph.force_rate = metadata_value(&metadata, FORCE_RATE_KEY).unwrap_or(0);
        }

        // The PipeWire driver reports its node's underruns itself; counting pw-top's ERR as
        // well would count them twice.
        if let Some(previous) = &last {
            if previous.node_id.is_some()
                && previous.node_id == graph.node_id
                && graph.node_errors > previous.node_errors
                && !counters.native_pipewire.load(Ordering::Relaxed)
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
    metadata_text(text, key)?.trim().parse().ok()
}

/// A value from `pw-metadata` output as text.
fn metadata_text<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    let needle = format!("key:'{}' value:'", key);
    text.lines().find_map(|line| {
        let start = line.find(&needle)? + needle.len();
        let end = line[start..].find('\'')? + start;
        Some(&line[start..end])
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
        // The ALSA buffer (2 periods) already holds the quantum: keep the request.
        assert_eq!(required_period(1024, 2048), 1024);
        assert_eq!(required_period(512, 1024), 512);
        assert_eq!(required_period(256, 0), 256);
        // Phase 0's crackles: a 1488 quantum against a 256-frame period (512-frame buffer).
        assert_eq!(required_period(256, 1488), 1024);
        assert_eq!(required_period(1024, 4096), 2048);
        assert_eq!(required_period(1024, 8192), MAX_PERIOD_FRAMES);
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
        // A 1024-frame period at 96 kHz (2048-frame buffer) would hold 2048 graph frames, but
        // not 4096 engine frames.
        assert_eq!(required_period(1024, graph.quantum_at(96_000)), 2048);
        assert_eq!(required_period(1024, graph.quantum_at(48_000)), 1024);
        assert_eq!(GraphInfo::default().quantum_at(44_100), 0);
    }

    #[test]
    fn mismatch_text_names_the_forcing_command() {
        let stream = StreamInfo {
            driver: crate::audio::stream::Driver::Alsa,
            device: "default".into(),
            label: "Default".into(),
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
        let text = describe_mismatch(&graph, &stream, 256, false);
        assert!(text.contains("1488-frame quantum"), "{}", text);
        assert!(text.contains("clock.force-quantum 1488"), "{}", text);
        assert!(text.contains("512-frame buffer"), "{}", text);

        let fine = GraphInfo {
            quantum: 256,
            rate: 48_000,
            ..Default::default()
        };
        assert_eq!(describe_mismatch(&fine, &stream, 256, false), "");

        let resampled = GraphInfo {
            quantum: 256,
            rate: 44_100,
            ..Default::default()
        };
        assert!(describe_mismatch(&resampled, &stream, 256, false).contains("44100 Hz"));

        // Another application forces a larger quantum on the PipeWire driver (REQ-010).
        let native = StreamInfo {
            driver: crate::audio::stream::Driver::PipeWire,
            period_frames: 512,
            ..stream
        };
        let other = GraphInfo {
            quantum: 2048,
            rate: 48_000,
            force_quantum: 2048,
            force_rate: 48_000,
            ..Default::default()
        };
        let text = describe_mismatch(&other, &native, 512, true);
        assert!(text.contains("Another application"), "{}", text);
        assert!(text.contains("2048-frame quantum at 48000 Hz"), "{}", text);
    }

    /// `MetadataIo` over a shared map, so the test can play another application.
    #[derive(Clone, Default)]
    struct FakeMetadata(Arc<std::sync::Mutex<(u32, u32)>>);

    impl FakeMetadata {
        fn get(&self) -> (u32, u32) {
            *self.0.lock().unwrap()
        }
        fn set(&self, forced: (u32, u32)) {
            *self.0.lock().unwrap() = forced;
        }
    }

    impl MetadataIo for FakeMetadata {
        fn read_forced(&mut self) -> Option<(u32, u32)> {
            Some(self.get())
        }
        fn write(&mut self, key: &str, value: u32) -> Result<(), String> {
            let mut forced = self.0.lock().unwrap();
            match key {
                FORCE_QUANTUM_KEY => forced.0 = value,
                FORCE_RATE_KEY => forced.1 = value,
                _ => return Err(format!("unknown key {}", key)),
            }
            Ok(())
        }
    }

    fn graph_forcing(forced: (u32, u32)) -> GraphInfo {
        GraphInfo {
            force_quantum: forced.0,
            force_rate: forced.1,
            ..Default::default()
        }
    }

    #[test]
    fn forced_clock_restores_what_was_there() {
        let metadata = FakeMetadata::default();
        let mut clock = ForcedClock::new(Box::new(metadata.clone()));
        assert!(
            clock.is_ours(&graph_forcing((2048, 0))),
            "forcing nothing yet"
        );

        clock.apply(512, 48_000).unwrap();
        assert_eq!(metadata.get(), (512, 48_000));
        assert!(clock.is_ours(&graph_forcing((512, 48_000))));
        // A buffer change forces again but still restores the original values.
        clock.apply(256, 48_000).unwrap();
        assert_eq!(metadata.get(), (256, 48_000));

        clock.restore();
        assert_eq!(metadata.get(), (0, 0));
        // Restoring twice changes nothing.
        metadata.set((1024, 0));
        clock.restore();
        assert_eq!(metadata.get(), (1024, 0));
    }

    #[test]
    fn forced_clock_leaves_another_applications_values() {
        let metadata = FakeMetadata::default();
        metadata.set((1024, 0));
        let mut clock = ForcedClock::new(Box::new(metadata.clone()));
        clock.apply(512, 48_000).unwrap();

        // Bitwig starts later and forces 2048.
        metadata.set((2048, 48_000));
        assert!(!clock.is_ours(&graph_forcing((2048, 48_000))));
        clock.restore();
        assert_eq!(metadata.get(), (2048, 48_000), "Bitwig's values stay");
    }

    #[test]
    fn forced_clock_forces_again_after_a_foreign_write() {
        let metadata = FakeMetadata::default();
        let mut clock = ForcedClock::new(Box::new(metadata.clone()));
        clock.apply(512, 48_000).unwrap();
        metadata.set((2048, 48_000));

        // The user changes the buffer: the engine forces again, and on exit gives back the
        // values the other application set.
        clock.apply(256, 48_000).unwrap();
        assert_eq!(metadata.get(), (256, 48_000));
        assert!(clock.is_ours(&graph_forcing((256, 48_000))));
        clock.restore();
        assert_eq!(metadata.get(), (2048, 48_000));
    }

    #[test]
    fn forced_clock_treats_a_change_to_either_value_as_foreign() {
        let metadata = FakeMetadata::default();
        let mut clock = ForcedClock::new(Box::new(metadata.clone()));
        clock.apply(512, 44_100).unwrap();
        // Another application changes only the rate.
        metadata.set((512, 96_000));
        assert!(!clock.is_ours(&graph_forcing((512, 96_000))));
        clock.restore();
        assert_eq!(metadata.get(), (512, 96_000));
    }

    #[test]
    fn realtime_state_from_policy_and_denial() {
        assert_eq!(
            realtime_state(Some(libc::SCHED_FIFO), false),
            RealtimeState::Granted
        );
        assert_eq!(
            realtime_state(Some(libc::SCHED_RR), true),
            RealtimeState::Granted
        );
        assert_eq!(
            realtime_state(Some(libc::SCHED_OTHER), true),
            RealtimeState::Denied
        );
        assert_eq!(realtime_state(None, true), RealtimeState::Denied);
        assert_eq!(
            realtime_state(Some(libc::SCHED_OTHER), false),
            RealtimeState::Unknown
        );
        assert_eq!(realtime_state(None, false), RealtimeState::Unknown);
    }

    #[test]
    fn default_sink_is_read_from_json_metadata() {
        let text = "Found \"default\" metadata 36\n\
            update: id:0 key:'default.audio.sink' value:'{\"name\":\"alsa_output.pci.analog-stereo\"}' type:'Spa:String:JSON'\n";
        let value = metadata_text(text, "default.audio.sink").unwrap();
        let json: serde_json::Value = serde_json::from_str(value).unwrap();
        assert_eq!(json["name"], "alsa_output.pci.analog-stereo");
    }
}

//! Logging for the plugin host process.
//!
//! Three outputs:
//! - its own log file, `<log dir>/<host key>-<pid>.log` (DEBUG and up, unbuffered so the lines
//!   before a crash are on disk);
//! - stderr at INFO and up, which the engine keeps the tail of for crash reports;
//! - WARN and ERROR lines forwarded to the engine as `HostMessage::Log`, so they reach the engine
//!   log and Godot's `/log`. Forwarding is rate-limited so a plugin that warns every block can't
//!   flood the control socket.
//!
//! One host can hold several plugin instances, so everything done for an instance runs inside
//! its [`instance_span`]; the file shows `instance{id=3 plugin="Dragonfly Room"}:` on each line,
//! and forwarded lines carry the instance id and plugin name.

use std::fs::{self, File};
use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use tracing::field::{Field, Visit};
use tracing::span::{Attributes, Id};
use tracing::{Event, Level, Subscriber};
use tracing_subscriber::filter::{EnvFilter, LevelFilter};
use tracing_subscriber::layer::{Context, SubscriberExt};
use tracing_subscriber::registry::LookupSpan;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::Layer;

use crate::audio::ipc::{log_file_name, HostMessage, InstanceId, LogLevel};

/// Name of the span that marks work done for one plugin instance.
pub const INSTANCE_SPAN: &str = "instance";

/// Env var with an `EnvFilter` directive for the host's log file.
pub const LOG_FILTER_ENV: &str = "SONARA_PLUGIN_LOG";

/// Default filter for the log file.
const DEFAULT_FILE_FILTER: &str = "info,plugin_host=debug,engine=debug";

/// Forwarded lines allowed per `FORWARD_WINDOW`; the rest are counted and reported once.
const FORWARD_LIMIT: u32 = 20;
const FORWARD_WINDOW: Duration = Duration::from_secs(1);

/// The span every instance's work runs in. Create it once per instance and enter it; creating
/// a span formats its fields, which is too slow to do per call.
///
/// A root span: an instance created while the provisional span of its `Initialize` is entered
/// must not nest inside it.
pub fn instance_span(instance_id: InstanceId, plugin: &str) -> tracing::Span {
    tracing::info_span!(parent: None, INSTANCE_SPAN, id = instance_id, plugin = %plugin)
}

/// Set up the host's logging. Returns the receiver of forwarded lines (drained by the main loop,
/// the only writer to the control socket) and the log file's path when one was opened.
///
/// `log_dir` None (the host was started by hand, or the directory can't be created) logs to
/// stderr only.
pub fn init(host_key: &str, log_dir: Option<&Path>) -> (Receiver<HostMessage>, Option<PathBuf>) {
    let (tx, rx) = mpsc::channel();

    let file = log_dir.and_then(|dir| open_log_file(dir, host_key));
    let file_filter = EnvFilter::try_from_env(LOG_FILTER_ENV)
        .unwrap_or_else(|_| EnvFilter::new(DEFAULT_FILE_FILTER));
    let file_layer = file.as_ref().map(|(file, _)| {
        tracing_subscriber::fmt::layer()
            .with_writer(Mutex::new(file.try_clone().expect("clone log file handle")))
            .with_ansi(false)
            .with_thread_names(true)
            .with_filter(file_filter)
    });

    // The engine keeps stderr's tail for crash reports, so no colour codes unless a person is
    // watching it (a debugger wrapper inherits the terminal).
    let stderr_layer = tracing_subscriber::fmt::layer()
        .with_writer(std::io::stderr)
        .with_ansi(std::io::stderr().is_terminal())
        .with_target(false)
        .with_thread_names(true)
        .with_filter(LevelFilter::INFO);

    tracing_subscriber::registry()
        .with(file_layer)
        .with(stderr_layer)
        .with(ForwardLayer::new(tx))
        .init();

    (rx, file.map(|(_, path)| path))
}

fn open_log_file(dir: &Path, host_key: &str) -> Option<(File, PathBuf)> {
    if let Err(e) = fs::create_dir_all(dir) {
        eprintln!("Can't create plugin log dir {}: {}", dir.display(), e);
        return None;
    }
    let path = dir.join(log_file_name(host_key, std::process::id()));
    match File::create(&path) {
        Ok(file) => Some((file, path)),
        Err(e) => {
            eprintln!("Can't create plugin log {}: {}", path.display(), e);
            None
        }
    }
}

/// Instance id and plugin name recorded from an `instance` span's fields.
#[derive(Debug, Clone, Default)]
struct InstanceFields {
    id: InstanceId,
    plugin: String,
}

impl Visit for InstanceFields {
    fn record_u64(&mut self, field: &Field, value: u64) {
        if field.name() == "id" {
            self.id = value as InstanceId;
        }
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        if field.name() == "id" {
            self.id = value as InstanceId;
        }
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        if field.name() == "plugin" {
            self.plugin = value.to_string();
        }
    }

    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        if field.name() == "plugin" {
            self.plugin = format!("{:?}", value);
        }
    }
}

/// The message field of an event.
#[derive(Default)]
struct MessageVisitor {
    message: String,
}

impl Visit for MessageVisitor {
    fn record_str(&mut self, field: &Field, value: &str) {
        if field.name() == "message" {
            self.message = value.to_string();
        }
    }

    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            self.message = format!("{:?}", value);
        }
    }
}

/// Counts forwarded lines per window.
struct RateLimit {
    window_start: Instant,
    sent: u32,
    suppressed: u32,
}

impl RateLimit {
    fn new(now: Instant) -> Self {
        Self {
            window_start: now,
            sent: 0,
            suppressed: 0,
        }
    }

    /// Whether a line may go out now, plus the number of lines suppressed in the window that
    /// just ended (to report before this one).
    fn admit(&mut self, now: Instant) -> (bool, u32) {
        let mut ended_suppressed = 0;
        if now.duration_since(self.window_start) >= FORWARD_WINDOW {
            ended_suppressed = self.suppressed;
            self.window_start = now;
            self.sent = 0;
            self.suppressed = 0;
        }
        if self.sent < FORWARD_LIMIT {
            self.sent += 1;
            (true, ended_suppressed)
        } else {
            self.suppressed += 1;
            (false, ended_suppressed)
        }
    }
}

/// Forwards WARN and ERROR events to the engine.
struct ForwardLayer {
    tx: Mutex<Sender<HostMessage>>,
    limit: Mutex<RateLimit>,
}

impl ForwardLayer {
    fn new(tx: Sender<HostMessage>) -> Self {
        Self {
            tx: Mutex::new(tx),
            limit: Mutex::new(RateLimit::new(Instant::now())),
        }
    }

    fn send(&self, msg: HostMessage) {
        if let Ok(tx) = self.tx.lock() {
            let _ = tx.send(msg);
        }
    }
}

impl<S> Layer<S> for ForwardLayer
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_new_span(&self, attrs: &Attributes<'_>, id: &Id, ctx: Context<'_, S>) {
        if attrs.metadata().name() != INSTANCE_SPAN {
            return;
        }
        let mut fields = InstanceFields::default();
        attrs.record(&mut fields);
        if let Some(span) = ctx.span(id) {
            span.extensions_mut().insert(fields);
        }
    }

    fn on_event(&self, event: &Event<'_>, ctx: Context<'_, S>) {
        let level = match *event.metadata().level() {
            Level::ERROR => LogLevel::Error,
            Level::WARN => LogLevel::Warn,
            _ => return,
        };

        let (admitted, suppressed) = match self.limit.lock() {
            Ok(mut limit) => limit.admit(Instant::now()),
            Err(_) => return,
        };
        if suppressed > 0 {
            self.send(HostMessage::Log {
                instance_id: 0,
                plugin: String::new(),
                level: LogLevel::Warn,
                message: format!(
                    "{} more warnings from this plugin host were not forwarded; see its log file",
                    suppressed
                ),
            });
        }
        if !admitted {
            return;
        }

        let mut visitor = MessageVisitor::default();
        event.record(&mut visitor);
        let instance = ctx.event_scope(event).and_then(|scope| {
            scope
                .from_root()
                .filter_map(|span| span.extensions().get::<InstanceFields>().cloned())
                .last()
        });
        let InstanceFields { id, plugin } = instance.unwrap_or_default();
        self.send(HostMessage::Log {
            instance_id: id,
            plugin,
            level,
            message: visitor.message,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn forwarded(rx: &Receiver<HostMessage>) -> Vec<(InstanceId, String, LogLevel, String)> {
        rx.try_iter()
            .filter_map(|msg| match msg {
                HostMessage::Log {
                    instance_id,
                    plugin,
                    level,
                    message,
                } => Some((instance_id, plugin, level, message)),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn warnings_carry_the_instance_they_were_logged_for() {
        let (tx, rx) = mpsc::channel();
        let subscriber = tracing_subscriber::registry().with(ForwardLayer::new(tx));
        tracing::subscriber::with_default(subscriber, || {
            tracing::info!("not forwarded");
            tracing::warn!("host-wide");
            let provisional = instance_span(7, "michaelwillis.dragonfly.room");
            let _outer = provisional.enter();
            // Created inside the provisional span, as `Initialize` does: must not nest in it.
            let span = instance_span(7, "Dragonfly Room");
            let _entered = span.enter();
            tracing::error!("plugin failed");
        });

        let lines = forwarded(&rx);
        assert_eq!(lines.len(), 2, "INFO stays local: {:?}", lines);
        assert_eq!(lines[0].0, 0);
        assert_eq!(lines[0].2, LogLevel::Warn);
        assert_eq!(lines[0].3, "host-wide");
        assert_eq!(lines[1].0, 7);
        assert_eq!(lines[1].1, "Dragonfly Room");
        assert_eq!(lines[1].2, LogLevel::Error);
        assert_eq!(lines[1].3, "plugin failed");
    }

    #[test]
    fn forwarding_is_rate_limited_and_reports_what_it_dropped() {
        let t0 = Instant::now();
        let mut limit = RateLimit::new(t0);
        for _ in 0..FORWARD_LIMIT {
            assert_eq!(limit.admit(t0), (true, 0));
        }
        assert_eq!(limit.admit(t0), (false, 0));
        assert_eq!(limit.admit(t0), (false, 0));
        // The next window admits again and reports the two it dropped.
        assert_eq!(limit.admit(t0 + FORWARD_WINDOW), (true, 2));
        assert_eq!(limit.admit(t0 + FORWARD_WINDOW), (true, 0));
    }
}

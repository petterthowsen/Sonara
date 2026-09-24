use crossbeam::channel::Sender;
use tracing::Subscriber;
use tracing_subscriber::Layer;

use crate::audio::EngineStatus;

/// A tracing layer that forwards WARN and ERROR logs to Godot via OSC
pub struct LogForwarder {
    status_tx: Sender<EngineStatus>,
}

impl LogForwarder {
    pub fn new(status_tx: Sender<EngineStatus>) -> Self {
        Self { status_tx }
    }
}

impl<S: Subscriber> Layer<S> for LogForwarder {
    fn on_event(
        &self,
        event: &tracing::Event<'_>,
        _ctx: tracing_subscriber::layer::Context<'_, S>,
    ) {
        let metadata = event.metadata();
        let level = metadata.level();

        // Only forward WARN and ERROR logs
        if !matches!(level, &tracing::Level::WARN | &tracing::Level::ERROR) {
            return;
        }

        // Extract the message from the event
        let mut visitor = MessageVisitor::default();
        event.record(&mut visitor);

        if let Some(message) = visitor.message {
            let level_str = match level {
                &tracing::Level::WARN => "warn",
                &tracing::Level::ERROR => "error",
                _ => return,
            };

            // Send to Godot via status channel
            // try_send: the status thread drains this channel and also logs, so a blocking send
            // on a full channel could deadlock it. The line is still in the log files.
            let _ = self.status_tx.try_send(EngineStatus::LogMessage {
                level: level_str.to_string(),
                message,
            });
        }
    }
}

/// Visitor to extract the message field from a tracing event
#[derive(Default)]
struct MessageVisitor {
    message: Option<String>,
}

impl tracing::field::Visit for MessageVisitor {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            self.message = Some(format!("{:?}", value));
        }
    }

    fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
        if field.name() == "message" {
            self.message = Some(value.to_string());
        }
    }
}

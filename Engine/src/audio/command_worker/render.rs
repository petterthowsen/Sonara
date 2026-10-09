//! Offline render commands on the command thread.

use tracing::warn;

use super::CommandWorker;
use crate::audio::commands::EngineStatus;
use crate::audio::render::{RenderHandle, RenderJob};

impl CommandWorker {
    /// Start an offline render on its own thread. Only one runs at a time; another job fails
    /// at once.
    pub(super) fn start_render(&mut self, job: RenderJob) {
        if let Some(running) = self.render.as_ref().filter(|r| !r.is_finished()) {
            self.send_status(EngineStatus::RenderFailed {
                job_id: job.job_id,
                error: format!("render {} is still running", running.job_id()),
            });
            return;
        }
        let job_id = job.job_id.clone();
        match RenderHandle::spawn(job, self.state.clone(), self.status_tx.clone()) {
            Ok(handle) => self.render = Some(handle),
            Err(e) => self.send_status(EngineStatus::RenderFailed {
                job_id,
                error: format!("couldn't start the render thread: {}", e),
            }),
        }
    }

    /// Cancel the running render if it is `job_id`.
    pub(super) fn cancel_render(&self, job_id: &str) {
        match self.render.as_ref().filter(|r| !r.is_finished()) {
            Some(running) if running.job_id() == job_id => running.cancel(),
            _ => warn!("Cancel for render {}, which isn't running", job_id),
        }
    }
}

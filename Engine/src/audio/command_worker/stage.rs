//! Virtual Stage commands that build their objects off the lock (spec 051): a channel entering
//! the Stage pan mode and the Stage return. The delay lines and the reverb allocate, so they are
//! built here with the state lock released and swapped in under it.

use tracing::warn;

use super::CommandWorker;
use crate::audio::commands::stage;
use crate::audio::commands::CommandEffects;
use crate::audio::stage::source::StageSource;
use crate::audio::stage::tail::StageTail;
use crate::audio::types::ChannelId;

impl CommandWorker {
    /// Put channel `id` in the Stage pan mode. Master and the Stage return are refused before
    /// anything is built.
    pub(super) fn set_stage_pan_mode(&self, id: ChannelId) {
        let sample_rate = {
            let state = self.lock_state();
            if let Some(reason) = stage::stage_refusal(&state, id) {
                warn!("Pan mode Stage refused for channel {}: {}", id, reason);
                return;
            }
            if state.channels.get(&id).is_some_and(|c| c.stage.is_some()) {
                return; // already a stage source: keep its delay history
            }
            state.device_sample_rate
        };
        let source = Box::new(StageSource::new(sample_rate, self.max_buffer_size));
        self.apply_stage(|state, effects| {
            stage::enter_stage(state, id, source, effects);
        });
    }

    /// Register channel `id` as the Stage return (0 clears it).
    pub(super) fn set_stage_return(&self, id: ChannelId) {
        let tail = (id != 0).then(|| {
            let sample_rate = self.lock_state().device_sample_rate;
            Box::new(StageTail::new(sample_rate, self.max_buffer_size))
        });
        self.apply_stage(|state, effects| {
            stage::set_return(state, id, tail, effects);
        });
    }

    /// Run `apply` under the lock, then drop what it replaced after the lock is released.
    fn apply_stage(
        &self,
        apply: impl FnOnce(&mut crate::audio::state::EngineState, &mut CommandEffects),
    ) {
        let mut effects = CommandEffects::default();
        {
            let mut state = self.lock_state();
            apply(&mut state, &mut effects);
        }
        let CommandEffects { statuses, trash } = effects;
        for status in statuses {
            self.send_status(status);
        }
        drop(trash);
    }
}

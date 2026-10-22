//! Virtual Stage rendering for a channel (spec 051).

use super::Channel;
use crate::audio::automation::StageParam;
use crate::audio::stage::{RoomModel, StageParams};

/// True if `left` and `right` are the same signal, so the source is mono.
fn is_mono(left: &[f32], right: &[f32]) -> bool {
    left.iter().zip(right).all(|(l, r)| l == r)
}

impl Channel {
    /// The placement the stage pass renders: `stage_params` with any automation override
    /// (`automation_stage`, normalized) mapped onto `room`'s spans. The base values are never
    /// written, so releasing a lane returns the source to where Godot placed it.
    pub fn effective_stage_params(&self, room: &RoomModel) -> StageParams {
        let mut params = self.stage_params;
        let over = |param: StageParam| {
            self.automation_stage[param as usize].map(|value| param.denormalize(value, room))
        };
        if let Some(v) = over(StageParam::X) {
            params.x = v;
        }
        if let Some(v) = over(StageParam::Y) {
            params.y = v;
        }
        if let Some(v) = over(StageParam::Z) {
            params.z = v;
        }
        if let Some(v) = over(StageParam::Size) {
            params.size = v;
        }
        if let Some(v) = over(StageParam::Rotation) {
            params.rotation_deg = v;
        }
        params
    }

    /// Place the channel's post-fader signal in the room: the buffers become the direct sound
    /// and `mix.stage_left/right` the reflections for the Stage return. A channel that isn't a
    /// stage source leaves its buffers alone and writes silent reflections.
    ///
    /// A source whose L and R are identical counts as mono and stays one point whatever its
    /// size (REQ-007): nothing records whether the input is mono, so it is read off the block.
    /// Call it every block while the channel is a stage source: the source's delay lines keep
    /// the input history, and skipping blocks would leave it stale.
    pub fn render_stage(&mut self, frames: usize) {
        let frames = frames
            .min(self.buffer_left.len())
            .min(self.buffer_right.len())
            .min(self.mix.stage_left.len())
            .min(self.mix.stage_right.len());
        let Some(room) = self.stage.as_ref().map(|stage| *stage.room()) else {
            self.mix.stage_left[..frames].fill(0.0);
            self.mix.stage_right[..frames].fill(0.0);
            return;
        };
        let params = self.effective_stage_params(&room);
        let Some(stage) = self.stage.as_mut() else {
            return;
        };
        let mono = is_mono(&self.buffer_left[..frames], &self.buffer_right[..frames]);
        stage.render(
            &mut self.buffer_left[..frames],
            &mut self.buffer_right[..frames],
            &mut self.mix.stage_left[..frames],
            &mut self.mix.stage_right[..frames],
            &params,
            mono,
            frames,
        );
    }
}

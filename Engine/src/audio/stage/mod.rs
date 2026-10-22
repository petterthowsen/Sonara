//! Virtual Stage (spec 051): a shoebox room shared by every channel in the Stage pan mode.
//!
//! - `image_source` computes the direct path and the first and second order reflections.
//! - `panner` turns a direction into per-output gains (the layout seam; stereo only for now).
//! - `source` renders one stage source: direct sound plus its reflections.
//! - `tail` is the shared late reverb on the Stage return.
//!
//! Coordinates are meters with the origin at the front-left floor corner: X runs left to right,
//! Y from the front wall to the back wall, Z up. Directions handed to a [`panner::Panner`] are in
//! the listener's frame instead: X right, Y forward (toward the front wall), Z up.

pub mod image_source;
pub mod panner;
pub mod source;
pub mod tail;

use super::types::ChannelId;

/// Distance at which a source sounds as loud as it would unspatialized.
pub const R_REF: f32 = 5.0;
pub const SPEED_OF_SOUND: f32 = 343.0;
/// Closest distance the distance law uses, so a source on the listener doesn't blow up.
pub const MIN_DISTANCE: f32 = 0.5;
/// Direct sound is never boosted by more than this (+6 dB).
pub const MAX_DIRECT_GAIN: f32 = 2.0;

/// First-order surfaces (and so first-order taps) per point.
pub const FIRST_ORDER_SURFACES: usize = 6;

pub const MAX_WIDTH: f32 = 60.0;
pub const MAX_DEPTH: f32 = 40.0;
pub const MAX_HEIGHT: f32 = 25.0;
pub const MIN_DIMENSION: f32 = 2.0;
pub const MIN_DECAY_S: f32 = 0.1;
pub const MAX_DECAY_S: f32 = 30.0;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Vec3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl Vec3 {
    pub const fn new(x: f32, y: f32, z: f32) -> Self {
        Self { x, y, z }
    }

    pub fn length(self) -> f32 {
        (self.x * self.x + self.y * self.y + self.z * self.z).sqrt()
    }
}

/// The six room surfaces, in the order of [`RoomModel::surfaces`] and the `/stage/set` message.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Surface {
    Front = 0,
    Back = 1,
    Left = 2,
    Right = 3,
    Floor = 4,
    Ceiling = 5,
}

impl Surface {
    pub const ALL: [Surface; 6] = [
        Surface::Front,
        Surface::Back,
        Surface::Left,
        Surface::Right,
        Surface::Floor,
        Surface::Ceiling,
    ];
}

/// How a surface reflects: a broadband gain and a high-frequency damping (0 = bright, 1 = dull).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SurfaceMaterial {
    pub gain: f32,
    pub hf_damping: f32,
}

impl Default for SurfaceMaterial {
    fn default() -> Self {
        Self {
            gain: 0.7,
            hf_damping: 0.3,
        }
    }
}

/// What the Stage return receives.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum OutputMode {
    /// Reflections and tail.
    #[default]
    Full = 0,
    /// Reflections only, for an external reverb on the Stage return.
    ReflectionsOnly = 1,
    /// Nothing reaches the Stage return.
    DirectOnly = 2,
}

impl From<i32> for OutputMode {
    fn from(value: i32) -> Self {
        match value {
            1 => OutputMode::ReflectionsOnly,
            2 => OutputMode::DirectOnly,
            _ => OutputMode::Full,
        }
    }
}

/// The project's one room. `Copy`, so the command thread hands it to every source under the lock.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RoomModel {
    pub width: f32,
    pub depth: f32,
    pub height: f32,
    pub listener: Vec3,
    /// Tail decay time (RT60) in seconds.
    pub decay_s: f32,
    /// Tail level relative to the reflections, in dB.
    pub tail_db: f32,
    /// Delay the direct sound by its distance to the listener.
    pub distance_delay: bool,
    pub output_mode: OutputMode,
    pub surfaces: [SurfaceMaterial; 6],
}

impl Default for RoomModel {
    /// A 20 × 25 × 10 m hall with the listener 12 m back, facing the front wall.
    fn default() -> Self {
        Self {
            width: 20.0,
            depth: 25.0,
            height: 10.0,
            listener: Vec3::new(10.0, 12.0, 1.5),
            decay_s: 2.0,
            tail_db: -6.0,
            distance_delay: false,
            output_mode: OutputMode::Full,
            surfaces: [SurfaceMaterial::default(); 6],
        }
    }
}

impl RoomModel {
    /// Limit every value to what the engine buffers are sized for and keep the listener inside.
    pub fn clamped(mut self) -> Self {
        self.width = self.width.clamp(MIN_DIMENSION, MAX_WIDTH);
        self.depth = self.depth.clamp(MIN_DIMENSION, MAX_DEPTH);
        self.height = self.height.clamp(MIN_DIMENSION, MAX_HEIGHT);
        self.listener = self.clamp_point(self.listener);
        self.decay_s = self.decay_s.clamp(MIN_DECAY_S, MAX_DECAY_S);
        self.tail_db = self.tail_db.clamp(-60.0, 12.0);
        for s in &mut self.surfaces {
            s.gain = s.gain.clamp(0.0, 1.0);
            s.hf_damping = s.hf_damping.clamp(0.0, 1.0);
        }
        self
    }

    /// `p` limited to the room's inside.
    pub fn clamp_point(&self, p: Vec3) -> Vec3 {
        Vec3::new(
            p.x.clamp(0.0, self.width),
            p.y.clamp(0.0, self.depth),
            p.z.clamp(0.0, self.height),
        )
    }

    pub fn volume(&self) -> f32 {
        self.width * self.depth * self.height
    }

    /// The longest image-source path the sources render, in meters: a second-order image is two
    /// walls away along one axis (3 room lengths at most) or one wall along two axes.
    pub fn max_path(&self) -> f32 {
        let d = [self.width, self.depth, self.height];
        let mut longest: f32 = 0.0;
        for a in 0..3 {
            let (b, c) = ((a + 1) % 3, (a + 2) % 3);
            let single = (3.0 * d[a]).powi(2) + d[b].powi(2) + d[c].powi(2);
            let pair = (2.0 * d[a]).powi(2) + (2.0 * d[b]).powi(2) + d[c].powi(2);
            longest = longest.max(single).max(pair);
        }
        longest.sqrt()
    }
}

/// Per-channel stage placement (the `/channel/{id}/stage` message).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StageParams {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    /// Width in meters of a stereo source; 0 renders one point.
    pub size: f32,
    /// Angle of the source's line in the top-down view, degrees. 0 = parallel to the front wall.
    pub rotation_deg: f32,
    pub sum_mode: SumMode,
    pub has_room: bool,
}

impl Default for StageParams {
    fn default() -> Self {
        Self {
            x: 10.0,
            y: 5.0,
            z: 1.5,
            size: 0.0,
            rotation_deg: 0.0,
            sum_mode: SumMode::LPlusR,
            has_room: false,
        }
    }
}

/// How a stereo source becomes one point at size 0.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum SumMode {
    /// (L + R) / sqrt 2: keeps the level of uncorrelated channels.
    #[default]
    LPlusR = 0,
    /// Mid, (L + R) / 2: keeps the level of identical channels.
    Mid = 1,
}

impl From<i32> for SumMode {
    fn from(value: i32) -> Self {
        if value == 1 {
            SumMode::Mid
        } else {
            SumMode::LPlusR
        }
    }
}

/// Engine-wide stage state (`EngineState::stage`).
#[derive(Clone, Copy, Debug, Default)]
pub struct StageState {
    pub room: RoomModel,
    /// The Stage return channel; `None` until `/stage/return` registers one.
    pub return_channel_id: Option<ChannelId>,
}

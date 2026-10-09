//! Sample buffers, play and loop regions, and the zones that voices play.

use super::params::{LoopMode, DEFAULT_ROOT};
use super::zones::{SelectableZone, ZoneRanges, ZoneSettings, UNGROUPED};

/// Shortest play region and loop, in frames.
pub(super) const MIN_REGION_FRAMES: f64 = 2.0;

pub(super) const MIN_LOOP_FRAMES: f64 = 4.0;

/// `Voice::zone` of the implicit single-mode zone.
pub(super) const SINGLE_ZONE: u16 = u16::MAX;

/// Decoded interleaved PCM. `sample_rate` is the buffer rate, which may differ from the device.
pub(super) struct SampleBuffer {
    pub(super) samples: Vec<f32>,
    pub(super) channels: usize,
    pub(super) frames: usize,
    pub(super) sample_rate: f32,
}

impl SampleBuffer {
    pub(super) fn new(samples: Vec<f32>, channels: usize, sample_rate: u32) -> Self {
        let channels = channels.max(1);
        Self {
            frames: samples.len() / channels,
            samples,
            channels,
            sample_rate: (sample_rate as f32).max(1.0),
        }
    }
}

/// Play region, loop and crossfade lengths in sample frames, ordered and clamped.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Regions {
    /// `[start, end)`.
    pub play: (f64, f64),
    /// `[start, end)`, inside `play`.
    pub loop_: (f64, f64),
    /// Forward crossfade length: capped by half the loop and by the material before Loop Start.
    pub xfade_fwd: f64,
    /// Reverse crossfade length: capped by half the loop and by the material after Loop End.
    pub xfade_rev: f64,
}

impl Regions {
    const EMPTY: Regions = Regions {
        play: (0.0, 0.0),
        loop_: (0.0, 0.0),
        xfade_fwd: 0.0,
        xfade_rev: 0.0,
    };

    pub(super) fn loop_len(&self) -> f64 {
        self.loop_.1 - self.loop_.0
    }
}

pub(super) fn ordered(a: f32, b: f32) -> (f64, f64) {
    let (a, b) = (a.clamp(0.0, 1.0) as f64, b.clamp(0.0, 1.0) as f64);
    (a.min(b), a.max(b))
}

/// Order and clamp the raw points: `start < end`, the loop inside `[start, end]` with a minimum
/// length, and the crossfade (`crossfade` is a fraction of the loop) capped per direction.
pub fn resolve_regions(
    frames: usize,
    start: f32,
    end: f32,
    loop_start: f32,
    loop_end: f32,
    crossfade: f32,
) -> Regions {
    if frames == 0 {
        return Regions::EMPTY;
    }
    let max = frames as f64;
    let (s, e) = ordered(start, end);
    let (mut a, mut b) = (s * max, e * max);
    if b - a < MIN_REGION_FRAMES {
        b = (a + MIN_REGION_FRAMES).min(max);
        a = (b - MIN_REGION_FRAMES).max(0.0);
    }
    let (ls, le) = ordered(loop_start, loop_end);
    let mut l0 = (ls * max).clamp(a, b);
    let mut l1 = (le * max).clamp(a, b);
    let min_loop = MIN_LOOP_FRAMES.min(b - a);
    if l1 - l0 < min_loop {
        l1 = l0 + min_loop;
        if l1 > b {
            l1 = b;
            l0 = b - min_loop;
        }
    }
    let len = l1 - l0;
    let wanted = (crossfade.clamp(0.0, 1.0) as f64 * len).min(len * 0.5);
    Regions {
        play: (a, b),
        loop_: (l0, l1),
        xfade_fwd: wanted.min(l0),
        xfade_rev: wanted.min(max - l1),
    }
}

/// One playable sample and everything a voice reads from it besides the device-wide settings.
pub(super) struct Zone {
    /// Godot's zone id (unused for the single-mode zone).
    pub(super) id: u32,
    pub(super) sample: Option<SampleBuffer>,
    pub(super) regions: Regions,
    /// Raw points, 0–1 over the file, resolved into `regions`.
    pub(super) start: f32,
    pub(super) end: f32,
    pub(super) loop_start: f32,
    pub(super) loop_end: f32,
    /// Fraction of the loop.
    pub(super) crossfade: f32,
    pub(super) loop_mode: LoopMode,
    pub(super) reverse: bool,
    pub(super) root: u8,
    /// Semitones, fine tune included.
    pub(super) tune: f32,
    pub(super) key_track: bool,
    pub(super) gain: f32,
    pub(super) ranges: ZoneRanges,
    pub(super) group_id: u32,
    /// Index of `group_id` in `SamplerDevice::groups`, or 0 (Ungrouped) while it's missing.
    pub(super) group_index: usize,
    /// Load in flight, so stale AFS completions can be ignored.
    pub(super) req_id: String,
    /// Last state sent on `loading_state` (`zone/{zid}/loading_state` for a multisample zone).
    pub(super) loading_state: String,
}

impl Zone {
    pub(super) fn empty(id: u32) -> Self {
        Self {
            id,
            sample: None,
            regions: Regions::EMPTY,
            start: 0.0,
            end: 1.0,
            loop_start: 0.0,
            loop_end: 1.0,
            crossfade: 0.0,
            loop_mode: LoopMode::Off,
            reverse: false,
            root: DEFAULT_ROOT,
            tune: 0.0,
            key_track: false,
            gain: 1.0,
            ranges: ZoneRanges::default(),
            group_id: UNGROUPED,
            group_index: 0,
            req_id: String::new(),
            loading_state: "idle".to_string(),
        }
    }

    pub(super) fn frames(&self) -> usize {
        self.sample.as_ref().map_or(0, |s| s.frames)
    }

    /// Re-resolve the play region, loop and crossfade from the raw points.
    pub(super) fn resolve_regions(&mut self) {
        self.regions = resolve_regions(
            self.frames(),
            self.start,
            self.end,
            self.loop_start,
            self.loop_end,
            self.crossfade,
        );
    }

    /// Take a multisample zone's settings. Key tracking follows the device Key Track parameter.
    pub(super) fn apply_settings(&mut self, s: &ZoneSettings) {
        self.ranges = s.ranges;
        self.root = s.root;
        self.tune = s.tune;
        self.gain = s.gain;
        self.start = s.start;
        self.end = s.end;
        self.reverse = s.reverse;
        self.loop_mode = LoopMode::from_index(s.loop_mode as usize);
        self.loop_start = s.loop_start;
        self.loop_end = s.loop_end;
        self.crossfade = s.crossfade;
        self.group_id = s.group_id;
        self.resolve_regions();
    }
}

impl SelectableZone for Zone {
    fn ranges(&self) -> &ZoneRanges {
        &self.ranges
    }

    fn group_index(&self) -> usize {
        self.group_index
    }

    fn is_playable(&self) -> bool {
        self.sample.is_some()
    }
}

/// The zone a voice plays: `single` for [`SINGLE_ZONE`], else `zones[index]`.
pub(super) fn zone_at<'a>(single: &'a Zone, zones: &'a [Zone], index: u16) -> Option<&'a Zone> {
    if index == SINGLE_ZONE {
        Some(single)
    } else {
        zones.get(index as usize)
    }
}

/// Linearly interpolate one stereo frame from interleaved PCM.
pub(super) fn interpolate_frame(sample: &SampleBuffer, position: f64) -> (f32, f32) {
    if sample.frames == 0 || sample.channels == 0 {
        return (0.0, 0.0);
    }
    let last = (sample.frames - 1) as f64;
    let pos = position.clamp(0.0, last);
    let i0 = pos.floor() as usize;
    let i1 = (i0 + 1).min(sample.frames - 1);
    let frac = (pos - i0 as f64) as f32;
    let ch = sample.channels;
    let read = |frame: usize, channel: usize| -> f32 {
        let idx = frame * ch + channel.min(ch - 1);
        sample.samples.get(idx).copied().unwrap_or(0.0)
    };
    if ch == 1 {
        let a = read(i0, 0);
        let b = read(i1, 0);
        let v = a + (b - a) * frac;
        (v, v)
    } else {
        let l0 = read(i0, 0);
        let l1 = read(i1, 0);
        let r0 = read(i0, 1);
        let r1 = read(i1, 1);
        (l0 + (l1 - l0) * frac, r0 + (r1 - r0) * frac)
    }
}

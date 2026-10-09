//! Sampler multisample zones (spec 023): key/velocity ranges with equal-power fades, zone
//! groups with mute/solo and All/Round robin/Random play modes, and the note-on zone selection.
//!
//! Pure and allocation-free on the audio path: [`select_zones`] only `clear()`s and `push()`es
//! within the capacity of the caller's reserved index buffer.

use std::f32::consts::FRAC_PI_2;

/// Most zones one Sampler holds. Zone indices travel as `u16`.
pub const MAX_ZONES: usize = 512;
/// Most groups one Sampler holds, Ungrouped (id 0) included.
pub const MAX_GROUPS: usize = 64;
/// Group id of "Ungrouped". It always exists, at index 0.
pub const UNGROUPED: u32 = 0;
/// No zone (a group's last Random pick before it has one).
pub const NO_ZONE: u16 = u16::MAX;

const TUNE_LIMIT: f32 = 48.0;
const GAIN_LIMIT: f32 = 4.0;

/// Key range, velocity range and their fade lengths, clamped and ordered.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ZoneRanges {
    pub key_lo: u8,
    pub key_hi: u8,
    pub vel_lo: u8,
    pub vel_hi: u8,
    /// Fade-in length in semitones from `key_lo`, fade-out length from `key_hi`.
    pub key_fade: (u8, u8),
    /// Fade-in length in velocity steps from `vel_lo`, fade-out length from `vel_hi`.
    pub vel_fade: (u8, u8),
}

impl Default for ZoneRanges {
    fn default() -> Self {
        Self {
            key_lo: 0,
            key_hi: 127,
            vel_lo: 1,
            vel_hi: 127,
            key_fade: (0, 0),
            vel_fade: (0, 0),
        }
    }
}

fn ordered_u8(a: i32, b: i32, min: i32) -> (u8, u8) {
    let (a, b) = (a.clamp(min, 127) as u8, b.clamp(min, 127) as u8);
    (a.min(b), a.max(b))
}

impl ZoneRanges {
    /// Keys clamp to 0–127, velocities to 1–127, each pair ordered. Fades clamp to the width of
    /// their range.
    pub fn new(
        key: (i32, i32),
        vel: (i32, i32),
        key_fade: (i32, i32),
        vel_fade: (i32, i32),
    ) -> Self {
        let (key_lo, key_hi) = ordered_u8(key.0, key.1, 0);
        let (vel_lo, vel_hi) = ordered_u8(vel.0, vel.1, 1);
        let fade = |f: i32, width: u8| f.clamp(0, width as i32) as u8;
        let key_w = key_hi - key_lo;
        let vel_w = vel_hi - vel_lo;
        Self {
            key_lo,
            key_hi,
            vel_lo,
            vel_hi,
            key_fade: (fade(key_fade.0, key_w), fade(key_fade.1, key_w)),
            vel_fade: (fade(vel_fade.0, vel_w), fade(vel_fade.1, vel_w)),
        }
    }

    pub fn contains(&self, note: u8, vel: u8) -> bool {
        (self.key_lo..=self.key_hi).contains(&note) && (self.vel_lo..=self.vel_hi).contains(&vel)
    }

    /// Product of the key and velocity fade gains for a note inside the ranges.
    pub fn gain(&self, note: u8, vel: u8) -> f32 {
        fade_gain(
            note,
            self.key_lo,
            self.key_hi,
            self.key_fade.0,
            self.key_fade.1,
        ) * fade_gain(
            vel,
            self.vel_lo,
            self.vel_hi,
            self.vel_fade.0,
            self.vel_fade.1,
        )
    }
}

/// Equal-power gain of `x` in `[lo, hi]` with a fade-in of `fade_in` steps from `lo` and a
/// fade-out of `fade_out` steps to `hi` (REQ-030): 0 at a faded edge, 1 outside the fades, 0
/// outside the range.
pub fn fade_gain(x: u8, lo: u8, hi: u8, fade_in: u8, fade_out: u8) -> f32 {
    let (x, lo, hi) = (x as i32, lo as i32, hi as i32);
    if x < lo || x > hi {
        return 0.0;
    }
    let mut gain = 1.0;
    let (fade_in, fade_out) = (fade_in as i32, fade_out as i32);
    if fade_in > 0 && x < lo + fade_in {
        gain *= ((x - lo) as f32 / fade_in as f32 * FRAC_PI_2).sin();
    }
    if fade_out > 0 && x > hi - fade_out {
        gain *= ((hi - x) as f32 / fade_out as f32 * FRAC_PI_2).sin();
    }
    gain
}

/// MIDI velocity 1–127 for a normalized note-on velocity.
pub fn velocity_to_midi(velocity: f32) -> u8 {
    (velocity * 127.0).round().clamp(1.0, 127.0) as u8
}

/// xorshift32 step. `state` must not be 0.
pub fn next_random(state: &mut u32) -> u32 {
    let mut x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    x
}

/// One zone's settings as Godot sends them on `zone/{zid}/set`, in real units.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ZoneSettings {
    pub ranges: ZoneRanges,
    pub root: u8,
    /// Semitones, fine tune included.
    pub tune: f32,
    /// Linear.
    pub gain: f32,
    /// Points are 0–1 over the file, as the single-mode parameters.
    pub start: f32,
    pub end: f32,
    pub reverse: bool,
    /// 0 = Off, 1 = On, 2 = Ping-Pong.
    pub loop_mode: u8,
    pub loop_start: f32,
    pub loop_end: f32,
    /// Fraction of the loop, 0–1.
    pub crossfade: f32,
    pub group_id: u32,
}

impl Default for ZoneSettings {
    fn default() -> Self {
        Self {
            ranges: ZoneRanges::default(),
            root: 60,
            tune: 0.0,
            gain: 1.0,
            start: 0.0,
            end: 1.0,
            reverse: false,
            loop_mode: 0,
            loop_start: 0.0,
            loop_end: 1.0,
            crossfade: 0.0,
            group_id: UNGROUPED,
        }
    }
}

fn finite_clamp(x: f32, lo: f32, hi: f32, fallback: f32) -> f32 {
    if x.is_finite() {
        x.clamp(lo, hi)
    } else {
        fallback
    }
}

impl ZoneSettings {
    /// Clamp every value into its valid range (non-finite floats take their default).
    pub fn sanitized(self) -> Self {
        Self {
            root: self.root.min(127),
            tune: finite_clamp(self.tune, -TUNE_LIMIT, TUNE_LIMIT, 0.0),
            gain: finite_clamp(self.gain, 0.0, GAIN_LIMIT, 1.0),
            start: finite_clamp(self.start, 0.0, 1.0, 0.0),
            end: finite_clamp(self.end, 0.0, 1.0, 1.0),
            loop_mode: self.loop_mode.min(2),
            loop_start: finite_clamp(self.loop_start, 0.0, 1.0, 0.0),
            loop_end: finite_clamp(self.loop_end, 0.0, 1.0, 1.0),
            crossfade: finite_clamp(self.crossfade, 0.0, 1.0, 0.0),
            ..self
        }
    }
}

/// How a group picks among its zones matching one note-on (REQ-032).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GroupPlayMode {
    All,
    RoundRobin,
    Random,
}

impl GroupPlayMode {
    /// 0 = All, 1 = Round robin, 2 = Random; anything else is All.
    pub fn from_index(index: i32) -> Self {
        match index {
            1 => Self::RoundRobin,
            2 => Self::Random,
            _ => Self::All,
        }
    }
}

/// A zone group's shared settings plus its selection state.
#[derive(Clone, Copy, Debug)]
pub struct ZoneGroup {
    pub id: u32,
    pub gain: f32,
    pub mute: bool,
    pub solo: bool,
    pub play_mode: GroupPlayMode,
    /// Round-robin counter, advanced at each note-on the group matches.
    rr_next: u32,
    /// Zone index of the last Random pick, so the next differs.
    last_zone: u16,
    // Per note-on scratch for `select_zones`.
    matches: u16,
    last_ord: u16,
    pick: u16,
    seen: u16,
}

impl ZoneGroup {
    pub fn new(id: u32) -> Self {
        Self {
            id,
            gain: 1.0,
            mute: false,
            solo: false,
            play_mode: GroupPlayMode::All,
            rr_next: 0,
            last_zone: NO_ZONE,
            matches: 0,
            last_ord: NO_ZONE,
            pick: 0,
            seen: 0,
        }
    }

    /// Replace the settings. A new play mode restarts the rotation.
    pub fn set(&mut self, gain: f32, mute: bool, solo: bool, play_mode: GroupPlayMode) {
        self.gain = finite_clamp(gain, 0.0, GAIN_LIMIT, 1.0);
        self.mute = mute;
        self.solo = solo;
        if play_mode != self.play_mode {
            self.play_mode = play_mode;
            self.rr_next = 0;
            self.last_zone = NO_ZONE;
        }
    }

    /// Zone `removed` was swap-removed and the zone at `moved_from` took its index.
    pub fn remap_zone(&mut self, removed: u16, moved_from: u16) {
        if self.last_zone == removed {
            self.last_zone = NO_ZONE;
        } else if self.last_zone == moved_from {
            self.last_zone = removed;
        }
    }
}

/// What [`select_zones`] reads from a zone.
pub trait SelectableZone {
    fn ranges(&self) -> &ZoneRanges;
    /// Index into the groups slice.
    fn group_index(&self) -> usize;
    /// Has PCM to play.
    fn is_playable(&self) -> bool;
}

/// Indices of the zones that start a voice for `note` at `vel` (REQ-016, REQ-031, REQ-032):
/// playable zones whose ranges contain the note, whose group isn't muted and is soloed when any
/// group is. A Round robin or Random group keeps one of its matches. Writes `out` in zone order
/// and never grows it past its capacity, so it doesn't allocate.
pub fn select_zones<Z: SelectableZone>(
    zones: &[Z],
    groups: &mut [ZoneGroup],
    any_solo: bool,
    note: u8,
    vel: u8,
    rng: &mut u32,
    out: &mut Vec<u16>,
) {
    out.clear();
    for group in groups.iter_mut() {
        group.matches = 0;
        group.last_ord = NO_ZONE;
        group.seen = 0;
    }
    for (index, zone) in zones.iter().enumerate() {
        if out.len() == out.capacity() {
            break;
        }
        if !zone.is_playable() || !zone.ranges().contains(note, vel) {
            continue;
        }
        let Some(group) = groups.get_mut(zone.group_index()) else {
            continue;
        };
        if group.mute || (any_solo && !group.solo) {
            continue;
        }
        if index as u16 == group.last_zone {
            group.last_ord = group.matches;
        }
        group.matches += 1;
        out.push(index as u16);
    }
    let mut picking = false;
    for group in groups.iter_mut().filter(|g| g.matches > 0) {
        let n = group.matches as u32;
        group.pick = match group.play_mode {
            GroupPlayMode::All => continue,
            GroupPlayMode::RoundRobin => {
                let k = group.rr_next % n;
                group.rr_next = group.rr_next.wrapping_add(1);
                k as u16
            }
            GroupPlayMode::Random if n == 1 => 0,
            GroupPlayMode::Random if (group.last_ord as u32) < n => {
                let k = next_random(rng) % (n - 1);
                (if k >= group.last_ord as u32 { k + 1 } else { k }) as u16
            }
            GroupPlayMode::Random => (next_random(rng) % n) as u16,
        };
        picking = true;
    }
    if !picking {
        return;
    }
    let mut kept = 0;
    for i in 0..out.len() {
        let index = out[i];
        let group = &mut groups[zones[index as usize].group_index()];
        let keep = group.play_mode == GroupPlayMode::All || group.seen == group.pick;
        group.seen += 1;
        if keep {
            if group.play_mode != GroupPlayMode::All {
                group.last_zone = index;
            }
            out[kept] = index;
            kept += 1;
        }
    }
    out.truncate(kept);
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestZone {
        ranges: ZoneRanges,
        group: usize,
        playable: bool,
    }

    impl SelectableZone for TestZone {
        fn ranges(&self) -> &ZoneRanges {
            &self.ranges
        }
        fn group_index(&self) -> usize {
            self.group
        }
        fn is_playable(&self) -> bool {
            self.playable
        }
    }

    fn zone(key: (i32, i32), vel: (i32, i32), group: usize) -> TestZone {
        TestZone {
            ranges: ZoneRanges::new(key, vel, (0, 0), (0, 0)),
            group,
            playable: true,
        }
    }

    fn groups(n: usize) -> Vec<ZoneGroup> {
        (0..n as u32).map(ZoneGroup::new).collect()
    }

    fn select(zones: &[TestZone], groups: &mut [ZoneGroup], note: u8, vel: u8) -> Vec<u16> {
        let any_solo = groups.iter().any(|g| g.solo);
        let mut out = Vec::with_capacity(MAX_ZONES);
        let mut rng = 0x1234_5678;
        select_zones(zones, groups, any_solo, note, vel, &mut rng, &mut out);
        out
    }

    #[test]
    fn fade_gain_edges() {
        // REQ-030: velocity 1–80 with a fade-out of 20, velocity 70.
        let g = fade_gain(70, 1, 80, 0, 20);
        assert!((g - (FRAC_PI_2 * 0.5).cos()).abs() < 1e-6, "{g}");
        assert!((g - 0.707).abs() < 0.001);
        assert_eq!(fade_gain(80, 1, 80, 0, 20), 0.0, "0 at the faded edge");
        assert_eq!(fade_gain(60, 1, 80, 0, 20), 1.0, "1 where the fade starts");
        assert_eq!(fade_gain(30, 1, 80, 0, 20), 1.0, "1 outside the fades");
        assert_eq!(fade_gain(10, 10, 20, 4, 0), 0.0, "0 at the faded low edge");
        assert!((fade_gain(12, 10, 20, 4, 0) - (FRAC_PI_2 * 0.5).sin()).abs() < 1e-6);
        assert_eq!(fade_gain(5, 10, 20, 0, 0), 0.0, "outside the range");
        let r = ZoneRanges::new((60, 72), (1, 80), (0, 6), (0, 20));
        assert!((r.gain(69, 70) - g * (FRAC_PI_2 * 0.5).sin()).abs() < 1e-6);
    }

    #[test]
    fn ranges_clamp_and_order() {
        let r = ZoneRanges::new((200, 64), (0, -5), (99, 2), (3, 3));
        assert_eq!((r.key_lo, r.key_hi), (64, 127));
        assert_eq!((r.vel_lo, r.vel_hi), (1, 1));
        assert_eq!(r.key_fade, (63, 2), "fades clamp to the range width");
        assert_eq!(r.vel_fade, (0, 0));
    }

    #[test]
    fn select_matches_key_and_velocity() {
        // REQ-016: A = C3–B3 @ 1–64, B = C3–B3 @ 65–127.
        let zones = [zone((60, 71), (1, 64), 0), zone((60, 71), (65, 127), 0)];
        let mut g = groups(1);
        assert_eq!(select(&zones, &mut g, 64, 40), vec![0]);
        assert_eq!(select(&zones, &mut g, 64, 100), vec![1]);
        assert!(select(&zones, &mut g, 40, 100).is_empty());
        let mut loading = zone((0, 127), (1, 127), 0);
        loading.playable = false;
        assert!(select(&[loading], &mut g, 60, 100).is_empty());
    }

    #[test]
    fn mute_and_solo_filter() {
        // Zone 0 Ungrouped, zones 1–2 in group 1 ("Soft"), all on every key.
        let zones = [
            zone((0, 127), (1, 127), 0),
            zone((0, 127), (1, 127), 1),
            zone((0, 127), (1, 127), 1),
        ];
        let mut g = groups(2);
        assert_eq!(select(&zones, &mut g, 60, 100), vec![0, 1, 2]);
        g[1].solo = true;
        assert_eq!(select(&zones, &mut g, 60, 100), vec![1, 2]);
        g[1].solo = false;
        g[1].mute = true;
        assert_eq!(select(&zones, &mut g, 60, 100), vec![0]);
        g[0].mute = true;
        assert!(select(&zones, &mut g, 60, 100).is_empty());
    }

    #[test]
    fn round_robin_cycles() {
        // Ungrouped zone 0 plays on every hit beside the round-robin group of three.
        let zones = [
            zone((0, 127), (1, 127), 0),
            zone((60, 60), (1, 127), 1),
            zone((60, 60), (1, 127), 1),
            zone((60, 60), (1, 127), 1),
        ];
        let mut g = groups(2);
        g[1].set(1.0, false, false, GroupPlayMode::RoundRobin);
        let hits: Vec<Vec<u16>> = (0..4).map(|_| select(&zones, &mut g, 60, 100)).collect();
        assert_eq!(hits, vec![vec![0, 1], vec![0, 2], vec![0, 3], vec![0, 1]]);
    }

    #[test]
    fn random_never_repeats_and_covers_all() {
        let zones = [
            zone((60, 60), (1, 127), 0),
            zone((60, 60), (1, 127), 0),
            zone((60, 60), (1, 127), 0),
        ];
        let mut g = groups(1);
        g[0].set(1.0, false, false, GroupPlayMode::Random);
        let mut out = Vec::with_capacity(MAX_ZONES);
        let mut rng = 0x9e37_79b9;
        let mut last = NO_ZONE;
        let mut hit = [0usize; 3];
        for _ in 0..100 {
            select_zones(&zones, &mut g, false, 60, 100, &mut rng, &mut out);
            assert_eq!(out.len(), 1);
            assert_ne!(out[0], last, "same zone twice in a row");
            last = out[0];
            hit[last as usize] += 1;
        }
        assert!(hit.iter().all(|&n| n > 0), "{hit:?}");
    }

    #[test]
    fn remap_follows_swap_remove() {
        let mut g = ZoneGroup::new(1);
        g.last_zone = 9;
        g.remap_zone(2, 9);
        assert_eq!(g.last_zone, 2);
        g.remap_zone(2, 9);
        assert_eq!(g.last_zone, NO_ZONE);
    }

    #[test]
    fn select_does_not_allocate() {
        let zones: Vec<TestZone> = (0..MAX_ZONES)
            .map(|i| zone(((i % 128) as i32, (i % 128) as i32), (1, 127), i % 3))
            .collect();
        let mut g = groups(3);
        g[1].set(1.0, false, false, GroupPlayMode::RoundRobin);
        g[2].set(1.0, false, false, GroupPlayMode::Random);
        let mut out = Vec::with_capacity(MAX_ZONES);
        let (ptr, cap) = (out.as_ptr(), out.capacity());
        let mut rng = 7;
        for n in 0..1000 {
            select_zones(
                &zones,
                &mut g,
                false,
                (n % 128) as u8,
                100,
                &mut rng,
                &mut out,
            );
            assert!(!out.is_empty());
        }
        let everything: Vec<TestZone> = (0..MAX_ZONES + 10)
            .map(|_| zone((0, 127), (1, 127), 0))
            .collect();
        select_zones(&everything, &mut g, false, 60, 100, &mut rng, &mut out);
        assert_eq!(out.len(), cap, "stops at capacity");
        assert_eq!((out.as_ptr(), out.capacity()), (ptr, cap));
    }

    #[test]
    fn settings_sanitize() {
        let s = ZoneSettings {
            root: 200,
            tune: f32::NAN,
            gain: 9.0,
            start: -1.0,
            loop_mode: 7,
            crossfade: 3.0,
            ..ZoneSettings::default()
        }
        .sanitized();
        assert_eq!(s.root, 127);
        assert_eq!(s.tune, 0.0);
        assert_eq!(s.gain, GAIN_LIMIT);
        assert_eq!(s.start, 0.0);
        assert_eq!(s.loop_mode, 2);
        assert_eq!(s.crossfade, 1.0);
    }

    #[test]
    fn velocity_maps_to_midi_steps() {
        assert_eq!(velocity_to_midi(0.0), 1);
        assert_eq!(velocity_to_midi(1.0), 127);
        assert_eq!(velocity_to_midi(64.0 / 127.0), 64);
    }
}

//! Mix analysis: per-bar (or per-beat) loudness, band energy, peak, crest and stereo metrics
//! for the master and chosen channels.
//!
//! The analyzer is fed the output of an offline render, one block at a time, and never runs
//! on the audio callback, so it allocates and has no locks or I/O. Digit scales live in
//! `scale.rs` and are applied by the Godot formatter; this file reports plain dB values.
//!
//! Taps are channel IDs (1 is the master). Frames are stereo interleaved `f32`.

mod filters;
pub mod scale;

use serde::{Deserialize, Serialize};

use self::filters::{BandBank, Frame, KWeight, PinkCalibration, BAND_COUNT, BAND_EDGES};
use self::scale::{FLOOR_DB, LUFS_OFFSET_DB, SCALE_VERSION};
use super::tempo_map::{fill_tick_rates, TempoMap};
use super::time_signature_map::TimeSignatureMap;
use super::types::ProjectSettings;

pub const BAND_NAMES: [&str; BAND_COUNT] = ["sub", "bass", "lowmid", "mid", "himid", "air"];

/// Ticks of slack when matching a frame to a bar. Ticks are summed frame by frame, so a frame
/// that lands exactly on a bar line can come out a hair below it.
const TICK_EPS: f64 = 1e-6;

/// Cap for the side/mid ratio of a signal with no mid.
const SIDE_MID_MAX: f32 = 1000.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Resolution {
    Bar,
    Beat,
}

pub struct AnalyzerConfig {
    pub sample_rate: f32,
    /// Tempo, ppq and base time signature (before the first map change).
    pub settings: ProjectSettings,
    pub tempo_map: TempoMap,
    pub time_signatures: TimeSignatureMap,
    pub resolution: Resolution,
    /// Frames are accumulated only while their tick is in `[range_start, range_end)`. Earlier
    /// frames still run through the filters, so pre-roll leaves them warm.
    pub range_start_tick: f64,
    pub range_end_tick: f64,
    /// Channel IDs to analyze, in the order `process_block` receives their buffers.
    pub taps: Vec<u32>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AnalysisHeader {
    pub scale_version: u32,
    pub sample_rate: f32,
    pub ppq: i32,
    pub resolution: Resolution,
    pub range_start_tick: f64,
    pub range_end_tick: f64,
    pub band_names: Vec<String>,
    /// `[low, high]` in Hz for each band.
    pub band_edges_hz: Vec<[f32; 2]>,
    pub taps: Vec<u32>,
}

/// Values for one tap over one bar or beat. Silence reads `FLOOR_DB`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TapMetrics {
    pub tap: u32,
    /// K-weighted loudness of the span (not gated), LUFS.
    pub lufs: f32,
    /// Band levels in dB, relative to a pink-noise tilt: pink noise reads the same in every
    /// band, and the same as its LUFS, so the digit scale applies to both.
    pub bands_db: [f32; BAND_COUNT],
    /// Sample peak, dBFS.
    pub peak_db: f32,
    /// True when a sample is above 0 dBFS.
    pub clipped: bool,
    /// Peak over RMS, dB (0 for silence).
    pub crest_db: f32,
    /// Left/right correlation, -1…1 (0 for silence).
    pub correlation: f32,
    /// Side energy over mid energy, linear. 0 is mono, 1 equal, above 1 mostly out of phase.
    pub side_mid: f32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BarAnalysis {
    /// 1-based bar number.
    pub bar: u32,
    /// 1-based beat within the bar at beat resolution, 0 at bar resolution.
    pub beat: u32,
    pub start_tick: f64,
    pub end_tick: f64,
    /// Frames accumulated. Less than the span's length when it is cut by the range.
    pub frames: u64,
    /// One entry per tap, in the header's order.
    pub taps: Vec<TapMetrics>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AnalysisResult {
    pub header: AnalysisHeader,
    pub bars: Vec<BarAnalysis>,
}

impl AnalysisResult {
    pub fn to_json(&self) -> serde_json::Result<String> {
        serde_json::to_string(self)
    }
}

/// Running sums for one tap in one span.
#[derive(Debug, Clone, Default)]
struct TapAcc {
    k_sq: f64,
    band_sq: [f64; BAND_COUNT],
    l_sq: f64,
    r_sq: f64,
    lr: f64,
    peak: f64,
}

impl TapAcc {
    #[inline]
    fn add(&mut self, x: Frame, k: Frame, bands: &[Frame; BAND_COUNT]) {
        self.k_sq += k[0] * k[0] + k[1] * k[1];
        for (sum, b) in self.band_sq.iter_mut().zip(bands) {
            *sum += b[0] * b[0] + b[1] * b[1];
        }
        self.l_sq += x[0] * x[0];
        self.r_sq += x[1] * x[1];
        self.lr += x[0] * x[1];
        self.peak = self.peak.max(x[0].abs()).max(x[1].abs());
    }

    fn finish(&self, tap: u32, frames: u64, pink: &PinkCalibration) -> TapMetrics {
        let n = frames.max(1) as f64;
        let db = |power: f64| -> f32 {
            if power > 1e-30 {
                ((10.0 * power.log10()) as f32).max(FLOOR_DB)
            } else {
                FLOOR_DB
            }
        };
        let mut bands_db = [FLOOR_DB; BAND_COUNT];
        for (i, out) in bands_db.iter_mut().enumerate() {
            let level = db(self.band_sq[i] / n / pink.band[i]);
            *out = if level > FLOOR_DB {
                level + LUFS_OFFSET_DB as f32
            } else {
                FLOOR_DB
            };
        }
        // Band levels also carry the K gain of pink, so pink's bands read as its LUFS.
        let k_pink_db = (10.0 * pink.k.log10()) as f32;
        for level in bands_db.iter_mut().filter(|l| **l > FLOOR_DB) {
            *level += k_pink_db;
        }
        let lufs = match db(self.k_sq / n) {
            l if l > FLOOR_DB => l + LUFS_OFFSET_DB as f32,
            _ => FLOOR_DB,
        };
        let peak_db = if self.peak > 1e-9 {
            ((20.0 * self.peak.log10()) as f32).max(FLOOR_DB)
        } else {
            FLOOR_DB
        };
        let rms_db = db((self.l_sq + self.r_sq) / (2.0 * n));
        let crest_db = if rms_db > FLOOR_DB {
            peak_db - rms_db
        } else {
            0.0
        };

        let energy = self.l_sq * self.r_sq;
        let correlation = if energy > 1e-30 {
            (self.lr / energy.sqrt()).clamp(-1.0, 1.0) as f32
        } else {
            0.0
        };
        let mid = (self.l_sq + self.r_sq + 2.0 * self.lr) / 4.0;
        let side = (self.l_sq + self.r_sq - 2.0 * self.lr) / 4.0;
        let side_mid = if mid > 1e-30 {
            ((side / mid) as f32).min(SIDE_MID_MAX)
        } else if side > 1e-30 {
            SIDE_MID_MAX
        } else {
            0.0
        };

        TapMetrics {
            tap,
            lufs,
            bands_db,
            peak_db,
            clipped: self.peak > 1.0,
            crest_db,
            correlation,
            side_mid,
        }
    }
}

struct Slot {
    bar: u32,
    beat: u32,
    start_tick: f64,
    end_tick: f64,
    frames: u64,
    taps: Vec<TapAcc>,
}

struct TapFilters {
    k: KWeight,
    bands: BandBank,
}

pub struct Analyzer {
    config: AnalyzerConfig,
    filters: Vec<TapFilters>,
    pink: PinkCalibration,
    slots: Vec<Slot>,
    /// End tick of the slot being filled, or `None` before the first frame in range.
    open_end: Option<f64>,
    next_tick: f64,
    rates: Vec<f64>,
    frame_slot: Vec<u32>,
}

const OUTSIDE: u32 = u32::MAX;

impl Analyzer {
    pub fn new(config: AnalyzerConfig) -> Self {
        let sr = config.sample_rate as f64;
        let filters = config
            .taps
            .iter()
            .map(|_| TapFilters {
                k: KWeight::new(sr),
                bands: BandBank::new(sr),
            })
            .collect();
        Self {
            next_tick: config.range_start_tick,
            config,
            filters,
            pink: PinkCalibration::new(sr),
            slots: Vec::new(),
            open_end: None,
            rates: Vec::new(),
            frame_slot: Vec::new(),
        }
    }

    /// The tick after the last frame of the previous block. A caller with no clock of its own
    /// passes this as the next block's `start_tick`.
    pub fn next_tick(&self) -> f64 {
        self.next_tick
    }

    /// Analyze `frames` frames. `taps` holds one stereo interleaved buffer per configured tap,
    /// in order, and `start_tick` is the tick of the block's first frame. Ticks inside the
    /// block follow the tempo map, the same way the render clock advances them.
    pub fn process_block(&mut self, start_tick: f64, frames: usize, taps: &[&[f32]]) {
        assert_eq!(taps.len(), self.filters.len(), "one buffer per tap");
        let frames = taps.iter().fold(frames, |n, t| n.min(t.len() / 2));

        fill_tick_rates(
            &self.config.tempo_map,
            &self.config.settings,
            start_tick,
            frames,
            self.config.sample_rate,
            &mut self.rates,
        );

        let mut pos = start_tick;
        self.frame_slot.clear();
        for i in 0..frames {
            let t = pos + TICK_EPS;
            let in_range = t >= self.config.range_start_tick && t < self.config.range_end_tick;
            let slot = if in_range {
                if self.open_end.map_or(true, |end| t >= end) {
                    self.open_slot(t);
                }
                let index = self.slots.len() - 1;
                self.slots[index].frames += 1;
                index as u32
            } else {
                OUTSIDE
            };
            self.frame_slot.push(slot);
            pos += self.rates[i];
        }
        self.next_tick = pos;

        for (ti, buf) in taps.iter().enumerate() {
            let filters = &mut self.filters[ti];
            for (i, &slot) in self.frame_slot.iter().enumerate() {
                let x = [buf[2 * i] as f64, buf[2 * i + 1] as f64];
                let k = filters.k.process(x);
                let bands = filters.bands.process(x);
                if slot != OUTSIDE {
                    self.slots[slot as usize].taps[ti].add(x, k, &bands);
                }
            }
        }
    }

    /// Start the bar (or beat) containing tick `t`.
    fn open_slot(&mut self, t: f64) {
        let s = &self.config.settings;
        let ppq = s.ppq as f64;
        let seg = self.config.time_signatures.segment_at(
            t,
            s.time_numerator.clamp(1, u16::MAX as i32) as u16,
            s.time_denominator.clamp(1, u16::MAX as i32) as u16,
            ppq,
        );
        let beat_ticks = ppq * 4.0 / seg.denominator as f64;
        let bar_end = seg.bar_start_tick + beat_ticks * seg.numerator as f64;
        let (beat, start, end) = match self.config.resolution {
            Resolution::Bar => (0, seg.bar_start_tick, bar_end),
            Resolution::Beat => {
                let index = (((t - seg.bar_start_tick) / beat_ticks).floor().max(0.0) as u32)
                    .min(seg.numerator as u32 - 1);
                let start = seg.bar_start_tick + index as f64 * beat_ticks;
                (index + 1, start, (start + beat_ticks).min(bar_end))
            }
        };
        self.slots.push(Slot {
            bar: seg.bar_index + 1,
            beat,
            start_tick: start,
            end_tick: end,
            frames: 0,
            taps: vec![TapAcc::default(); self.config.taps.len()],
        });
        self.open_end = Some(end);
    }

    pub fn finish(self) -> AnalysisResult {
        let c = &self.config;
        let header = AnalysisHeader {
            scale_version: SCALE_VERSION,
            sample_rate: c.sample_rate,
            ppq: c.settings.ppq,
            resolution: c.resolution,
            range_start_tick: c.range_start_tick,
            range_end_tick: c.range_end_tick,
            band_names: BAND_NAMES.iter().map(|n| n.to_string()).collect(),
            band_edges_hz: BAND_EDGES
                .iter()
                .map(|&(a, b)| [a as f32, b as f32])
                .collect(),
            taps: c.taps.clone(),
        };
        let bars = self
            .slots
            .iter()
            .map(|slot| BarAnalysis {
                bar: slot.bar,
                beat: slot.beat,
                start_tick: slot.start_tick,
                end_tick: slot.end_tick,
                frames: slot.frames,
                taps: slot
                    .taps
                    .iter()
                    .zip(&c.taps)
                    .map(|(acc, &tap)| acc.finish(tap, slot.frames, &self.pink))
                    .collect(),
            })
            .collect();
        AnalysisResult { header, bars }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::{pink_noise, sine, stereo};

    const SR: f32 = 48_000.0;

    fn config(taps: usize, resolution: Resolution, range: (f64, f64)) -> AnalyzerConfig {
        AnalyzerConfig {
            sample_rate: SR,
            settings: ProjectSettings::default(),
            tempo_map: TempoMap::default(),
            time_signatures: TimeSignatureMap::default(),
            resolution,
            range_start_tick: range.0,
            range_end_tick: range.1,
            taps: (1..=taps as u32).collect(),
        }
    }

    /// Run one stereo signal through in `block`-frame pieces, carrying the clock like the
    /// render loop does.
    fn run(config: AnalyzerConfig, signals: &[&[f32]], block: usize) -> AnalysisResult {
        let total = signals[0].len() / 2;
        let mut analyzer = Analyzer::new(config);
        let mut at = 0;
        while at < total {
            let n = block.min(total - at);
            let slices: Vec<&[f32]> = signals.iter().map(|s| &s[2 * at..2 * (at + n)]).collect();
            let start = analyzer.next_tick();
            analyzer.process_block(start, n, &slices);
            at += n;
        }
        analyzer.finish()
    }

    fn one_bar(signal: &[f32]) -> TapMetrics {
        let r = run(config(1, Resolution::Bar, (0.0, 3840.0)), &[signal], 512);
        assert_eq!(r.bars.len(), 1);
        r.bars[0].taps[0].clone()
    }

    fn bar_frames() -> usize {
        96_000 // 4/4 at 120 bpm, 48 kHz
    }

    #[test]
    fn reference_tone_reads_minus_23_lufs() {
        // A stereo sine at -23 dBFS peak in both channels is -23 LUFS (0 dBFS reads 0 LUFS).
        let amp = 10f32.powf(-23.0 / 20.0);
        let m = one_bar(&stereo(&sine(997.0, SR, bar_frames(), amp)));
        assert!((m.lufs + 23.0).abs() < 0.5, "got {} LUFS", m.lufs);
        assert!((m.peak_db + 23.0).abs() < 0.05);
        assert!((m.crest_db - 3.01).abs() < 0.05);
        assert!(!m.clipped);
    }

    #[test]
    fn k_weighting_follows_the_standard_at_other_rates() {
        for rate in [44_100.0f32, 96_000.0] {
            let frames = rate as usize * 2;
            let mut cfg = config(1, Resolution::Bar, (0.0, 3840.0));
            cfg.sample_rate = rate;
            let amp = 10f32.powf(-23.0 / 20.0);
            let sig = stereo(&sine(997.0, rate, frames, amp));
            let r = run(cfg, &[&sig], 480);
            let lufs = r.bars[0].taps[0].lufs;
            assert!((lufs + 23.0).abs() < 0.5, "{rate}: {lufs}");
        }
    }

    #[test]
    fn k_weighting_has_the_standard_shelf_and_high_pass() {
        // BS.1770 K gain: about +0.69 dB at 1 kHz, +4 dB high on the shelf, 38 Hz high-pass.
        let amp = 10f32.powf(-23.0 / 20.0);
        let lufs = |hz: f32| one_bar(&stereo(&sine(hz, SR, bar_frames(), amp))).lufs;
        assert!(
            (lufs(10_000.0) + 19.7).abs() < 0.3,
            "10 kHz: {}",
            lufs(10_000.0)
        );
        assert!(lufs(20.0) < -23.0 - 3.0, "20 Hz: {}", lufs(20.0));
    }

    #[test]
    fn band_tones_land_in_their_band() {
        // Tones at each band's geometric centre.
        for (band, &(lo, hi)) in BAND_EDGES.iter().enumerate() {
            let hz = ((lo * hi) as f32).sqrt();
            let m = one_bar(&stereo(&sine(hz, SR, bar_frames(), 0.1)));
            for (other, level) in m.bands_db.iter().enumerate() {
                if other != band {
                    // Neighbours are at least 15 dB down, the rest further.
                    let drop = m.bands_db[band] - level;
                    assert!(
                        drop > 15.0,
                        "{hz} Hz: band {other} only {drop} dB below {band}"
                    );
                }
            }
        }
    }

    #[test]
    fn one_khz_sine_is_mid_dominant() {
        let m = one_bar(&stereo(&sine(1000.0, SR, bar_frames(), 0.1)));
        let mid = m.bands_db[3];
        // 1 kHz is a third of an octave above lowmid's edge, so lowmid sees a little of it.
        assert!(mid - m.bands_db[2] > 6.0, "{:?}", m.bands_db);
        for band in [0, 1, 4, 5] {
            assert!(mid - m.bands_db[band] > 25.0, "{:?}", m.bands_db);
        }
    }

    #[test]
    fn pink_noise_reads_flat_across_the_bands() {
        let frames = SR as usize * 4;
        let mut cfg = config(1, Resolution::Bar, (0.0, 3840.0));
        cfg.range_end_tick = 1e9;
        // Four seconds is two bars; analyze the second so the filters have settled.
        cfg.range_start_tick = 3840.0;
        let noise = stereo(&pink_noise(frames, 0.3, 7));
        let r = run(cfg, &[&noise], 512);
        let bands = r.bars[0].taps[0].bands_db;
        let (lo, hi) = bands
            .iter()
            .fold((f32::MAX, f32::MIN), |(lo, hi), &b| (lo.min(b), hi.max(b)));
        assert!(hi - lo < 2.5, "spread {} dB: {bands:?}", hi - lo);
        // And the loudness sits with the bands to within a digit.
        let lufs = r.bars[0].taps[0].lufs;
        assert!((lufs - bands[3]).abs() < 1.5, "{lufs} vs {bands:?}");
    }

    #[test]
    fn silence_reads_the_floor() {
        let m = one_bar(&vec![0.0; bar_frames() * 2]);
        assert_eq!(m.lufs, FLOOR_DB);
        assert_eq!(m.peak_db, FLOOR_DB);
        assert_eq!(m.bands_db, [FLOOR_DB; BAND_COUNT]);
        assert_eq!((m.crest_db, m.correlation, m.side_mid), (0.0, 0.0, 0.0));
    }

    #[test]
    fn stereo_metrics() {
        let mono = sine(440.0, SR, bar_frames(), 0.5);
        let m = one_bar(&stereo(&mono));
        assert!((m.correlation - 1.0).abs() < 1e-4);
        assert!(m.side_mid < 1e-6);

        let inverted: Vec<f32> = mono.iter().flat_map(|&x| [x, -x]).collect();
        let m = one_bar(&inverted);
        assert!((m.correlation + 1.0).abs() < 1e-4);
        assert!(m.side_mid > 1000.0 - 1.0); // all side

        let left_only: Vec<f32> = mono.iter().flat_map(|&x| [x, 0.0]).collect();
        let m = one_bar(&left_only);
        assert!(m.correlation.abs() < 1e-4);
        assert!((m.side_mid - 1.0).abs() < 1e-3);
    }

    #[test]
    fn peak_and_clip_flag() {
        let mut signal = stereo(&sine(220.0, SR, bar_frames(), 0.5));
        assert!(!one_bar(&signal).clipped);
        signal[1000] = 1.2;
        let m = one_bar(&signal);
        assert!(m.clipped);
        assert!((m.peak_db - 20.0 * 1.2f32.log10()).abs() < 1e-3);
        signal[1000] = 1.0; // exactly full scale is not over
        assert!(!one_bar(&signal).clipped);
    }

    #[test]
    fn bar_boundaries_are_exact_at_constant_tempo() {
        let signal = stereo(&sine(440.0, SR, bar_frames() * 3, 0.1));
        let r = run(
            config(1, Resolution::Bar, (0.0, 3.0 * 3840.0)),
            &[&signal],
            777,
        );
        let frames: Vec<u64> = r.bars.iter().map(|b| b.frames).collect();
        assert_eq!(frames, vec![96_000; 3]);
        let bars: Vec<u32> = r.bars.iter().map(|b| b.bar).collect();
        assert_eq!(bars, vec![1, 2, 3]);
    }

    #[test]
    fn beats_split_the_bar() {
        let signal = stereo(&sine(440.0, SR, bar_frames(), 0.1));
        let r = run(config(1, Resolution::Beat, (0.0, 3840.0)), &[&signal], 512);
        let beats: Vec<(u32, u32, u64)> =
            r.bars.iter().map(|b| (b.bar, b.beat, b.frames)).collect();
        assert_eq!(
            beats,
            vec![
                (1, 1, 24_000),
                (1, 2, 24_000),
                (1, 3, 24_000),
                (1, 4, 24_000)
            ]
        );
    }

    /// Frame at which the render clock reaches `tick`, from the closed-form tempo integral.
    fn frame_at(map: &TempoMap, tick: f64) -> f64 {
        map.seconds_at(tick, 120.0, 960.0) * SR as f64
    }

    #[test]
    fn bar_boundaries_follow_tempo_and_time_signature_changes() {
        // 4/4, then 7/8 from bar 3, then 3/4 from bar 5, with a tempo ramp across the lot.
        let tempo = TempoMap::from_points(vec![(0, 120.0), (9600, 90.0), (14400, 150.0)]);
        let sigs = TimeSignatureMap::from_changes(vec![(3, 7, 8), (5, 3, 4)]);
        // Bars: 3840, 3840, 3360, 3360, 2880, 2880 ticks.
        let bar_ticks = [3840.0, 3840.0, 3360.0, 3360.0, 2880.0, 2880.0];
        let total: f64 = bar_ticks.iter().sum();
        let mut starts = vec![0.0];
        for len in bar_ticks {
            starts.push(starts.last().unwrap() + len);
        }

        let frames = frame_at(&tempo, total).ceil() as usize + 1000;
        let signal = stereo(&sine(300.0, SR, frames, 0.1));
        let mut cfg = config(1, Resolution::Bar, (0.0, total));
        cfg.tempo_map = tempo.clone();
        cfg.time_signatures = sigs;
        let r = run(cfg, &[&signal], 480);

        assert_eq!(r.bars.len(), 6);
        let mut at = 0u64;
        for (i, bar) in r.bars.iter().enumerate() {
            assert_eq!(bar.bar, i as u32 + 1);
            assert_eq!(bar.start_tick, starts[i]);
            assert_eq!(bar.end_tick, starts[i + 1]);
            at += bar.frames;
            // The clock steps tempo once per frame, so allow a frame or two against the
            // closed form.
            let expected = frame_at(&tempo, starts[i + 1]);
            assert!(
                (at as f64 - expected).abs() <= 2.0,
                "bar {} ends at frame {at}, expected {expected}",
                i + 1
            );
        }
    }

    #[test]
    fn only_the_range_is_reported() {
        // Four bars of signal, range is bars 2–3. The first bar is pre-roll.
        let signal = stereo(&sine(440.0, SR, bar_frames() * 4, 0.1));
        let r = run(
            config(1, Resolution::Bar, (3840.0, 3.0 * 3840.0)),
            &[&signal],
            512,
        );
        let bars: Vec<u32> = r.bars.iter().map(|b| b.bar).collect();
        assert_eq!(bars, vec![2, 3]);
        assert!(r.bars.iter().all(|b| b.frames == 96_000));
        assert_eq!(r.header.range_start_tick, 3840.0);
    }

    #[test]
    fn a_range_starting_mid_bar_reports_a_partial_bar() {
        let signal = stereo(&sine(440.0, SR, bar_frames() * 2, 0.1));
        let r = run(
            config(1, Resolution::Bar, (1920.0, 7680.0)),
            &[&signal],
            512,
        );
        assert_eq!(r.bars.len(), 2);
        assert_eq!(r.bars[0].frames, 48_000);
        assert_eq!(r.bars[0].start_tick, 0.0);
        assert_eq!(r.bars[1].frames, 96_000);
    }

    #[test]
    fn pre_roll_warms_the_filters() {
        // A tone that only just started would read low in a cold bar; with pre-roll the first
        // reported bar matches the steady state.
        let signal = stereo(&sine(60.0, SR, bar_frames() * 3, 0.3));
        let warm = run(
            config(1, Resolution::Bar, (3840.0, 7680.0)),
            &[&signal],
            512,
        );
        let steady = run(
            config(1, Resolution::Bar, (7680.0, 11520.0)),
            &[&signal],
            512,
        );
        let (a, b) = (&warm.bars[0].taps[0], &steady.bars[0].taps[0]);
        assert!((a.lufs - b.lufs).abs() < 0.01);
        assert!((a.bands_db[1] - b.bands_db[1]).abs() < 0.01);
    }

    #[test]
    fn block_size_does_not_change_the_result() {
        let tempo = TempoMap::from_points(vec![(0, 120.0), (5000, 80.0)]);
        let sigs = TimeSignatureMap::from_changes(vec![(2, 3, 4)]);
        let frames = SR as usize * 6;
        let a = stereo(&pink_noise(frames, 0.3, 3));
        let b = stereo(&sine(220.0, SR, frames, 0.2));
        let make = || {
            let mut cfg = config(2, Resolution::Beat, (960.0, 9000.0));
            cfg.tempo_map = tempo.clone();
            cfg.time_signatures = sigs.clone();
            cfg
        };
        let reference = run(make(), &[&a, &b], frames);
        for block in [1, 64, 333, 512, 4096] {
            let split = run(make(), &[&a, &b], block);
            assert_eq!(split, reference, "block size {block}");
        }
        assert!(reference.bars.len() > 4);
        assert_eq!(reference.header.taps, vec![1, 2]);
    }

    #[test]
    fn taps_are_analyzed_independently() {
        let low = stereo(&sine(80.0, SR, bar_frames(), 0.3));
        let high = stereo(&sine(9000.0, SR, bar_frames(), 0.3));
        let r = run(
            config(2, Resolution::Bar, (0.0, 3840.0)),
            &[&low, &high],
            512,
        );
        let (low, high) = (&r.bars[0].taps[0], &r.bars[0].taps[1]);
        let loudest = |m: &TapMetrics| {
            m.bands_db
                .iter()
                .enumerate()
                .max_by(|a, b| a.1.total_cmp(b.1))
                .unwrap()
                .0
        };
        assert_eq!(loudest(low), 1);
        assert_eq!(loudest(high), 5);
    }

    #[test]
    fn result_round_trips_through_json() {
        let signal = stereo(&sine(440.0, SR, bar_frames(), 0.1));
        let r = run(config(1, Resolution::Bar, (0.0, 3840.0)), &[&signal], 512);
        let parsed: AnalysisResult = serde_json::from_str(&r.to_json().unwrap()).unwrap();
        assert_eq!(parsed, r);
        assert_eq!(parsed.header.scale_version, SCALE_VERSION);
        assert_eq!(parsed.header.band_names.len(), BAND_COUNT);
    }
}

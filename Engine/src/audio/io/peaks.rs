//! Streaming peak builder for waveform display.
//!
//! Peaks are computed in source-sample space (the file's own rate, before resampling). Each
//! block stores min, max, mean square and the mean squares of three display bands (low, mid,
//! high). Level 0 uses `BASE_BLOCK` frames per block; each further level merges two blocks of
//! the level below, so the levels nest exactly.

/// Frames per block at level 0. Blocks are aligned to frame 0 of the file.
pub const BASE_BLOCK: u32 = 64;
/// Stop adding levels once a level's block size would exceed this.
pub const MAX_BLOCK_SIZE: u64 = 1 << 20;

const LOW_CUTOFF_HZ: f64 = 200.0;
const HIGH_CUTOFF_HZ: f64 = 2000.0;

/// One block of one channel: `[min, max, mean_square, low_ms, mid_ms, high_ms]`.
pub type Block = [f32; 6];

/// 2nd-order RBJ biquad, transposed direct form II. Display-only, so no phase care.
#[derive(Clone, Copy, Default)]
struct Biquad {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    z1: f64,
    z2: f64,
}

impl Biquad {
    fn new(sample_rate: u32, cutoff: f64, highpass: bool) -> Self {
        let sr = sample_rate.max(1) as f64;
        let f = cutoff.min(sr * 0.45);
        let w0 = 2.0 * std::f64::consts::PI * f / sr;
        let (sin, cos) = w0.sin_cos();
        let alpha = sin / (2.0 * std::f64::consts::FRAC_1_SQRT_2);
        let a0 = 1.0 + alpha;
        let (b0, b1, b2) = if highpass {
            ((1.0 + cos) / 2.0, -(1.0 + cos), (1.0 + cos) / 2.0)
        } else {
            ((1.0 - cos) / 2.0, 1.0 - cos, (1.0 - cos) / 2.0)
        };
        Self {
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: -2.0 * cos / a0,
            a2: (1.0 - alpha) / a0,
            z1: 0.0,
            z2: 0.0,
        }
    }

    #[inline]
    fn process(&mut self, x: f64) -> f64 {
        let y = self.b0 * x + self.z1;
        self.z1 = self.b1 * x - self.a1 * y + self.z2;
        self.z2 = self.b2 * x - self.a2 * y;
        y
    }
}

/// Running state for the current block of one channel.
#[derive(Clone, Copy)]
struct ChannelAcc {
    low: Biquad,
    high: Biquad,
    /// Mid band = high-pass at the low cutoff into low-pass at the high cutoff. `x - low - high`
    /// would leak badly into mid because of the filters' phase shift.
    mid_hp: Biquad,
    mid_lp: Biquad,
    min: f32,
    max: f32,
    sum_sq: f64,
    low_sq: f64,
    mid_sq: f64,
    high_sq: f64,
}

impl ChannelAcc {
    fn new(sample_rate: u32) -> Self {
        let mut acc = Self {
            low: Biquad::new(sample_rate, LOW_CUTOFF_HZ, false),
            high: Biquad::new(sample_rate, HIGH_CUTOFF_HZ, true),
            mid_hp: Biquad::new(sample_rate, LOW_CUTOFF_HZ, true),
            mid_lp: Biquad::new(sample_rate, HIGH_CUTOFF_HZ, false),
            min: 0.0,
            max: 0.0,
            sum_sq: 0.0,
            low_sq: 0.0,
            mid_sq: 0.0,
            high_sq: 0.0,
        };
        acc.reset_block();
        acc
    }

    fn reset_block(&mut self) {
        self.min = f32::INFINITY;
        self.max = f32::NEG_INFINITY;
        self.sum_sq = 0.0;
        self.low_sq = 0.0;
        self.mid_sq = 0.0;
        self.high_sq = 0.0;
    }

    #[inline]
    fn push(&mut self, x: f32) {
        self.min = self.min.min(x);
        self.max = self.max.max(x);
        let xd = x as f64;
        let low = self.low.process(xd);
        let high = self.high.process(xd);
        let mid = self.mid_lp.process(self.mid_hp.process(xd));
        self.sum_sq += xd * xd;
        self.low_sq += low * low;
        self.mid_sq += mid * mid;
        self.high_sq += high * high;
    }

    fn take_block(&mut self, len: u32) -> Block {
        let n = len.max(1) as f64;
        let block = [
            self.min,
            self.max,
            (self.sum_sq / n) as f32,
            (self.low_sq / n) as f32,
            (self.mid_sq / n) as f32,
            (self.high_sq / n) as f32,
        ];
        self.reset_block();
        block
    }
}

/// One resolution level: `blocks[channel][block]`.
#[derive(Debug, Clone)]
pub struct PeakLevel {
    pub block_size: u64,
    pub blocks: Vec<Vec<Block>>,
}

impl PeakLevel {
    pub fn num_blocks(&self) -> u64 {
        self.blocks.first().map(|b| b.len() as u64).unwrap_or(0)
    }
}

/// Finished peak data for a whole file.
#[derive(Debug, Clone)]
pub struct Peaks {
    pub channels: u16,
    pub source_sample_rate: u32,
    pub frames: u64,
    pub base_block: u32,
    pub levels: Vec<PeakLevel>,
}

/// Streaming builder, fed native-rate planar chunks one at a time.
pub struct PeakBuilder {
    channels: u16,
    sample_rate: u32,
    frames: u64,
    acc: Vec<ChannelAcc>,
    block_fill: u32,
    base: Vec<Vec<Block>>,
}

impl PeakBuilder {
    pub fn new(channels: u16, sample_rate: u32) -> Self {
        Self {
            channels,
            sample_rate,
            frames: 0,
            acc: vec![ChannelAcc::new(sample_rate); channels as usize],
            block_fill: 0,
            base: vec![Vec::new(); channels as usize],
        }
    }

    pub fn frames(&self) -> u64 {
        self.frames
    }

    /// Feed one planar chunk. Missing channels are treated as silence.
    pub fn push(&mut self, chunk: &[Vec<f32>]) {
        let len = chunk.first().map(|c| c.len()).unwrap_or(0);
        let mut i = 0;
        while i < len {
            let take = ((BASE_BLOCK - self.block_fill) as usize).min(len - i);
            for (ch, acc) in self.acc.iter_mut().enumerate() {
                match chunk.get(ch) {
                    Some(samples) => {
                        for &x in &samples[i..(i + take).min(samples.len())] {
                            acc.push(x);
                        }
                    }
                    None => {
                        for _ in 0..take {
                            acc.push(0.0);
                        }
                    }
                }
            }
            i += take;
            self.block_fill += take as u32;
            if self.block_fill == BASE_BLOCK {
                self.flush_block();
            }
        }
        self.frames += len as u64;
    }

    fn flush_block(&mut self) {
        let len = self.block_fill;
        for (acc, out) in self.acc.iter_mut().zip(self.base.iter_mut()) {
            out.push(acc.take_block(len));
        }
        self.block_fill = 0;
    }

    /// Close the partial last block and build levels 1..N.
    pub fn finish(mut self) -> Peaks {
        if self.block_fill > 0 {
            self.flush_block();
        }
        let frames = self.frames;
        let mut levels = vec![PeakLevel {
            block_size: BASE_BLOCK as u64,
            blocks: self.base,
        }];
        loop {
            let prev = levels.last().unwrap();
            let next_size = prev.block_size * 2;
            if prev.num_blocks() <= 1 || next_size > MAX_BLOCK_SIZE {
                break;
            }
            let next = merge_level(prev, frames);
            levels.push(next);
        }
        Peaks {
            channels: self.channels,
            source_sample_rate: self.sample_rate,
            frames,
            base_block: BASE_BLOCK,
            levels,
        }
    }
}

/// Real frame count of block `b` in a level of `block_size` over `frames` total frames.
fn block_len(b: u64, block_size: u64, frames: u64) -> u64 {
    frames.saturating_sub(b * block_size).min(block_size)
}

fn merge_level(prev: &PeakLevel, frames: u64) -> PeakLevel {
    let n = prev.num_blocks();
    let blocks = prev
        .blocks
        .iter()
        .map(|src| {
            (0..n.div_ceil(2))
                .map(|j| {
                    let a = src[(2 * j) as usize];
                    let Some(&b) = src.get((2 * j + 1) as usize) else {
                        return a;
                    };
                    let la = block_len(2 * j, prev.block_size, frames) as f64;
                    let lb = block_len(2 * j + 1, prev.block_size, frames) as f64;
                    let w = la + lb;
                    let avg = |i: usize| ((a[i] as f64 * la + b[i] as f64 * lb) / w) as f32;
                    [
                        a[0].min(b[0]),
                        a[1].max(b[1]),
                        avg(2),
                        avg(3),
                        avg(4),
                        avg(5),
                    ]
                })
                .collect()
        })
        .collect();
    PeakLevel {
        block_size: prev.block_size * 2,
        blocks,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn build(channels: Vec<Vec<f32>>, sr: u32) -> Peaks {
        let mut b = PeakBuilder::new(channels.len() as u16, sr);
        // Feed in odd-sized chunks to exercise block boundaries.
        let len = channels[0].len();
        let mut i = 0;
        while i < len {
            let end = (i + 1000).min(len);
            let chunk: Vec<Vec<f32>> = channels.iter().map(|c| c[i..end].to_vec()).collect();
            b.push(&chunk);
            i = end;
        }
        b.finish()
    }

    #[test]
    fn impulse_survives_every_level() {
        let mut s = vec![0.0f32; 100_000];
        s[54_321] = 0.9;
        s[77_777] = -0.8;
        let p = build(vec![s], 48000);
        assert!(p.levels.len() > 5);
        for level in &p.levels {
            let max = level.blocks[0]
                .iter()
                .map(|b| b[1])
                .fold(f32::MIN, f32::max);
            let min = level.blocks[0]
                .iter()
                .map(|b| b[0])
                .fold(f32::MAX, f32::min);
            assert_eq!(max, 0.9, "level block {}", level.block_size);
            assert_eq!(min, -0.8, "level block {}", level.block_size);
        }
    }

    #[test]
    fn partial_last_block() {
        let s = vec![0.5f32; 64 * 3 + 10];
        let p = build(vec![s], 44100);
        let base = &p.levels[0].blocks[0];
        assert_eq!(base.len(), 4);
        // The 10-frame tail is averaged over its real length.
        assert!((base[3][2] - 0.25).abs() < 1e-6);
        assert_eq!(base[3][1], 0.5);
        // Merged level weights the tail by frame count.
        let l1 = &p.levels[1].blocks[0];
        assert_eq!(l1.len(), 2);
        assert!((l1[1][2] - 0.25).abs() < 1e-6);
    }

    #[test]
    fn rms_of_constant_signal() {
        let p = build(vec![vec![-0.3f32; 10_000]], 44100);
        for level in &p.levels {
            for b in &level.blocks[0] {
                assert!((b[2].sqrt() - 0.3).abs() < 1e-5);
            }
        }
    }

    fn band_energy(freq: f32) -> [f32; 3] {
        let sr = 48000;
        let s: Vec<f32> = (0..sr)
            .map(|i| (2.0 * std::f32::consts::PI * freq * i as f32 / sr as f32).sin())
            .collect();
        let p = build(vec![s], sr);
        let top = p.levels.last().unwrap();
        let b = top.blocks[0][0];
        [b[3], b[4], b[5]]
    }

    #[test]
    fn sine_lands_in_expected_band() {
        let [low, mid, high] = band_energy(100.0);
        assert!(low > 4.0 * mid && low > 4.0 * high, "{low} {mid} {high}");
        let [low, mid, high] = band_energy(5000.0);
        assert!(high > 4.0 * mid && high > 4.0 * low, "{low} {mid} {high}");
    }

    #[test]
    fn level_sizes_nest() {
        let p = build(
            vec![vec![0.1f32; 1_234_567], vec![0.2f32; 1_234_567]],
            44100,
        );
        assert_eq!(p.levels[0].num_blocks(), 1_234_567u64.div_ceil(64));
        for w in p.levels.windows(2) {
            assert_eq!(w[1].num_blocks(), w[0].num_blocks().div_ceil(2));
            assert_eq!(w[1].block_size, w[0].block_size * 2);
        }
        let top = p.levels.last().unwrap();
        assert!(top.num_blocks() <= 1 || top.block_size * 2 > MAX_BLOCK_SIZE);
        // A short file stops at a single block.
        let p = build(vec![vec![0.1f32; 10_000]], 44100);
        assert_eq!(p.levels.last().unwrap().num_blocks(), 1);
    }
}

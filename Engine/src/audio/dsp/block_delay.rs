//! A stereo whole-block delay: write a block, then read it back `delay` samples late.
//!
//! - Sized once in [`StereoBlockDelay::prepare`] (command thread); the rest never allocates.
//! - Per block: `write` the input, then `add_delayed` / `read_delayed` any number of times.
//!   Output frame `i` is the input from `delay` samples before frame `i`, so `delay = 0` is the
//!   block just written. Reads reach back into earlier blocks, so `delay` may exceed the block.

use super::delay_line::DelayLine;

#[derive(Clone, Debug, Default)]
pub struct StereoBlockDelay {
    left: DelayLine,
    right: DelayLine,
}

impl StereoBlockDelay {
    /// An empty delay; call `prepare` before use.
    pub fn new() -> Self {
        Self::default()
    }

    /// Allocate for delays up to `max_delay` samples and blocks up to `max_block` frames, and
    /// clear. Command thread only.
    pub fn prepare(&mut self, max_delay: usize, max_block: usize) {
        self.left.prepare(max_delay + max_block);
        self.right.prepare(max_delay + max_block);
    }

    pub fn clear(&mut self) {
        self.left.clear();
        self.right.clear();
    }

    /// Longest delay a read can use for a block of `frames`, in samples.
    pub fn max_delay(&self, frames: usize) -> usize {
        (self.left.max_delay() as usize).saturating_sub(frames)
    }

    /// Append one block. Call once per block, before reading it back.
    #[inline]
    pub fn write(&mut self, left: &[f32], right: &[f32], frames: usize) {
        for i in 0..frames {
            self.left.push(left[i]);
            self.right.push(right[i]);
        }
    }

    /// Frame `i` of the block just written reads this many pushes back.
    #[inline]
    fn ago(frames: usize, i: usize, delay: usize) -> usize {
        frames - i + delay
    }

    /// Add `gain` times the delayed block to `out_l` / `out_r`. Delays beyond the prepared
    /// maximum clamp to it.
    #[inline]
    pub fn add_delayed(
        &self,
        delay: usize,
        gain: f32,
        frames: usize,
        out_l: &mut [f32],
        out_r: &mut [f32],
    ) {
        for i in 0..frames {
            let ago = Self::ago(frames, i, delay);
            out_l[i] += gain * self.left.read(ago);
            out_r[i] += gain * self.right.read(ago);
        }
    }

    /// Frame `i` of the delayed block, as (left, right). For readers that can't hand over
    /// slices, such as the interleaved hardware write.
    #[inline]
    pub fn sample(&self, delay: usize, frames: usize, i: usize) -> (f32, f32) {
        let ago = Self::ago(frames, i, delay);
        (self.left.read(ago), self.right.read(ago))
    }

    /// Append one interleaved stereo block.
    #[inline]
    pub fn write_interleaved(&mut self, buf: &[f32], frames: usize) {
        for frame in buf.chunks_exact(2).take(frames) {
            self.left.push(frame[0]);
            self.right.push(frame[1]);
        }
    }

    /// Overwrite an interleaved stereo block with the delayed block.
    #[inline]
    pub fn read_interleaved(&self, delay: usize, frames: usize, out: &mut [f32]) {
        for (i, frame) in out.chunks_exact_mut(2).take(frames).enumerate() {
            let ago = Self::ago(frames, i, delay);
            frame[0] = self.left.read(ago);
            frame[1] = self.right.read(ago);
        }
    }

    /// Overwrite `out_l` / `out_r` with the delayed block.
    #[inline]
    pub fn read_delayed(&self, delay: usize, frames: usize, out_l: &mut [f32], out_r: &mut [f32]) {
        for i in 0..frames {
            let ago = Self::ago(frames, i, delay);
            out_l[i] = self.left.read(ago);
            out_r[i] = self.right.read(ago);
        }
    }
}

/// One parallel branch's alignment delay (spec 042 part D): a container delays its faster
/// branches (and its disabled dry path) so they line up with the slowest one. At 0 it does
/// nothing and owns no memory.
#[derive(Clone, Debug, Default)]
pub struct AlignDelay {
    frames: usize,
    line: StereoBlockDelay,
}

impl AlignDelay {
    /// Command thread, from `update_latency`: set the delay. A change allocates and clears the
    /// history; the same value keeps it running.
    pub fn set(&mut self, frames: usize, max_block: usize) {
        if frames == self.frames {
            return;
        }
        self.frames = frames;
        self.line = StereoBlockDelay::new();
        if frames > 0 {
            self.line.prepare(frames, max_block);
        }
    }

    pub fn frames(&self) -> usize {
        self.frames
    }

    /// Delay an interleaved stereo block in place.
    #[inline]
    pub fn apply(&mut self, buf: &mut [f32], frames: usize) {
        if self.frames > 0 {
            self.line.write_interleaved(buf, frames);
            self.line.read_interleaved(self.frames, frames, buf);
        }
    }

    /// Feed an interleaved block without reading it back, to keep the history current for a
    /// path that may switch to reading it later (a container's dry path while it's enabled).
    #[inline]
    pub fn write(&mut self, buf: &[f32], frames: usize) {
        if self.frames > 0 {
            self.line.write_interleaved(buf, frames);
        }
    }

    /// Write `input` and read it back delayed into `out`. At 0 this is a plain copy.
    #[inline]
    pub fn process(&mut self, input: &[f32], out: &mut [f32], frames: usize) {
        if self.frames > 0 {
            self.line.write_interleaved(input, frames);
            self.line.read_interleaved(self.frames, frames, out);
        } else {
            let n = (frames * 2).min(input.len()).min(out.len());
            out[..n].copy_from_slice(&input[..n]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Stream `blocks` of `frames` through the delay and check every output sample against the
    /// input `delay` samples earlier (zero before the start).
    fn check(delay: usize, frames: usize, blocks: usize) {
        let mut line = StereoBlockDelay::new();
        line.prepare(delay, frames);
        let sample = |n: usize| (n + 1) as f32;
        let mut n = 0;
        for _ in 0..blocks {
            let l: Vec<f32> = (n..n + frames).map(sample).collect();
            let r: Vec<f32> = l.iter().map(|x| -x).collect();
            line.write(&l, &r, frames);

            let (mut out_l, mut out_r) = (vec![0.0; frames], vec![0.0; frames]);
            line.read_delayed(delay, frames, &mut out_l, &mut out_r);
            for i in 0..frames {
                let want = if n + i >= delay {
                    sample(n + i - delay)
                } else {
                    0.0
                };
                assert_eq!(out_l[i], want, "delay {delay} left frame {}", n + i);
                assert_eq!(out_r[i], -want, "delay {delay} right frame {}", n + i);
            }

            // add_delayed accumulates onto what is there, scaled by the gain.
            let (mut sum_l, mut sum_r) = (vec![1.0; frames], vec![1.0; frames]);
            line.add_delayed(delay, 0.5, frames, &mut sum_l, &mut sum_r);
            for i in 0..frames {
                assert_eq!(sum_l[i], 1.0 + 0.5 * out_l[i]);
                assert_eq!(sum_r[i], 1.0 + 0.5 * out_r[i]);
            }
            n += frames;
        }
    }

    #[test]
    fn align_delay_delays_interleaved_blocks() {
        let mut align = AlignDelay::default();
        align.set(3, 4);
        let mut out = Vec::new();
        for block in 0..3 {
            let mut buf: Vec<f32> = (0..4)
                .flat_map(|i| {
                    let n = (block * 4 + i + 1) as f32;
                    [n, -n]
                })
                .collect();
            align.apply(&mut buf, 4);
            out.extend(buf);
        }
        let left: Vec<f32> = out.iter().step_by(2).copied().collect();
        let want: Vec<f32> = (0..12)
            .map(|n| if n < 3 { 0.0 } else { (n - 2) as f32 })
            .collect();
        assert_eq!(left, want);
        assert!(out.chunks(2).all(|f| f[1] == -f[0]));
    }

    #[test]
    fn block_delay_reads_back_exact() {
        check(0, 64, 4); // the block just written
        check(1, 64, 4);
        check(10, 64, 4); // shorter than the block
        check(64, 64, 4); // exactly one block
        check(100, 64, 6); // longer than the block, across block boundaries
        check(1000, 64, 40); // many blocks back
        check(37, 1, 100); // single-frame blocks
    }

    #[test]
    fn block_delay_clamps_beyond_its_maximum() {
        let mut line = StereoBlockDelay::new();
        line.prepare(10, 8);
        assert!(line.max_delay(8) >= 10);
        let block = [1.0f32; 8];
        line.write(&block, &block, 8);
        let (mut l, mut r) = ([0.0; 8], [0.0; 8]);
        line.read_delayed(1_000_000, 8, &mut l, &mut r);
    }
}

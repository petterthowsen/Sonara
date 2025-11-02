use once_cell::sync::Lazy;

const SINE_TABLE_SIZE: usize = 65536; // 64k samples for high quality

/// Sine lookup table for fast sine generation
static SINE_TABLE: Lazy<Vec<f32>> = Lazy::new(|| {
    let mut table = Vec::with_capacity(SINE_TABLE_SIZE);
    for i in 0..SINE_TABLE_SIZE {
        let phase = (i as f32 / SINE_TABLE_SIZE as f32) * 2.0 * std::f32::consts::PI;
        table.push(phase.sin());
    }
    table
});

#[inline]
fn fast_sin(phase: f64) -> f32 {
    let idx = ((phase.fract() * SINE_TABLE_SIZE as f64) as usize) % SINE_TABLE_SIZE;
    SINE_TABLE[idx]
}

/// Waveform types supported by the oscillator
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Waveform {
    Sine = 0,
    Square = 1,
    Saw = 2,
    Triangle = 3,
}

impl From<u8> for Waveform {
    fn from(value: u8) -> Self {
        match value {
            0 => Waveform::Sine,
            1 => Waveform::Square,
            2 => Waveform::Saw,
            3 => Waveform::Triangle,
            _ => Waveform::Sine,
        }
    }
}

/// High-performance oscillator using phase accumulator
///
/// Features:
/// - Sine wave uses lookup table for ~10x performance
/// - Branchless phase wrapping
/// - Multiple waveforms: sine, square, saw, triangle
pub struct Oscillator {
    pub phase: f64,
    pub phase_increment: f64,
}

impl Oscillator {
    pub fn new() -> Self {
        Self {
            phase: 0.0,
            phase_increment: 0.0,
        }
    }

    /// Set the oscillator frequency in Hz
    pub fn set_frequency(&mut self, frequency: f64, sample_rate: f64) {
        self.phase_increment = frequency / sample_rate;
    }

    /// Reset the oscillator phase to 0
    pub fn reset(&mut self) {
        self.phase = 0.0;
    }

    /// Process a block of samples with the given waveform
    pub fn process_block(&mut self, waveform: u8, output: &mut [f32], frames: usize) {
        match waveform {
            0 => self.process_sine(output, frames),
            1 => self.process_square(output, frames),
            2 => self.process_saw(output, frames),
            3 => self.process_triangle(output, frames),
            _ => self.process_sine(output, frames),
        }
    }

    fn process_sine(&mut self, output: &mut [f32], frames: usize) {
        for i in 0..frames {
            output[i] = fast_sin(self.phase);
            self.phase += self.phase_increment;
            // Fast wrapping using branchless cast (no branch!)
            self.phase -= (self.phase >= 1.0) as i32 as f64;
        }
    }

    fn process_square(&mut self, output: &mut [f32], frames: usize) {
        for i in 0..frames {
            output[i] = if self.phase < 0.5 { 1.0 } else { -1.0 };
            self.phase += self.phase_increment;
            self.phase -= (self.phase >= 1.0) as i32 as f64;
        }
    }

    fn process_saw(&mut self, output: &mut [f32], frames: usize) {
        for i in 0..frames {
            output[i] = (self.phase * 2.0 - 1.0) as f32;
            self.phase += self.phase_increment;
            self.phase -= (self.phase >= 1.0) as i32 as f64;
        }
    }

    fn process_triangle(&mut self, output: &mut [f32], frames: usize) {
        for i in 0..frames {
            output[i] = if self.phase < 0.5 {
                (self.phase * 4.0 - 1.0) as f32
            } else {
                (3.0 - self.phase * 4.0) as f32
            };
            self.phase += self.phase_increment;
            self.phase -= (self.phase >= 1.0) as i32 as f64;
        }
    }
}

impl Default for Oscillator {
    fn default() -> Self {
        Self::new()
    }
}

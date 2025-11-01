use super::{
    AudioDevice, DeviceCategory, DeviceVariant, MidiPort, ParamId, ParamInfo, ParamValue, PortFlow,
};
use fundsp::hacker32::*;
use std::sync::atomic::{AtomicI8, AtomicU8, Ordering};

const MAX_VOICES: usize = 16;
const VOICE_SILENCE_THRESHOLD: f32 = 0.001;

/// Voice state for polyphonic synthesis
struct Voice {
    /// MIDI note number
    midi_note: u8,
    /// Note velocity (0.0-1.0)
    velocity: f32,
    /// Frequency in Hz
    frequency: f32,
    /// Voice active flag
    is_active: bool,
    /// Time when note was triggered (for voice stealing)
    note_on_time: u64,
    /// Trigger signal for ADSR (1.0 = note on, 0.0 = note off)
    trigger: Shared,
    /// FunDSP graph for this voice (stored as AudioUnit for flexibility)
    dsp_graph: Option<Box<dyn AudioUnit>>,
    /// Sample counter for silence detection
    silent_samples: usize,
}

impl Voice {
    fn new() -> Self {
        Self {
            midi_note: 0,
            velocity: 0.0,
            frequency: 440.0,
            is_active: false,
            note_on_time: 0,
            trigger: shared(0.0),
            dsp_graph: None,
            silent_samples: 0,
        }
    }

    /// Build a simple 2-oscillator graph (no unison) - much more CPU efficient
    #[allow(clippy::too_many_arguments)]
    fn build_simple_graph(
        &mut self,
        sample_rate: f32,
        waveform_a: u8,
        waveform_b: u8,
        freq_a: f32,
        freq_b: f32,
        attack_shared: &Shared,
        decay_shared: &Shared,
        sustain_shared: &Shared,
        release_shared: &Shared,
        master_volume_shared: &Shared,
        osc_a_level_shared: &Shared,
        osc_b_level_shared: &Shared,
    ) {
        // Reconstruct the nodes
        let envelope = var(&self.trigger) >> adsr_live(
            attack_shared.value(),
            decay_shared.value(),
            sustain_shared.value(),
            release_shared.value(),
        );
        let volume_smooth = var(master_volume_shared) >> follow(0.01);
        let osc_a_level = var(osc_a_level_shared) >> follow(0.01);
        let osc_b_level = var(osc_b_level_shared) >> follow(0.01);
        // Helper macro to create single oscillator
        macro_rules! make_osc {
            (0, $freq:expr) => { sine_hz($freq) };
            (1, $freq:expr) => { square_hz($freq) };
            (2, $freq:expr) => { saw_hz($freq) };
            (3, $freq:expr) => { triangle_hz($freq) };
        }
        
        // Build simple 2-oscillator graph - just 16 combinations (4x4 waveforms)
        let graph: Box<dyn AudioUnit> = match (waveform_a, waveform_b) {
            (0, 0) => {
                let mut g = (make_osc!(0, freq_a) * osc_a_level + make_osc!(0, freq_b) * osc_b_level)
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (0, 1) => {
                let mut g = (make_osc!(0, freq_a) * osc_a_level + make_osc!(1, freq_b) * osc_b_level)
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (0, 2) => {
                let mut g = (make_osc!(0, freq_a) * osc_a_level + make_osc!(2, freq_b) * osc_b_level)
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (0, 3) => {
                let mut g = (make_osc!(0, freq_a) * osc_a_level + make_osc!(3, freq_b) * osc_b_level)
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (1, 0) => {
                let mut g = (make_osc!(1, freq_a) * osc_a_level + make_osc!(0, freq_b) * osc_b_level)
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (1, 1) => {
                let mut g = (make_osc!(1, freq_a) * osc_a_level + make_osc!(1, freq_b) * osc_b_level)
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (1, 2) => {
                let mut g = (make_osc!(1, freq_a) * osc_a_level + make_osc!(2, freq_b) * osc_b_level)
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (1, 3) => {
                let mut g = (make_osc!(1, freq_a) * osc_a_level + make_osc!(3, freq_b) * osc_b_level)
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (2, 0) => {
                let mut g = (make_osc!(2, freq_a) * osc_a_level + make_osc!(0, freq_b) * osc_b_level)
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (2, 1) => {
                let mut g = (make_osc!(2, freq_a) * osc_a_level + make_osc!(1, freq_b) * osc_b_level)
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (2, 2) => {
                let mut g = (make_osc!(2, freq_a) * osc_a_level + make_osc!(2, freq_b) * osc_b_level)
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (2, 3) => {
                let mut g = (make_osc!(2, freq_a) * osc_a_level + make_osc!(3, freq_b) * osc_b_level)
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (3, 0) => {
                let mut g = (make_osc!(3, freq_a) * osc_a_level + make_osc!(0, freq_b) * osc_b_level)
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (3, 1) => {
                let mut g = (make_osc!(3, freq_a) * osc_a_level + make_osc!(1, freq_b) * osc_b_level)
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (3, 2) => {
                let mut g = (make_osc!(3, freq_a) * osc_a_level + make_osc!(2, freq_b) * osc_b_level)
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (3, 3) => {
                let mut g = (make_osc!(3, freq_a) * osc_a_level + make_osc!(3, freq_b) * osc_b_level)
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            _ => {
                // Default to sine + sine
                let mut g = (make_osc!(0, freq_a) * osc_a_level + make_osc!(0, freq_b) * osc_b_level)
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
        };
        
        self.dsp_graph = Some(graph);
    }


    /// Build the DSP graph for this voice with dual oscillators and unison
    /// Uses Shared vars for smooth parameter changes without rebuilding
    #[allow(clippy::too_many_arguments)]
    fn build_graph(
        &mut self,
        sample_rate: f32,
        waveform_a: u8,
        waveform_b: u8,
        osc_a_octave: i8,
        osc_b_octave: i8,
        osc_a_unison_voices: u8,
        osc_b_unison_voices: u8,
        attack_shared: &Shared,
        decay_shared: &Shared,
        sustain_shared: &Shared,
        release_shared: &Shared,
        master_volume_shared: &Shared,
        osc_a_level_shared: &Shared,
        osc_b_level_shared: &Shared,
        osc_a_unison_detune_shared: &Shared,
        osc_b_unison_detune_shared: &Shared,
        osc_b_detune_shared: &Shared,
    ) {
        // Use shared vars with follow() smoothing for smooth parameter changes
        // ADSR envelope uses constants at build time (envelope shape per voice stays constant)
        // but volume and levels use shared vars for real-time smooth changes
        let envelope = var(&self.trigger) >> adsr_live(
            attack_shared.value(),
            decay_shared.value(),
            sustain_shared.value(),
            release_shared.value(),
        );
        
        // Master volume with smoothing (10ms response time for smooth changes)
        let volume_smooth = var(master_volume_shared) >> follow(0.01);
        
        // Oscillator levels with smoothing
        let osc_a_level_smooth = var(osc_a_level_shared) >> follow(0.01);
        let osc_b_level_smooth = var(osc_b_level_shared) >> follow(0.01);
        
        // Calculate base frequencies with octave shifting
        let freq_a = self.frequency * 2.0_f32.powi(osc_a_octave as i32);
        
        // Oscillator B has both octave shift and independent detune
        let detune_cents = osc_b_detune_shared.value();
        let detune_multiplier = 2.0_f32.powf(detune_cents / 1200.0);
        let freq_b = self.frequency * 2.0_f32.powi(osc_b_octave as i32) * detune_multiplier;
        
        // Optimization: Use simple 2-oscillator graph when unison is disabled (vastly more efficient)
        if osc_a_unison_voices == 1 && osc_b_unison_voices == 1 {
            self.build_simple_graph(
                sample_rate,
                waveform_a,
                waveform_b,
                freq_a,
                freq_b,
                attack_shared,
                decay_shared,
                sustain_shared,
                release_shared,
                master_volume_shared,
                osc_a_level_shared,
                osc_b_level_shared,
            );
            return;
        }
        
        // Get unison detune amounts
        let unison_detune_a = osc_a_unison_detune_shared.value(); // 0-100 cents
        let unison_detune_b = osc_b_unison_detune_shared.value(); // 0-100 cents

        // Always build 6 oscillators per slot (max unison), but weight unused voices with 0
        // This avoids FunDSP's type system issues with dynamic voice counts
        const MAX_UNISON: usize = 6;
        
        // Helper to calculate 6 frequencies and weights for unison
        let calc_unison = |base_freq: f32, num_voices: u8, detune_cents: f32| -> ([f32; MAX_UNISON], [f32; MAX_UNISON]) {
            let num = std::cmp::max(std::cmp::min(num_voices, MAX_UNISON as u8), 1) as usize;
            let mut freqs = [base_freq; MAX_UNISON];
            let mut weights = [0.0; MAX_UNISON];
            let norm = 1.0 / num as f32;
            
            for i in 0..num {
                let offset = if num == 1 {
                    0.0
                } else {
                    // Map i from 0..num to -detune_cents..+detune_cents
                    let t = i as f32 / (num - 1) as f32; // 0.0 to 1.0
                    (t * 2.0 - 1.0) * detune_cents // -detune_cents to +detune_cents
                };
                let freq_mult = 2.0_f32.powf(offset / 1200.0);
                freqs[i] = base_freq * freq_mult;
                weights[i] = norm;
            }
            
            (freqs, weights)
        };
        
        let (freqs_a, weights_a) = calc_unison(freq_a, osc_a_unison_voices, unison_detune_a);
        let (freqs_b, weights_b) = calc_unison(freq_b, osc_b_unison_voices, unison_detune_b);
        
        // Helper macros to build unison stacks with exactly 6 voices (to avoid type system issues)
        // Unused voices have weight 0
        macro_rules! build_sine_unison {
            ($freqs:expr, $weights:expr) => {
                sine_hz($freqs[0]) * dc($weights[0])
                + sine_hz($freqs[1]) * dc($weights[1])
                + sine_hz($freqs[2]) * dc($weights[2])
                + sine_hz($freqs[3]) * dc($weights[3])
                + sine_hz($freqs[4]) * dc($weights[4])
                + sine_hz($freqs[5]) * dc($weights[5])
            };
        }
        
        macro_rules! build_square_unison {
            ($freqs:expr, $weights:expr) => {
                square_hz($freqs[0]) * dc($weights[0])
                + square_hz($freqs[1]) * dc($weights[1])
                + square_hz($freqs[2]) * dc($weights[2])
                + square_hz($freqs[3]) * dc($weights[3])
                + square_hz($freqs[4]) * dc($weights[4])
                + square_hz($freqs[5]) * dc($weights[5])
            };
        }
        
        macro_rules! build_saw_unison {
            ($freqs:expr, $weights:expr) => {
                saw_hz($freqs[0]) * dc($weights[0])
                + saw_hz($freqs[1]) * dc($weights[1])
                + saw_hz($freqs[2]) * dc($weights[2])
                + saw_hz($freqs[3]) * dc($weights[3])
                + saw_hz($freqs[4]) * dc($weights[4])
                + saw_hz($freqs[5]) * dc($weights[5])
            };
        }
        
        macro_rules! build_triangle_unison {
            ($freqs:expr, $weights:expr) => {
                triangle_hz($freqs[0]) * dc($weights[0])
                + triangle_hz($freqs[1]) * dc($weights[1])
                + triangle_hz($freqs[2]) * dc($weights[2])
                + triangle_hz($freqs[3]) * dc($weights[3])
                + triangle_hz($freqs[4]) * dc($weights[4])
                + triangle_hz($freqs[5]) * dc($weights[5])
            };
        }
        
        // Build complete graph with both oscillators' unison stacks
        // Match on all 16 waveform combinations (4 x 4)
        let graph: Box<dyn AudioUnit> = match (waveform_a, waveform_b) {
            (0, 0) => {
                let mut g = (build_sine_unison!(freqs_a, weights_a) * osc_a_level_smooth 
                    + build_sine_unison!(freqs_b, weights_b) * osc_b_level_smooth) 
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (0, 1) => {
                let mut g = (build_sine_unison!(freqs_a, weights_a) * osc_a_level_smooth 
                    + build_square_unison!(freqs_b, weights_b) * osc_b_level_smooth) 
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (0, 2) => {
                let mut g = (build_sine_unison!(freqs_a, weights_a) * osc_a_level_smooth 
                    + build_saw_unison!(freqs_b, weights_b) * osc_b_level_smooth) 
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (0, 3) => {
                let mut g = (build_sine_unison!(freqs_a, weights_a) * osc_a_level_smooth 
                    + build_triangle_unison!(freqs_b, weights_b) * osc_b_level_smooth) 
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (1, 0) => {
                let mut g = (build_square_unison!(freqs_a, weights_a) * osc_a_level_smooth 
                    + build_sine_unison!(freqs_b, weights_b) * osc_b_level_smooth) 
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (1, 1) => {
                let mut g = (build_square_unison!(freqs_a, weights_a) * osc_a_level_smooth 
                    + build_square_unison!(freqs_b, weights_b) * osc_b_level_smooth) 
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (1, 2) => {
                let mut g = (build_square_unison!(freqs_a, weights_a) * osc_a_level_smooth 
                    + build_saw_unison!(freqs_b, weights_b) * osc_b_level_smooth) 
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (1, 3) => {
                let mut g = (build_square_unison!(freqs_a, weights_a) * osc_a_level_smooth 
                    + build_triangle_unison!(freqs_b, weights_b) * osc_b_level_smooth) 
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (2, 0) => {
                let mut g = (build_saw_unison!(freqs_a, weights_a) * osc_a_level_smooth 
                    + build_sine_unison!(freqs_b, weights_b) * osc_b_level_smooth) 
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (2, 1) => {
                let mut g = (build_saw_unison!(freqs_a, weights_a) * osc_a_level_smooth 
                    + build_square_unison!(freqs_b, weights_b) * osc_b_level_smooth) 
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (2, 2) => {
                let mut g = (build_saw_unison!(freqs_a, weights_a) * osc_a_level_smooth 
                    + build_saw_unison!(freqs_b, weights_b) * osc_b_level_smooth) 
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (2, 3) => {
                let mut g = (build_saw_unison!(freqs_a, weights_a) * osc_a_level_smooth 
                    + build_triangle_unison!(freqs_b, weights_b) * osc_b_level_smooth) 
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (3, 0) => {
                let mut g = (build_triangle_unison!(freqs_a, weights_a) * osc_a_level_smooth 
                    + build_sine_unison!(freqs_b, weights_b) * osc_b_level_smooth) 
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (3, 1) => {
                let mut g = (build_triangle_unison!(freqs_a, weights_a) * osc_a_level_smooth 
                    + build_square_unison!(freqs_b, weights_b) * osc_b_level_smooth) 
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (3, 2) => {
                let mut g = (build_triangle_unison!(freqs_a, weights_a) * osc_a_level_smooth 
                    + build_saw_unison!(freqs_b, weights_b) * osc_b_level_smooth) 
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            (3, 3) => {
                let mut g = (build_triangle_unison!(freqs_a, weights_a) * osc_a_level_smooth 
                    + build_triangle_unison!(freqs_b, weights_b) * osc_b_level_smooth) 
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            _ => {
                // Default to sine + sine
                let mut g = (build_sine_unison!(freqs_a, weights_a) * osc_a_level_smooth 
                    + build_sine_unison!(freqs_b, weights_b) * osc_b_level_smooth) 
                    * envelope * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
        };

        self.dsp_graph = Some(graph);
    }

    /// Trigger note on
    fn note_on(&mut self, note: u8, velocity: u8, time: u64) {
        self.midi_note = note;
        self.velocity = velocity as f32 / 127.0;
        self.frequency = midi_note_to_hz(note);
        self.is_active = true;
        self.note_on_time = time;
        self.trigger.set_value(1.0);
        self.silent_samples = 0;
    }

    /// Trigger note off
    fn note_off(&mut self) {
        self.trigger.set_value(0.0);
        // Don't set is_active = false yet, let the release phase complete
    }

    /// Reset voice to default state
    fn reset(&mut self) {
        self.is_active = false;
        self.trigger.set_value(0.0);
        self.velocity = 0.0;
        self.silent_samples = 0;
        if let Some(ref mut graph) = self.dsp_graph {
            graph.reset();
        }
    }
}

/// Polyphonic synthesizer device powered by FunDSP
///
/// Features:
/// - Polyphonic voice management (up to 16 voices)
/// - Dual oscillators with independent waveforms and levels
/// - Per-oscillator octave shifting (-2 to +2 octaves)
/// - Per-oscillator unison (1-6 voices with detune spread)
/// - Oscillator B independent detune (-100 to +100 cents)
/// - Multiple waveforms (sine, square, saw, triangle)
/// - ADSR amplitude envelope
/// - Master volume control
/// - Voice stealing when voices are exhausted
pub struct PolySynthDevice {
    sample_rate: f32,
    voices: Vec<Voice>,
    time_counter: u64,

    // Oscillator waveform parameters (using atomics for topology changes)
    waveform_a: AtomicU8,
    waveform_b: AtomicU8,
    
    // Oscillator octave parameters (using atomics for topology changes)
    osc_a_octave: AtomicI8,
    osc_b_octave: AtomicI8,
    
    // Unison voice count parameters (using atomics for topology changes)
    osc_a_unison_voices: AtomicU8,
    osc_b_unison_voices: AtomicU8,
    
    // Envelope parameters (using Shared for smooth changes)
    attack: Shared,
    decay: Shared,
    sustain: Shared,
    release: Shared,
    
    // Level parameters (using Shared for smooth changes)
    osc_a_level: Shared,
    osc_b_level: Shared,
    master_volume: Shared,
    
    // Detune parameters (using Shared for smooth changes)
    osc_a_unison_detune: Shared,  // 0-100 cents spread for unison
    osc_b_unison_detune: Shared,  // 0-100 cents spread for unison
    osc_b_detune: Shared,          // -100 to +100 cents independent detune

    // Parameter change tracking
    params_dirty: bool,

    // Lifecycle state
    is_active: bool,
    is_enabled: bool,

    // Queued MIDI for frame-accurate scheduling within next block
    queued_midi: Vec<(usize, u8, u8, bool)>,
}

impl PolySynthDevice {
    pub fn new(sample_rate: f32) -> Self {
        Self {
            sample_rate,
            voices: (0..MAX_VOICES).map(|_| Voice::new()).collect(),
            time_counter: 0,
            waveform_a: AtomicU8::new(0),       // Sine
            waveform_b: AtomicU8::new(2),       // Saw
            osc_a_octave: AtomicI8::new(0),     // 0 octaves (center)
            osc_b_octave: AtomicI8::new(0),     // 0 octaves (center)
            osc_a_unison_voices: AtomicU8::new(1), // Single voice
            osc_b_unison_voices: AtomicU8::new(1), // Single voice
            attack: shared(0.01),
            decay: shared(0.1),
            sustain: shared(0.7),
            release: shared(0.3),
            osc_a_level: shared(0.7),           // 70% level
            osc_b_level: shared(0.3),           // 30% level
            master_volume: shared(0.3),
            osc_a_unison_detune: shared(10.0),  // 10 cents spread
            osc_b_unison_detune: shared(10.0),  // 10 cents spread
            osc_b_detune: shared(0.0),          // No detune by default
            params_dirty: true,
            is_active: true,
            is_enabled: true,
            queued_midi: Vec::with_capacity(128),
        }
    }

    /// Find a free voice, or None if all voices are in use
    fn find_free_voice(&self) -> Option<usize> {
        self.voices.iter().position(|v| !v.is_active)
    }

    /// Find the voice playing a specific MIDI note
    fn find_voice_for_note(&self, note: u8) -> Option<usize> {
        self.voices
            .iter()
            .position(|v| v.is_active && v.midi_note == note && v.trigger.value() > 0.0)
    }

    /// Steal the oldest voice (voice with earliest note_on_time)
    fn steal_voice(&self) -> Option<usize> {
        self.voices
            .iter()
            .enumerate()
            .filter(|(_, v)| v.is_active)
            .min_by_key(|(_, v)| v.note_on_time)
            .map(|(idx, _)| idx)
    }

    /// Rebuild DSP graphs only for topology changes (waveform, octave, unison voices)
    /// Smooth parameters (ADSR, volume, levels, detune) use Shared vars and don't need rebuilds
    fn rebuild_graphs_if_needed(&mut self) {
        if !self.params_dirty {
            return;
        }

        let waveform_a = self.waveform_a.load(Ordering::Relaxed);
        let waveform_b = self.waveform_b.load(Ordering::Relaxed);
        let osc_a_octave = self.osc_a_octave.load(Ordering::Relaxed);
        let osc_b_octave = self.osc_b_octave.load(Ordering::Relaxed);
        let osc_a_unison_voices = self.osc_a_unison_voices.load(Ordering::Relaxed);
        let osc_b_unison_voices = self.osc_b_unison_voices.load(Ordering::Relaxed);

        // Only rebuild voices that are inactive (will get new topology on next note-on)
        // Active voices keep their current topology until released
        // This prevents retrigger artifacts during playback
        for voice in self.voices.iter_mut() {
            if !voice.is_active || voice.dsp_graph.is_none() {
                voice.build_graph(
                    self.sample_rate,
                    waveform_a,
                    waveform_b,
                    osc_a_octave,
                    osc_b_octave,
                    osc_a_unison_voices,
                    osc_b_unison_voices,
                    &self.attack,
                    &self.decay,
                    &self.sustain,
                    &self.release,
                    &self.master_volume,
                    &self.osc_a_level,
                    &self.osc_b_level,
                    &self.osc_a_unison_detune,
                    &self.osc_b_unison_detune,
                    &self.osc_b_detune,
                );
            }
        }

        self.params_dirty = false;
    }
}

impl AudioDevice for PolySynthDevice {
    fn process_block(&mut self, _inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        // Handle inactive state
        if !self.is_active {
            for sample in outputs.iter_mut() {
                *sample = 0.0;
            }
            return;
        }

        // Handle disabled state (bypassed)
        if !self.is_enabled {
            for sample in outputs.iter_mut() {
                *sample = 0.0;
            }
            return;
        }

        // Rebuild graphs if parameters changed
        self.rebuild_graphs_if_needed();

        // Clear output buffer
        outputs[..sample_count * 2].fill(0.0);

        // Sort queued MIDI by offset
        let mut events = core::mem::take(&mut self.queued_midi);
        events.sort_unstable_by_key(|e| e.0);
        let mut next_event_idx = 0usize;

        // Render sample-by-sample to honor event offsets
        for i in 0..sample_count {
            // Apply all events scheduled for this sample index
            while next_event_idx < events.len() && events[next_event_idx].0 == i {
                let (_ofs, note, velocity, is_on) = events[next_event_idx];
                next_event_idx += 1;

                if is_on && velocity > 0 {
                    if let Some(idx) = self.find_voice_for_note(note) {
                        self.voices[idx].note_on(note, velocity, self.time_counter);
                        self.voices[idx].build_graph(
                            self.sample_rate,
                            self.waveform_a.load(Ordering::Relaxed),
                            self.waveform_b.load(Ordering::Relaxed),
                            self.osc_a_octave.load(Ordering::Relaxed),
                            self.osc_b_octave.load(Ordering::Relaxed),
                            self.osc_a_unison_voices.load(Ordering::Relaxed),
                            self.osc_b_unison_voices.load(Ordering::Relaxed),
                            &self.attack,
                            &self.decay,
                            &self.sustain,
                            &self.release,
                            &self.master_volume,
                            &self.osc_a_level,
                            &self.osc_b_level,
                            &self.osc_a_unison_detune,
                            &self.osc_b_unison_detune,
                            &self.osc_b_detune,
                        );
                    } else if let Some(idx) = self.find_free_voice().or_else(|| self.steal_voice())
                    {
                        self.voices[idx].note_on(note, velocity, self.time_counter);
                        self.voices[idx].build_graph(
                            self.sample_rate,
                            self.waveform_a.load(Ordering::Relaxed),
                            self.waveform_b.load(Ordering::Relaxed),
                            self.osc_a_octave.load(Ordering::Relaxed),
                            self.osc_b_octave.load(Ordering::Relaxed),
                            self.osc_a_unison_voices.load(Ordering::Relaxed),
                            self.osc_b_unison_voices.load(Ordering::Relaxed),
                            &self.attack,
                            &self.decay,
                            &self.sustain,
                            &self.release,
                            &self.master_volume,
                            &self.osc_a_level,
                            &self.osc_b_level,
                            &self.osc_a_unison_detune,
                            &self.osc_b_unison_detune,
                            &self.osc_b_detune,
                        );
                    }
                } else {
                    if let Some(idx) = self.find_voice_for_note(note) {
                        self.voices[idx].note_off();
                    }
                }
            }

            // Sum all active voices for this sample
            let mut sample_sum = 0.0f32;
            for voice in self.voices.iter_mut() {
                if !voice.is_active {
                    continue;
                }
                if let Some(ref mut graph) = voice.dsp_graph {
                    let s = graph.get_mono();
                    if s.abs() < VOICE_SILENCE_THRESHOLD {
                        voice.silent_samples += 1;
                        if voice.silent_samples > 1000 && voice.trigger.value() <= 0.0 {
                            voice.reset();
                            continue;
                        }
                    } else {
                        voice.silent_samples = 0;
                    }
                    sample_sum += s;
                }
            }

            let idx = i * 2;
            if idx < outputs.len() {
                outputs[idx] += sample_sum;
            }
            if idx + 1 < outputs.len() {
                outputs[idx + 1] += sample_sum;
            }
        }

        // Clear any leftover queued events
        self.queued_midi.clear();

        // Increment time counter for voice stealing priority
        self.time_counter = self.time_counter.wrapping_add(1);
    }

    fn send_midi_event(&mut self, note: u8, velocity: u8, is_note_on: bool, frame_offset: usize) {
        // Queue for next block
        self.queued_midi.push((
            std::cmp::min(frame_offset, usize::MAX),
            note,
            velocity,
            is_note_on,
        ));
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        match param_id {
            0 => {
                // Waveform A (0-1.0 mapped to 0-3)
                let waveform = std::cmp::min(((value * 3.99) as u8), 3);
                self.waveform_a.store(waveform, Ordering::Relaxed);
                self.params_dirty = true; // Topology change requires rebuild
            }
            1 => {
                // Attack (0.001-2.0s) - smooth parameter, no rebuild needed
                let attack = 0.001 + value * 1.999;
                self.attack.set_value(attack);
            }
            2 => {
                // Decay (0.001-2.0s) - smooth parameter, no rebuild needed
                let decay = 0.001 + value * 1.999;
                self.decay.set_value(decay);
            }
            3 => {
                // Sustain (0.0-1.0) - smooth parameter, no rebuild needed
                self.sustain.set_value(value);
            }
            4 => {
                // Release (0.001-3.0s) - smooth parameter, no rebuild needed
                let release = 0.001 + value * 2.999;
                self.release.set_value(release);
            }
            5 => {
                // Master Volume (0.0-1.0) - smooth parameter, no rebuild needed
                self.master_volume.set_value(value);
            }
            6 => {
                // Oscillator A Level (0.0-1.0) - smooth parameter, no rebuild needed
                self.osc_a_level.set_value(value);
            }
            7 => {
                // Waveform B (0-1.0 mapped to 0-3)
                let waveform = std::cmp::min(((value * 3.99) as u8), 3);
                self.waveform_b.store(waveform, Ordering::Relaxed);
                self.params_dirty = true; // Topology change requires rebuild
            }
            8 => {
                // Oscillator B Level (0.0-1.0) - smooth parameter, no rebuild needed
                self.osc_b_level.set_value(value);
            }
            9 => {
                // Oscillator B Detune (0.0-1.0 mapped to -100 to +100 cents)
                let detune = (value - 0.5) * 200.0; // 0.0 → -100, 0.5 → 0, 1.0 → +100
                self.osc_b_detune.set_value(detune);
            }
            10 => {
                // Osc A Octave (0.0-1.0 mapped to -2 to +2 octaves)
                let octave = ((value * 4.99) as i8) - 2; // 0.0 → -2, 0.5 → 0, 1.0 → +2
                self.osc_a_octave.store(octave, Ordering::Relaxed);
                self.params_dirty = true; // Topology change requires rebuild
            }
            11 => {
                // Osc B Octave (0.0-1.0 mapped to -2 to +2 octaves)
                let octave = ((value * 4.99) as i8) - 2; // 0.0 → -2, 0.5 → 0, 1.0 → +2
                self.osc_b_octave.store(octave, Ordering::Relaxed);
                self.params_dirty = true; // Topology change requires rebuild
            }
            12 => {
                // Osc A Unison Voices (0.0-1.0 mapped to 1-6 voices)
                let voices = 1 + std::cmp::min((value * 5.99) as u8, 5); // 1-6
                self.osc_a_unison_voices.store(voices, Ordering::Relaxed);
                self.params_dirty = true; // Topology change requires rebuild
            }
            13 => {
                // Osc B Unison Voices (0.0-1.0 mapped to 1-6 voices)
                let voices = 1 + std::cmp::min((value * 5.99) as u8, 5); // 1-6
                self.osc_b_unison_voices.store(voices, Ordering::Relaxed);
                self.params_dirty = true; // Topology change requires rebuild
            }
            14 => {
                // Osc A Unison Detune (0.0-1.0 mapped to 0-100 cents)
                let detune = value * 100.0;
                self.osc_a_unison_detune.set_value(detune);
            }
            15 => {
                // Osc B Unison Detune (0.0-1.0 mapped to 0-100 cents)
                let detune = value * 100.0;
                self.osc_b_unison_detune.set_value(detune);
            }
            _ => {}
        }
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        match param_id {
            0 => Some((self.waveform_a.load(Ordering::Relaxed) as f32) / 4.0),
            1 => Some((self.attack.value() - 0.001) / 1.999),
            2 => Some((self.decay.value() - 0.001) / 1.999),
            3 => Some(self.sustain.value()),
            4 => Some((self.release.value() - 0.001) / 2.999),
            5 => Some(self.master_volume.value()),
            6 => Some(self.osc_a_level.value()),
            7 => Some((self.waveform_b.load(Ordering::Relaxed) as f32) / 4.0),
            8 => Some(self.osc_b_level.value()),
            9 => Some((self.osc_b_detune.value() + 100.0) / 200.0), // -100→0.0, 0→0.5, +100→1.0
            10 => Some(((self.osc_a_octave.load(Ordering::Relaxed) + 2) as f32) / 4.0), // -2→0.0, 0→0.5, +2→1.0
            11 => Some(((self.osc_b_octave.load(Ordering::Relaxed) + 2) as f32) / 4.0), // -2→0.0, 0→0.5, +2→1.0
            12 => Some(((self.osc_a_unison_voices.load(Ordering::Relaxed) - 1) as f32) / 5.0), // 1→0.0, 6→1.0
            13 => Some(((self.osc_b_unison_voices.load(Ordering::Relaxed) - 1) as f32) / 5.0), // 1→0.0, 6→1.0
            14 => Some(self.osc_a_unison_detune.value() / 100.0), // 0-100 cents → 0.0-1.0
            15 => Some(self.osc_b_unison_detune.value() / 100.0), // 0-100 cents → 0.0-1.0
            _ => None,
        }
    }

    fn device_id(&self) -> &str {
        "sonara.builtin.polysynth"
    }

    fn device_name(&self) -> &str {
        "PolySynth"
    }

    fn device_category(&self) -> DeviceCategory {
        DeviceCategory::Instrument
    }

    fn device_variant(&self) -> DeviceVariant {
        DeviceVariant::BuiltIn
    }

    fn midi_ports(&self) -> Vec<MidiPort> {
        vec![MidiPort {
            id: 0,
            name: "MIDI In".to_string(),
            flow: PortFlow::Input,
        }]
    }

    fn parameters(&self) -> Vec<ParamInfo> {
        vec![
            ParamInfo {
                id: 0,
                name: "Waveform A".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 0.0, // Sine
                is_automation_safe: true,
                param_type: super::ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: 1,
                name: "Attack".to_string(),
                unit: "s".to_string(),
                min: 0.0,
                max: 1.0,
                default: 0.005,
                is_automation_safe: true,
                param_type: super::ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: 2,
                name: "Decay".to_string(),
                unit: "s".to_string(),
                min: 0.0,
                max: 1.0,
                default: 0.05,
                is_automation_safe: true,
                param_type: super::ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: 3,
                name: "Sustain".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 0.7,
                is_automation_safe: true,
                param_type: super::ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: 4,
                name: "Release".to_string(),
                unit: "s".to_string(),
                min: 0.0,
                max: 1.0,
                default: 0.1,
                is_automation_safe: true,
                param_type: super::ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: 5,
                name: "Master Volume".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 0.3,
                is_automation_safe: true,
                param_type: super::ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: 6,
                name: "Osc A Level".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 0.7,
                is_automation_safe: true,
                param_type: super::ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: 7,
                name: "Waveform B".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 0.5, // Saw (2/4 = 0.5)
                is_automation_safe: true,
                param_type: super::ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: 8,
                name: "Osc B Level".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 0.3,
                is_automation_safe: true,
                param_type: super::ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: 9,
                name: "Osc B Detune".to_string(),
                unit: "cents".to_string(),
                min: 0.0,
                max: 1.0,
                default: 0.5, // 0 cents (center)
                is_automation_safe: true,
                param_type: super::ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: 10,
                name: "Osc A Octave".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 0.5, // 0 octaves (center)
                is_automation_safe: true,
                param_type: super::ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: 11,
                name: "Osc B Octave".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 0.5, // 0 octaves (center)
                is_automation_safe: true,
                param_type: super::ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: 12,
                name: "Osc A Unison".to_string(),
                unit: "voices".to_string(),
                min: 0.0,
                max: 1.0,
                default: 0.0, // 1 voice
                is_automation_safe: true,
                param_type: super::ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: 13,
                name: "Osc B Unison".to_string(),
                unit: "voices".to_string(),
                min: 0.0,
                max: 1.0,
                default: 0.0, // 1 voice
                is_automation_safe: true,
                param_type: super::ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: 14,
                name: "Osc A Uni Detune".to_string(),
                unit: "cents".to_string(),
                min: 0.0,
                max: 1.0,
                default: 0.1, // 10 cents
                is_automation_safe: true,
                param_type: super::ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: 15,
                name: "Osc B Uni Detune".to_string(),
                unit: "cents".to_string(),
                min: 0.0,
                max: 1.0,
                default: 0.1, // 10 cents
                is_automation_safe: true,
                param_type: super::ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
        ]
    }

    fn reset(&mut self) {
        for voice in self.voices.iter_mut() {
            voice.reset();
        }
        self.time_counter = 0;
    }

    fn is_active(&self) -> bool {
        self.is_active
    }

    fn activate(&mut self) -> Result<(), String> {
        self.is_active = true;
        self.params_dirty = true;
        Ok(())
    }

    fn deactivate(&mut self) -> Result<(), String> {
        self.is_active = false;
        self.reset();
        Ok(())
    }

    fn is_enabled(&self) -> bool {
        self.is_enabled
    }

    fn set_enabled(&mut self, enabled: bool) {
        self.is_enabled = enabled;
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

/// Convert MIDI note number to frequency in Hz
fn midi_note_to_hz(note: u8) -> f32 {
    440.0 * 2.0_f32.powf((note as f32 - 69.0) / 12.0)
}

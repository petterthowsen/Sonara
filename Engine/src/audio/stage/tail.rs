//! The shared late tail of the Stage return: a Hall reverb fed by every source's reflections,
//! mixed back over them. `StageTail` is built (allocating) by the command thread and run by the
//! Stage return's device chain before its user devices.

use super::image_source::taps;
use super::{OutputMode, RoomModel, Vec3};
use crate::audio::devices::reverb::{
    self, ReverbDevice, ALGORITHM, DECAY, EARLY, HIGH_MULT, LOW_MULT, MIX, PREDELAY, SIZE,
};
use crate::audio::devices::AudioDevice;
use crate::audio::devices::ParamId;

/// Hall in the reverb's algorithm list.
const HALL: f32 = 1.0;
/// Room volumes (m³) mapped to Size 0 % and 100 %.
const SIZE_MIN_VOLUME: f32 = 100.0;
const SIZE_MAX_VOLUME: f32 = 30_000.0;
/// Time to fade the tail out or in when the output mode changes.
const GAIN_RAMP_S: f32 = 0.020;
/// High-frequency decay multiplier of a fully damped room (the reverb's own range is 0.1..1).
const HIGH_MULT_DAMPED: f32 = 0.4;

pub struct StageTail {
    reverb: ReverbDevice,
    max_frames: usize,
    sample_rate: f32,
    /// Interleaved input and wet output for one chunk.
    input: Vec<f32>,
    wet: Vec<f32>,
    /// Linear level of the tail over the reflections, from the room's `tail_db`.
    gain: f32,
    /// Where the fade is now; 0 once the tail is out of the output.
    level: f32,
    /// The tail is part of the output (Full mode).
    enabled: bool,
    /// The room last passed to `configure`, so a rebuilt tail can be fitted to it again.
    room: RoomModel,
}

impl StageTail {
    /// Allocates; call off the audio thread. `max_frames` is the largest block `process` gets in
    /// one call (longer ones are chunked).
    pub fn new(sample_rate: f32, max_frames: usize) -> Self {
        let max_frames = max_frames.max(1);
        let mut reverb = ReverbDevice::new(sample_rate);
        reverb.prepare(sample_rate, max_frames);
        let mut tail = Self {
            reverb,
            max_frames,
            sample_rate,
            input: vec![0.0; max_frames * 2],
            wet: vec![0.0; max_frames * 2],
            gain: 1.0,
            level: 1.0,
            enabled: true,
            room: RoomModel::default(),
        };
        tail.set(ALGORITHM, HALL);
        tail.set(EARLY, 0.0);
        tail.set(MIX, 100.0);
        tail.set(LOW_MULT, 1.0);
        tail.configure(&RoomModel::default());
        tail.reverb.reset();
        tail
    }

    fn set(&mut self, id: ParamId, real: f32) {
        if let Some(spec) = reverb::TABLE.spec(id) {
            self.reverb.set_parameter(id, spec.to_norm(real));
        }
    }

    /// Fit the tail to `room`: its decay time, a size from its volume, a pre-delay of the mean
    /// second-order reflection lag (so the tail starts where the reflections thin out), a
    /// high-frequency decay from the surfaces' damping, the tail level and the output mode.
    /// Safe to call under the state lock: only parameter targets change.
    pub fn configure(&mut self, room: &RoomModel) {
        self.room = *room;
        self.set(DECAY, room.decay_s);

        let volume = room.volume().clamp(SIZE_MIN_VOLUME, SIZE_MAX_VOLUME);
        let size = (volume / SIZE_MIN_VOLUME).ln() / (SIZE_MAX_VOLUME / SIZE_MIN_VOLUME).ln();
        self.set(SIZE, size * 100.0);

        // A source halfway between the listener and the front wall stands in for the stage.
        let stage = room.clamp_point(Vec3::new(
            room.listener.x,
            room.listener.y * 0.5,
            room.listener.z,
        ));
        let lag_s = taps(room, stage, room.listener, false).mean_second_order_delay_s();
        self.set(PREDELAY, lag_s * 1000.0);

        let damping =
            room.surfaces.iter().map(|s| s.hf_damping).sum::<f32>() / room.surfaces.len() as f32;
        self.set(HIGH_MULT, 1.0 - (1.0 - HIGH_MULT_DAMPED) * damping);

        self.gain = 10.0_f32.powf(room.tail_db / 20.0);
        self.enabled = room.output_mode == OutputMode::Full;
    }

    /// Add the tail to `left`/`right`, which hold the sum of all reflections. In any mode but
    /// Full the tail fades out, then stops rendering and is cleared.
    pub fn process(&mut self, left: &mut [f32], right: &mut [f32], frames: usize) {
        let frames = frames.min(left.len()).min(right.len());
        let mut done = 0;
        while done < frames {
            let n = (frames - done).min(self.max_frames);
            self.process_chunk(&mut left[done..done + n], &mut right[done..done + n]);
            done += n;
        }
    }

    fn process_chunk(&mut self, left: &mut [f32], right: &mut [f32]) {
        let n = left.len();
        let target = if self.enabled { 1.0 } else { 0.0 };
        if self.level == 0.0 && target == 0.0 {
            return;
        }
        for i in 0..n {
            self.input[i * 2] = left[i];
            self.input[i * 2 + 1] = right[i];
        }
        self.reverb
            .process_block(&self.input[..n * 2], &mut self.wet[..n * 2], n);

        let step = n as f32 / (GAIN_RAMP_S * self.sample_rate);
        let end = if target > self.level {
            (self.level + step).min(target)
        } else {
            (self.level - step).max(target)
        };
        let ramp = (end - self.level) / n as f32;
        for i in 0..n {
            let g = (self.level + ramp * i as f32) * self.gain;
            left[i] += self.wet[i * 2] * g;
            right[i] += self.wet[i * 2 + 1] * g;
        }
        self.level = end;
        if self.level == 0.0 {
            // Out of the mix: drop what was ringing so re-enabling starts clean.
            self.reverb.reset();
        }
    }

    /// The room the tail is fitted to.
    pub fn room(&self) -> &RoomModel {
        &self.room
    }

    /// Whether the tail may still be ringing (it is in the mix, or just faded out).
    pub fn is_active(&self) -> bool {
        self.level > 0.0 || self.enabled
    }

    pub fn reset(&mut self) {
        self.reverb.reset();
        self.level = if self.enabled { 1.0 } else { 0.0 };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::{impulse, rms, schroeder_t60};
    use crate::audio::stage::MicSetup;

    const SR: f32 = 48_000.0;
    const BLOCK: usize = 512;

    fn room(decay: f32) -> RoomModel {
        RoomModel {
            width: 24.0,
            depth: 30.0,
            height: 12.0,
            listener: Vec3::new(12.0, 20.0, 1.5),
            decay_s: decay,
            tail_db: 0.0,
            ..RoomModel::default()
        }
    }

    /// Feed `input` through the tail block by block and return the left output.
    fn run(tail: &mut StageTail, input: &[f32]) -> Vec<f32> {
        let mut out = Vec::new();
        for chunk in input.chunks(BLOCK) {
            let mut l = chunk.to_vec();
            let mut r = chunk.to_vec();
            tail.process(&mut l, &mut r, chunk.len());
            out.extend(l);
        }
        out
    }

    fn tail_for(room: &RoomModel) -> StageTail {
        let mut tail = StageTail::new(SR, BLOCK);
        tail.configure(room);
        // Let the parameter ramps settle before measuring.
        run(&mut tail, &vec![0.0; SR as usize / 2]);
        tail
    }

    /// The tail's own contribution: output minus the input that was added to.
    fn tail_only(out: &[f32], input: &[f32]) -> Vec<f32> {
        out.iter().zip(input).map(|(o, i)| o - i).collect()
    }

    #[test]
    fn tail_decay_matches_room() {
        for decay in [1.0, 2.5, 5.0] {
            let r = room(decay);
            let mut tail = tail_for(&r);
            let input = impulse((SR * (decay * 2.0 + 1.0)) as usize);
            let wet = tail_only(&run(&mut tail, &input), &input);
            let t60 = schroeder_t60(&wet, SR).expect("decays");
            assert!(
                (t60 - decay).abs() <= decay * 0.15,
                "decay {decay} s measured {t60} s"
            );
        }
    }

    #[test]
    fn output_modes() {
        let input = impulse(SR as usize);
        let measure = |mode: OutputMode| {
            let mut r = room(2.0);
            r.output_mode = mode;
            let mut tail = tail_for(&r);
            let out = run(&mut tail, &input);
            // What the tail added to the impulse.
            crate::audio::dsp::test_util::peak(&tail_only(&out, &input))
        };
        assert!(
            measure(OutputMode::Full) > 1e-3,
            "{}",
            measure(OutputMode::Full)
        );
        // Reflections only and Direct only add nothing to what the sources already sent.
        assert_eq!(measure(OutputMode::ReflectionsOnly), 0.0);
        assert_eq!(measure(OutputMode::DirectOnly), 0.0);
    }

    #[test]
    fn mode_switch_fades_instead_of_cutting() {
        let r = room(3.0);
        let mut tail = tail_for(&r);
        run(&mut tail, &impulse(SR as usize / 4));
        let mut off = r;
        off.output_mode = OutputMode::ReflectionsOnly;
        tail.configure(&off);
        let out = run(&mut tail, &vec![0.0; SR as usize / 4]);
        let first = out[..BLOCK].iter().map(|v| v.abs()).fold(0.0, f32::max);
        assert!(first > 0.0, "the tail is still audible during the fade");
        assert!(out[SR as usize / 8..].iter().all(|&v| v == 0.0));
        assert!(!tail.is_active());
    }

    #[test]
    fn tail_rings_after_input_stops() {
        let r = room(3.0);
        let mut tail = tail_for(&r);
        // One second of noise, then silence.
        let mut input = crate::audio::dsp::test_util::white_noise(SR as usize, 0.5, 3);
        input.extend(vec![0.0; (SR * 4.0) as usize]);
        let out = run(&mut tail, &input);
        let second = |s: f32| &out[(SR * s) as usize..(SR * (s + 0.25)) as usize];
        // Still sounding a full decay time after the input stopped, and then gone.
        assert!(rms(second(1.0 + 2.5)) > 1e-5, "{}", rms(second(3.5)));
        assert!(rms(second(1.0 + 0.1)) > rms(second(1.0 + 2.5)));
        assert!(rms(&out[out.len() - 4800..]) < rms(second(1.1)) * 0.01);
    }

    #[test]
    fn longer_decay_rings_longer() {
        let short = {
            let mut t = tail_for(&room(1.0));
            let input = impulse(SR as usize * 3);
            rms(&run(&mut t, &input)[SR as usize * 2..])
        };
        let long = {
            let mut t = tail_for(&room(6.0));
            let input = impulse(SR as usize * 3);
            rms(&run(&mut t, &input)[SR as usize * 2..])
        };
        assert!(long > short * 10.0);
    }

    #[test]
    fn tail_ignores_mic() {
        let impulse_out = |mic: MicSetup| {
            let mut r = room(2.0);
            r.mic = mic;
            let mut tail = tail_for(&r);
            let input = impulse(SR as usize);
            (run(&mut tail, &input), tail.gain, tail.enabled)
        };
        let pan = impulse_out(MicSetup::Pan);
        for mic in MicSetup::ALL {
            assert!(impulse_out(mic) == pan, "{mic:?} changes the tail");
        }
    }
}

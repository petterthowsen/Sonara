//! Device-level tests of the Sampler: parameters, regions and loops, voices, multisample zones.

use super::params::{
    LoopMode, PlayMode, DEFAULT_VOICES, MAX_VOICES, PARAM_ATTACK, PARAM_COUNT, PARAM_CROSSFADE,
    PARAM_CUTOFF, PARAM_DECAY, PARAM_END, PARAM_FILTER_KEY_TRACK, PARAM_FILTER_TYPE, PARAM_FINE,
    PARAM_KEY_TRACK, PARAM_LOOP_END, PARAM_LOOP_MODE, PARAM_LOOP_START, PARAM_PLAY_MODE,
    PARAM_RELEASE, PARAM_RESONANCE, PARAM_REVERSE, PARAM_ROOT, PARAM_SPEED, PARAM_START,
    PARAM_SUSTAIN, PARAM_TUNE, PARAM_VELOCITY, PARAM_VOICES, PARAM_VOLUME, SPEED_MAX, SPEED_MIN,
    TABLE, TIME_MAX, TIME_MIN, VOICES_MIN,
};
use super::regions::{
    resolve_regions, SampleBuffer, MIN_LOOP_FRAMES, MIN_REGION_FRAMES, SINGLE_ZONE,
};
use super::voice::{
    advance, playback_increment, read_voice, sample_rate_ratio, tracked_cutoff, Voice,
};
use super::zones::{GroupPlayMode, ZoneRanges, ZoneSettings, MAX_ZONES, UNGROUPED};
use super::*;
use crate::audio::commands::EngineStatus;
use crate::audio::devices::{AudioDevice, DevicePath, ParamId};
use crate::audio::midi_types::NoteEvent;
use crate::audio::modulation::envelope::AdsrState;
use std::f32::consts::FRAC_PI_2;

// Reference mappings the table must keep (saved projects store these normalized values).
fn speed_from_normalized(value: f32) -> f32 {
    SPEED_MIN * (SPEED_MAX / SPEED_MIN).powf(value.clamp(0.0, 1.0))
}
fn time_from_normalized(value: f32) -> f32 {
    TIME_MIN + value.clamp(0.0, 1.0) * (TIME_MAX - TIME_MIN)
}
fn voices_from_normalized(value: f32) -> usize {
    let span = (MAX_VOICES - VOICES_MIN) as f32;
    (value.clamp(0.0, 1.0) * span).round() as usize + VOICES_MIN
}
fn voices_to_normalized(count: usize) -> f32 {
    (count - VOICES_MIN) as f32 / (MAX_VOICES - VOICES_MIN) as f32
}
fn norm_of(id: ParamId, real: f32) -> f32 {
    TABLE.spec(id).unwrap().to_norm(real)
}

fn device() -> SamplerDevice {
    SamplerDevice::new(48_000.0, 0, DevicePath::root(0), None)
}

/// Mono ramp `frame / frames` loaded at the device rate.
fn ramp_device(frames: usize) -> SamplerDevice {
    let mut d = device();
    let samples = (0..frames).map(|i| i as f32 / frames as f32).collect();
    d.set_sample("r", samples, 1, 48_000);
    d
}

fn render(d: &mut SamplerDevice, frames: usize) -> Vec<f32> {
    let mut out = Vec::with_capacity(frames * 2);
    let mut left = frames;
    while left > 0 {
        let n = left.min(256);
        let mut block = vec![0.0; n * 2];
        d.process_block(&[], &mut block, n);
        out.extend_from_slice(&block);
        left -= n;
    }
    out
}

fn rms(interleaved: &[f32]) -> f32 {
    (interleaved.iter().map(|x| x * x).sum::<f32>() / interleaved.len() as f32).sqrt()
}

fn voice_at(position: f64, direction: f64) -> Voice {
    let mut v = Voice::idle(48_000.0);
    v.active = true;
    v.position = position;
    v.direction = direction;
    v
}

// === Pre-existing behavior ===

#[test]
fn key_track_transposes_from_root() {
    let at_root = playback_increment(1.0, 0.0, true, 60, 60);
    let up_octave = playback_increment(1.0, 0.0, true, 72, 60);
    assert!((at_root - 1.0).abs() < 1e-9);
    assert!((up_octave - 2.0).abs() < 1e-9);
}

#[test]
fn key_track_off_ignores_note() {
    let a = playback_increment(1.0, 0.0, false, 36, 60);
    let b = playback_increment(1.0, 12.0, false, 80, 60);
    assert!((a - 1.0).abs() < 1e-9);
    assert!((b - 2.0).abs() < 1e-9);
}

#[test]
fn speed_compounds_with_tune() {
    let rate = playback_increment(2.0, 12.0, false, 60, 60);
    assert!((rate - 4.0).abs() < 1e-9);
}

#[test]
fn default_speed_normalized_is_log_midpoint() {
    let sampler = SamplerDevice::new_for_metadata();
    let normalized = sampler.get_parameter(PARAM_SPEED).unwrap();
    assert!(
        (normalized - 0.5).abs() < 1e-5,
        "unity speed must be OSC 0.5 (log), not linear (1.0-0.25)/(4-0.25)=0.2"
    );
    assert!((sampler.p.speed - 1.0).abs() < 1e-5);
}

#[test]
fn preexisting_ids_keep_their_normalized_mapping() {
    let mut d = SamplerDevice::new_for_metadata();
    for n in [0.0_f32, 0.2, 0.5, 0.8, 1.0] {
        d.set_parameter(PARAM_VOLUME, n);
        assert!((d.p.volume - n * 2.0).abs() < 1e-5);
        d.set_parameter(PARAM_TUNE, n);
        assert!((d.p.tune - (n * 48.0 - 24.0)).abs() < 1e-4);
        d.set_parameter(PARAM_SPEED, n);
        let want = speed_from_normalized(n);
        assert!((d.p.speed - want).abs() < 1e-4 * want.max(1.0), "{n}");
        d.set_parameter(PARAM_ROOT, n);
        assert_eq!(d.p.root, (n * 127.0).round() as u8);
        d.set_parameter(PARAM_VELOCITY, n);
        assert!((d.p.velocity_amount - n).abs() < 1e-6);
        d.set_parameter(PARAM_VOICES, n);
        assert_eq!(d.p.voices, voices_from_normalized(n));
        assert_eq!(d.voice_count, voices_from_normalized(n));
        for id in [PARAM_ATTACK, PARAM_DECAY, PARAM_RELEASE] {
            d.set_parameter(id, n);
        }
        let want = time_from_normalized(n);
        assert!((d.p.attack - want).abs() < 1e-5);
        assert!((d.p.decay - want).abs() < 1e-5);
        assert!((d.p.release - want).abs() < 1e-5);
        d.set_parameter(PARAM_SUSTAIN, n);
        assert!((d.p.sustain - n).abs() < 1e-6);
        d.set_parameter(PARAM_PLAY_MODE, n);
        assert_eq!(d.p.play_mode == PlayMode::Gated, n >= 0.5);
        d.set_parameter(PARAM_KEY_TRACK, n);
        assert_eq!(d.p.key_track, n >= 0.5);
        for id in [
            PARAM_VOLUME,
            PARAM_TUNE,
            PARAM_SPEED,
            PARAM_VELOCITY,
            PARAM_SUSTAIN,
        ] {
            assert!((d.get_parameter(id).unwrap() - n).abs() < 1e-6);
        }
    }
}

#[test]
fn sample_rate_ratio_compensates_44k_on_48k_device() {
    let ratio = sample_rate_ratio(44_100.0, 48_000.0);
    assert!((ratio - 44_100.0 / 48_000.0).abs() < 1e-12);
}

#[test]
fn mismatched_sample_rate_slows_or_speeds_root_playback() {
    let mut sampler = SamplerDevice::new(48_000.0, 0, DevicePath::root(0), None);
    sampler.set_sample("r", vec![0.5; 8], 2, 44_100);
    sampler.note_on(60, 1.0);
    let voice = sampler.voices.iter().find(|v| v.active).unwrap();
    let expected = 44_100.0 / 48_000.0;
    assert!((voice.increment - expected).abs() < 1e-9);
}

#[test]
fn one_shot_ignores_note_off() {
    let mut sampler = SamplerDevice::new_for_metadata();
    sampler.set_sample("r", vec![0.5; 8], 2, 48_000);
    sampler.note_on(60, 1.0);
    sampler.note_off(60);
    assert!(sampler.voices.iter().any(|v| v.is_held()));
}

#[test]
fn gated_releases_on_note_off() {
    let mut sampler = SamplerDevice::new_for_metadata();
    sampler.set_parameter(PARAM_PLAY_MODE, 1.0);
    sampler.set_sample("r", vec![0.5; 8], 2, 48_000);
    sampler.note_on(60, 1.0);
    sampler.note_off(60);
    assert!(sampler
        .voices
        .iter()
        .any(|v| v.active && v.envelope.state() == AdsrState::Release));
}

#[test]
fn attack_fades_in_from_silence() {
    let mut sampler = SamplerDevice::new(48_000.0, 0, DevicePath::root(0), None);
    sampler.set_sample("r", vec![1.0; 256], 2, 48_000);
    sampler.note_on(60, 1.0);
    let mut out = vec![0.0; 16];
    sampler.process_block(&[], &mut out, 8);
    assert!(out[0].abs() < 0.1, "first sample should be near silence");
    assert!(
        out[0].abs() < out[14].abs(),
        "attack should rise across the block"
    );
}

#[test]
fn adsr_params_roundtrip() {
    let mut sampler = SamplerDevice::new_for_metadata();
    sampler.set_parameter(PARAM_ATTACK, 0.5);
    sampler.set_parameter(PARAM_DECAY, 0.25);
    sampler.set_parameter(PARAM_SUSTAIN, 0.8);
    sampler.set_parameter(PARAM_RELEASE, 0.1);
    assert!((sampler.get_parameter(PARAM_ATTACK).unwrap() - 0.5).abs() < 1e-5);
    assert!((sampler.get_parameter(PARAM_DECAY).unwrap() - 0.25).abs() < 1e-5);
    assert!((sampler.get_parameter(PARAM_SUSTAIN).unwrap() - 0.8).abs() < 1e-5);
    assert!((sampler.get_parameter(PARAM_RELEASE).unwrap() - 0.1).abs() < 1e-5);
}

#[test]
fn voices_roundtrip_and_default() {
    let mut sampler = SamplerDevice::new_for_metadata();
    assert_eq!(sampler.voice_count, DEFAULT_VOICES);
    sampler.set_parameter(PARAM_VOICES, voices_to_normalized(1));
    assert_eq!(sampler.voice_count, 1);
    sampler.set_parameter(PARAM_VOICES, 1.0);
    assert_eq!(sampler.voice_count, MAX_VOICES);
    assert!((sampler.get_parameter(PARAM_VOICES).unwrap() - 1.0).abs() < 1e-5);
}

#[test]
fn retrigger_overlaps_until_voice_limit() {
    let mut sampler = SamplerDevice::new(48_000.0, 0, DevicePath::root(0), None);
    sampler.set_sample("r", vec![0.5; 8], 2, 48_000);
    sampler.note_on(60, 1.0);
    sampler.note_on(60, 1.0);
    assert_eq!(sampler.voices.iter().filter(|v| v.active).count(), 2);

    sampler.set_parameter(PARAM_VOICES, voices_to_normalized(1));
    assert_eq!(sampler.voices.iter().filter(|v| v.active).count(), 1);

    sampler.note_on(60, 1.0);
    assert_eq!(sampler.voices.iter().filter(|v| v.active).count(), 1);
}

#[test]
fn choke_fades_sounding_voices_to_silence() {
    let mut d = SamplerDevice::new(48_000.0, 0, DevicePath::root(0), None);
    d.set_sample("c", vec![0.5; 48_000], 1, 48_000);
    d.note_on(60, 1.0);
    render(&mut d, 256);
    d.choke(0);
    let out = render(&mut d, 512);
    assert!(out[out.len() - 64..].iter().all(|s| *s == 0.0));
    assert!(!d.any_voice_active());
}

// === New parameters ===

#[test]
fn key_track_defaults_off_and_fine_is_a_cent_per_hundredth() {
    let mut d = ramp_device(100);
    assert!(!d.p.key_track);
    assert_eq!(d.get_parameter(PARAM_KEY_TRACK), Some(0.0));
    d.note_on(72, 1.0);
    let plain = d.voices.iter().find(|v| v.active).unwrap().increment;
    assert!(
        (plain - 1.0).abs() < 1e-9,
        "off: the note doesn't transpose"
    );

    d.set_parameter(PARAM_FINE, norm_of(PARAM_FINE, 100.0));
    d.note_on(60, 1.0);
    let fine = d
        .voices
        .iter()
        .filter(|v| v.active)
        .last()
        .unwrap()
        .increment;
    assert!((fine - 2.0_f64.powf(1.0 / 12.0)).abs() < 1e-6, "{fine}");
}

#[test]
fn new_params_have_their_documented_defaults() {
    let d = SamplerDevice::new_for_metadata();
    let infos = d.parameters();
    let default_of = |id| infos.iter().find(|i| i.id == id).unwrap().default;
    assert_eq!(default_of(PARAM_ROOT), 60.0);
    assert_eq!(default_of(PARAM_CUTOFF), 1_000.0);
    assert_eq!(default_of(PARAM_SPEED), 100.0);
    assert_eq!(d.p.loop_mode, LoopMode::Off);
    assert!(d.p.filter.is_none());
    assert_eq!(infos.len(), PARAM_COUNT);
    assert_eq!(
        infos.iter().find(|i| i.id == PARAM_ROOT).unwrap().unit,
        "note"
    );
}

// === Regions ===

#[test]
fn start_end_restore_is_order_independent() {
    let mut d = ramp_device(1000);
    d.set_parameter(PARAM_START, 0.5);
    d.set_parameter(PARAM_END, 0.6);
    d.set_parameter(PARAM_START, 0.7);
    d.set_parameter(PARAM_END, 0.9);
    assert_eq!(d.get_parameter(PARAM_START), Some(0.7));
    assert!((d.single.regions.play.0 - 700.0).abs() < 1e-3);
    assert!((d.single.regions.play.1 - 900.0).abs() < 1e-3);
}

#[test]
fn region_rejects_inverted_start_end() {
    let r = resolve_regions(100, 0.8, 0.2, 0.0, 1.0, 0.0);
    assert!(r.play.1 > r.play.0);
    assert!((r.play.0 - 20.0).abs() < 1e-3 && (r.play.1 - 80.0).abs() < 1e-3);
    let tiny = resolve_regions(100, 0.5, 0.5, 0.0, 1.0, 0.0);
    assert!(tiny.play.1 - tiny.play.0 >= MIN_REGION_FRAMES);
}

#[test]
fn loop_is_clamped_into_the_play_region() {
    let r = resolve_regions(1000, 0.2, 0.8, 0.0, 1.0, 0.0);
    assert!((r.loop_.0 - 200.0).abs() < 1e-3 && (r.loop_.1 - 800.0).abs() < 1e-3);
    let r = resolve_regions(1000, 0.2, 0.8, 0.9, 0.95, 0.0);
    assert!(r.loop_.0 >= r.play.0 && r.loop_.1 <= r.play.1);
    assert!(r.loop_len() >= MIN_LOOP_FRAMES);
    let r = resolve_regions(1000, 0.2, 0.8, 0.6, 0.4, 0.0);
    assert!(
        (r.loop_.0 - 400.0).abs() < 1e-3 && (r.loop_.1 - 600.0).abs() < 1e-3,
        "inverted loop points are ordered"
    );
}

// === Voice state machine ===

#[test]
fn loop_off_stops_at_the_boundary_without_reading_past() {
    let r = resolve_regions(100, 0.2, 0.5, 0.0, 1.0, 0.0);
    let mut v = voice_at(r.play.0, 1.0);
    for _ in 0..100 {
        advance(&mut v, &r, LoopMode::Off);
        assert!(v.position < r.play.1);
    }
    assert!(v.ending);

    let mut v = voice_at(r.play.1 - 1.0, -1.0);
    for _ in 0..100 {
        advance(&mut v, &r, LoopMode::Off);
        assert!(v.position >= r.play.0);
    }
    assert!(v.ending);
}

#[test]
fn sample_end_declicks_and_ends_the_voice() {
    let mut d = device();
    d.set_sample("r", vec![0.5, 0.5], 2, 48_000);
    d.note_on(60, 1.0);
    render(&mut d, 8);
    assert!(d.voices.iter().any(|v| v.active && v.ending));
    render(&mut d, 400);
    assert!(!d.voices.iter().any(|v| v.active), "ended after the fade");
}

#[test]
fn loop_on_wraps_forward_and_reverse() {
    let r = resolve_regions(100, 0.0, 1.0, 0.3, 0.4, 0.0);
    let mut v = voice_at(20.0, 1.0);
    let mut entered = false;
    for _ in 0..200 {
        advance(&mut v, &r, LoopMode::On);
        entered |= v.in_loop;
        if v.in_loop {
            assert!(
                v.position >= 29.999 && v.position < 40.001,
                "{}",
                v.position
            );
        }
        assert!(!v.ending);
    }
    assert!(entered);

    let mut v = voice_at(99.0, -1.0);
    let mut entered = false;
    for _ in 0..200 {
        advance(&mut v, &r, LoopMode::On);
        entered |= v.in_loop;
        if v.in_loop {
            assert!(
                v.position >= 29.999 && v.position <= 40.001,
                "{}",
                v.position
            );
        }
        assert!(!v.ending && v.direction < 0.0);
    }
    assert!(entered);
}

#[test]
fn ping_pong_bounces_between_the_loop_points() {
    for start_dir in [1.0, -1.0] {
        let r = resolve_regions(100, 0.0, 1.0, 0.3, 0.4, 0.0);
        let mut v = voice_at(if start_dir > 0.0 { 20.0 } else { 99.0 }, start_dir);
        let mut flips = 0;
        let mut last = v.direction;
        for _ in 0..200 {
            advance(&mut v, &r, LoopMode::PingPong);
            if v.in_loop {
                assert!(v.position >= 29.999 && v.position <= 40.001);
            }
            if v.direction != last {
                flips += 1;
                last = v.direction;
            }
            assert!(!v.ending);
        }
        assert!(flips >= 3, "dir {start_dir}: {flips} bounces");
    }
}

#[test]
fn loop_survives_shrinking_and_catches_a_late_voice() {
    // A voice past a shrunk loop end wraps back inside with rem_euclid.
    let r = resolve_regions(100, 0.0, 1.0, 0.3, 0.4, 0.0);
    let mut v = voice_at(39.5, 1.0);
    v.in_loop = true;
    let small = resolve_regions(100, 0.0, 1.0, 0.3, 0.34, 0.0);
    advance(&mut v, &small, LoopMode::On);
    assert!(v.position >= 30.0 && v.position < 34.0, "{}", v.position);
    // A voice before the loop plays into it when the loop turns on.
    let mut v = voice_at(10.0, 1.0);
    for _ in 0..30 {
        advance(&mut v, &r, LoopMode::On);
    }
    assert!(v.in_loop);
}

#[test]
fn note_off_releases_a_looping_one_shot_and_the_loop_runs_through_release() {
    let mut d = ramp_device(100);
    d.set_parameter(PARAM_LOOP_MODE, 0.5);
    d.set_parameter(PARAM_RELEASE, norm_of(PARAM_RELEASE, 0.5));
    d.note_on(60, 1.0);
    render(&mut d, 256);
    d.note_off(60);
    let tail = render(&mut d, 4_800);
    let v = d.voices.iter().find(|v| v.active).unwrap();
    assert_eq!(v.envelope.state(), AdsrState::Release);
    assert!(!v.ending, "still looping, not ended");
    assert!(rms(&tail[tail.len() - 400..]) > 0.0);
}

#[test]
fn reverse_starts_at_the_end_and_plays_backwards() {
    let mut d = ramp_device(1000);
    d.set_parameter(PARAM_REVERSE, 1.0);
    d.note_on(60, 1.0);
    let out = render(&mut d, 300);
    // The ramp falls: the later (post-attack) output is lower than the earlier.
    assert!(out[2 * 200] > out[2 * 290]);
    assert!(out[2 * 290] > 0.0);
}

// === Crossfade ===

fn max_step_across_wrap(mode: LoopMode, xfade: f32) -> f32 {
    let frames = 1000;
    let samples: Vec<f32> = (0..frames).map(|i| i as f32 / frames as f32).collect();
    let s = SampleBuffer {
        samples,
        channels: 1,
        frames,
        sample_rate: 48_000.0,
    };
    let r = resolve_regions(frames, 0.0, 1.0, 0.4, 0.6, xfade);
    let mut v = voice_at(450.0, 1.0);
    v.in_loop = true;
    let mut last = read_voice(&s, &v, &r, mode).0;
    let mut worst = 0.0f32;
    for _ in 0..600 {
        advance(&mut v, &r, mode);
        let now = read_voice(&s, &v, &r, mode).0;
        worst = worst.max((now - last).abs());
        last = now;
    }
    worst
}

#[test]
fn crossfade_zero_is_a_hard_jump_and_positive_is_continuous() {
    assert!(max_step_across_wrap(LoopMode::On, 0.0) > 0.15);
    assert!(max_step_across_wrap(LoopMode::On, 0.5) < 0.02);
}

#[test]
fn crossfade_is_capped_by_the_loop_and_the_material_outside_it() {
    let r = resolve_regions(1000, 0.0, 1.0, 0.0, 0.5, 1.0);
    assert_eq!(r.xfade_fwd, 0.0, "nothing before frame 0");
    assert_eq!(r.xfade_rev, 250.0, "half the loop");
    let r = resolve_regions(1000, 0.0, 1.0, 0.1, 0.9, 1.0);
    assert!((r.xfade_fwd - 100.0).abs() < 1e-3);
    assert!((r.xfade_rev - 100.0).abs() < 1e-3);
}

#[test]
fn ping_pong_ignores_the_crossfade() {
    assert!(max_step_across_wrap(LoopMode::PingPong, 1.0) < 0.005);
    let s = SampleBuffer {
        samples: (0..100).map(|i| i as f32).collect(),
        channels: 1,
        frames: 100,
        sample_rate: 48_000.0,
    };
    let r = resolve_regions(100, 0.0, 1.0, 0.2, 0.8, 1.0);
    let mut v = voice_at(79.0, 1.0);
    v.in_loop = true;
    assert_eq!(read_voice(&s, &v, &r, LoopMode::PingPong).0, 79.0);
}

// === Live pitch ===

#[test]
fn pitch_params_move_sounding_voices() {
    let mut d = ramp_device(10_000);
    d.note_on(60, 1.0);
    render(&mut d, 16);
    assert!((d.voices[0].increment - 1.0).abs() < 1e-9);
    d.set_parameter(PARAM_TUNE, 1.0);
    render(&mut d, 16);
    assert!((d.voices[0].increment - 4.0).abs() < 1e-6);
    d.set_parameter(PARAM_SPEED, norm_of(PARAM_SPEED, 200.0));
    render(&mut d, 16);
    assert!((d.voices[0].increment - 8.0).abs() < 1e-4);
}

// === Filter ===

fn sine_device(hz: f32) -> SamplerDevice {
    let mut d = device();
    let samples = (0..48_000)
        .map(|i| (std::f32::consts::TAU * hz * i as f32 / 48_000.0).sin())
        .collect();
    d.set_sample("r", samples, 1, 48_000);
    d
}

#[test]
fn lp12_attenuates_a_high_sine_and_off_is_a_bypass() {
    let mut dry = sine_device(5_000.0);
    dry.note_on(60, 1.0);
    let dry_out = render(&mut dry, 9_600);

    let mut wet = sine_device(5_000.0);
    wet.set_parameter(PARAM_FILTER_TYPE, 1.0 / 6.0);
    wet.set_parameter(PARAM_CUTOFF, norm_of(PARAM_CUTOFF, 200.0));
    wet.note_on(60, 1.0);
    let wet_out = render(&mut wet, 9_600);
    let (dry_rms, wet_rms) = (rms(&dry_out[9_600..]), rms(&wet_out[9_600..]));
    assert!(dry_rms > 0.3, "{dry_rms}");
    assert!(wet_rms < dry_rms * 0.05, "{wet_rms} vs {dry_rms}");
}

#[test]
fn filter_key_track_follows_the_pitch_from_the_root() {
    assert!((tracked_cutoff(1_000.0, 1.0, 72, 60) - 2_000.0).abs() < 0.5);
    assert!((tracked_cutoff(1_000.0, 1.0, 48, 60) - 500.0).abs() < 0.5);
    assert!((tracked_cutoff(1_000.0, 0.5, 72, 60) - 1_414.2).abs() < 1.0);
    assert!((tracked_cutoff(1_000.0, 0.0, 96, 60) - 1_000.0).abs() < 1e-3);
}

#[test]
fn switching_filter_types_while_sounding_stays_finite() {
    let mut d = device();
    let mut rng = 1u32;
    let noise: Vec<f32> = (0..48_000)
        .map(|_| {
            rng ^= rng << 13;
            rng ^= rng >> 17;
            rng ^= rng << 5;
            rng as i32 as f32 / i32::MAX as f32
        })
        .collect();
    d.set_sample("r", noise, 1, 48_000);
    d.set_parameter(PARAM_RESONANCE, 1.0);
    d.set_parameter(PARAM_LOOP_MODE, 0.5);
    for n in 0..8 {
        d.note_on(48 + n * 3, 1.0);
    }
    for step in 0..64 {
        d.set_parameter(PARAM_FILTER_TYPE, (step % 7) as f32 / 6.0);
        d.set_parameter(PARAM_CUTOFF, (step % 5) as f32 / 4.0);
        let out = render(&mut d, 64);
        assert!(
            out.iter().all(|x| x.is_finite() && x.abs() < 100.0),
            "{step}"
        );
    }
}

/// Worst case: 64 looping voices through LP24. Run with `--release -- --ignored`.
#[test]
#[ignore]
fn sixty_four_voice_filter_cost() {
    let mut d = sine_device(220.0);
    d.set_parameter(PARAM_VOICES, 1.0);
    d.set_parameter(PARAM_LOOP_MODE, 0.5);
    d.set_parameter(PARAM_FILTER_TYPE, 2.0 / 6.0);
    d.set_parameter(PARAM_FILTER_KEY_TRACK, 1.0);
    for n in 0..64 {
        d.note_on(30 + n, 1.0);
    }
    let blocks = 1_000;
    let mut out = vec![0.0; 512 * 2];
    let t = std::time::Instant::now();
    for _ in 0..blocks {
        d.process_block(&[], &mut out, 512);
    }
    let per_block = t.elapsed().as_secs_f64() / blocks as f64;
    let budget = 512.0 / 48_000.0;
    println!(
        "64 voices: {:.1}% of the block budget",
        100.0 * per_block / budget
    );
    assert!(per_block < budget * 0.5);
}

// === Playheads stream ===

fn decode(bytes: &[u8]) -> Vec<[f32; 3]> {
    let count = u32::from_le_bytes(bytes[..4].try_into().unwrap()) as usize;
    assert_eq!(bytes.len(), 4 + count * PLAYHEAD_RECORD_BYTES);
    (0..count)
        .map(|i| {
            let f = |k: usize| {
                let at = 4 + i * PLAYHEAD_RECORD_BYTES + k * 4;
                f32::from_le_bytes(bytes[at..at + 4].try_into().unwrap())
            };
            [f(0), f(1), f(2)]
        })
        .collect()
}

fn poll_after(d: &mut SamplerDevice, frames: usize) -> Option<Vec<u8>> {
    render(d, frames);
    d.poll_device_data().map(|(kind, bytes)| {
        assert_eq!(kind, "playheads");
        bytes
    })
}

#[test]
fn playheads_stream_reports_every_voice() {
    let mut d = ramp_device(48_000);
    assert!(d.subscribe_data("spectrum").is_err());
    d.subscribe_data("playheads").unwrap();
    d.note_on(60, 1.0);
    d.note_on(64, 1.0);
    let first = decode(&poll_after(&mut d, 2_048).expect("record"));
    assert_eq!(first.len(), 2);
    let second = decode(&poll_after(&mut d, 2_048).expect("record"));
    for (a, b) in first.iter().zip(&second) {
        assert!(b[0] > a[0], "positions advance: {a:?} -> {b:?}");
        assert!(a[1] > 0.0 && (0.0..=1.0).contains(&a[2]));
    }
    d.unsubscribe_data("playheads");
    assert!(poll_after(&mut d, 2_048).is_none());
}

#[test]
fn playheads_stream_sends_one_empty_record_when_the_last_voice_ends() {
    let mut d = device();
    d.set_sample("r", vec![0.5; 3_000], 1, 48_000);
    d.subscribe_data("playheads").unwrap();
    assert!(poll_after(&mut d, 2_048).is_none(), "nothing to say yet");
    d.note_on(60, 1.0);
    let playing = decode(&poll_after(&mut d, 2_048).expect("record"));
    assert_eq!(playing.len(), 1);
    let ended = decode(&poll_after(&mut d, 2_048).expect("empty record"));
    assert!(ended.is_empty());
    assert!(poll_after(&mut d, 2_048).is_none(), "only once");
}

// === Multisample (spec 023) ===

fn multi() -> SamplerDevice {
    let mut d = device();
    d.set_multisample(true);
    d
}

fn zone_settings(key: (i32, i32), vel: (i32, i32), root: u8) -> ZoneSettings {
    ZoneSettings {
        ranges: ZoneRanges::new(key, vel, (0, 0), (0, 0)),
        root,
        ..ZoneSettings::default()
    }
}

/// Zone `id` with `frames` of constant `value`, loaded at the device rate.
fn add_zone(d: &mut SamplerDevice, id: u32, settings: ZoneSettings, frames: usize) {
    d.set_zone(id, &settings);
    d.set_zone_sample(id, "", vec![0.5; frames], 1, 48_000);
}

/// Zone ids of the sounding voices, in voice order.
fn sounding(d: &SamplerDevice) -> Vec<u32> {
    d.voices
        .iter()
        .filter(|v| v.active)
        .map(|v| d.zones[v.zone as usize].id)
        .collect()
}

#[test]
fn multisample_plays_matching_zone_only() {
    // REQ-016: A = C3–B3 @ 1–64, B = C3–B3 @ 65–127.
    let mut d = multi();
    add_zone(&mut d, 1, zone_settings((60, 71), (1, 64), 60), 48_000);
    add_zone(&mut d, 2, zone_settings((60, 71), (65, 127), 60), 48_000);
    d.note_on(64, 40.0 / 127.0);
    assert_eq!(sounding(&d), vec![1]);
    d.reset();
    d.note_on(64, 100.0 / 127.0);
    assert_eq!(sounding(&d), vec![2]);
    d.reset();
    d.note_on(40, 1.0);
    assert!(sounding(&d).is_empty(), "outside every zone");
    d.note_on(60, 1.0);
    assert!(rms(&render(&mut d, 512)) > 0.1);
}

#[test]
fn zone_key_track_follows_device_param() {
    // REQ-018: Key Track defaults off, so a zone plays at its natural pitch; switched on, a
    // zone with root C3 plays E3 four semitones up.
    let mut d = multi();
    assert!(!d.p.key_track);
    add_zone(&mut d, 1, zone_settings((60, 64), (1, 127), 60), 1_000);
    d.note_on(64, 1.0);
    let inc = |d: &SamplerDevice| d.voices.iter().find(|v| v.active).unwrap().increment;
    assert!((inc(&d) - 1.0).abs() < 1e-9, "{}", inc(&d));
    d.set_parameter(PARAM_KEY_TRACK, 1.0);
    render(&mut d, 16);
    assert!(
        (inc(&d) - 2.0_f64.powf(4.0 / 12.0)).abs() < 1e-9,
        "{}",
        inc(&d)
    );
}

#[test]
fn device_tune_ignored_in_multisample() {
    // REQ-017: device Root/Tune/Fine don't reach a zone; its own tune and the device-wide
    // Speed do, also on sounding voices.
    let mut d = multi();
    d.set_parameter(PARAM_TUNE, 1.0);
    d.set_parameter(PARAM_FINE, 1.0);
    d.set_parameter(PARAM_ROOT, 0.0);
    let mut s = zone_settings((0, 127), (1, 127), 60);
    s.tune = 0.5;
    add_zone(&mut d, 1, s, 48_000);
    d.note_on(60, 1.0);
    let inc = |d: &SamplerDevice| d.voices.iter().find(|v| v.active).unwrap().increment;
    assert!((inc(&d) - 2.0_f64.powf(0.5 / 12.0)).abs() < 1e-6);
    d.set_parameter(PARAM_TUNE, 0.0);
    d.set_parameter(PARAM_SPEED, norm_of(PARAM_SPEED, 200.0));
    render(&mut d, 16);
    assert!((inc(&d) - 2.0 * 2.0_f64.powf(0.5 / 12.0)).abs() < 1e-4);
    s.tune = 12.0;
    d.set_zone(1, &s);
    render(&mut d, 16);
    assert!(
        (inc(&d) - 4.0).abs() < 1e-4,
        "zone edits move sounding voices"
    );
}

#[test]
fn note_off_releases_all_stacked_voices() {
    let mut d = multi();
    d.set_parameter(PARAM_PLAY_MODE, 1.0);
    add_zone(&mut d, 1, zone_settings((0, 127), (1, 127), 60), 48_000);
    add_zone(&mut d, 2, zone_settings((0, 127), (1, 127), 60), 48_000);
    d.note_on(60, 1.0);
    d.note_on(60, 1.0);
    assert_eq!(sounding(&d).len(), 4);
    d.note_off(60);
    let released = |d: &SamplerDevice| {
        d.voices
            .iter()
            .filter(|v| v.active && v.envelope.state() == AdsrState::Release)
            .map(|v| v.trigger)
            .collect::<Vec<_>>()
    };
    let first = released(&d);
    assert_eq!(first.len(), 2, "both voices of the first note-on");
    assert_eq!(first[0], first[1]);
    d.note_off(60);
    assert_eq!(released(&d).len(), 4);
}

#[test]
fn note_off_releases_a_looping_zone_in_one_shot() {
    let mut d = multi();
    let mut looping = zone_settings((0, 127), (1, 127), 60);
    looping.loop_mode = 1;
    add_zone(&mut d, 1, looping, 48_000);
    add_zone(&mut d, 2, zone_settings((0, 127), (1, 127), 60), 48_000);
    d.note_on(60, 1.0);
    d.note_off(60);
    let states: Vec<(u32, AdsrState)> = d
        .voices
        .iter()
        .filter(|v| v.active)
        .map(|v| (d.zones[v.zone as usize].id, v.envelope.state()))
        .collect();
    assert!(states.contains(&(1, AdsrState::Release)), "{states:?}");
    assert!(states
        .iter()
        .any(|&(id, st)| id == 2 && st != AdsrState::Release));
}

#[test]
fn voices_cap_counts_zone_voices() {
    // REQ-019: Voices = 2, two stacked zones: the second note steals both older voices.
    let mut d = multi();
    d.set_parameter(PARAM_VOICES, voices_to_normalized(2));
    add_zone(&mut d, 1, zone_settings((0, 127), (1, 127), 60), 48_000);
    add_zone(&mut d, 2, zone_settings((0, 127), (1, 127), 60), 48_000);
    d.note_on(60, 1.0);
    assert_eq!(sounding(&d).len(), 2);
    d.note_on(62, 1.0);
    let notes: Vec<u8> = d
        .voices
        .iter()
        .filter(|v| v.active)
        .map(|v| v.note)
        .collect();
    assert_eq!(notes, vec![62, 62]);
}

#[test]
fn remove_zone_remaps_voices() {
    let mut d = multi();
    for (id, key) in [(10, 60), (11, 62), (12, 64)] {
        add_zone(
            &mut d,
            id,
            zone_settings((key, key), (1, 127), key as u8),
            48_000,
        );
    }
    for key in [60, 62, 64] {
        d.note_on(key, 1.0);
    }
    d.remove_zone(10);
    assert_eq!(d.zones.len(), 2);
    let mut playing: Vec<(u32, u8)> = d
        .voices
        .iter()
        .filter(|v| v.active)
        .map(|v| (d.zones[v.zone as usize].id, v.note))
        .collect();
    playing.sort();
    assert_eq!(
        playing,
        vec![(11, 62), (12, 64)],
        "voices follow the moved zone"
    );
    assert!(rms(&render(&mut d, 256)) > 0.0);
    d.remove_zone(12);
    d.remove_zone(99);
    assert_eq!(sounding(&d), vec![11]);
}

#[test]
fn mode_switch_kills_voices() {
    let mut d = ramp_device(48_000);
    d.note_on(60, 1.0);
    d.set_multisample(true);
    assert!(!d.any_voice_active());
    add_zone(&mut d, 1, zone_settings((0, 127), (1, 127), 60), 48_000);
    d.note_on(60, 1.0);
    d.set_multisample(true);
    assert!(d.any_voice_active(), "same mode again is a no-op");
    d.set_multisample(false);
    assert!(!d.any_voice_active());
    assert!(d.zones.is_empty() && d.groups.is_empty());
    d.set_zone(1, &zone_settings((0, 127), (1, 127), 60));
    assert!(d.zones.is_empty(), "zones need multisample mode");
    d.note_on(60, 1.0);
    assert_eq!(d.voices.iter().filter(|v| v.active).count(), 1);
    assert_eq!(
        d.voices.iter().find(|v| v.active).unwrap().zone,
        SINGLE_ZONE
    );
}

#[test]
fn groups_gain_mute_and_removal() {
    let mut d = multi();
    let mut soft = zone_settings((0, 127), (1, 127), 60);
    soft.group_id = 3;
    add_zone(&mut d, 1, soft, 48_000);
    add_zone(&mut d, 2, zone_settings((0, 127), (1, 127), 60), 48_000);
    assert_eq!(
        d.zones[0].group_index, 0,
        "missing group falls back to Ungrouped"
    );
    d.set_zone_group(3, 0.5, false, false, GroupPlayMode::All);
    assert_eq!(d.zones[0].group_index, 1, "relinked when the group arrives");
    d.note_on(60, 1.0);
    let gains: Vec<(u32, f32)> = d
        .voices
        .iter()
        .filter(|v| v.active)
        .map(|v| (d.zones[v.zone as usize].id, v.gain))
        .collect();
    assert_eq!(gains, vec![(1, 0.5), (2, 1.0)]);
    d.reset();
    d.set_zone_group(3, 0.5, false, true, GroupPlayMode::All);
    d.note_on(60, 1.0);
    assert_eq!(sounding(&d), vec![1], "solo");
    d.reset();
    d.remove_zone_group(3);
    assert!(!d.any_solo);
    assert_eq!(
        (d.zones[0].group_id, d.zones[0].group_index),
        (UNGROUPED, 0)
    );
    d.note_on(60, 1.0);
    assert_eq!(sounding(&d), vec![1, 2]);
    d.remove_zone_group(UNGROUPED);
    assert_eq!(d.groups.len(), 1);
}

#[test]
fn velocity_fade_scales_the_voice() {
    // REQ-030 example: velocity 1–80 with a fade-out of 20, hit at 70.
    let mut d = multi();
    let mut s = zone_settings((0, 127), (1, 80), 60);
    s.ranges = ZoneRanges::new((0, 127), (1, 80), (0, 0), (0, 20));
    add_zone(&mut d, 1, s, 48_000);
    d.note_on(60, 70.0 / 127.0);
    let v = d.voices.iter().find(|v| v.active).unwrap();
    assert!((v.gain - (FRAC_PI_2 * 0.5).cos() * (70.0 / 127.0)).abs() < 1e-5);
    d.reset();
    d.note_on(60, 80.0 / 127.0);
    assert!(!d.any_voice_active(), "silent at the faded edge: no voice");
}

/// 512 zones (four per key) and 64 note-ons stay far inside one block's budget.
#[test]
fn many_zones_note_on_is_bounded() {
    let mut d = multi();
    d.set_parameter(PARAM_VOICES, 1.0);
    for id in 0..MAX_ZONES as u32 {
        let key = (id / 4) as i32;
        add_zone(
            &mut d,
            id,
            zone_settings((key, key), (1, 127), key as u8),
            64,
        );
    }
    assert_eq!(d.zones.len(), MAX_ZONES);
    let cap = d.match_scratch.capacity();
    let t = std::time::Instant::now();
    for n in 0..64u8 {
        d.note_on(n * 2, 1.0);
    }
    let elapsed = t.elapsed();
    assert_eq!(d.match_scratch.capacity(), cap);
    assert_eq!(d.voices.iter().filter(|v| v.active).count(), MAX_VOICES);
    // Generous for debug builds; release is orders of magnitude faster.
    assert!(elapsed.as_millis() < 50, "{elapsed:?}");
}

#[test]
fn stale_zone_load_ignored() {
    let mut d = multi();
    d.set_zone(1, &zone_settings((0, 127), (1, 127), 60));
    d.begin_zone_load(1, "new".to_string());
    d.set_zone_sample(1, "old", vec![0.5; 100], 1, 48_000);
    assert!(d.zones[0].sample.is_none(), "stale request ignored");
    d.set_zone_sample(7, "new", vec![0.5; 100], 1, 48_000);
    assert_eq!(d.zones.len(), 1, "unknown zone ignored");
    d.set_zone_sample(1, "new", vec![0.5; 100], 1, 48_000);
    assert_eq!(d.zones[0].frames(), 100);
    assert_eq!(d.zones[0].loading_state, "ready");
}

#[test]
fn playheads_only_focused_zone() {
    // REQ-024: a chord across two zones shows only the focused zone's voices.
    let mut d = multi();
    add_zone(&mut d, 1, zone_settings((0, 63), (1, 127), 60), 24_000);
    add_zone(&mut d, 2, zone_settings((64, 127), (1, 127), 72), 48_000);
    d.subscribe_data("playheads").unwrap();
    d.note_on(60, 1.0);
    d.note_on(62, 1.0);
    d.note_on(72, 1.0);
    d.set_focus(1);
    let heads = decode(&poll_after(&mut d, 2_048).expect("record"));
    assert_eq!(heads.len(), 2);
    // ~2_048 frames into a 24_000-frame zone, not normalized over zone 2's 48_000.
    assert!((heads[0][0] - 2_048.0 / 24_000.0).abs() < 0.01, "{heads:?}");
    d.set_focus(2);
    assert_eq!(decode(&poll_after(&mut d, 2_048).unwrap()).len(), 1);
    d.set_focus(9);
    assert!(decode(&poll_after(&mut d, 2_048).unwrap()).is_empty());
}

#[test]
fn failed_zone_is_silent_others_play() {
    let (tx, rx) = crossbeam::channel::unbounded();
    let mut d = SamplerDevice::new(48_000.0, 2, DevicePath::root(0), Some(tx));
    d.set_multisample(true);
    d.set_zone(1, &zone_settings((0, 63), (1, 127), 60));
    d.set_zone(2, &zone_settings((64, 127), (1, 127), 72));
    d.begin_zone_load(1, "a".to_string());
    d.begin_zone_load(2, "b".to_string());
    d.fail_zone_load(1, "a", "file not found");
    d.set_zone_sample(2, "b", vec![0.5; 48_000], 1, 48_000);
    let states: Vec<(u32, String)> = rx
        .try_iter()
        .filter_map(|s| match s {
            EngineStatus::SamplerZoneLoadingState { zone_id, state, .. } => Some((zone_id, state)),
            _ => None,
        })
        .collect();
    assert!(states.contains(&(1, "failed:file not found".to_string())));
    assert!(states.contains(&(2, "ready".to_string())));
    d.note_on(60, 1.0);
    assert!(!d.any_voice_active(), "the failed zone is silent");
    d.note_on(72, 1.0);
    assert_eq!(sounding(&d), vec![2]);
    assert_eq!(
        d.zone_state_statuses().len(),
        2,
        "state/get resends every zone"
    );
}

// === Single-mode fixture (spec 023 T-005) ===

/// Per-block (bit hash, RMS) of a fixed single-mode render: two scenarios covering a
/// reversed crossfaded loop through LP24 with key tracking and a mid-note pitch change, and
/// a forward Ping-Pong loop in a trimmed region with a gated release. Recorded on the code
/// before the zone refactor, so the zone path must reproduce it bit for bit.
fn single_mode_fixture() -> Vec<(u64, f32)> {
    let on = |key, velocity| NoteEvent::On {
        note_id: 0,
        key,
        velocity,
    };
    let off = |key| NoteEvent::Off {
        note_id: 0,
        key,
        release: 0.5,
    };
    let samples: Vec<f32> = (0..24_000)
        .flat_map(|i| {
            let t = i as f32 / 48_000.0;
            let l = (std::f32::consts::TAU * 220.0 * t).sin() * 0.6 + (i % 97) as f32 / 400.0;
            let r = (std::f32::consts::TAU * 331.0 * t).sin() * 0.5 - (i % 53) as f32 / 300.0;
            [l, r]
        })
        .collect();
    let mut blocks = Vec::new();
    let mut run = |d: &mut SamplerDevice, step: &dyn Fn(&mut SamplerDevice, usize)| {
        for block in 0..24 {
            step(d, block);
            let mut out = vec![0.0f32; 256 * 2];
            d.process_block(&[], &mut out, 256);
            let mut hash = 0xcbf2_9ce4_8422_2325u64;
            for x in &out {
                hash = (hash ^ x.to_bits() as u64).wrapping_mul(0x100_0000_01b3);
            }
            blocks.push((hash, rms(&out)));
        }
    };

    let mut a = device();
    a.set_sample("a", samples.clone(), 2, 44_100);
    a.set_parameter(PARAM_KEY_TRACK, 1.0);
    a.set_parameter(PARAM_REVERSE, 1.0);
    a.set_parameter(PARAM_LOOP_MODE, 0.5);
    a.set_parameter(PARAM_LOOP_START, 0.3);
    a.set_parameter(PARAM_LOOP_END, 0.6);
    a.set_parameter(PARAM_CROSSFADE, norm_of(PARAM_CROSSFADE, 30.0));
    a.set_parameter(PARAM_FILTER_TYPE, 2.0 / 6.0);
    a.set_parameter(PARAM_CUTOFF, norm_of(PARAM_CUTOFF, 2_000.0));
    a.set_parameter(PARAM_RESONANCE, 0.4);
    a.set_parameter(PARAM_FILTER_KEY_TRACK, 0.5);
    a.set_parameter(PARAM_ROOT, norm_of(PARAM_ROOT, 57.0));
    run(&mut a, &|d, block| match block {
        0 => {
            d.send_note_event(&on(60, 0.8), 17);
            d.send_note_event(&on(67, 0.5), 130);
        }
        6 => d.set_parameter(PARAM_TUNE, norm_of(PARAM_TUNE, 3.0)),
        9 => d.set_parameter(PARAM_FINE, norm_of(PARAM_FINE, -40.0)),
        12 => d.send_note_event(&off(60), 64),
        14 => d.set_parameter(PARAM_CUTOFF, norm_of(PARAM_CUTOFF, 600.0)),
        _ => {}
    });

    let mut b = device();
    b.set_sample("b", samples, 2, 48_000);
    b.set_parameter(PARAM_PLAY_MODE, 1.0);
    b.set_parameter(PARAM_START, 0.1);
    b.set_parameter(PARAM_END, 0.7);
    b.set_parameter(PARAM_LOOP_MODE, 1.0);
    b.set_parameter(PARAM_LOOP_START, 0.2);
    b.set_parameter(PARAM_LOOP_END, 0.25);
    b.set_parameter(PARAM_VELOCITY, 0.5);
    b.set_parameter(PARAM_RELEASE, norm_of(PARAM_RELEASE, 0.05));
    run(&mut b, &|d, block| match block {
        0 => d.send_note_event(&on(48, 1.0), 0),
        3 => d.send_note_event(&on(72, 0.3), 200),
        8 => d.set_parameter(PARAM_SPEED, norm_of(PARAM_SPEED, 150.0)),
        10 => d.send_note_event(&off(48), 10),
        16 => d.send_note_event(&off(72), 0),
        _ => {}
    });
    blocks
}

/// Block hashes of [`single_mode_fixture`], recorded before the zone refactor.
const SINGLE_MODE_FIXTURE: [u64; 48] = [
    14206959556813367124,
    17739970396413959311,
    16375157930753748474,
    7602148075931357404,
    6082375776345269119,
    15203502640084660737,
    15949397729668078016,
    6042357849161996924,
    852704725007154123,
    670701819617410879,
    12734231012316984580,
    9561008414411622059,
    15775830726042474405,
    420039192125132452,
    13113945623445414435,
    17631944859054756961,
    11536535370512420425,
    1208451133442155396,
    3431255463954417967,
    17325285220867068646,
    17479275945307132020,
    18140119704573567085,
    17017164475258079043,
    16355768676671113191,
    6492222591069766020,
    5825699738955252143,
    13718680342333316252,
    6719355808529577290,
    17381493052313732927,
    4591614688271898581,
    5731359738487504240,
    52773419609060268,
    16372273707863486210,
    4576185814297321848,
    12237556130485292987,
    15237157378695495744,
    3298634046225823811,
    130937475898819506,
    4757032436453216695,
    15448315486338422620,
    18275370344189011179,
    13458987673212643287,
    13340110937421438874,
    11029006805787110254,
    2295699601456801913,
    6090403448540165059,
    16384491379877320832,
    6305337554215224320,
];

#[test]
fn single_mode_unchanged_through_zone_path() {
    let blocks = single_mode_fixture();
    assert!(blocks.iter().any(|b| b.1 > 0.01), "the fixture makes sound");
    for (i, ((hash, rms), want)) in blocks.iter().zip(SINGLE_MODE_FIXTURE).enumerate() {
        assert_eq!(*hash, want, "block {i} changed (rms now {rms})");
    }
    assert_eq!(blocks.len(), SINGLE_MODE_FIXTURE.len());
}

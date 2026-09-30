//! Conformance checks every built-in effect in `factory::EFFECT_IDS` must pass (spec 012,
//! Phase 0). A new effect gets them by being added to that list.
//!
//! Each check builds a fresh device with `create_effect`, so checks don't leak state into each
//! other. Failures are collected per effect and reported together.

use super::{
    create_effect, enum_to_norm, norm_to_enum, real_to_norm, AudioDevice, ParamInfo, ParamType,
    EFFECT_IDS,
};
use crate::audio::dsp::test_util::{peak, render, stereo, white_noise};

const SR: f32 = 48_000.0;
const MAX_FRAMES: usize = 4_096;
/// Effects that don't pass yet, with the reason. `known_failing_effects_still_fail` runs them.
const KNOWN_FAILING: &[(&str, &str)] = &[(
    "sonara.builtin.delay",
    "the pre-012 Delay advertises 1–5000 ms but maps 1–1250 ms; Delay v2 (Phase 1) replaces it",
)];

fn make(id: &str) -> Box<dyn AudioDevice> {
    create_effect(id, SR, MAX_FRAMES).unwrap_or_else(|| panic!("{id} is not an effect"))
}

/// Interleaved stereo noise followed by silence.
fn noise_then_silence(noise_seconds: f32, silence_seconds: f32) -> Vec<f32> {
    let mut mono = white_noise((noise_seconds * SR) as usize, 0.5, 11);
    mono.resize(mono.len() + (silence_seconds * SR) as usize, 0.0);
    stereo(&mono)
}

/// The normalized value a parameter should read back after being set to `norm`.
fn canonical(info: &ParamInfo, norm: f32) -> f32 {
    match info.param_type {
        ParamType::Float => norm.clamp(0.0, 1.0),
        ParamType::Enum => {
            let count = info.enum_values.len();
            enum_to_norm(norm_to_enum(norm, count), count)
        }
        ParamType::Bool => {
            if norm >= 0.5 {
                1.0
            } else {
                0.0
            }
        }
    }
}

/// The normalized value of a parameter's advertised (real) default.
fn default_norm(info: &ParamInfo) -> f32 {
    match info.param_type {
        ParamType::Float => real_to_norm(
            info.default,
            info.min,
            info.max,
            info.is_logarithmic,
            info.skew,
        ),
        ParamType::Enum => enum_to_norm(info.default.max(0.0) as usize, info.enum_values.len()),
        ParamType::Bool => canonical(info, info.default),
    }
}

fn check_parameters_round_trip(id: &str) -> Result<(), String> {
    let mut device = make(id);
    for info in device.parameters() {
        for norm in [0.0, 0.25, 0.5, 0.73, 1.0] {
            device.set_parameter(info.id, norm);
            let got = device
                .get_parameter(info.id)
                .ok_or_else(|| format!("'{}' has no value", info.name))?;
            let expected = canonical(&info, norm);
            if (got - expected).abs() > 1e-4 {
                return Err(format!(
                    "'{}' set to {norm} reads back {got} (expected {expected})",
                    info.name
                ));
            }
        }
    }
    Ok(())
}

fn check_defaults_match_metadata(id: &str) -> Result<(), String> {
    let device = make(id);
    for info in device.parameters() {
        let got = device.get_parameter(info.id).unwrap_or(f32::NAN);
        let expected = default_norm(&info);
        if !((got - expected).abs() <= 1e-4) {
            return Err(format!(
                "'{}' starts at {got}, but its advertised default {} is {expected} normalized",
                info.name, info.default
            ));
        }
    }
    Ok(())
}

fn check_bypass_is_bit_exact(id: &str) -> Result<(), String> {
    let mut device = make(id);
    device.set_enabled(false);
    let input = noise_then_silence(0.5, 0.0);
    if render(device.as_mut(), &input, &[512]) != input {
        return Err("bypassed output differs from the input".into());
    }
    Ok(())
}

fn check_mix_zero_is_bit_exact_dry(id: &str) -> Result<(), String> {
    let mut device = make(id);
    let Some(mix) = device.parameters().into_iter().find(|p| p.name == "Mix") else {
        return Ok(()); // No Mix parameter.
    };
    device.set_parameter(mix.id, 0.0);
    // Let any smoothing settle before comparing.
    render(device.as_mut(), &vec![0.0; (SR as usize / 10) * 2], &[512]);
    let input = noise_then_silence(0.5, 0.0);
    if render(device.as_mut(), &input, &[512]) != input {
        return Err("Mix 0 output differs from the dry input".into());
    }
    Ok(())
}

fn check_every_rate_stays_finite(id: &str) -> Result<(), String> {
    for rate in [44_100.0, 48_000.0, 96_000.0, 192_000.0] {
        let mut device = make(id);
        device.prepare(rate, MAX_FRAMES);
        let input = noise_then_silence(1.0, 1.0);
        if let Some(bad) = render(device.as_mut(), &input, &[512])
            .iter()
            .find(|x| !x.is_finite())
        {
            return Err(format!("{bad} in the output at {rate} Hz"));
        }
    }
    Ok(())
}

fn check_block_size_independence(id: &str) -> Result<(), String> {
    let input = noise_then_silence(1.0, 0.5);
    let reference = render(make(id).as_mut(), &input, &[512]);
    let odd = render(make(id).as_mut(), &input, &[1, 37, 256, 4_096]);
    let worst = reference
        .iter()
        .zip(&odd)
        .map(|(a, b)| (a - b).abs())
        .fold(0.0f32, f32::max);
    if worst > 1e-3 {
        return Err(format!(
            "odd block sizes differ from 512-frame blocks by up to {worst}"
        ));
    }
    Ok(())
}

fn check_reset_clears_the_tail(id: &str) -> Result<(), String> {
    let mut device = make(id);
    render(device.as_mut(), &noise_then_silence(0.5, 0.0), &[512]);
    device.reset();
    let after = render(device.as_mut(), &noise_then_silence(0.0, 0.5), &[512]);
    if peak(&after) > 1e-9 {
        return Err(format!(
            "output peaks at {} after reset with silent input",
            peak(&after)
        ));
    }
    Ok(())
}

fn check_tail_dies_out(id: &str) -> Result<(), String> {
    let mut device = make(id);
    let output = render(device.as_mut(), &noise_then_silence(1.0, 20.0), &[512]);
    let last_second = &output[output.len() - SR as usize * 2..];
    if peak(last_second) > 1e-6 {
        return Err(format!(
            "still at {} after 19 s of silence (defaults)",
            peak(last_second)
        ));
    }
    Ok(())
}

const CHECKS: &[(&str, fn(&str) -> Result<(), String>)] = &[
    ("parameters round-trip", check_parameters_round_trip),
    ("defaults match metadata", check_defaults_match_metadata),
    ("bypass is bit-exact", check_bypass_is_bit_exact),
    ("Mix 0 is bit-exact dry", check_mix_zero_is_bit_exact_dry),
    ("finite at every rate", check_every_rate_stays_finite),
    ("block-size independent", check_block_size_independence),
    ("reset clears the tail", check_reset_clears_the_tail),
    ("tail dies out", check_tail_dies_out),
];

/// Every failed check for effect `id`, as "check: reason" lines.
fn failures(id: &str) -> Vec<String> {
    CHECKS
        .iter()
        .filter_map(|(name, check)| check(id).err().map(|e| format!("{id} — {name}: {e}")))
        .collect()
}

fn is_known_failing(id: &str) -> bool {
    KNOWN_FAILING.iter().any(|(known, _)| *known == id)
}

#[test]
fn every_builtin_effect_conforms() {
    let failed: Vec<String> = EFFECT_IDS
        .iter()
        .filter(|id| !is_known_failing(id))
        .flat_map(|id| failures(id))
        .collect();
    assert!(failed.is_empty(), "\n{}", failed.join("\n"));
}

/// Shows why the known-failing effects fail, and fails once one of them passes (so it can come
/// off the list). `cargo test known_failing -- --ignored --nocapture`.
#[test]
#[ignore = "effects on KNOWN_FAILING are expected to fail"]
fn known_failing_effects_still_fail() {
    for (id, reason) in KNOWN_FAILING {
        let failed = failures(id);
        println!("{id} ({reason}):");
        for line in &failed {
            println!("  {line}");
        }
        assert!(
            !failed.is_empty(),
            "{id} now conforms: take it off KNOWN_FAILING"
        );
    }
}

#[test]
fn known_failing_entries_are_real_effects() {
    for (id, _) in KNOWN_FAILING {
        assert!(EFFECT_IDS.contains(id), "{id} isn't in EFFECT_IDS");
    }
}

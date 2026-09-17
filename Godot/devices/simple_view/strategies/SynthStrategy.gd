## SynthStrategy.gd
## Synth rules: cutoff and output first, then filter, envelopes, oscillators and modulation.

class_name SynthStrategy extends GenericStrategy


func role_keywords() -> Dictionary:
	return {
		"cutoff": ["cutoff"],
		"resonance": ["res", "reso", "resonance"],
		"filter": ["filter", "flt", "vcf", "keytrack", "drive"],
		"oscillator": ["osc*", "wave*", "shape", "pitch", "tune", "detune", "octave", "oct", "semi*", "fine", "coarse", "unison", "voices", "pw", "pulse", "sub", "noise"],
		"envelope": ["attack", "decay", "sustain", "release", "env*", "adsr", "hold"],
		"modulation": ["lfo", "rate", "depth", "mod*", "vibrato", "speed"],
		"effects": ["chorus", "delay", "reverb", "fx", "dist*"],
		"performance": ["glide", "portamento", "porta", "bend", "legato", "poly*", "mono", "velocity", "vel"],
		"output": ["volume", "vol", "master", "output", "gain", "amp", "level", "pan"],
	}


func role_weights() -> Dictionary:
	return {
		"cutoff": 1.0,
		"output": 0.9,
		"resonance": 0.85,
		"envelope": 0.75,
		"filter": 0.65,
		"oscillator": 0.6,
		"modulation": 0.5,
		"effects": 0.4,
		"performance": 0.35,
		OTHER_ROLE: 0.3,
	}


func groups() -> Array[Dictionary]:
	return [
		{"id": "oscillators", "title": "Oscillators", "roles": ["oscillator"]},
		{"id": "filter", "title": "Filter", "roles": ["cutoff", "resonance", "filter"]},
		{"id": "envelopes", "title": "Envelopes", "roles": ["envelope"]},
		{"id": "modulation", "title": "Modulation", "roles": ["modulation"]},
		{"id": "effects", "title": "Effects", "roles": ["effects"]},
		{"id": "output", "title": "Output", "roles": ["output", "performance"]},
	]

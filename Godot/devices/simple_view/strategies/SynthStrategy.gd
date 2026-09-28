## SynthStrategy.gd
## Synth rules: cutoff and output first, then filter, envelopes, oscillators and modulation.
## Modulation, effects and the arpeggiator/sequencer get pages of their own; everything else sits
## on Main.

class_name SynthStrategy extends GenericStrategy


func role_keywords() -> Dictionary:
	return {
		"cutoff": ["cutoff"],
		"resonance": ["res", "reso", "resonance"],
		"filter": ["filter", "flt", "vcf", "keytrack", "drive"],
		"arpeggiator": ["arp*", "seq*"],
		# Before oscillator and envelope: "LFO Wave" and "Mod Env Attack" are modulation.
		"modulation": ["lfo", "rate", "depth", "mod", "modul*", "matrix", "vibrato", "speed"],
		"oscillator": ["osc*", "wave*", "shape", "pitch", "tune", "detune", "octave", "oct", "semi*", "fine", "coarse", "unison", "voices", "pw", "pulse", "sub", "noise", "sampl*"],
		"envelope": ["attack", "decay", "sustain", "release", "env*", "adsr", "hold"],
		"effects": ["effect*", "chorus", "delay", "reverb", "fx", "dist*", "phaser", "flanger", "eq"],
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
		"arpeggiator": 0.3,
		OTHER_ROLE: 0.3,
	}


func groups() -> Array[Dictionary]:
	return [
		{"id": "oscillators", "title": "Oscillators", "roles": ["oscillator"]},
		{"id": "filter", "title": "Filter", "roles": ["cutoff", "resonance", "filter"]},
		{"id": "envelopes", "title": "Envelopes", "roles": ["envelope"]},
		{"id": "modulation", "title": "Modulation", "roles": ["modulation"], "page": "Modulation"},
		{"id": "effects", "title": "Effects", "roles": ["effects"], "page": "Effects"},
		{"id": "arpeggiator", "title": "Arpeggiator", "roles": ["arpeggiator"], "page": "Arp"},
		{"id": "output", "title": "Output", "roles": ["output", "performance"]},
	]

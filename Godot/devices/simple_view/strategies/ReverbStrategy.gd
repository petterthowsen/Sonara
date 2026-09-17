## ReverbStrategy.gd
## Reverb rules: levels together in Mix, decay/size first, then space, tone and modulation.

class_name ReverbStrategy extends GenericStrategy


func role_keywords() -> Dictionary:
	return {
		"mix": ["mix", "dry", "wet", "level", "blend", "balance", "volume", "gain", "output"],
		"predelay": ["predelay", "pre", "delay"],
		"decay": ["decay", "rt60", "time", "length", "reverb"],
		"size": ["size", "room", "space", "scale"],
		"shape": ["width", "diffuse", "diffusion", "density", "spread", "stereo", "send", "early", "late"],
		"tone": ["low", "high", "lo", "hi", "cut", "cross", "mult", "damp*", "tone", "lowcut", "highcut", "lpf", "hpf", "freq*", "bass", "treble", "eq"],
		"modulation": ["spin", "wander", "mod*", "rate", "depth", "chorus"],
	}


func role_weights() -> Dictionary:
	return {
		"mix": 1.0,
		"decay": 0.95,
		"size": 0.9,
		"predelay": 0.6,
		"shape": 0.5,
		"tone": 0.45,
		"modulation": 0.35,
		OTHER_ROLE: 0.3,
	}


func groups() -> Array[Dictionary]:
	return [
		{"id": "mix", "title": "Mix", "roles": ["mix"]},
		{"id": "space", "title": "Space", "roles": ["decay", "size", "predelay", "shape"]},
		{"id": "tone", "title": "Tone", "roles": ["tone"]},
		{"id": "modulation", "title": "Modulation", "roles": ["modulation"]},
	]

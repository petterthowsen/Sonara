## DelayStrategy.gd
## Delay rules: time and feedback first, then mix, tone, stereo and modulation.

class_name DelayStrategy extends GenericStrategy


func role_keywords() -> Dictionary:
	return {
		"mix": ["mix", "dry", "wet", "level", "blend", "balance", "volume", "gain", "output"],
		"feedback": ["feedback", "fb", "repeat*", "regen*"],
		"time": ["time", "delay", "sync", "division", "length", "bpm", "note", "beat*"],
		"tone": ["low", "high", "cut", "filter", "damp*", "tone", "freq*", "lpf", "hpf", "lowcut", "highcut"],
		"stereo": ["pan", "width", "ping", "pong", "pingpong", "stereo", "spread", "cross"],
		"modulation": ["mod*", "rate", "depth", "wow", "flutter"],
	}


func role_weights() -> Dictionary:
	return {
		"time": 1.0,
		"feedback": 0.95,
		"mix": 0.9,
		"tone": 0.5,
		"stereo": 0.45,
		"modulation": 0.35,
		OTHER_ROLE: 0.3,
	}


func groups() -> Array[Dictionary]:
	return [
		{"id": "delay", "title": "Delay", "roles": ["time", "feedback"]},
		{"id": "mix", "title": "Mix", "roles": ["mix"]},
		{"id": "tone", "title": "Tone", "roles": ["tone"]},
		{"id": "stereo", "title": "Stereo", "roles": ["stereo"]},
		{"id": "modulation", "title": "Modulation", "roles": ["modulation"]},
	]

## CompressorStrategy.gd
## Compressor rules: threshold and ratio first, then timing, output and sidechain.

class_name CompressorStrategy extends GenericStrategy


func role_keywords() -> Dictionary:
	return {
		"threshold": ["threshold", "thresh", "thr"],
		"ratio": ["ratio"],
		"attack": ["attack", "att", "atk"],
		"release": ["release", "rel"],
		"knee": ["knee"],
		"sidechain": ["sidechain", "sc", "hpf", "filter", "detect*", "lookahead", "key"],
		"mix": ["mix", "dry", "wet", "blend"],
		"makeup": ["makeup", "gain", "output", "out", "volume", "level", "trim"],
	}


func role_weights() -> Dictionary:
	return {
		"threshold": 1.0,
		"ratio": 0.95,
		"attack": 0.85,
		"release": 0.8,
		"makeup": 0.75,
		"mix": 0.6,
		"knee": 0.5,
		"sidechain": 0.35,
		OTHER_ROLE: 0.3,
	}


func groups() -> Array[Dictionary]:
	return [
		{"id": "dynamics", "title": "Dynamics", "roles": ["threshold", "ratio", "knee"]},
		{"id": "timing", "title": "Timing", "roles": ["attack", "release"]},
		{"id": "output", "title": "Output", "roles": ["makeup", "mix"]},
		{"id": "sidechain", "title": "Sidechain", "roles": ["sidechain"]},
	]

## EqStrategy.gd
## EQ rules: gain and frequency first, grouped per band ("Band 1", "Low", …) instead of per role.

class_name EqStrategy extends GenericStrategy

## Name tokens that identify a band by position.
const BAND_WORDS := ["low", "lo", "lowmid", "mid", "highmid", "high", "hi", "bass", "treble", "presence", "air"]


func role_keywords() -> Dictionary:
	return {
		"enable": ["enable*", "on", "active", "bypass"],
		"shape": ["type", "shape", "mode", "slope"],
		"frequency": ["freq*", "hz", "cutoff"],
		"gain": ["gain", "boost"],
		"q": ["q", "bandwidth", "bw", "width", "res*"],
		"output": ["output", "out", "master", "volume", "level", "trim"],
	}


func role_weights() -> Dictionary:
	return {
		"gain": 0.9,
		"frequency": 0.85,
		"output": 0.8,
		"q": 0.7,
		"shape": 0.5,
		"enable": 0.4,
		OTHER_ROLE: 0.3,
	}


func groups() -> Array[Dictionary]:
	return [
		{"id": "output", "title": "Output", "roles": ["output"]},
	]


## Group by band: a band number ("Band 2 Gain", "B2 Freq") or position word ("Low Gain").
func group_for_item(item: Dictionary) -> Dictionary:
	var name: String = item.get("label", "")
	if name.is_empty() and item.has("name"):
		name = item.name
	var tokens := ParamClassifier.name_tokens(name)
	for i in range(tokens.size()):
		var token := tokens[i]
		if token == "band" and i + 1 < tokens.size() and tokens[i + 1].is_valid_int():
			return {"id": "band_" + tokens[i + 1], "title": "Band " + tokens[i + 1]}
		var digits := token.trim_prefix("band").trim_prefix("b")
		if digits != token and digits.is_valid_int():
			return {"id": "band_" + digits, "title": "Band " + digits}
		if token in BAND_WORDS:
			return {"id": "band_" + token, "title": token.capitalize()}
	return super.group_for_item(item)

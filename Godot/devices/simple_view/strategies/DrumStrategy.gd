## DrumStrategy.gd
## Drum rules: Tune and Decay are the large knobs, levels go in a row, and the rest is grouped
## by the device's module path. The drum devices declare one `module` per section (Body, Punch,
## Click, Noise, Mode, Global), so the generator's module grouping produces those sections; this
## strategy ranks Tune/Decay as the large knobs and supplies groups for devices whose parameters
## carry no module.

class_name DrumStrategy extends GenericStrategy


func role_keywords() -> Dictionary:
	return {
		# Before tone: "Tune" is the pitch, not a tone control.
		"tune": ["tune", "pitch", "freq*", "note"],
		"decay": ["decay", "length", "time", "release"],
		"level": ["level", "volume", "gain", "output", "amount", "mix", "blend"],
		"tone": ["tone", "color", "cut*", "filter", "sweep", "resonance", "res", "q"],
		"character": ["drive", "curve", "humanize", "velocity", "mode", "gate", "glide"],
	}


func role_weights() -> Dictionary:
	return {
		"tune": 1.0,
		"decay": 0.95,
		"level": 0.7,
		"tone": 0.5,
		"character": 0.4,
		OTHER_ROLE: 0.3,
	}


func groups() -> Array[Dictionary]:
	return [
		{"id": "drum", "title": "Drum", "roles": ["tune", "decay"]},
		{"id": "levels", "title": "Levels", "roles": ["level"]},
		{"id": "tone", "title": "Tone", "roles": ["tone"]},
		{"id": "character", "title": "Character", "roles": ["character"]},
	]


## Mark a drum's Tune knob to show a note name (E0) instead of raw Hz. The engine advertises
## Tune in Hz, so the note name is a display override only.
func decorate_control(control: Dictionary, params: Array) -> Dictionary:
	var ids: Array = control.get("params", [])
	if ids.size() != 1 or String(control.get("kind", "")) not in [SimpleControlKinds.KNOB, SimpleControlKinds.SLIDER]:
		return control
	for param in params:
		if param != null and int(param.id) == int(ids[0]) and role_for(param) == "tune":
			var marked := control.duplicate()
			marked["unit"] = "note"
			return marked
	return control

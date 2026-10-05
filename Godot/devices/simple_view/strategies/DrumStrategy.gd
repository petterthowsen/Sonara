## DrumStrategy.gd
## Drum rules: Tune and Decay are the large knobs, levels go in a row, and the rest is grouped
## by the device's module path. The built-in drums declare one `module` per section: the drum
## itself (Kick, Snare, Hat, Clap) first, then its layers (Punch, Click, Noise, Snappy, Snap,
## Tone, Hands), the Kick's 808 mode and the shared Global block last. Their tables list each
## section's controls in playing order, so a drum keeps that order instead of the generic
## "levels first" rule. This strategy also supplies groups for devices whose parameters carry no
## module.

class_name DrumStrategy extends GenericStrategy


func role_keywords() -> Dictionary:
	# Checked in this order: the shared drum controls and the 808 mode first, so their "Output"
	# and "Release" don't rank them as levels or decays and pull their sections forward.
	return {
		"global": ["output", "humanize", "velocity"],
		"mode": ["gate", "glide", "release", "keytrack"],
		# Before tone: "Tune" is the pitch, not a tone control.
		"tune": ["tune", "pitch", "freq*", "note"],
		"decay": ["decay", "length", "time"],
		# Before level: "Click Tone" is a tone control of the Click section, not its level.
		"tone": ["tone", "color", "cut*", "filter", "sweep", "punch", "resonance", "res", "q", "ring",
			"body", "overtone"],
		"level": ["level", "volume", "gain", "amount", "mix", "blend", "click", "noise", "snappy",
			"snap", "metal", "room", "hands"],
		"character": ["drive", "curve", "shape", "mode", "spread", "loose"],
	}


func role_weights() -> Dictionary:
	return {
		"tune": 1.0,
		"decay": 0.95,
		"level": 0.7,
		"tone": 0.5,
		"character": 0.4,
		"mode": 0.35,
		OTHER_ROLE: 0.3,
		"global": 0.2,
	}


func groups() -> Array[Dictionary]:
	return [
		{"id": "drum", "title": "Drum", "roles": ["tune", "decay"]},
		{"id": "levels", "title": "Levels", "roles": ["level"]},
		{"id": "tone", "title": "Tone", "roles": ["tone"]},
		{"id": "character", "title": "Character", "roles": ["character"]},
		{"id": "mode", "title": "Mode", "roles": ["mode"]},
		{"id": "global", "title": "Global", "roles": ["global"]},
	]


## Tune leads its section and fine controls (Keytrack) trail; everything else keeps the device's
## own order, since a drum lists its controls the way they are played ("Punch" before "Punch
## Time", "Snappy" before its Decay).
func priority_tier(item: Dictionary) -> int:
	if item.get("role", "") == "tune":
		return 0
	var text := String(item.get("label", ""))
	if text.is_empty():
		text = String(item.get("name", ""))
	if ParamClassifier.tokens_match(ParamClassifier.name_tokens(text), fine_keywords()):
		return 2
	return 1


## Mark a drum's Tune knob to show a note name (E0) instead of raw Hz. The engine advertises
## Tune in Hz, so the note name is a display override only. A Tune in semitones (the Hat's
## transpose) keeps its own unit.
func decorate_control(control: Dictionary, params: Array) -> Dictionary:
	var ids: Array = control.get("params", [])
	if ids.size() != 1 or String(control.get("kind", "")) not in [SimpleControlKinds.KNOB, SimpleControlKinds.SLIDER]:
		return control
	for param in params:
		if param != null and int(param.id) == int(ids[0]) and role_for(param) == "tune" \
				and String(param.unit) == "Hz":
			var marked := control.duplicate()
			marked["unit"] = "note"
			return marked
	return control

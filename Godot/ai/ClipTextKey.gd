# ClipTextKey.gd
# Key / scale-degree labels and drum lane names for clip text.
class_name ClipTextKey extends RefCounted


const TIER_VEL: Array[int] = [0, 17, 30, 43, 56, 69, 82, 95, 108, 121]

const _MAJOR: Array[int] = [0, 2, 4, 5, 7, 9, 11]
const _MINOR: Array[int] = [0, 2, 3, 5, 7, 8, 10]
const _DORIAN: Array[int] = [0, 2, 3, 5, 7, 9, 10]
const _MIXO: Array[int] = [0, 2, 4, 5, 7, 9, 10]

const _DRUM_PITCH: Dictionary = {
	"KICK": 36, "BD": 36, "BASS": 36, "KICK1": 36, "KICK2": 35,
	"SNARE": 38, "SD": 38, "SN": 38, "SNARE2": 40,
	"SIDE": 37, "RIM": 37, "CLAP": 39,
	"HAT": 42, "HH": 42, "CHH": 42, "CLOSED": 42,
	"PHAT": 44, "OHAT": 46, "OH": 46, "OPEN": 46,
	"FLOOR": 41, "FLOOR2": 43, "TOM": 45, "TOM2": 47, "TOM3": 48, "TOM4": 50,
	"CRASH": 49, "CRASH2": 57, "RIDE": 51,
}

const _DRUM_LABEL: Dictionary = {
	35: "KICK2", 36: "KICK", 37: "RIM", 38: "SNARE", 39: "CLAP", 40: "SNARE2",
	41: "FLOOR", 42: "HAT", 43: "FLOOR2", 44: "PHAT", 45: "TOM", 46: "OHAT",
	47: "TOM2", 48: "TOM3", 49: "CRASH", 50: "TOM4", 51: "RIDE", 57: "CRASH2",
}


## Velocity 1–9 → default tier curve. 0 or out of range → 100.
static func tier_to_velocity(tier: int) -> int:
	if tier < 1 or tier > 9:
		return 100
	return TIER_VEL[tier]


## Nearest dynamic tier (1–9) for a MIDI velocity.
static func velocity_to_tier(velocity: int) -> int:
	var best := 7
	var best_d := 999
	for t in range(1, 10):
		var d: int = absi(velocity - TIER_VEL[t])
		if d < best_d:
			best_d = d
			best = t
	return best


## Parse `Cmin`, `Gmaj`, `F# dorian`. Empty dict if unknown.
static func parse_key(text: String) -> Dictionary:
	var s := text.strip_edges()
	if s.is_empty():
		return {}
	# Root may include #/b: C, F#, Bb
	var root := ""
	var rest := s
	if s.length() >= 2 and (s[1] == "#" or s[1] == "b" or s[1] == "B"):
		if s[1] != "B" or s.to_lower().begins_with("bb"):
			root = s.substr(0, 2)
			rest = s.substr(2)
		else:
			root = s.substr(0, 1)
			rest = s.substr(1)
	else:
		root = s.substr(0, 1)
		rest = s.substr(1)
	var semi := Midi._note_name_to_semitone(root)
	if semi < 0:
		return {}
	var qual := rest.strip_edges().to_lower()
	var intervals: Array[int] = _MAJOR
	var quality := "maj"
	if qual.begins_with("min") or qual.begins_with("aeol") or qual == "m":
		intervals = _MINOR
		quality = "min"
	elif qual.begins_with("dor"):
		intervals = _DORIAN
		quality = "dorian"
	elif qual.begins_with("mix"):
		intervals = _MIXO
		quality = "mixolydian"
	elif qual.is_empty() or qual.begins_with("maj") or qual.begins_with("ion"):
		intervals = _MAJOR
		quality = "maj"
	else:
		intervals = _MINOR if qual.begins_with("m") else _MAJOR
		quality = "min" if qual.begins_with("m") else "maj"
	return {"root": semi, "quality": quality, "intervals": intervals, "label": root + quality}


## Scale-degree token (`1`, `b3`, `#4`) for a MIDI pitch in this key.
static func degree_label(midi_note: int, key: Dictionary) -> String:
	if key.is_empty() or not key.has("root"):
		return ""
	var pc: int = posmod(midi_note - int(key.root), 12)
	var names := {
		0: "1", 1: "b2", 2: "2", 3: "b3", 4: "3", 5: "4",
		6: "#4", 7: "5", 8: "b6", 9: "6", 10: "b7", 11: "7",
	}
	return str(names.get(pc, ""))


## Pitch name, using flats when the degree is flat (Bb3 vs A#3).
static func pitch_name(midi_note: int, key: Dictionary = {}) -> String:
	var deg := degree_label(midi_note, key)
	if deg.begins_with("b"):
		return _flat_name(midi_note)
	return Midi.midi_to_note_name(midi_note)


## Resolve a lane token: `Bb3`, `b7`, `C3`, `KICK`, or `36`. -1 on failure.
static func parse_pitch(token: String, key: Dictionary = {}, hint_octave: int = 3) -> int:
	var s := token.strip_edges()
	if s.is_empty():
		return -1
	if not key.is_empty() and _is_degree_token(s):
		return _degree_to_midi(s, key, hint_octave)
	if s.is_valid_int():
		var n := s.to_int()
		return n if n >= 0 and n <= 127 else -1
	var drum: int = int(_DRUM_PITCH.get(s.to_upper(), -1))
	if drum >= 0:
		return drum
	var midi := Midi.note_name_to_midi(s)
	if midi >= 0:
		return midi
	return _degree_to_midi(s, key, hint_octave)


## Default GM-ish drum lane label, or a pitch name.
static func drum_label(midi_note: int, overrides: Dictionary = {}) -> String:
	if overrides.has(midi_note):
		return str(overrides[midi_note])
	if _DRUM_LABEL.has(midi_note):
		return str(_DRUM_LABEL[midi_note])
	return Midi.midi_to_note_name(midi_note)


## Core empty-drum lanes (KICK / SNARE / HAT).
static func default_drum_pitches() -> Array[int]:
	return [36, 38, 42]


static func _is_degree_token(token: String) -> bool:
	var s := token.strip_edges().to_lower()
	return s in [
		"1", "2", "3", "4", "5", "6", "7",
		"b2", "b3", "b5", "b6", "b7",
		"#1", "#2", "#4", "#5", "#6",
	]


static func _flat_name(midi_note: int) -> String:
	const FLATS: Array[String] = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
	var pc := posmod(midi_note, 12)
	@warning_ignore("integer_division")
	var octave := (midi_note / 12) - 2
	return FLATS[pc] + str(octave)


static func _degree_to_midi(token: String, key: Dictionary, hint_octave: int) -> int:
	if key.is_empty() or not key.has("root"):
		return -1
	var s := token.strip_edges().to_lower()
	var acc := 0
	if s.begins_with("b"):
		acc = -1
		s = s.substr(1)
	elif s.begins_with("#"):
		acc = 1
		s = s.substr(1)
	if s.is_empty() or not s.is_valid_int():
		return -1
	var deg := s.to_int()
	if deg < 1 or deg > 7:
		return -1
	# Diatonic steps from the major-degree table, then apply accidental.
	const MAJOR_OFF: Array[int] = [0, 0, 2, 4, 5, 7, 9, 11]
	var off: int = MAJOR_OFF[deg] + acc
	var pc: int = posmod(int(key.root) + off, 12)
	var midi := (hint_octave + 2) * 12 + pc
	return clampi(midi, 0, 127)

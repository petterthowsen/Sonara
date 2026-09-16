@tool
class_name Midi extends RefCounted

# MIDI Utilities - Static Functions Only
# Provides conversion between MIDI note numbers and note names

# MIDI note range
const MIDI_MIN: int = 0    # C-2
const MIDI_MAX: int = 127  # G9

# Middle C is MIDI note 60 = C3 (scientific pitch notation used in most DAWs)
const MIDDLE_C: int = 60
const MIDDLE_C_OCTAVE: int = 3

# Note names (within an octave)
const NOTE_NAMES: Array[String] = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

# ============================================================================
# MIDI NOTE CONVERSIONS
# ============================================================================

static func midi_to_note_name(midi_note: int) -> String:
	"""Convert MIDI note number to note name (e.g., 60 -> "C3")."""
	if midi_note < MIDI_MIN or midi_note > MIDI_MAX:
		return "Invalid"
	
	var note_in_octave = midi_note % 12
	@warning_ignore("integer_division")
	var octave = (midi_note / 12) - 2  # Octave offset: MIDI 0 = C-2
	
	return NOTE_NAMES[note_in_octave] + str(octave)

static func note_name_to_midi(note_name: String) -> int:
	"""Convert note name to MIDI note number (e.g., "C3" -> 60).
	Supports formats: C3, C#3, Db3, etc."""
	if note_name.is_empty():
		return -1
	
	# Parse note and octave
	var note_part = ""
	var octave_part = ""
	var i = 0
	
	# Extract note name (C, C#, Db, etc.)
	while i < note_name.length() and not note_name[i].is_valid_int():
		note_part += note_name[i]
		i += 1
	
	# Extract octave (including negative)
	octave_part = note_name.substr(i)
	
	if note_part.is_empty() or octave_part.is_empty():
		return -1
	
	# Convert note name to semitone (0-11)
	var semitone = _note_name_to_semitone(note_part)
	if semitone < 0:
		return -1
	
	# Parse octave
	var octave = octave_part.to_int()
	
	# Calculate MIDI note: (octave + 2) * 12 + semitone
	var midi_note = (octave + 2) * 12 + semitone
	
	return clamp(midi_note, MIDI_MIN, MIDI_MAX)

static func _note_name_to_semitone(note: String) -> int:
	"""Convert note name (C, C#, Db, etc.) to semitone (0-11)."""
	note = note.to_upper()
	
	# Handle sharps
	if note in NOTE_NAMES:
		return NOTE_NAMES.find(note)
	
	# Handle flats (convert to sharp equivalent)
	var flat_to_sharp = {
		"DB": "C#", "EB": "D#", "GB": "F#", "AB": "G#", "BB": "A#"
	}
	
	if note in flat_to_sharp:
		return NOTE_NAMES.find(flat_to_sharp[note])
	
	return -1

static func get_octave(midi_note: int) -> int:
	"""Get the octave number for a MIDI note (C3 = octave 3)."""
	@warning_ignore("integer_division")
	return (midi_note / 12) - 2

static func get_note_in_octave(midi_note: int) -> int:
	"""Get the note within the octave (0-11, where 0=C, 1=C#, etc.)."""
	return midi_note % 12

static func is_black_key(midi_note: int) -> bool:
	"""Check if a MIDI note is a black key on the piano."""
	var note_in_octave = midi_note % 12
	return note_in_octave in [1, 3, 6, 8, 10]  # C#, D#, F#, G#, A#

static func is_white_key(midi_note: int) -> bool:
	"""Check if a MIDI note is a white key on the piano."""
	return not is_black_key(midi_note)

# ============================================================================
# FREQUENCY CONVERSIONS
# ============================================================================

static func midi_to_frequency(midi_note: int) -> float:
	"""Convert MIDI note to frequency in Hz (A4 = 440 Hz)."""
	# Formula: f = 440 * 2^((n - 69) / 12)
	# Where 69 is MIDI note A4
	return 440.0 * pow(2.0, (midi_note - 69) / 12.0)

static func frequency_to_midi(frequency: float) -> int:
	"""Convert frequency in Hz to nearest MIDI note."""
	# Formula: n = 69 + 12 * log2(f / 440)
	var midi_note = 69 + 12 * (log(frequency / 440.0) / log(2.0))
	return roundi(clamp(midi_note, MIDI_MIN, MIDI_MAX))


static func frequency_to_note_name(frequency: float) -> String:
	var midi_note = frequency_to_midi(frequency)
	return midi_to_note_name(midi_note)


static func frequency_text(frequency: float, short := true) -> String:
	if frequency < 1000.0:
		return str(roundi(frequency)) + ("" if short else " Hz")
	else:
		return str(roundi(frequency / 1000.0)) + ("k" if short else " kHz")

# ============================================================================
# CC NAMES
# ============================================================================

## Standard MIDI CC (Control Change) names, keyed by controller number (REQ-016).
const CC_NAMES: Dictionary = {
	1: "Mod Wheel",
	2: "Breath",
	4: "Foot Controller",
	5: "Portamento Time",
	7: "Volume",
	8: "Balance",
	10: "Pan",
	11: "Expression",
	64: "Sustain",
	65: "Portamento",
	66: "Sostenuto",
	67: "Soft Pedal",
	68: "Legato",
	69: "Hold 2",
	71: "Resonance",
	72: "Release Time",
	73: "Attack Time",
	74: "Cutoff",
	75: "Decay Time",
	76: "Vibrato Rate",
	77: "Vibrato Depth",
	78: "Vibrato Delay",
	84: "Portamento Control",
	91: "Reverb",
	93: "Chorus",
	120: "All Sound Off",
	121: "Reset All Controllers",
	122: "Local Control",
	123: "All Notes Off",
}


## Standard name for controller `cc`, falling back to `CC{n}` when unassigned (REQ-016).
static func cc_name(cc: int) -> String:
	return CC_NAMES.get(cc, "CC%d" % cc)


## Display name for controller `cc`: a non-empty `device_supplied` label wins, else `cc_name`,
## prefixed with the controller number (e.g. `CC1 Mod Wheel`).
static func cc_display_name(cc: int, device_supplied: String = "") -> String:
	var label := device_supplied if device_supplied != "" else cc_name(cc)
	return "CC%d %s" % [cc, label]
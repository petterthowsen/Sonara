class_name TransferReport extends RefCounted

## What an import or export dropped or approximated (REQ-023/024). Repeats of one kind on one
## subject (track, device, ...) collapse into a single entry with a count.

# Import (REQ-023)
const PLUGIN_FORMAT := "plugin_format"            # VST2/VST3/AU device, not loadable
const CLAP_MISSING := "clap_missing"              # CLAP plugin that isn't installed
const GENERIC_DEVICE := "generic_device"          # Equalizer, Compressor, NoiseGate, Limiter
const FOREIGN_BUILTIN := "foreign_builtin"        # another vendor's BuiltinDevice
const SONARA_DEVICE_MISSING := "sonara_device_missing"
const WARP_APPROXIMATED := "warp_approximated"
const NOTE_CHANNEL := "note_channel"
const NOTE_EXPRESSION := "note_expression"
const CLIP_AUTOMATION := "clip_automation"
const EXPRESSION_AUTOMATION := "expression_automation"
const UNSUPPORTED_AUTOMATION := "unsupported_automation"  # send pan, mute, bypass, unresolved
const CROSSFADE := "crossfade"
const VCA := "vca"
const SCENE_CLIP := "scene_clip"
const MONO_CHANNEL := "mono_channel"
const BUS_CLIP := "bus_clip"
const SIGNATURE_OFF_BAR := "signature_off_bar"
const SEND_CLAMPED := "send_clamped"
const VOLUME_CLAMPED := "volume_clamped"
const NESTED_LOOP := "nested_loop"
const AUDIO_MISSING := "audio_missing"
const STATE_MISMATCH := "state_mismatch"
# Export (REQ-024)
const MARKER_DURATION := "marker_duration"
const CLIP_TRANSPOSE := "clip_transpose"
const CLIP_GAIN_OFFSET := "clip_gain_offset"
const CLIP_REVERSE := "clip_reverse"
const PAN_MODE := "pan_mode"
const HARDWARE_OUTPUT := "hardware_output"
const PHASE_INVERT := "phase_invert"
const PLUGIN_NO_STATE := "plugin_no_state"
const FILE_MISSING := "file_missing"
const MODULATORS := "modulators"
const DRUM_CHOKE_GROUP := "drum_choke_group"      # Drum Machine pad choke groups have no DAWproject mapping

## Text per kind. `{n}` is the count, `{detail}` the distinct details joined by ", ".
const TEMPLATES: Dictionary = {
	PLUGIN_FORMAT: "{detail} plugin not supported (only CLAP plugins load), skipped",
	CLAP_MISSING: "CLAP plugin {detail} is not installed, skipped",
	GENERIC_DEVICE: "{detail} device has no Sonara equivalent, skipped",
	FOREIGN_BUILTIN: "{detail} is another application's built-in device, skipped",
	SONARA_DEVICE_MISSING: "Sonara device {detail} is not available, skipped",
	WARP_APPROXIMATED: "{n} audio clips with more than two warp markers approximated by a constant stretch",
	NOTE_CHANNEL: "{n} notes on MIDI channel {detail} moved to channel 0",
	NOTE_EXPRESSION: "{n} per-note expression lanes dropped",
	CLIP_AUTOMATION: "{n} clip-level automation lanes dropped",
	EXPRESSION_AUTOMATION: "{n} expression automation lanes ({detail}) dropped",
	UNSUPPORTED_AUTOMATION: "{n} automation lanes ({detail}) dropped",
	CROSSFADE: "{n} crossfades imported as overlapping clips with ordinary fades",
	VCA: "VCA channel imported as a plain bus without its member control",
	SCENE_CLIP: "{n} clip launcher clips dropped",
	MONO_CHANNEL: "mono channel imported as stereo",
	BUS_CLIP: "{n} clips on a bus track dropped",
	SIGNATURE_OFF_BAR: "{n} time signature changes off a bar line moved to the next bar",
	SEND_CLAMPED: "{n} send levels above +12 dB clamped to +12 dB",
	VOLUME_CLAMPED: "volume above +12 dB clamped to +12 dB",
	NESTED_LOOP: "{n} looped clips holding nested clips play only their first pass",
	AUDIO_MISSING: "{detail}: audio file not found",
	STATE_MISMATCH: "{detail} state belongs to a different plugin, ignored",
	MARKER_DURATION: "{n} marker durations not exported",
	CLIP_TRANSPOSE: "{n} clip instances with transpose exported as separate transposed clips",
	CLIP_GAIN_OFFSET: "{n} clip gain offsets not exported",
	CLIP_REVERSE: "{n} reversed clip instances exported as their forward audio",
	PAN_MODE: "pan mode {detail} exported as pan position only",
	HARDWARE_OUTPUT: "hardware output routing exported as master",
	PHASE_INVERT: "phase invert not exported",
	PLUGIN_NO_STATE: "{detail} state could not be fetched, exported without it",
	FILE_MISSING: "{detail}: referenced file not found, not embedded",
	MODULATORS: "{detail}: modulators are kept only in Sonara's own state; other applications ignore them",
	DRUM_CHOKE_GROUP: "{detail}: Drum Machine choke groups are kept only in Sonara's own state; other applications ignore them",
}

var _entries: Array[Dictionary] = []
var _index: Dictionary = {}  # "kind|subject" -> position in _entries


## Record one occurrence. `subject` is the track/device/clip name; `detail` an optional
## qualifier (channel number, plugin name, ...).
func add(kind: String, subject: String = "", detail: String = "") -> void:
	var key := "%s|%s" % [kind, subject]
	var entry: Dictionary
	if _index.has(key):
		entry = _entries[_index[key]]
	else:
		entry = {"kind": kind, "subject": subject, "count": 0, "details": []}
		_index[key] = _entries.size()
		_entries.append(entry)
	entry.count += 1
	if detail != "" and not entry.details.has(detail):
		entry.details.append(detail)


func entries() -> Array[Dictionary]:
	return _entries


func is_empty() -> bool:
	return _entries.is_empty()


func count_of(kind: String) -> int:
	var n := 0
	for e in _entries:
		if e.kind == kind:
			n += e.count
	return n


func entry_text(entry: Dictionary) -> String:
	var template: String = TEMPLATES.get(entry.kind, entry.kind)
	var text := template.replace("{n}", str(entry.count)).replace("{detail}", ", ".join(entry.details))
	if entry.subject != "":
		return "%s: %s" % [entry.subject, text]
	return text


func to_text() -> String:
	var lines: PackedStringArray = []
	for e in _entries:
		lines.append(entry_text(e))
	return "\n".join(lines)

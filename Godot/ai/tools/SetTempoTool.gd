# SetTempoTool.gd
class_name SetTempoTool extends AiTool


const MIN_BPM := 20.0
const MAX_BPM := 999.0
const MAX_NUMERATOR := 32
const DENOMINATORS := [1, 2, 4, 8, 16, 32]


func get_name() -> String:
	return "set_tempo"


func get_description() -> String:
	return "Set the project tempo (BPM) and/or time signature (e.g. 3/4, 6/8). Clip notes keep their tick positions. Undoable."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"bpm": {"type": "number", "description": "Tempo in BPM, 20–999"},
			"time_signature": {"type": "string", "description": "Numerator/denominator, e.g. 4/4, 3/4, 7/8. Denominator is a power of two up to 32"},
		},
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	if not args.has("bpm") and not args.has("time_signature"):
		return fail("Pass bpm, time_signature, or both")
	var bpm := -1.0
	if args.has("bpm"):
		var raw = args.bpm
		if not (raw is float or raw is int or str(raw).is_valid_float()):
			return fail("bpm must be a number")
		bpm = float(raw)
		if bpm < MIN_BPM or bpm > MAX_BPM:
			return fail("bpm must be between %s and %s" % [_fmt_bpm(MIN_BPM), _fmt_bpm(MAX_BPM)])
	var sig: Array = []
	if args.has("time_signature"):
		var parsed = parse_time_signature(str(args.time_signature))
		if parsed is Dictionary:
			return parsed
		sig = parsed
	var editor: Editor = Sonara.editor
	var old_tempo: float = project.tempo
	var old_sig := "%d/%d" % [project.time_numerator, project.time_denominator]
	if bpm > 0.0:
		editor.set_tempo(bpm)
	if not sig.is_empty():
		editor.set_time_signature(sig[0], sig[1])
	var new_sig := "%d/%d" % [project.time_numerator, project.time_denominator]
	var bits: PackedStringArray = []
	if bpm > 0.0:
		bits.append("tempo %s → %s BPM" % [_fmt_bpm(old_tempo), _fmt_bpm(project.tempo)] if not is_equal_approx(old_tempo, project.tempo) else "tempo already %s BPM" % _fmt_bpm(project.tempo))
	if not sig.is_empty():
		bits.append("time signature %s → %s" % [old_sig, new_sig] if old_sig != new_sig else "time signature already %s" % new_sig)
	return ok_text("Set " + ", ".join(bits), {"tempo": project.tempo, "time_signature": new_sig})


## `[numerator, denominator]` from `"7/8"`, or fail(...).
static func parse_time_signature(text: String) -> Variant:
	var parts := text.strip_edges().split("/")
	if parts.size() != 2 or not parts[0].strip_edges().is_valid_int() or not parts[1].strip_edges().is_valid_int():
		return fail("time_signature must look like 4/4, got '%s'" % text)
	var num := parts[0].strip_edges().to_int()
	var den := parts[1].strip_edges().to_int()
	if num < 1 or num > MAX_NUMERATOR:
		return fail("Numerator must be 1–%d" % MAX_NUMERATOR)
	if not DENOMINATORS.has(den):
		return fail("Denominator must be one of 1, 2, 4, 8, 16, 32")
	return [num, den]


## `120` or `92.5`.
static func _fmt_bpm(bpm: float) -> String:
	if is_equal_approx(bpm, roundf(bpm)):
		return str(int(roundf(bpm)))
	return "%.2f" % bpm

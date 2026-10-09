# AudioImportDefaults.gd
# What stretch mode and clip tempo a newly imported audio file starts with (spec 029).
#
# A file name that carries a tempo ("loop_120bpm.wav", "Drums 95 BPM.wav", "bass_128_Am.wav")
# imports as Stretch at that tempo. Anything else imports as Raw with the project tempo at the
# drop position as clip tempo, so switching to Repitch or Stretch later starts at 1:1.
class_name AudioImportDefaults extends RefCounted

## Tempos outside this range are not taken from a file name (a bare number is rarely a tempo).
const MIN_NAME_BPM := 60.0
const MAX_NAME_BPM := 200.0

static var _explicit_re: RegEx = null
static var _bare_re: RegEx = null


## `{ "mode": Clip.StretchMode, "bpm": float }` for importing `path` at `project_bpm`.
static func for_file(path: String, project_bpm: float) -> Dictionary:
	var parsed := parse_tempo(path)
	if parsed > 0.0:
		return { "mode": Clip.StretchMode.STRETCH, "bpm": parsed }
	return { "mode": Clip.StretchMode.RAW, "bpm": project_bpm }


## Tempo written in the file name, or 0.0 when there is none in the 60-200 range.
## "120bpm", "120 BPM", "120_bpm" win over a bare number set off by separators ("_120_").
static func parse_tempo(path: String) -> float:
	_ensure_regexes()
	var stem := path.get_file().get_basename().to_lower()
	var explicit := _explicit_re.search(stem)
	if explicit:
		return _in_range(explicit.get_string(1).to_float())
	for m in _bare_re.search_all(stem):
		var bpm := _in_range(m.get_string(1).to_float())
		if bpm > 0.0:
			return bpm
	return 0.0


static func _in_range(bpm: float) -> float:
	return bpm if bpm >= MIN_NAME_BPM and bpm <= MAX_NAME_BPM else 0.0


static func _ensure_regexes() -> void:
	if _explicit_re != null:
		return
	_explicit_re = RegEx.create_from_string("(?<![0-9.])([0-9]{2,3}(?:\\.[0-9]+)?)[\\s_\\-]?bpm")
	_bare_re = RegEx.create_from_string("(?:^|[\\s_\\-.()\\[\\]])([0-9]{2,3})(?=$|[\\s_\\-.()\\[\\]])")

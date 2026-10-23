class_name Metronome extends RefCounted

## Spec 053: the metronome. Two kinds of state:
##   - Sound and on/off are user settings (`metronome/*` in `Settings`), the same in every project.
##     The model listens to `Settings.setting_changed` and sends them to the engine.
##   - Patterns are project data: one bar of emphasis levels per time signature, saved in the
##     `.sonara` file and sent as `/metronome/pattern`. Only edited signatures are stored; any other
##     signature plays its default pattern (REQ-013).
## UI code calls the setters here and listens to the signals; it never sends OSC itself.

## A pattern was edited, reset or replaced (including undo).
signal changed()
## A `metronome/*` setting changed (the key, without sending anything itself).
signal setting_changed(key: String)

## Emphasis levels: 0 is Off, 1 (weakest) to 4 (strongest).
const LEVEL_OFF := 0
const MAX_LEVEL := 4
## Step resolutions the engine accepts, as the note denominator (4 = quarter notes).
const RESOLUTIONS: Array[int] = [4, 8, 16]
## The engine's limit on steps in one pattern.
const MAX_STEPS := 128
## Previews are rate-limited to one per this many milliseconds (REQ-024).
const AUDITION_INTERVAL_MSEC := 150

const SOUND_BEEP := 0
const SOUND_WOOD := 1
const SOUND_LABELS: Array[String] = ["Beep", "Wood"]

const KEY_ENABLED := "metronome/enabled"
const KEY_SOUND := "metronome/sound"
const KEY_TUNE := "metronome/tune"
const KEY_DECAY := "metronome/decay"
const KEY_TONE := "metronome/tone"
const KEY_LEVEL := "metronome/level"
const KEY_EMPHASIS_VOLUME := "metronome/emphasis_volume"
const KEY_EMPHASIS_PITCH := "metronome/emphasis_pitch"
## The settings behind `/metronome/sound`, in wire order after the sound index.
const SOUND_KEYS: Array[String] = [
	KEY_SOUND, KEY_TUNE, KEY_DECAY, KEY_TONE, KEY_LEVEL, KEY_EMPHASIS_VOLUME, KEY_EMPHASIS_PITCH,
]

## Edited patterns: `"num/den"` -> `{"resolution": int, "levels": Array[int]}`.
var _patterns: Dictionary = {}

## Owning project (weak). Sends happen only while it is connected to the engine.
var _project_ref: WeakRef = null
var _last_audition_msec: int = -1000000


func _init() -> void:
	# The Settings autoload is absent in a bare `-s` script before its first frame.
	var settings := _settings()
	if settings != null:
		settings.setting_changed.connect(_on_setting_changed)


func set_project(project: Object) -> void:
	_project_ref = weakref(project) if project else null


# ============================================================================
# GRID HELPERS (pure)
# ============================================================================

## "num/den", the key of a signature.
static func signature_key(num: int, den: int) -> String:
	return "%d/%d" % [num, den]


## Steps in one bar of `num/den` at resolution `res` (the note denominator), or 0 when the
## resolution does not divide the bar into whole steps.
static func step_count(num: int, den: int, res: int) -> int:
	if num < 1 or den < 1 or res < 1 or (num * res) % den != 0:
		return 0
	return num * res / den


## Steps in one beat (the signature's denominator note): the visual group size. 1 when the
## resolution is as coarse as the beat or coarser.
static func group_size(den: int, res: int) -> int:
	return maxi(res / maxi(den, 1), 1)


## Resolutions the popup offers for `num/den` (REQ-011): not coarser than the beat, a whole step
## count, and within the engine's step limit. Empty for 32nds, which the engine cannot take over
## OSC; such a signature plays its default pattern and is not editable.
static func allowed_resolutions(num: int, den: int) -> Array[int]:
	var result: Array[int] = []
	for res in RESOLUTIONS:
		var steps := step_count(num, den, res)
		if res >= den and steps > 0 and steps <= MAX_STEPS:
			result.append(res)
	return result


## Resolution of the default pattern: the beat, or 1/4 for denominators 1 and 2 (REQ-013). It is
## 1/32 for denominator 32, as in the engine.
static func default_resolution(den: int) -> int:
	return clampi(den, 4, 32)


## The default pattern (REQ-013): level 4 on the first beat, level 2 on every other beat start.
static func default_levels(num: int, den: int) -> Array[int]:
	var steps := step_count(num, den, default_resolution(den))
	var per_beat := group_size(den, default_resolution(den))
	var levels: Array[int] = []
	for i in steps:
		levels.append((4 if i == 0 else 2) if i % per_beat == 0 else LEVEL_OFF)
	return levels


## `levels` rebuilt for resolution `to_res` from `from_res`: a step keeps the level of the old step
## that starts at the same moment, or is Off where none does. A round trip to a finer resolution
## and back loses nothing.
static func convert_levels(levels: Array, num: int, den: int, from_res: int, to_res: int) -> Array[int]:
	var steps := step_count(num, den, to_res)
	var result: Array[int] = []
	for i in steps:
		var from_pos := i * from_res
		var level := LEVEL_OFF
		if from_pos % to_res == 0:
			var source := from_pos / to_res
			if source < levels.size():
				level = int(levels[source])
		result.append(level)
	return result


## Index of the step a position inside the bar falls on, for the playhead highlight. `tick_in_bar`
## is the distance from the bar start in ticks; `ppq` ticks per quarter note.
static func step_index_at(tick_in_bar: int, res: int, ppq: int, steps: int) -> int:
	var step_ticks := ppq * 4 / maxi(res, 1)
	if step_ticks <= 0 or steps <= 0:
		return -1
	return clampi(tick_in_bar / step_ticks, 0, steps - 1)


# ============================================================================
# PATTERN QUERIES
# ============================================================================

## Whether `num/den` can be edited: it has at least one allowed resolution.
func is_editable(num: int, den: int) -> bool:
	return not allowed_resolutions(num, den).is_empty()


## True when `num/den` has an edited pattern of its own.
func is_edited(num: int, den: int) -> bool:
	return _patterns.has(signature_key(num, den))


func has_edits() -> bool:
	return not _patterns.is_empty()


## Resolution of `num/den`'s pattern (the default's when never edited).
func resolution_of(num: int, den: int) -> int:
	var entry: Variant = _patterns.get(signature_key(num, den))
	return int(entry["resolution"]) if entry != null else default_resolution(den)


## Levels of `num/den`'s pattern, a copy (the default pattern when never edited).
func levels_of(num: int, den: int) -> Array[int]:
	var entry: Variant = _patterns.get(signature_key(num, den))
	if entry == null:
		return default_levels(num, den)
	var levels: Array[int] = []
	levels.assign(entry["levels"])
	return levels


# ============================================================================
# PATTERN SETTERS
# ============================================================================
# Each one sends the pattern to the engine and emits `changed`.

## Set one step of `num/den` to `level` (0 to 4). A never-edited signature is stored first, at its
## default resolution. Ignored for a non-editable signature or an out-of-range step.
func set_step(num: int, den: int, index: int, level: int) -> void:
	if not is_editable(num, den):
		return
	var levels := levels_of(num, den)
	if index < 0 or index >= levels.size():
		return
	levels[index] = clampi(level, LEVEL_OFF, MAX_LEVEL)
	_store(num, den, resolution_of(num, den), levels)
	_commit_pattern(num, den)


## Change the resolution of `num/den`, converting the steps (see `convert_levels`). Ignored when
## the resolution is not offered for the signature.
func set_resolution(num: int, den: int, res: int) -> void:
	if res not in allowed_resolutions(num, den):
		return
	var from_res := resolution_of(num, den)
	if res == from_res and is_edited(num, den):
		return
	_store(num, den, res, convert_levels(levels_of(num, den), num, den, from_res, res))
	_commit_pattern(num, den)


## Put `num/den` back to the default pattern (REQ-014).
func reset_pattern(num: int, den: int) -> void:
	if _patterns.erase(signature_key(num, den)):
		_commit_pattern(num, den)


func _store(num: int, den: int, res: int, levels: Array[int]) -> void:
	_patterns[signature_key(num, den)] = {"resolution": res, "levels": levels}


func _commit_pattern(num: int, den: int) -> void:
	_send_pattern(signature_key(num, den))
	changed.emit()


# ============================================================================
# SETTINGS BRIDGE
# ============================================================================

func is_enabled() -> bool:
	return bool(_get_setting(KEY_ENABLED))


## Turn the metronome on or off. Goes through Settings, which saves it and calls back here.
func set_enabled(on: bool) -> void:
	_set_setting(KEY_ENABLED, on)


## Value of one `metronome/*` setting.
func get_param(key: String):
	return _get_setting(key)


## Set one `metronome/*` sound setting (clamped by Settings).
func set_param(key: String, value) -> void:
	if key in SOUND_KEYS:
		_set_setting(key, value)


## The `/metronome/sound` arguments, in wire order.
func sound_args() -> Array:
	return [
		int(_get_setting(KEY_SOUND)), float(_get_setting(KEY_TUNE)), float(_get_setting(KEY_DECAY)),
		float(_get_setting(KEY_TONE)), float(_get_setting(KEY_LEVEL)),
		float(_get_setting(KEY_EMPHASIS_VOLUME)), float(_get_setting(KEY_EMPHASIS_PITCH)),
	]


func _on_setting_changed(key: String, _value) -> void:
	if key == KEY_ENABLED:
		_send_enabled()
	elif key in SOUND_KEYS:
		_send_sound()
	else:
		return
	setting_changed.emit(key)


func _settings() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("Settings") if tree != null else null


func _get_setting(key: String):
	var settings := _settings()
	return settings.get_value(key) if settings != null else null


func _set_setting(key: String, value) -> void:
	var settings := _settings()
	if settings != null:
		settings.set_value(key, value)


# ============================================================================
# AUDITION (REQ-024)
# ============================================================================

## Ask the engine for one preview click at `level` (1 to 4), at most once per
## `AUDITION_INTERVAL_MSEC`. Returns whether it was sent. The caller decides when to preview
## (while the transport is stopped). `now_msec` is for tests.
func audition(level: int, now_msec: int = -1) -> bool:
	var now := Time.get_ticks_msec() if now_msec < 0 else now_msec
	if now - _last_audition_msec < AUDITION_INTERVAL_MSEC:
		return false
	_last_audition_msec = now
	_send("/metronome/audition", [clampi(level, 1, MAX_LEVEL)])
	return true


# ============================================================================
# SNAPSHOTS (undo)
# ============================================================================

## The patterns, deep-copied, comparable with `==`. Same shape as `to_json`, but always present.
func get_state() -> Dictionary:
	return to_json()


## Replace the patterns from a `get_state()` snapshot. Sends what differs and emits `changed` once.
func set_state(state: Dictionary) -> void:
	var before := _patterns
	_patterns = {}
	_read(state)
	var keys := {}
	for key in before:
		keys[key] = true
	for key in _patterns:
		keys[key] = true
	for key in keys:
		if before.get(key) != _patterns.get(key):
			_send_pattern(key)
	changed.emit()


# ============================================================================
# ENGINE SYNC
# ============================================================================

## The `/metronome/pattern` arguments for a stored signature key, or `[]` when it has none.
func pattern_args(key: String) -> Array:
	var entry: Variant = _patterns.get(key)
	var parts := key.split("/")
	if entry == null or parts.size() != 2:
		return []
	var args: Array = [int(parts[0]), int(parts[1]), int(entry["resolution"])]
	args.append_array(entry["levels"])
	return args


## Everything the engine needs, as `[address, args]` pairs in send order: clear, every edited
## pattern, the sound, then on/off (REQ-032).
func sync_messages() -> Array:
	var messages: Array = [["/metronome/clear", []]]
	var keys := _patterns.keys()
	keys.sort()
	for key in keys:
		messages.append(["/metronome/pattern", pattern_args(key)])
	messages.append(["/metronome/sound", sound_args()])
	messages.append(["/metronome/enabled", [1 if is_enabled() else 0]])
	return messages


func sync_to_engine() -> void:
	for message in sync_messages():
		AudioEngineOSC.send(message[0], message[1])


func _send_pattern(key: String) -> void:
	var parts := key.split("/")
	if parts.size() != 2:
		return
	var args := pattern_args(key)
	if args.is_empty():
		# No levels removes the signature's pattern.
		args = [int(parts[0]), int(parts[1]), default_resolution(int(parts[1]))]
	_send("/metronome/pattern", args)


func _send_sound() -> void:
	_send("/metronome/sound", sound_args())


func _send_enabled() -> void:
	_send("/metronome/enabled", [1 if is_enabled() else 0])


func _send(address: String, args: Array) -> void:
	var project: Object = _project_ref.get_ref() if _project_ref else null
	if project != null and project.is_connected_to_engine():
		AudioEngineOSC.send(address, args)


# ============================================================================
# SERIALIZATION
# ============================================================================

## `{"patterns": {"7/8": {"resolution": 8, "levels": [4, 0, 2, ...]}}}`.
func to_json() -> Dictionary:
	var patterns := {}
	for key in _patterns:
		var entry: Dictionary = _patterns[key]
		patterns[key] = {"resolution": int(entry["resolution"]), "levels": (entry["levels"] as Array).duplicate()}
	return {"patterns": patterns}


static func from_json(data: Dictionary) -> Metronome:
	var metronome := Metronome.new()
	metronome._read(data)
	return metronome


## Overwrite the patterns from `data` without sending or emitting (project load).
func load_json(data: Dictionary) -> void:
	_patterns = {}
	_read(data)


## Read the patterns of `data`, dropping any entry that is not valid for its signature.
func _read(data: Dictionary) -> void:
	var stored: Variant = data.get("patterns")
	if not stored is Dictionary:
		return
	for key in stored:
		var parts := str(key).split("/")
		var entry: Variant = stored[key]
		if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int() or not entry is Dictionary:
			continue
		var num := int(parts[0])
		var den := int(parts[1])
		var res := int(entry.get("resolution", 0))
		var raw: Variant = entry.get("levels")
		if not raw is Array or res not in allowed_resolutions(num, den) or raw.size() != step_count(num, den, res):
			continue
		var levels: Array[int] = []
		for value in raw:
			levels.append(clampi(int(value), LEVEL_OFF, MAX_LEVEL))
		_patterns[signature_key(num, den)] = {"resolution": res, "levels": levels}

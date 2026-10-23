class_name VirtualStage extends RefCounted

## Spec 051: the project's one virtual room. Holds the room dimensions, wall materials, listener,
## tail settings and output mode, and sends them as `/stage/set` when the project is connected.
## Source placement lives on `Channel` (`stage_*`); the Stage return is a flagged bus channel (see
## `Project.ensure_stage_return`). Coordinates are meters with the origin at the front-left floor
## corner, X to the right and Y toward the back wall; the listener faces the front wall.

## A change to any room value (including a preset switch). Views redraw and clamp sources.
signal changed()

## Output modes. The numbers are the OSC values.
enum OutputMode {
	FULL,              # Reflections and tail
	REFLECTIONS_ONLY,  # For an external reverb on the Stage return
	DIRECT_ONLY,       # Nothing reaches the Stage return
}

## Mic setups (spec 052): the stereo array the listener records with. The numbers are the OSC values.
enum MicSetup { PAN, XY, BLUMLEIN, MID_SIDE, AB, ORTF, DECCA }
const MIC_IDS: Array[String] = ["pan", "xy", "blumlein", "ms", "ab", "ortf", "decca"]
const MIC_LABELS: Array[String] = ["Pan", "XY", "Blumlein", "Mid/Side", "AB", "ORTF", "Decca tree"]

## Limits of the engine (`audio/stage/mod.rs`); it clamps to the same values.
const MAX_WIDTH := 60.0
const MAX_DEPTH := 40.0
const MAX_HEIGHT := 25.0
const MIN_DIMENSION := 2.0
const MIN_DECAY_S := 0.1
const MAX_DECAY_S := 30.0
const MIN_TAIL_DB := -60.0
const MAX_TAIL_DB := 12.0

## Source defaults when a channel first enters Stage (REQ-002).
const DEFAULT_SOURCE_HEIGHT := 1.2
const DEFAULT_STEREO_SIZE := 3.0
## Visual-only source rectangle and Section mode (spec 052).
const DEFAULT_SOURCE_DEPTH := 2.0
## Floor space one player needs: width x depth in meters.
const PLAYER_FOOTPRINT := Vector2(1.0, 1.2)
const MIN_PLAYERS := 1
const MAX_PLAYERS := 64
const DEFAULT_PLAYERS := 8
## Distance from the listener at which a source sounds as loud as it did when panned.
const REFERENCE_DISTANCE := 5.0

## Preset id (see StagePresets) the room started from, or "" for none.
var preset: String = StagePresets.DEFAULT_PRESET
## True once a value was edited after the preset was applied (REQ-015).
var modified: bool = false

var width: float = 22.0
var depth: float = 28.0
var height: float = 11.0
var listener: Vector3 = Vector3(11.0, 14.0, 1.8)
var decay_s: float = 1.6
var tail_db: float = -6.0
var distance_delay: bool = false
var output_mode: OutputMode = OutputMode.FULL
var mic_setup: MicSetup = MicSetup.PAN
## Material id per surface, in StagePresets.SURFACES order.
var materials: Array[String] = []

## Owning project (weak). Sends happen only while it is connected to the engine.
var _project_ref: WeakRef = null


func _init() -> void:
	_load_preset_values(StagePresets.DEFAULT_PRESET)


func set_project(project: Object) -> void:
	_project_ref = weakref(project) if project else null


# ============================================================================
# PRESETS
# ============================================================================

## Apply a preset: dimensions, materials, listener and tail settings. Distance delay and the
## output mode are the user's own choices and stay. Returns false for an unknown id.
func apply_preset(id: String) -> bool:
	if not StagePresets.has_preset(id):
		return false
	_load_preset_values(id)
	_commit()
	return true


## Display name of the current room, e.g. `Church` or `Church (modified)`; `Custom` with no preset.
func preset_label() -> String:
	if preset == "" or not StagePresets.has_preset(preset):
		return "Custom"
	var label := StagePresets.preset_label(preset)
	return label + " (modified)" if modified else label


func _load_preset_values(id: String) -> void:
	var p := StagePresets.preset(id)
	preset = id
	modified = false
	width = p["width"]
	depth = p["depth"]
	height = p["height"]
	var l: Array = p["listener"]
	listener = Vector3(l[0], l[1], l[2])
	decay_s = p["decay_s"]
	tail_db = p["tail_db"]
	materials.assign(p["materials"])


# ============================================================================
# SETTERS
# ============================================================================
# Every setter clamps, marks the preset modified, sends `/stage/set` and emits `changed`.

func set_room_size(w: float, d: float, h: float) -> void:
	width = clampf(w, MIN_DIMENSION, MAX_WIDTH)
	depth = clampf(d, MIN_DIMENSION, MAX_DEPTH)
	height = clampf(h, MIN_DIMENSION, MAX_HEIGHT)
	listener = clamp_point(listener)
	_edited()


func set_width(value: float) -> void:
	set_room_size(value, depth, height)


func set_depth(value: float) -> void:
	set_room_size(width, value, height)


func set_height(value: float) -> void:
	set_room_size(width, depth, value)


func set_listener(position: Vector3) -> void:
	listener = clamp_point(position)
	_edited()


func set_decay_s(value: float) -> void:
	decay_s = clampf(value, MIN_DECAY_S, MAX_DECAY_S)
	_edited()


func set_tail_db(value: float) -> void:
	tail_db = clampf(value, MIN_TAIL_DB, MAX_TAIL_DB)
	_edited()


func set_distance_delay(enabled: bool) -> void:
	distance_delay = enabled
	_edited()


func set_output_mode(mode: int) -> void:
	output_mode = clampi(mode, OutputMode.FULL, OutputMode.DIRECT_ONLY) as OutputMode
	_edited()


func set_mic_setup(mode: int) -> void:
	mic_setup = clampi(mode, MicSetup.PAN, MicSetup.DECCA) as MicSetup
	_edited()


## Set one surface (`StagePresets.SURFACES`) to a material id. Unknown surface or material: ignored.
func set_material(surface: String, material_id: String) -> void:
	var index := StagePresets.SURFACES.find(surface)
	if index < 0 or not StagePresets.has_material(material_id):
		return
	materials[index] = material_id
	_edited()


func get_material(surface: String) -> String:
	var index := StagePresets.SURFACES.find(surface)
	return materials[index] if index >= 0 else ""


## `p` clamped into the room.
func clamp_point(p: Vector3) -> Vector3:
	return Vector3(clampf(p.x, 0.0, width), clampf(p.y, 0.0, depth), clampf(p.z, 0.0, height))


## Depth (Y, m) a channel gets when it first enters Stage: `REFERENCE_DISTANCE` in front of the listener.
func default_source_depth() -> float:
	return clampf(listener.y - REFERENCE_DISTANCE, minf(0.5, depth * 0.5), maxf(depth - 0.5, depth * 0.5))


func default_source_height() -> float:
	return minf(DEFAULT_SOURCE_HEIGHT, height)


func _edited() -> void:
	modified = preset != ""
	_commit()


func _commit() -> void:
	_send()
	changed.emit()


# ============================================================================
# SNAPSHOTS (undo)
# ============================================================================

func get_state() -> Dictionary:
	return to_json()


## Apply a snapshot from get_state(). Sends once and emits `changed` once.
func set_state(state: Dictionary) -> void:
	_read(state)
	_commit()


# ============================================================================
# ENGINE SYNC
# ============================================================================

## The `/stage/set` arguments, in wire order.
func osc_args() -> Array:
	var args: Array = [
		width, depth, height, listener.x, listener.y, listener.z, decay_s, tail_db,
		1 if distance_delay else 0, int(output_mode),
	]
	for material_id in materials:
		args.append(StagePresets.gain(material_id))
		args.append(StagePresets.damping(material_id))
	args.append(int(mic_setup))
	return args


func sync_to_engine() -> void:
	AudioEngineOSC.send("/stage/set", osc_args())


func _send() -> void:
	var project: Object = _project_ref.get_ref() if _project_ref else null
	if project != null and project.is_connected_to_engine():
		sync_to_engine()


# ============================================================================
# SERIALIZATION
# ============================================================================

func to_json() -> Dictionary:
	var mats := {}
	for i in StagePresets.SURFACES.size():
		mats[StagePresets.SURFACES[i]] = materials[i]
	return {
		"preset": preset,
		"modified": modified,
		"width": width,
		"depth": depth,
		"height": height,
		"listener": [listener.x, listener.y, listener.z],
		"materials": mats,
		"decay_s": decay_s,
		"tail_db": tail_db,
		"distance_delay": distance_delay,
		"output_mode": int(output_mode),
		"mic": MIC_IDS[mic_setup],
	}


static func from_json(data: Dictionary) -> VirtualStage:
	var stage := VirtualStage.new()
	stage._read(data)
	return stage


## Overwrite the values present in `data` without sending or emitting (project load).
func load_json(data: Dictionary) -> void:
	_read(data)


## Overwrite the values present in `data`; a missing key keeps the current value.
func _read(data: Dictionary) -> void:
	preset = str(data.get("preset", preset))
	modified = bool(data.get("modified", modified))
	width = clampf(float(data.get("width", width)), MIN_DIMENSION, MAX_WIDTH)
	depth = clampf(float(data.get("depth", depth)), MIN_DIMENSION, MAX_DEPTH)
	height = clampf(float(data.get("height", height)), MIN_DIMENSION, MAX_HEIGHT)
	var l: Variant = data.get("listener")
	if l is Array and l.size() == 3:
		listener = Vector3(float(l[0]), float(l[1]), float(l[2]))
	listener = clamp_point(listener)
	decay_s = clampf(float(data.get("decay_s", decay_s)), MIN_DECAY_S, MAX_DECAY_S)
	tail_db = clampf(float(data.get("tail_db", tail_db)), MIN_TAIL_DB, MAX_TAIL_DB)
	distance_delay = bool(data.get("distance_delay", distance_delay))
	output_mode = clampi(int(data.get("output_mode", output_mode)), OutputMode.FULL, OutputMode.DIRECT_ONLY) as OutputMode
	# A missing or unknown id is Pan (older projects).
	var mic_index := MIC_IDS.find(str(data.get("mic", MIC_IDS[mic_setup])))
	mic_setup = (mic_index if mic_index >= 0 else MicSetup.PAN) as MicSetup
	var mats: Variant = data.get("materials")
	if mats is Dictionary:
		for i in StagePresets.SURFACES.size():
			var id := str(mats.get(StagePresets.SURFACES[i], materials[i]))
			materials[i] = id if StagePresets.has_material(id) else materials[i]


## True when every value equals a fresh Stage's (the project then saves no `stage` block).
func is_default() -> bool:
	return to_json() == VirtualStage.new().to_json()

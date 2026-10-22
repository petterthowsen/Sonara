class_name StagePresets extends RefCounted

## Spec 051: the room presets and the wall material table of the virtual stage.
## Pure data. A material is stored by id; `gain()` and `damping()` convert its absorption
## coefficients to the values the engine takes per surface (`/stage/set`).

## Surfaces in the order the engine expects them.
const SURFACES: Array[String] = ["front", "back", "left", "right", "floor", "ceiling"]

const DEFAULT_PRESET := "scoring_stage"
const DEFAULT_MATERIAL := "plaster"

## Material id -> {label, lo, hi}. `lo` is the absorption coefficient around 500 Hz (broadband
## level), `hi` the one around 4 kHz (how much the surface dulls the reflection).
const MATERIALS := {
	"concrete": {"label": "Concrete", "lo": 0.02, "hi": 0.05},
	"stone": {"label": "Stone", "lo": 0.02, "hi": 0.04},
	"plaster": {"label": "Plaster", "lo": 0.03, "hi": 0.05},
	"glass": {"label": "Glass", "lo": 0.04, "hi": 0.02},
	"wood": {"label": "Wood", "lo": 0.10, "hi": 0.08},
	"wood_panel": {"label": "Wood panelling", "lo": 0.15, "hi": 0.10},
	"carpet": {"label": "Carpet", "lo": 0.08, "hi": 0.60},
	"curtain": {"label": "Curtain", "lo": 0.35, "hi": 0.50},
	"audience": {"label": "Audience", "lo": 0.60, "hi": 0.85},
	"acoustic_panel": {"label": "Acoustic panel", "lo": 0.70, "hi": 0.85},
}

## Preset id -> room. `listener` is [x, y, z] in meters from the front-left floor corner,
## `materials` follows SURFACES. `tail_db` is the tail level against the reflections; it is a
## starting calibration, to be tuned by ear per preset (spec 051 T-026).
const PRESETS := {
	"scoring_stage": {
		"label": "Scoring Stage",
		"width": 22.0, "depth": 28.0, "height": 11.0,
		"listener": [11.0, 14.0, 1.8],
		"decay_s": 1.6, "tail_db": -6.0,
		"materials": ["wood_panel", "plaster", "wood_panel", "wood_panel", "wood", "plaster"],
	},
	"concert_hall": {
		"label": "Concert Hall",
		"width": 32.0, "depth": 40.0, "height": 18.0,
		"listener": [16.0, 20.0, 2.5],
		"decay_s": 2.2, "tail_db": -5.0,
		"materials": ["wood_panel", "plaster", "plaster", "plaster", "wood", "plaster"],
	},
	"church": {
		"label": "Church",
		"width": 20.0, "depth": 40.0, "height": 24.0,
		"listener": [10.0, 24.0, 1.7],
		"decay_s": 4.5, "tail_db": -4.0,
		"materials": ["stone", "stone", "stone", "stone", "stone", "plaster"],
	},
	"chamber_room": {
		"label": "Chamber Room",
		"width": 10.0, "depth": 14.0, "height": 5.0,
		"listener": [5.0, 8.0, 1.5],
		"decay_s": 0.9, "tail_db": -9.0,
		"materials": ["wood_panel", "plaster", "wood_panel", "wood_panel", "wood", "plaster"],
	},
	"studio_room": {
		"label": "Studio Room",
		"width": 6.0, "depth": 8.0, "height": 3.2,
		"listener": [3.0, 5.0, 1.4],
		"decay_s": 0.35, "tail_db": -12.0,
		"materials": ["acoustic_panel", "plaster", "curtain", "curtain", "carpet", "acoustic_panel"],
	},
}

## Preset ids in menu order.
const PRESET_ORDER: Array[String] = [
	"scoring_stage", "concert_hall", "church", "chamber_room", "studio_room",
]


static func preset_ids() -> Array[String]:
	return PRESET_ORDER.duplicate()


static func has_preset(id: String) -> bool:
	return PRESETS.has(id)


static func preset_label(id: String) -> String:
	return PRESETS[id]["label"] if PRESETS.has(id) else ""


## The preset's definition (a deep copy), or an empty Dictionary for an unknown id.
static func preset(id: String) -> Dictionary:
	return PRESETS[id].duplicate(true) if PRESETS.has(id) else {}


static func material_ids() -> Array:
	return MATERIALS.keys()


static func has_material(id: String) -> bool:
	return MATERIALS.has(id)


static func material_label(id: String) -> String:
	return MATERIALS[id]["label"] if MATERIALS.has(id) else id


## Broadband reflection gain (pressure) of a material: sqrt(1 - absorption).
static func gain(material_id: String) -> float:
	var m: Dictionary = MATERIALS.get(material_id, MATERIALS[DEFAULT_MATERIAL])
	return sqrt(clampf(1.0 - float(m["lo"]), 0.0, 1.0))


## High-frequency damping 0 (bright) to 1 (dull): the extra absorption at 4 kHz relative to the
## energy that is still reflected.
static func damping(material_id: String) -> float:
	var m: Dictionary = MATERIALS.get(material_id, MATERIALS[DEFAULT_MATERIAL])
	var lo: float = m["lo"]
	return clampf((float(m["hi"]) - lo) / maxf(1.0 - lo, 0.05), 0.0, 1.0)

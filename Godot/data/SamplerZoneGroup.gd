## SamplerZoneGroup.gd
## A named set of Sampler zones (spec 023). Carries what applies to several zones at once. Group 0
## is "Ungrouped": it always exists and has no name of its own. Plain data; SamplerMultisample owns
## the setters and the OSC.
class_name SamplerZoneGroup extends RefCounted

enum PlayMode { ALL, ROUND_ROBIN, RANDOM }

const UNGROUPED_ID := 0
const UNGROUPED_NAME := "Ungrouped"

var id: int = UNGROUPED_ID
var name: String = ""
var gain: float = 1.0
var mute: bool = false
var solo: bool = false
var play_mode: int = PlayMode.ALL


func _init(p_id: int = UNGROUPED_ID, p_name: String = "") -> void:
	id = p_id
	name = p_name


func display_name() -> String:
	return UNGROUPED_NAME if id == UNGROUPED_ID else name


## Arguments of `zone_group/{id}/set`: gain, mute, solo, play_mode.
func to_osc_args() -> Array:
	return [gain, 1 if mute else 0, 1 if solo else 0, play_mode]


## The mutable fields as a dictionary, for diffing and `set_group_fields`.
func fields() -> Dictionary:
	return {"gain": gain, "mute": mute, "solo": solo, "play_mode": play_mode}


func apply_fields(values: Dictionary) -> void:
	if values.has("name") and id != UNGROUPED_ID:
		name = str(values["name"])
	if values.has("gain"):
		gain = clampf(float(values["gain"]), 0.0, 4.0)
	if values.has("mute"):
		mute = bool(values["mute"])
	if values.has("solo"):
		solo = bool(values["solo"])
	if values.has("play_mode"):
		play_mode = clampi(int(values["play_mode"]), PlayMode.ALL, PlayMode.RANDOM)


func to_json() -> Dictionary:
	var data := fields()
	if id != UNGROUPED_ID:
		data["id"] = id
		data["name"] = name
	return data


static func from_json(data: Dictionary, p_id: int = UNGROUPED_ID) -> SamplerZoneGroup:
	var group := SamplerZoneGroup.new(int(data.get("id", p_id)), str(data.get("name", "")))
	group.apply_fields(data)
	return group

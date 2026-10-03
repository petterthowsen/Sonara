## One modulator on a device instance (spec 018): a kind (`lfo`, `adsr`, `ad`, `velocity`,
## `keytrack`, `random`), its own parameters and the routes it drives.
##
## A modulator belongs to exactly one `DeviceInstance`. Every mutator goes through the owner, so
## the model, the OSC messages and the signals stay in step; `params` and `routes` are read
## directly. A route target is relative to the owning device: `param/{id}`, `child/{i.j}/param/{id}`
## or `mod/{mod_id}/param/{id}`; the amount is −1..1 in normalized units.
class_name Modulator extends RefCounted

## Stable id within the owning device (0–7). Saved with the project.
var mod_id: int = 0

## The kind's engine id (`lfo`, `adsr`, ...).
var kind: String = ""

## Display name (`LFO 1`, `Filter Env`); unique among the owner's modulators.
var name: String = ""

## Kind parameter id -> normalized 0.0–1.0 value.
var params: Dictionary = {}

## Route target -> amount (-1..1). Amount 0 is never stored.
var routes: Dictionary = {}

var _owner_ref: WeakRef = null


## Untyped: naming `DeviceInstance` here would make the two class_name scripts reference each
## other and Godot fails to resolve the cycle.
func set_owner(owner) -> void:
	_owner_ref = weakref(owner) if owner else null


func owner():
	return _owner_ref.get_ref() if _owner_ref != null else null


## Current normalized value of kind parameter `param_id` (0.0 when unset).
func get_param(param_id: int) -> float:
	return float(params.get(param_id, 0.0))


## Amount of the route to `target` (0.0 when there is none).
func get_route(target: String) -> float:
	return float(routes.get(target, 0.0))


## The parameter descriptors of this modulator's kind (empty when the kind isn't advertised).
func get_parameters() -> Array[DeviceParameter]:
	var o = owner()
	return o.get_modulator_kind_params(kind) if o != null else ([] as Array[DeviceParameter])


func get_parameter(param_id: int) -> DeviceParameter:
	for param in get_parameters():
		if param.id == param_id:
			return param
	return null


## A modulator parameter's current normalized value (same as `get_param`, for the automation
## target's uniform interface).
func get_parameter_normalized(param_id: int) -> float:
	return get_param(param_id)


func set_param(param_id: int, value: float) -> void:
	var o = owner()
	if o != null:
		o.set_modulator_param(mod_id, param_id, value)


func set_route(target: String, amount: float) -> void:
	var o = owner()
	if o != null:
		o.set_route_amount(mod_id, target, amount)


func set_name(new_name: String) -> void:
	var o = owner()
	if o != null:
		o.rename_modulator(mod_id, new_name)

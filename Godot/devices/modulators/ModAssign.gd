## Shared assign-mode state for the Modulators UI (spec 018).
##
## Autoload-free: one static holder carries the active modulator and emits `changed` when assign
## mode begins or ends, or when a route moves. A control registers itself through `attach()` and
## from then on its ModDisplay state (ranges, colors, assign affordance) follows the model: while
## a modulator is active, dragging the control edits the route's amount through
## `DeviceInstance.set_route_amount` instead of the parameter value.
##
## The owner is the device the active modulator belongs to. A control is a target when its device
## is the owner or nested inside it, so a container's LFO reaches its children but not a sibling.
class_name ModAssign extends RefCounted

## Assign mode began/ended, or a route moved (so every attached control refreshes).
signal changed()

static var _holder: ModAssign


static func holder() -> ModAssign:
	if _holder == null:
		_holder = ModAssign.new()
	return _holder


## Owner of the active modulator (a DeviceInstance), or null when assign mode is off.
var owner_device = null
var mod_id := -1
## Modulator under the mouse in the pane (a DeviceInstance and mod id), or null/-1. Its bindings
## are shown on the controls it reaches, outside assign mode too.
var hover_device = null
var hover_mod_id := -1


# ============================================================================
# STATE
# ============================================================================

## Enter assign mode for `mod_id` on `device`.
static func begin(device, id: int) -> void:
	var h := holder()
	h.owner_device = device
	h.mod_id = id
	h.changed.emit()


## Show (or, with `hovered` false, stop showing) the bindings of `id` on `device`.
static func set_hover(device, id: int, hovered: bool) -> void:
	var h := holder()
	if hovered:
		h.hover_device = device
		h.hover_mod_id = id
	elif h.hover_device == device and h.hover_mod_id == id:
		h.hover_device = null
		h.hover_mod_id = -1
	else:
		return
	h.changed.emit()


## Modulator whose bindings the controls show: the one being assigned, else the hovered one.
## Returns {device, mod_id}, or {} when there is none.
static func focus() -> Dictionary:
	var h := holder()
	if h.owner_device != null and h.mod_id >= 0:
		return {"device": h.owner_device, "mod_id": h.mod_id}
	if h.hover_device != null and h.hover_mod_id >= 0:
		return {"device": h.hover_device, "mod_id": h.hover_mod_id}
	return {}


## Leave assign mode.
static func end() -> void:
	var h := holder()
	h.owner_device = null
	h.mod_id = -1
	h.changed.emit()


## Begin picking `mod_id` when it isn't already active, else end it (the wire button's toggle).
static func toggle(device, id: int) -> void:
	if is_active_for(device, id):
		end()
	else:
		begin(device, id)


static func is_active() -> bool:
	return holder().owner_device != null and holder().mod_id >= 0


static func active_owner():
	return holder().owner_device


static func active_mod_id() -> int:
	return holder().mod_id


static func is_active_for(device, id: int) -> bool:
	var h := holder()
	return h.owner_device != null and h.owner_device == device and h.mod_id == id


## Color of the active modulator: its index in the owning device's modulator list.
static func active_color() -> Color:
	var h := holder()
	if h.owner_device == null:
		return Color.WHITE
	var mod = h.owner_device.get_modulator(h.mod_id)
	if mod == null:
		return Color.WHITE
	var index: int = h.owner_device.modulators.find(mod)
	return ModDisplay.source_color(maxi(index, 0))


## True when `device` is the active owner or nested inside it.
static func is_target(device) -> bool:
	var h := holder()
	var walk = device
	while walk != null:
		if walk == h.owner_device:
			return true
		walk = walk.get_parent_device()
	return false


# ============================================================================
# TARGETS AND RANGES
# ============================================================================

## Route target on `device` for parameter `param_id`, relative to `owner_device`
## (`param/{id}` or `child/{i.j}/param/{id}`); "" when `device` isn't nested inside the owner.
static func relative_target(owner_device, device, param_id: int) -> String:
	if owner_device == null or device == null:
		return ""
	var path = owner_device.relative_index_path(device)
	if path == null:
		return ""
	if (path as Array).is_empty():
		return "param/%d" % param_id
	var parts: Array[String] = []
	for index in path:
		parts.append(str(index))
	return "child/%s/param/%d" % [".".join(parts), param_id]


## Every route into `(device, param_id)` from `device` itself and each ancestor that holds
## modulators, in `ModDisplay` range format ({amount, color, source, bipolar}).
static func ranges_for(device, param_id: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var walk = device
	while walk != null:
		var target := relative_target(walk, device, param_id)
		if target != "":
			for route in walk.get_routes_into(target):
				out.append({
					"amount": float(route["amount"]),
					"color": ModDisplay.source_color(int(route.get("color_index", 0))),
					"source": "%s:%d" % [walk.id, int(route.get("mod_id", 0))],
					"bipolar": bool(route.get("bipolar", false)),
				})
		walk = walk.get_parent_device()
	return out


## The focused modulator's route into `(device, param_id)` (at most one); empty when no
## modulator is hovered or being assigned. Controls show one source at a time.
static func focused_ranges_for(device, param_id: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var focused := focus()
	if focused.is_empty() or not is_instance_valid(focused["device"]):
		return out
	var source := "%s:%d" % [focused["device"].id, int(focused["mod_id"])]
	for route in ranges_for(device, param_id):
		if route["source"] == source:
			out.append(route)
			break
	return out


## Amount of the active route into `(device, param_id)`, 0 when there is none.
static func amount_for(device, param_id: int) -> float:
	var h := holder()
	if h.owner_device == null:
		return 0.0
	var target := relative_target(h.owner_device, device, param_id)
	if target == "":
		return 0.0
	var mod = h.owner_device.get_modulator(h.mod_id)
	return mod.get_route(target) if mod != null else 0.0


## Assign tooltip for `amount`: octaves for a logarithmic (Hz) parameter, else percent.
static func amount_text(device, param_id: int, amount: float) -> String:
	var param = device.get_parameter(param_id) if device != null else null
	if param != null and param.is_logarithmic:
		var base: float = device.get_parameter_normalized(param_id)
		var low: float = param.normalized_to_value(base)
		var high: float = param.normalized_to_value(clampf(base + amount, 0.0, 1.0))
		if low > 0.0 and high > 0.0:
			return "%+.1f oct" % (log(high / low) / log(2.0))
	return ModDisplay.default_amount_text(amount)


# ============================================================================
# CONTROL WIRING
# ============================================================================

## Wire `node` (a ModDisplay-aware knob/slider/fader) to parameter `param_id` of `device`.
## Assign drags write the active route; ranges and colors follow the model afterwards.
static func attach(node: Control, device, param_id: int) -> void:
	if node == null or device == null:
		return
	var param = device.get_parameter(param_id)
	if param == null or not param.is_modulatable:
		return
	# Guard against stacking connections when a control is attached more than once.
	if node.get_meta("mod_attached", false):
		return
	node.set_meta("mod_attached", true)
	if "mod_amount_text_callback" in node:
		node.set("mod_amount_text_callback", func(amount) -> String:
			return amount_text(device, param_id, amount))
	node.mod_amount_changed.connect(func(amount: float): _on_node_amount_changed(amount, node, device, param_id))
	var on_changed: Callable = func(): _refresh_node(node, device, param_id)
	var on_route: Callable = func(_id, _target, _amount): _refresh_node(node, device, param_id)
	holder().changed.connect(on_changed)
	device.route_changed.connect(on_route)
	# The holder outlives the control, so drop its connection as the control leaves the tree.
	node.tree_exiting.connect(func():
		if holder().changed.is_connected(on_changed):
			holder().changed.disconnect(on_changed)
		if is_instance_valid(device) and device.route_changed.is_connected(on_route):
			device.route_changed.disconnect(on_route))
	_refresh_node(node, device, param_id)


static func _on_node_amount_changed(amount: float, node: Control, device, param_id: int) -> void:
	var h := holder()
	if h.owner_device == null:
		return
	var target := relative_target(h.owner_device, device, param_id)
	if target == "":
		return
	h.owner_device.set_route_amount(h.mod_id, target, amount)
	_refresh_node(node, device, param_id)


static func _refresh_node(node: Control, device, param_id: int) -> void:
	if node == null or not is_instance_valid(node):
		return
	var param = device.get_parameter(param_id) if device != null else null
	var live: bool = is_active() and param != null and param.is_modulatable and is_target(device)
	node.mod_ranges = focused_ranges_for(device, param_id)
	_refresh_hint(node, device, param_id)
	node.mod_assign_active = live
	if live:
		node.mod_assign_color = active_color()
		node.mod_assign_amount = amount_for(device, param_id)


## Amount readout and colour of the focused modulator's route into this control (cleared when
## it has none).
static func _refresh_hint(node: Control, device, param_id: int) -> void:
	var text := ""
	var focused := focus()
	if not focused.is_empty() and is_instance_valid(focused["device"]):
		var owner = focused["device"]
		var mod = owner.get_modulator(int(focused["mod_id"]))
		var target := relative_target(owner, device, param_id)
		if mod != null and target != "" and mod.routes.has(target) and absf(mod.get_route(target)) > 0.001:
			text = amount_text(device, param_id, mod.get_route(target))
			node.mod_hint_color = ModDisplay.source_color(maxi(owner.modulators.find(mod), 0))
	node.mod_hint_text = text


## Re-emit `changed` so every attached control redraws (the pane calls this after editing a
## route, including on a nested device whose own signal doesn't reach the controls).
static func notify_changed() -> void:
	holder().changed.emit()

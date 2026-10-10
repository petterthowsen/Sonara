## Payload for dragging a modulator panel to swap it with a sibling (spec 033, phase 2). Nothing
## moves until the drop: `resolve` maps the mouse to a target panel, `commit` swaps the two array
## entries through `DeviceInstance.swap_modulators`. The pane is the single drop host — a drop on a
## placeholder, on the dragged panel itself, on another device's panel or outside the grid resolves
## to nothing (no cleanup needed; a cancelled drag only frees the ghost).
class_name ModulatorDrag extends RefCounted

## Device instance id the drag came from.
var device_id: String = ""
## The dragged modulator's stable id (0–7).
var mod_id: int = -1
var pane: Control = null
## Ghost that follows the cursor (the pane positions it in `_input`).
var preview: Control = null
## True after a drop changed something.
var did_commit: bool = false


func _init(_pane: Control, _device_id: String, _mod_id: int, _preview: Control) -> void:
	pane = _pane
	device_id = _device_id
	mod_id = _mod_id
	preview = _preview


## Where a drop lands.
class Target extends RefCounted:
	var valid := false
	## The panel the drop lands on (the drop indicator outlines it).
	var panel: Control = null
	var mod_id: int = -1
	var indicator_rect: Rect2 = Rect2()

	func is_valid() -> bool:
		return valid

	## Swap the dragged modulator with the target's; true when something changed.
	func commit(drag: ModulatorDrag) -> bool:
		if not valid or drag == null or drag.pane == null or drag.pane.device == null:
			return false
		if drag.pane.device.get_modulator(drag.mod_id) == null \
				or drag.pane.device.get_modulator(mod_id) == null:
			return false
		drag.pane.device.swap_modulators(drag.mod_id, mod_id)
		drag.did_commit = true
		return true


## Start dragging `mod` from its panel: build the ghost and the payload.
static func start(pane: Control, mod: Modulator) -> ModulatorDrag:
	if pane == null or pane.device == null or mod == null:
		return null
	var drag := ModulatorDrag.new(pane, pane.device.id, mod.mod_id, make_preview(mod))
	pane.add_child(drag.preview)
	drag.preview.global_position = pane.get_global_mouse_position() + Vector2(-12, -12)
	return drag


## Resolve the drop target at global `mouse` inside `pane`: the visible panel under the pointer
## that isn't the dragged one. Placeholders, another device's panels and empty space stay invalid.
static func resolve(pane: Control, drag: ModulatorDrag, global_mouse: Vector2) -> Target:
	var target := Target.new()
	if pane == null or drag == null or pane.device == null or pane.device.id != drag.device_id:
		return target
	if not DragDrop.is_point_visible(pane, global_mouse):
		return target
	for panel in pane._tiles:
		if not DragDrop.is_point_visible(panel, global_mouse):
			continue
		if panel.modulator == null or panel.modulator.mod_id == drag.mod_id:
			return target
		target.valid = true
		target.panel = panel
		target.mod_id = panel.modulator.mod_id
		target.indicator_rect = panel.get_global_rect()
		return target
	return target


## Ghost label that follows the cursor.
static func make_preview(mod: Modulator) -> Control:
	var ghost := PanelContainer.new()
	var label_node := Label.new()
	label_node.text = mod.name if mod != null else "Modulator"
	label_node.add_theme_font_size_override("font_size", 12)
	ghost.add_child(label_node)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.2, 0.24, 0.3, 0.95)
	style.set_corner_radius_all(4)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	ghost.add_theme_stylebox_override("panel", style)
	ghost.top_level = true
	ghost.z_index = 1000
	ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return ghost

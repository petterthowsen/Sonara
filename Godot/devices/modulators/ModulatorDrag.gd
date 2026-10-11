## Payload for dragging a modulator panel to a sibling (spec 033 phase 2; pairs in 036). Nothing
## moves until the drop: `resolve` maps the mouse to a target panel, `commit` swaps two plain
## modulators or moves a block (an XY pad's two slots) through `DeviceInstance`. The pane is the
## single drop host — a drop on a placeholder, on the dragged panel itself, on another device's
## panel or outside the grid resolves to nothing (no cleanup needed; a cancelled drag only frees
## the ghost).
class_name ModulatorDrag extends RefCounted

## Device instance id the drag came from.
var device_id: String = ""
## The dragged block's first modulator id (the X slot for a pair, else the modulator itself).
var mod_id: int = -1
## Entries the block spans: 1 for a plain modulator, 2 for an XY pad pair.
var mod_count: int = 1
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

	## Swap with the target (two plain modulators) or move the block next to it — a swap would
	## split a pair (spec 036 D4). True when something changed.
	func commit(drag: ModulatorDrag) -> bool:
		if not valid or drag == null or drag.pane == null or drag.pane.device == null:
			return false
		var device = drag.pane.device
		if device.get_modulator(drag.mod_id) == null or device.get_modulator(mod_id) == null:
			return false
		var from_index: int = device._modulator_index(drag.mod_id)
		var target_index: int = device._modulator_index(mod_id)
		if from_index < 0 or target_index < 0:
			return false
		var target_count := 1
		for pad in device.xy_pairs():
			if pad.x.mod_id == mod_id or pad.y.mod_id == mod_id:
				target_count = 2
		if drag.mod_count == 1 and target_count == 1:
			device.swap_modulators(drag.mod_id, mod_id)
		else:
			# The dragged block takes the target's place: the target index, adjusted for the
			# dragged block having been removed before it (keeping pairs adjacent either way).
			var to_index := target_index - drag.mod_count if target_index > from_index else target_index
			device.move_modulator_block(from_index, drag.mod_count, to_index)
		drag.did_commit = true
		return true


## Start dragging `mod` from its panel: build the ghost and the payload. A pair drags as one
## block of two entries, whichever slot it started from.
static func start(pane: Control, mod: Modulator) -> ModulatorDrag:
	if pane == null or pane.device == null or mod == null:
		return null
	var block := block_for(pane.device, mod)
	var drag := ModulatorDrag.new(pane, pane.device.id, block[0], make_preview(mod))
	drag.mod_count = block[1]
	pane.add_child(drag.preview)
	drag.preview.global_position = pane.get_global_mouse_position() + Vector2(-12, -12)
	return drag


## The contiguous block `mod` belongs to as `[start_mod_id, count]`: a pair's two slots
## (`xyx`+`xyy` adjacent) or the single modulator.
static func block_for(device, mod: Modulator) -> Array:
	for pad in device.xy_pairs():
		if pad.x == mod or pad.y == mod:
			return [pad.x.mod_id, 2]
	return [mod.mod_id, 1]


## Resolve the drop target at global `mouse` inside `pane`: the visible panel under the pointer
## that isn't part of the dragged block. Placeholders, another device's panels and empty space
## stay invalid.
static func resolve(pane: Control, drag: ModulatorDrag, global_mouse: Vector2) -> Target:
	var target := Target.new()
	if pane == null or drag == null or pane.device == null or pane.device.id != drag.device_id:
		return target
	if not DragDrop.is_point_visible(pane, global_mouse):
		return target
	for panel in pane._tiles:
		if not DragDrop.is_point_visible(panel, global_mouse):
			continue
		if panel.modulator == null or panel.represents(drag.mod_id):
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

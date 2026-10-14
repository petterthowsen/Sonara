## Payload for dragging a modulator panel to another grid cell (spec 033 phase 2; pairs in 036).
## Nothing moves until the drop: `resolve` maps the mouse to a target cell — a panel (the two swap
## cells) or a placeholder (the panel moves there) — and `commit` moves the tile (an XY pad's two
## slots together) through `DeviceInstance.move_modulator_to_cell`. The pane is the single drop
## host — a drop on the dragged panel itself, on another device's grid or outside the grid
## resolves to nothing (no cleanup needed; a cancelled drag only frees the ghost).
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
	## The panel or placeholder the drop lands on (the drop indicator outlines it).
	var panel: Control = null
	## The target panel's modulator, or −1 over a placeholder.
	var mod_id: int = -1
	## Grid cell the dragged tile moves to.
	var cell: int = -1
	var indicator_rect: Rect2 = Rect2()

	func is_valid() -> bool:
		return valid

	## Move the dragged tile to the target cell; a tile there takes the dragged one's old cell.
	## Pairs move whole, so they never split (spec 036 D4). True when something changed.
	func commit(drag: ModulatorDrag) -> bool:
		if not valid or drag == null or drag.pane == null or drag.pane.device == null:
			return false
		if not drag.pane.device.move_modulator_to_cell(drag.mod_id, cell):
			return false
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


## Resolve the drop target at global `mouse` inside `pane`: the visible panel (not the dragged
## one) or placeholder under the pointer. Another device's grid and empty space stay invalid.
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
		target.cell = panel.modulator.cell
		target.indicator_rect = panel.get_global_rect()
		return target
	for placeholder in pane._placeholders:
		if not DragDrop.is_point_visible(placeholder, global_mouse):
			continue
		target.valid = true
		target.panel = placeholder
		target.cell = int(placeholder.get_meta(&"cell", -1))
		target.indicator_rect = placeholder.get_global_rect()
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

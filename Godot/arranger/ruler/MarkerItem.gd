# MarkerItem.gd
# One song marker on the marker lane: labeled range with draggable edges and body.
class_name MarkerItem extends Control

signal range_gesture_finished(marker: SongMarker, old_start: int, old_duration: int, gesture_label: String)

const RESIZE_EDGE_SIZE := 8.0
const DRAG_THRESHOLD := 10.0

@onready var panel: PanelContainer = $Panel
@onready var name_edit: SmartLineEdit = $Panel/MarginContainer/NameEdit

var song_marker: SongMarker = null
var grid_helper: GridHelper = null

var _is_resizing := false
var _resize_edge := ""
var _resize_start_global: Vector2 = Vector2.ZERO
var _resize_start_ticks: int = 0
var _resize_start_duration: int = 0

var _is_dragging := false
var _drag_activated := false
var _drag_start_global: Vector2 = Vector2.ZERO
var _drag_start_ticks: int = 0
var _drag_start_duration: int = 0

var _name_before_edit: String = ""
var _last_click_time: float = 0.0
const DOUBLE_CLICK_THRESHOLD := 0.3


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	if name_edit:
		name_edit.value_type = SmartLineEdit.ValueType.STRING
		name_edit.edit_via_click = true
		name_edit.value_changed.connect(_on_name_committed)
		name_edit.line_edit.focus_entered.connect(_on_name_edit_focus_entered)


## Bind UI to marker data and shared grid state.
func bind(marker: SongMarker, gh: GridHelper) -> void:
	if song_marker and song_marker.name_changed.is_connected(_on_marker_name_changed):
		song_marker.name_changed.disconnect(_on_marker_name_changed)
	if song_marker and song_marker.color_changed.is_connected(_on_marker_color_changed):
		song_marker.color_changed.disconnect(_on_marker_color_changed)
	if song_marker and song_marker.range_changed.is_connected(_on_marker_range_changed):
		song_marker.range_changed.disconnect(_on_marker_range_changed)

	song_marker = marker
	grid_helper = gh

	if song_marker:
		if not song_marker.name_changed.is_connected(_on_marker_name_changed):
			song_marker.name_changed.connect(_on_marker_name_changed)
		if not song_marker.color_changed.is_connected(_on_marker_color_changed):
			song_marker.color_changed.connect(_on_marker_color_changed)
		if not song_marker.range_changed.is_connected(_on_marker_range_changed):
			song_marker.range_changed.connect(_on_marker_range_changed)

	if is_inside_tree():
		_refresh_from_marker()


## Open the name field for editing (e.g. right after create).
func begin_name_edit() -> void:
	if name_edit:
		_name_before_edit = song_marker.name if song_marker else ""
		name_edit.start_editing()


## Reposition/size from tick range and current scroll/zoom.
func refresh_layout() -> void:
	if song_marker == null or grid_helper == null:
		return
	var x := grid_helper.ticks_to_pixels(song_marker.start_ticks) - grid_helper.scroll_position
	var w := grid_helper.ticks_to_pixels(song_marker.duration_ticks)
	var lane_h := size.y
	if get_parent():
		lane_h = get_parent().size.y
	position = Vector2(x, 0.0)
	size = Vector2(maxi(4.0, w), lane_h)
	custom_minimum_size = Vector2(maxi(4.0, w), 22)


func _refresh_from_marker() -> void:
	if song_marker == null:
		return
	_apply_panel_color()
	if name_edit:
		name_edit.set_value(song_marker.name)
		var font_col := Utils.contrasting_text_color(song_marker.color)
		name_edit.set_font_color(font_col)
	refresh_layout()


func _apply_panel_color() -> void:
	if panel == null or song_marker == null:
		return
	var style := panel.get_theme_stylebox("panel")
	if style == null:
		style = StyleBoxFlat.new()
	elif not (style is StyleBoxFlat):
		style = style.duplicate()
	else:
		style = style.duplicate()
	var flat := style as StyleBoxFlat
	flat.bg_color = song_marker.color
	panel.add_theme_stylebox_override("panel", flat)


func _get_edge_at(local_pos: Vector2) -> String:
	if local_pos.x <= RESIZE_EDGE_SIZE:
		return "left"
	if local_pos.x >= size.x - RESIZE_EDGE_SIZE:
		return "right"
	return ""


func _min_duration_ticks() -> int:
	if grid_helper:
		return grid_helper.get_ticks_per_beat()
	return 960


func _marker_track() -> MarkerTrack:
	return get_parent() as MarkerTrack


func _track_local_x_from_event(event: InputEventMouse) -> float:
	var track := _marker_track()
	if track:
		return track.get_local_mouse_position().x
	return event.position.x


func _gui_input(event: InputEvent) -> void:
	if song_marker == null or grid_helper == null:
		return

	if event is InputEventMouseMotion:
		_update_cursor(get_local_mouse_position())

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if event.ctrl_pressed or event.meta_pressed:
				var track := _marker_track()
				if track:
					track.start_additive_gesture(_track_local_x_from_event(event))
				accept_event()
				return

			var edge := _get_edge_at(get_local_mouse_position())
			if edge != "":
				_is_resizing = true
				_resize_edge = edge
				_resize_start_global = event.global_position
				_resize_start_ticks = song_marker.start_ticks
				_resize_start_duration = song_marker.duration_ticks
				accept_event()
				return

			var now := Time.get_ticks_msec() / 1000.0
			if now - _last_click_time < DOUBLE_CLICK_THRESHOLD:
				_last_click_time = 0.0
				begin_name_edit()
				accept_event()
				return
			_last_click_time = now

			_is_dragging = true
			_drag_activated = false
			_drag_start_global = event.global_position
			_drag_start_ticks = song_marker.start_ticks
			_drag_start_duration = song_marker.duration_ticks
			accept_event()
		else:
			if _is_resizing:
				_finish_resize_gesture()
				accept_event()
			elif _is_dragging:
				_finish_drag_gesture()
				accept_event()

	elif event is InputEventMouseMotion and _is_resizing:
		_apply_resize(event.global_position)
		accept_event()

	elif event is InputEventMouseMotion and _is_dragging:
		var delta = event.global_position - _drag_start_global
		if not _drag_activated and delta.length() > DRAG_THRESHOLD:
			_drag_activated = true
		if _drag_activated:
			_apply_move(delta.x)
			accept_event()


func _apply_resize(global_pos: Vector2) -> void:
	var track := _marker_track()
	if track == null:
		return
	var pixel_delta := global_pos.x - _resize_start_global.x
	var tick_delta := grid_helper.pixels_to_ticks(pixel_delta)
	var min_dur := _min_duration_ticks()
	var fixed_end := _resize_start_ticks + _resize_start_duration

	if _resize_edge == "left":
		var new_start := _resize_start_ticks + tick_delta
		var clamped := track.clamp_marker_left_resize(
			song_marker, new_start, fixed_end, _resize_start_ticks, min_dur
		)
		song_marker.set_range(clamped.x, clamped.y, min_dur)
	elif _resize_edge == "right":
		var new_duration := _resize_start_duration + tick_delta
		var end_ticks := _resize_start_ticks + new_duration
		new_duration = track.clamp_marker_right_resize(
			song_marker, _resize_start_ticks, end_ticks, fixed_end, min_dur
		)
		song_marker.set_range(_resize_start_ticks, new_duration, min_dur)

	refresh_layout()


func _apply_move(pixel_delta_x: float) -> void:
	var track := _marker_track()
	if track == null:
		return
	var tick_delta := grid_helper.pixels_to_ticks(pixel_delta_x)
	var new_start := _drag_start_ticks + tick_delta
	var min_dur := _min_duration_ticks()
	new_start = track.clamp_marker_move(song_marker, new_start, _drag_start_duration, min_dur)
	song_marker.set_range(new_start, _drag_start_duration, min_dur)
	refresh_layout()


func _finish_resize_gesture() -> void:
	_is_resizing = false
	_resize_edge = ""
	if (
		song_marker.start_ticks != _resize_start_ticks
		or song_marker.duration_ticks != _resize_start_duration
	):
		range_gesture_finished.emit(
			song_marker, _resize_start_ticks, _resize_start_duration, "Resize Marker"
		)


func _finish_drag_gesture() -> void:
	if _drag_activated and (
		song_marker.start_ticks != _drag_start_ticks
		or song_marker.duration_ticks != _drag_start_duration
	):
		range_gesture_finished.emit(
			song_marker, _drag_start_ticks, _drag_start_duration, "Move Marker"
		)
	_is_dragging = false
	_drag_activated = false


func _update_cursor(local_pos: Vector2) -> void:
	if _is_resizing or _is_dragging and _drag_activated:
		mouse_default_cursor_shape = Control.CURSOR_HSIZE if _is_resizing else Control.CURSOR_MOVE
		return
	var edge := _get_edge_at(local_pos)
	if edge != "":
		mouse_default_cursor_shape = Control.CURSOR_HSIZE
	else:
		mouse_default_cursor_shape = Control.CURSOR_MOVE


func _on_marker_name_changed(new_name: String) -> void:
	if name_edit and not name_edit.is_editing:
		name_edit.set_value(new_name)


func _on_marker_color_changed(_color: Color) -> void:
	_apply_panel_color()
	if name_edit and song_marker:
		name_edit.set_font_color(Utils.contrasting_text_color(song_marker.color))


func _on_marker_range_changed(_start: int, _duration: int) -> void:
	refresh_layout()


func _on_name_edit_focus_entered() -> void:
	if song_marker:
		_name_before_edit = song_marker.name


func _on_name_committed(new_name: Variant) -> void:
	if song_marker == null:
		return
	var new_str := str(new_name).strip_edges()
	if new_str.is_empty():
		new_str = "Marker"
	if new_str == _name_before_edit:
		return
	HistoryUtil.execute_property("Rename Marker", song_marker, "set_name", _name_before_edit, new_str)

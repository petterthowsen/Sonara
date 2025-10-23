# Midi Editor
# 
# Composed of a VPiano (Vertical Piano keys) on the left side
# and NoteArea: NoteLanes, GridRenderer and NoteContainer
#
# designed to have a ScrollContainer with only vertical scroll enabled
# I.E VPiano, and notte_area nodes are as tall as the keyboard
#
# vertical zoom is handled by inc/dec the note lane/piano key heights in sync
#
# horizontal zoom handled by h_scroll
class_name MidiEditor extends ScrollContainer

@onready var v_piano: VPiano = $HBox/VPiano
@onready var note_area: Control = $HBox/NoteArea
@onready var note_lanes: NoteLanes = $HBox/NoteArea/NoteLanes
@onready var grid_renderer: GridRenderer = $HBox/NoteArea/GridRenderer

@onready var h_scroll: ScrollContainer = $HBox/NoteArea/HScroll
@onready var note_editor: NoteContainer = $HBox/NoteArea/HScroll/NoteEditor

var grid_helper: GridHelper:
	set(gh):
		if grid_helper != gh:
			grid_helper = gh
			note_lanes.grid_helper = gh
			note_editor.grid_helper = gh
			grid_renderer.set_grid_helper(gh)
			grid_helper.changed.connect(_on_grid_helper_changed)

# Local cursor position (in ticks) - propagated to NoteEditor
var cursor_position_ticks: int = 0:
	set(value):
		cursor_position_ticks = value
		note_editor.cursor_position_ticks = cursor_position_ticks


func _ready():
	# Connect to horizontal scroll events for infinite scrolling
	if h_scroll:
		h_scroll.get_h_scroll_bar().value_changed.connect(_on_h_scroll_changed)


func _on_grid_helper_changed():
	pass


func _on_h_scroll_changed(_value: float):
	"""Update container width when scrolling horizontally."""
	note_editor.update_container_width()


# note height: synced to v_piano, note_lanes and note_editor
var note_height_min := 8
var note_height_max := 40
@export var note_height := 20:
	set(nh):
		if note_height != nh:
			note_height = clamp(nh, note_height_min, note_height_max)
			v_piano.key_height = note_height
			note_lanes.key_height = note_height
			note_editor.note_height = note_height

var scroll_speed_notes = 2

var scroll_speed_v : int:
	get:
		return scroll_speed_notes * note_height

var scroll_speed_h = 100

# The clip instance that opened this editor (for context, not edited directly)
var clip_instance: ClipInstance = null

# Convenience to get the Clip of clip_instance
var clip: Clip:
	get:
		return clip_instance.clip if clip_instance else null
	set(clip):
		pass

func unbind():
	clip = null
	clip_instance = null
	note_editor.unbind()

func bind_to_clip_instance(ci : ClipInstance):
	if clip_instance:
		unbind()
	
	clip_instance = ci
	note_editor.bind(clip_instance)
	
	call_deferred("scroll_to_note")


# set vertical scroll to the given note, or default to average note or C3 if no notes
func scroll_to_note(note: int = -1):
	if note == -1:
		if not clip or not clip.midi_notes.size():
			note = 60
		else:
			note = clip.find_average_note()
	
	var y = note_editor.note_to_y(note)
	var target_scroll = y - (size.y * 0.5)
	scroll_vertical = max(0, target_scroll)


func set_horizontal_zoom(new_pixels_per_beat: float) -> void:
	"""Set horizontal zoom level using GridHelper."""
	if grid_helper:
		grid_helper.pixels_per_beat = clamp(new_pixels_per_beat, 8.0, 512.0)

func _zoom_vertical(delta_note_height: int):
	"""Zoom vertically while maintaining the visual position of notes at the mouse cursor."""
	var note_editor_mouse_pos = note_editor.get_local_mouse_position()
	
	# Store the old note height for ratio calculation
	var old_note_height = note_height
	
	# Apply zoom
	note_height += delta_note_height
	note_height = clamp(note_height, note_height_min, note_height_max)
	
	# If we hit the limits, don't adjust scroll
	if note_height == old_note_height:
		return

	# Calculate the zoom ratio
	var zoom_ratio = float(note_height) / float(old_note_height)
	
	# Calculate the new scroll position to keep the same note under the mouse
	# Use the zoom ratio to calculate the expected change in note position
	# The note position should scale by the zoom ratio
	var old_note_y = note_editor_mouse_pos.y
	var new_note_y = old_note_y * zoom_ratio
	
	# Calculate the scroll offset needed to keep the note under the mouse
	var scroll_offset = new_note_y - note_editor_mouse_pos.y
	
	# Apply the scroll offset to the current scroll position
	var target_scroll = scroll_vertical + scroll_offset
	
	# Apply the new scroll position
	scroll_vertical = max(0, target_scroll)



func _gui_input(event: InputEvent):
	if event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			if event.alt_pressed:
				# alt scroll up: scroll left
				h_scroll.scroll_horizontal -= scroll_speed_h
				# sync to grid helper
				grid_helper.scroll_position = h_scroll.scroll_horizontal
			elif event.shift_pressed:
				# horizontal zoom in
				set_horizontal_zoom(grid_helper.pixels_per_beat * 1.1)
			elif event.ctrl_pressed:
				# vertical zoom in
				_zoom_vertical(1)
			else:
				# vertical scroll up
				scroll_vertical -= scroll_speed_v
			accept_event()
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if event.alt_pressed:
				# alt scroll down: scroll right
				h_scroll.scroll_horizontal += scroll_speed_h
				# sync to grid helper
				grid_helper.scroll_position = h_scroll.scroll_horizontal
			elif event.shift_pressed:
				# horizontal zoom out
				set_horizontal_zoom(grid_helper.pixels_per_beat * 0.9)
			elif event.ctrl_pressed:
				# vertical zoom out
				_zoom_vertical(-1)
			else:
				# scroll down
				scroll_vertical += scroll_speed_v
			accept_event()

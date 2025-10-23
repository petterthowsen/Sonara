class_name ClipEditor extends HBoxContainer

# left panel will show track list when showing multiple clips, with buttons to switch between clips
@onready var left_panel: PanelContainer = $LeftPanel

# main panel shows ruler and midi editor
@onready var main_panel: PanelContainer = $MainPanel

@onready var ruler: Ruler = $MainPanel/VBox/Ruler
@onready var midi_editor = $MainPanel/VBox/MidiEditor

var grid_helper: GridHelper:
	set(gh):
		if grid_helper != gh:
			grid_helper = gh
			midi_editor.grid_helper = gh
			ruler.set_grid_helper(gh)

# Local cursor position (in ticks) - separate from main playhead
# Used for paste operations and other editing functions
var cursor_position_ticks: int = 0:
	set(value):
		cursor_position_ticks = value
		# Update NoteEditor's cursor
		if midi_editor:
			midi_editor.cursor_position_ticks = cursor_position_ticks

# Store pending clip instance until we become visible
var pending_clip_instance: ClipInstance = null

func _ready():
	grid_helper = GridHelper.new()
	
	# Connect GridHelper signals
	grid_helper.changed.connect(_on_grid_helper_changed)
	
	# Connect to visibility changes
	visibility_changed.connect(_on_visibility_changed)
	
	# Connect to Ruler's click event to update cursor position
	ruler.start_position_requested.connect(_on_ruler_position_requested)
	
	if Sonara.editor:
		Sonara.editor.clip_instance_selected.connect(_on_editor_clip_instance_selected)
		Sonara.editor.tempo_changed.connect(_on_editor_tempo_changed)
		Sonara.editor.time_signature_changed.connect(_on_editor_time_signature_changed)


func _on_editor_clip_instance_selected(clip_instance : ClipInstance):
	# Store the clip instance - will bind when we become visible
	pending_clip_instance = clip_instance
	
	# If we're already visible, bind immediately
	if is_visible_in_tree():
		_bind_pending_clip()


func _on_editor_tempo_changed(tempo : float):
	if is_visible_in_tree() or true:
		grid_helper.tempo = tempo
	

func _on_editor_time_signature_changed(numerator : int, denominator : int):
	if is_visible_in_tree() or true:
		grid_helper.time_numerator = numerator
		grid_helper.time_denominator = denominator

func _on_visibility_changed():
	"""Handle visibility changes - bind pending clip when becoming visible."""
	if is_visible_in_tree():
		# focus the note editor
		midi_editor.note_editor.call_deferred("grab_focus")

		# bind the pending clip
		if pending_clip_instance:
			call_deferred("_bind_pending_clip")
	
func _bind_pending_clip():
	"""Bind the pending clip instance to the midi editor."""
	if not pending_clip_instance:
		return
		
	midi_editor.bind_to_clip_instance(pending_clip_instance)

	# Clear pending clip
	pending_clip_instance = null

func _on_grid_helper_changed():
	"""GridHelper changes are handled automatically via signals."""
	pass


func _on_ruler_position_requested(ticks: int):
	"""Handle ruler clicks - set cursor position."""
	cursor_position_ticks = ticks
	print("[ClipEditor] Cursor position set to tick %d" % ticks)

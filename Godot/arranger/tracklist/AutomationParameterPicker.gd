# AutomationParameterPicker.gd
# The "what should this lane drive?" popup (REQ-015, REQ-016), a PopupPanel with a search field
# above a scrolling list. What it lists comes from `AutomationParameterTree` (labelled dividers per
# category, devices in chain order, slot children as submenus when the list is hierarchical - the
# `appearance/automation_parameter_list` setting); this node only shows one level of it at a time.
#
# A submenu opens in place (a Back button and the level's path appear above the list) rather than
# in a cascading popup, so the search box and the keyboard work the same on every level.
# Searching is fuzzy over the current level and everything below it; matches listed in the level
# itself rank first, deeper ones show their path ("PolySynth › FX › EQ › Band 1 Freq").
#
# Keyboard: the search field always has focus, so typing searches at once. Up/Down (and
# PageUp/PageDown) move the selection, Enter chooses (or opens a submenu), Right opens a submenu,
# Left or Backspace on an empty field goes back, Escape closes.
class_name AutomationParameterPicker extends PopupPanel

static var logger := Log.make("AutomationParameterPicker")

const SCENE := preload("res://arranger/tracklist/AutomationParameterPicker.tscn")
const MAX_LIST_HEIGHT := 360.0
const MIN_LIST_HEIGHT := 120.0
const PAGE_STEP := 8

## The chosen target. The caller creates the lane, so this stays free of history concerns.
signal parameter_chosen(track: Track, target: AutomationTarget)

var track: Track = null
var channel: Channel = null
var tree: AutomationParameterTree = null

@onready var _header: Control = %Header
@onready var _back_button: Button = %BackButton
@onready var _path_label: Label = %PathLabel
@onready var _search_edit: LineEdit = %SearchEdit
@onready var _scroll: ScrollContainer = %Scroll
@onready var _rows: VBoxContainer = %Rows
@onready var _empty_label: Label = %EmptyLabel

## Levels opened so far; the last one is shown.
var _stack: Array[AutomationParameterTree.Level] = []
## One entry per selectable row on screen: {button, row: Row}.
var _entries: Array = []
var _selected: int = -1


## A picker ready to be added to the tree.
static func create() -> AutomationParameterPicker:
	return SCENE.instantiate() as AutomationParameterPicker


func _enter_tree() -> void:
	# The packed scene is visible for editor authoring; instances must start hidden.
	if visible:
		hide()


func _ready() -> void:
	_back_button.pressed.connect(_go_back)
	_search_edit.text_changed.connect(_on_search_changed)
	_search_edit.gui_input.connect(_on_search_gui_input)
	popup_hide.connect(_on_hidden)


## Rebuild for `p_track` and pop up at `global_position`. Does nothing when the track has no
## linked channel - there is nothing to automate.
func open_for(p_track: Track, global_position: Vector2) -> void:
	track = p_track
	channel = track.get_linked_channel() if track else null
	if channel == null:
		logger.warn("No linked channel for track %s; nothing to automate" % (track.name if track else "<null>"))
		return
	_rebuild()
	if tree.is_empty():
		logger.info("Every automatable parameter on %s already has a lane" % track.name)
		return
	var anchor := Rect2(global_position - Vector2.ONE * ContextMenuPopup.MOUSE_OFFSET, Vector2.ONE * ContextMenuPopup.MOUSE_OFFSET * 2.0)
	# Auto-closes like every menu. The search field is always focused, so ContextMenuPopup only
	# treats it as "inside" while it has text or was typed in recently - a search in progress is
	# not cut off, an untouched picker is.
	ContextMenuPopup.popup_anchored(self, anchor, false, true)
	_search_edit.grab_focus()


## Build the tree for the current `track` / `channel` and show its root level.
func _rebuild() -> void:
	tree = AutomationParameterTree.build(track, channel, Settings.get_value(AutomationParameterTree.SETTING_KEY) != AutomationParameterTree.MODE_FLAT)
	show_level(tree.root)


## Show `level` as the root of a fresh navigation (also the entry point for tests).
func show_level(level: AutomationParameterTree.Level) -> void:
	if not is_node_ready():
		# Not in the scene tree yet: the nodes below only exist after _ready.
		return
	_stack.clear()
	_stack.append(level)
	_search_edit.text = ""
	_refresh()
	_scroll.custom_minimum_size.y = clampf(_rows.get_combined_minimum_size().y, MIN_LIST_HEIGHT, MAX_LIST_HEIGHT)
	size = Vector2i(0, 0)


# ============================================================================
# LIST
# ============================================================================

func _current() -> AutomationParameterTree.Level:
	return _stack.back()


## Redraw the list for the current level and query, selecting the first row.
func _refresh() -> void:
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	_entries.clear()
	_selected = -1

	var level := _current()
	var query := _search_edit.text.strip_edges()
	_header.visible = _stack.size() > 1
	_path_label.text = AutomationParameterTree.SEPARATOR.join(level.trail)
	_search_edit.placeholder_text = "Search %s" % level.label if _stack.size() > 1 else "Search parameters"

	if query.is_empty():
		for row: AutomationParameterTree.Row in level.rows:
			match row.kind:
				AutomationParameterTree.Row.Kind.HEADER:
					_add_header(row.label)
				AutomationParameterTree.Row.Kind.ITEM:
					_add_entry(row.label, row)
				AutomationParameterTree.Row.Kind.SUBMENU:
					_add_entry(row.label + "  ›", row)
		_empty_label.visible = false
	else:
		var results := tree.search(level, query)
		for result in results:
			var text: String = result.row.label
			if not result.path.is_empty():
				text = AutomationParameterTree.SEPARATOR.join(result.path) + AutomationParameterTree.SEPARATOR + text
			_add_entry(text, result.row)
		_empty_label.visible = results.is_empty()
	_select(0)


func _add_header(text: String) -> void:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 6)
	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"HeaderSmall"
	label.modulate = Color(1, 1, 1, 0.6)
	line.add_child(label)
	var rule := HSeparator.new()
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(rule)
	if _rows.get_child_count() > 0:
		var gap := Control.new()
		gap.custom_minimum_size.y = 4
		_rows.add_child(gap)
	_rows.add_child(line)


func _add_entry(text: String, row: AutomationParameterTree.Row) -> void:
	var button := Button.new()
	button.theme_type_variation = &"FlatButton"
	button.text = text
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.toggle_mode = true
	button.focus_mode = Control.FOCUS_NONE
	button.clip_text = true
	var index := _entries.size()
	button.mouse_entered.connect(_select.bind(index, false))
	button.pressed.connect(_activate.bind(index))
	_rows.add_child(button)
	_entries.append({"button": button, "row": row})


## Highlight entry `index` (wrapping is the caller's business) and keep it in view.
func _select(index: int, scroll: bool = true) -> void:
	if _entries.is_empty():
		_selected = -1
		return
	index = clampi(index, 0, _entries.size() - 1)
	if _selected >= 0 and _selected < _entries.size():
		_entries[_selected]["button"].set_pressed_no_signal(false)
	_selected = index
	var button: Button = _entries[index]["button"]
	button.set_pressed_no_signal(true)
	if scroll and button.is_inside_tree():
		_scroll.ensure_control_visible.call_deferred(button)


func _move_selection(delta: int) -> void:
	if _entries.is_empty():
		return
	_select(posmod(_selected + delta, _entries.size()))


## Choose the selected row: automate its parameter, or open its submenu.
func _activate(index: int = -1) -> void:
	if index < 0:
		index = _selected
	if index < 0 or index >= _entries.size():
		return
	var row: AutomationParameterTree.Row = _entries[index]["row"]
	if row.kind == AutomationParameterTree.Row.Kind.SUBMENU:
		_open_level(row.level)
	elif row.target != null:
		_emit(row.target)


func _open_level(level: AutomationParameterTree.Level) -> void:
	_stack.append(level)
	_search_edit.text = ""
	_refresh()
	_scroll.scroll_vertical = 0


func _go_back() -> void:
	if _stack.size() <= 1:
		return
	_stack.pop_back()
	_search_edit.text = ""
	_refresh()
	_scroll.scroll_vertical = 0
	_search_edit.grab_focus()


# ============================================================================
# INPUT
# ============================================================================

func _on_search_changed(_text: String) -> void:
	_refresh()
	_scroll.scroll_vertical = 0


func _on_search_gui_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	var handled := true
	match key.keycode:
		KEY_DOWN:
			_move_selection(1)
		KEY_UP:
			_move_selection(-1)
		KEY_PAGEDOWN:
			_select(mini(_selected + PAGE_STEP, _entries.size() - 1))
		KEY_PAGEUP:
			_select(maxi(_selected - PAGE_STEP, 0))
		KEY_ENTER, KEY_KP_ENTER:
			_activate()
		KEY_ESCAPE:
			ContextMenuPopup.close(self)
		KEY_RIGHT:
			handled = _selected_is_submenu() and _search_edit.caret_column >= _search_edit.text.length() \
					and _search_edit.text.is_empty()
			if handled:
				_activate()
		KEY_LEFT:
			handled = _search_edit.text.is_empty() and _stack.size() > 1
			if handled:
				_go_back()
		KEY_BACKSPACE:
			handled = _search_edit.text.is_empty() and _stack.size() > 1
			if handled:
				_go_back()
		_:
			handled = false
	if handled:
		_search_edit.accept_event()


func _selected_is_submenu() -> bool:
	return _selected >= 0 and _selected < _entries.size() \
			and _entries[_selected]["row"].kind == AutomationParameterTree.Row.Kind.SUBMENU


func _on_hidden() -> void:
	_search_edit.text = ""


func _emit(target: AutomationTarget) -> void:
	ContextMenuPopup.close(self)
	logger.info("Automate %s on track %s" % [str(target), track.name if track else "<null>"])
	parameter_chosen.emit(track, target)

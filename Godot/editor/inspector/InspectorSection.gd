# InspectorSection.gd
# Base class for one block of the Inspector: a collapsible header over a two-column grid of
# label and editor rows. InspectorPanel owns the sections and shows those that handle the current
# selection.
#
# To add a section: extend this class, override `handles()` (static), `_build()` (create rows),
# `_watch_models()` (call `watch()` for each model signal that should refresh the rows) and
# `_refresh()` (write model state into the editors). Then add the script to
# `InspectorPanel.section_scripts()`. Sections stack in that order.
#
# Rules for subclasses:
# - Editors never write model fields or send OSC. They call model setters through undoable
#   commands (`HistoryUtil.execute_many`, or `record_many` after a live drag).
# - `_refresh()` runs from model signals, never from a timer. Editors set by `_refresh()` must not
#   commit: use the `*_no_signal` setters, or check `is_refreshing()` in a handler.
# - With several objects selected a field shows the shared value, or "—" when they differ.
class_name InspectorSection extends VBoxContainer

## Shown in a field whose selected objects disagree.
const MIXED_TEXT := "—"
const LABEL_MIN_WIDTH := 72.0

## Header caption.
var title: String = "":
	set(value):
		title = value
		_update_header()

## Project used for tick formatting. Falls back to the editor's project when unset.
var project: Project = null

## The objects this section is bound to.
var objects: Array = []

var _built := false
var _refreshing := false
var _collapsed := false
var _header: Button
var _grid: GridContainer
var _watched: Array = []


## True when this section applies to `selected`. Override in subclasses.
static func handles(_selected: Array) -> bool:
	return false


## Create the rows. Called once, before the first bind. Override in subclasses.
func _build() -> void:
	pass


## Connect model signals with `watch()`. Called on every bind. Override in subclasses.
func _watch_models() -> void:
	pass


## Write model state into the editors. Override in subclasses.
func _refresh() -> void:
	pass


## Called after the section has been unbound. Override to drop non-signal state.
func _on_unbound() -> void:
	pass


func _ready() -> void:
	_ensure_built()


## Show `selected`: connect to the models and refresh the rows.
func bind(selected: Array) -> void:
	_ensure_built()
	unbind()
	objects = selected.duplicate()
	_watch_models()
	refresh()


## Disconnect from the models. Safe to call repeatedly.
func unbind() -> void:
	for entry in _watched:
		var sig: Signal = entry[0]
		var cb: Callable = entry[1]
		if is_instance_valid(sig.get_object()) and sig.is_connected(cb):
			sig.disconnect(cb)
	_watched.clear()
	objects = []
	_on_unbound()


## Re-read the models into the editors.
func refresh() -> void:
	if _refreshing:
		return
	_refreshing = true
	_refresh()
	_refreshing = false


## True while `_refresh()` runs, so a handler can ignore edits it caused itself.
func is_refreshing() -> bool:
	return _refreshing


## Connect `sig` so that it refreshes the section, or call `handler` when given.
func watch(sig: Signal, handler: Callable = Callable()) -> void:
	var cb := handler if handler.is_valid() else _on_model_changed
	if sig.is_connected(cb):
		return
	sig.connect(cb)
	_watched.append([sig, cb])


func _on_model_changed() -> void:
	refresh()


## The project to format ticks with.
func get_project() -> Project:
	if project != null:
		return project
	if Sonara and Sonara.editor:
		return Sonara.editor.project
	return null


# ============================================================================
# ROW HELPERS
# ============================================================================

## Add a row: a dim caption in the left column and `editor` in the right. Returns the caption.
func add_row(caption: String, editor: Control) -> Label:
	_ensure_built()
	var label := Label.new()
	label.text = caption
	label.custom_minimum_size.x = LABEL_MIN_WIDTH
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	label.add_theme_color_override(&"font_color", UiColors.role(&"text_dim"))
	_grid.add_child(label)
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_child(editor)
	return label


## A text field that commits on Enter or when it loses focus. `on_commit` gets the typed text.
## Escape drops the edit. Empty text is never committed, so a mixed field left alone stays mixed.
func make_text_field(on_commit: Callable) -> LineEdit:
	var edit := LineEdit.new()
	edit.custom_minimum_size.x = 0.0
	edit.placeholder_text = MIXED_TEXT
	edit.select_all_on_focus = true
	edit.text_submitted.connect(func(text: String) -> void:
		_commit_text(edit, text, on_commit)
		edit.release_focus())
	edit.focus_exited.connect(func() -> void:
		_commit_text(edit, edit.text, on_commit))
	edit.gui_input.connect(func(event: InputEvent) -> void:
		if event.is_action_pressed(&"ui_cancel"):
			refresh()
			edit.release_focus()
			edit.accept_event())
	return edit


func _commit_text(edit: LineEdit, text: String, on_commit: Callable) -> void:
	if _refreshing or text.strip_edges().is_empty():
		return
	on_commit.call(text)
	# Show what the model accepted (clamped, rejected, or unchanged).
	refresh()


## A toggle button that reads On / Off, or "—" when the selected objects differ.
## `on_toggled` gets the new state.
func make_toggle(on_toggled: Callable) -> Button:
	var button := Button.new()
	button.toggle_mode = true
	button.text = "Off"
	button.toggled.connect(func(pressed: bool) -> void:
		if _refreshing:
			return
		on_toggled.call(pressed)
		refresh())
	return button


## Fill a toggle from per-object booleans: pressed when all are true, "—" when they differ.
func show_toggle(button: Button, flags: Array) -> void:
	var mixed := not all_same(flags)
	button.set_pressed_no_signal(not mixed and not flags.is_empty() and bool(flags[0]))
	button.text = MIXED_TEXT if mixed else ("On" if button.button_pressed else "Off")


## Fill a text field from per-object values: the shared value, or empty (so the "—" placeholder
## shows) when they differ. `format` turns a value into text.
func show_text(edit: LineEdit, values: Array, format: Callable = Callable()) -> void:
	if values.is_empty() or not all_same(values):
		edit.text = ""
		return
	edit.text = str(format.call(values[0])) if format.is_valid() else str(values[0])


## True when `values` is empty or all entries are equal.
static func all_same(values: Array) -> bool:
	for i in range(1, values.size()):
		if values[i] != values[0]:
			return false
	return true


# ============================================================================
# CHROME
# ============================================================================

func _ensure_built() -> void:
	if _built:
		return
	_built = true
	_header = Button.new()
	_header.theme_type_variation = &"FlatButton"
	_header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_header.focus_mode = Control.FOCUS_NONE
	_header.pressed.connect(_toggle_collapsed)
	add_child(_header)
	_grid = GridContainer.new()
	_grid.columns = 2
	add_child(_grid)
	_update_header()
	_build()


func _toggle_collapsed() -> void:
	set_collapsed(not _collapsed)


## Fold the rows away, keeping the header.
func set_collapsed(value: bool) -> void:
	_collapsed = value
	if _grid:
		_grid.visible = not _collapsed
	_update_header()


func is_collapsed() -> bool:
	return _collapsed


func _update_header() -> void:
	if _header == null:
		return
	_header.text = title
	var icon_name := "chevron-right" if _collapsed else "chevron-down"
	_header.icon = load("res://assets/icons/%s.svg" % icon_name)

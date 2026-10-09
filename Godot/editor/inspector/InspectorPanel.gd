# InspectorPanel.gd
# The Inspector dock content: a stack of InspectorSections for the current selection, or an empty
# state. Editor feeds it the selection with `set_selection()`. A section is created the first time
# it is needed and then reused: on every selection change the panel shows the sections that
# `handles()` the selection, binds those, and unbinds the rest.
class_name InspectorPanel extends ScrollContainer

## Section scripts, top to bottom. Each extends InspectorSection. Phase 2 and 3 of spec 029 add
## AudioClipInspector after ClipInspector.
static func section_scripts() -> Array[GDScript]:
	return [ClipInspector]

## Project used by the sections for tick formatting. Falls back to the editor's project when unset.
var project: Project = null

var _selection: Array = []
var _sections: Dictionary = {}  # GDScript -> InspectorSection
@onready var _stack: VBoxContainer = %Sections
@onready var _empty_label: Label = %EmptyLabel


func _ready() -> void:
	_empty_label.add_theme_color_override(&"font_color", UiColors.role(&"text_dim"))
	_apply_selection()


## Show the sections that apply to `selected` (ClipInstances today; other object types later).
func set_selection(selected: Array) -> void:
	_selection = selected.duplicate()
	if is_node_ready():
		_apply_selection()


## Sections that are shown now, top to bottom.
func get_visible_sections() -> Array[InspectorSection]:
	var out: Array[InspectorSection] = []
	for script in section_scripts():
		var section: InspectorSection = _sections.get(script)
		if section and section.visible:
			out.append(section)
	return out


## The section made from `script`, or null when it was never needed yet.
func get_section(script: GDScript) -> InspectorSection:
	return _sections.get(script)


func _apply_selection() -> void:
	var any_shown := false
	for script in section_scripts():
		var wanted: bool = not _selection.is_empty() and script.handles(_selection)
		var section: InspectorSection = _sections.get(script)
		if wanted and section == null:
			section = script.new()
			_sections[script] = section
			_stack.add_child(section)
		if section == null:
			continue
		if wanted:
			section.project = project
			section.visible = true
			section.bind(_selection)
			any_shown = true
		elif section.visible:
			section.unbind()
			section.visible = false
	_empty_label.visible = not any_shown

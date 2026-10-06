## The focused zone's name, group, key range, velocity range, gain and fades, editable (spec 023,
## REQ-023). Shown by the Sampler's Companion view in multisample mode, where the Panel view has
## its waveform. The layout lives in `ZoneStrip.tscn`; this script binds it to the model.
##
## Knob edits go through `SamplerActions.set_zone_fields` (consecutive edits of one zone merge
## into one undo step); renaming and changing the group are one step each.
class_name ZoneStrip extends HBoxContainer

## Knob node → [zone field, min, max, default].
const KNOB_FIELDS := {
	"KeyLo": ["key_lo", 0, 127, 0], "KeyHi": ["key_hi", 0, 127, 127],
	"VelLo": ["vel_lo", 1, 127, 1], "VelHi": ["vel_hi", 1, 127, 127],
	"KeyFadeLo": ["key_fade_lo", 0, 48, 0], "KeyFadeHi": ["key_fade_hi", 0, 48, 0],
	"VelFadeLo": ["vel_fade_lo", 0, 126, 0], "VelFadeHi": ["vel_fade_hi", 0, 126, 0],
	"Gain": ["gain", 0.0, 2.0, 1.0],
}

@onready var name_edit: LineEdit = %NameEdit
@onready var group_option: OptionButton = %GroupOption

var device: DeviceInstance = null
## Knob node name → LabeledKnob.
var knobs: Dictionary[String, LabeledKnob] = {}

var _model: SamplerMultisample = null
var _syncing := false


func _ready() -> void:
	for knob_name in KNOB_FIELDS:
		var labeled: LabeledKnob = get_node("%" + knob_name)
		knobs[knob_name] = labeled
		labeled.label.add_theme_font_size_override("font_size", 10)
		var spec: Array = KNOB_FIELDS[knob_name]
		var knob := labeled.knob
		knob.min_value = spec[1]
		knob.max_value = spec[2]
		knob.step = 0.0 if knob_name == "Gain" else 1.0
		knob.value_default = spec[3]
		knob.value_text_callback = knob_text.bind(knob_name)
		knob.value_changed.connect(_on_knob_changed.bind(knob_name))
		knob.reset_requested.connect(_on_knob_reset.bind(knob_name))
	name_edit.text_submitted.connect(func(_t: String) -> void: _commit_name())
	name_edit.focus_exited.connect(_commit_name)
	group_option.item_selected.connect(_on_group_selected)
	if device != null:
		_refresh()


func bind(p_device: DeviceInstance) -> void:
	unbind()
	device = p_device
	_model = device.ensure_multisample()
	_model.focus_changed.connect(_on_focus_changed)
	_model.zone_changed.connect(_on_zone_changed)
	_model.zones_changed.connect(_refresh)
	_model.groups_changed.connect(_refresh)
	_refresh()


func unbind() -> void:
	if _model != null:
		_model.focus_changed.disconnect(_on_focus_changed)
		_model.zone_changed.disconnect(_on_zone_changed)
		_model.zones_changed.disconnect(_refresh)
		_model.groups_changed.disconnect(_refresh)
	_model = null
	device = null


func zone() -> SamplerZone:
	return _model.focused_zone() if _model != null and _model.active else null


func _on_focus_changed(_zone_id: int) -> void:
	_refresh()


func _on_zone_changed(zone_id: int) -> void:
	if _model != null and zone_id == _model.focused_zone_id:
		_refresh()


## A knob's readout: note names for keys, dB for gain, steps for the rest.
static func knob_text(value: float, knob_name: String) -> String:
	match knob_name:
		"KeyLo", "KeyHi":
			return Midi.midi_to_note_name(roundi(value))
		"Gain":
			return "-inf dB" if value <= 0.0001 else "%+.1f dB" % (20.0 * log(value) / log(10.0))
		"KeyFadeLo", "KeyFadeHi":
			return "%d st" % roundi(value)
	return "%d" % roundi(value)


## Copy the focused zone onto the controls without echoing back.
func _refresh() -> void:
	if not is_node_ready():
		return
	var z := zone()
	_syncing = true
	group_option.disabled = z == null
	name_edit.editable = z != null
	if not name_edit.has_focus():
		name_edit.text = z.name if z else ""
	group_option.clear()
	if _model != null:
		group_option.add_item(SamplerZoneGroup.UNGROUPED_NAME, SamplerZoneGroup.UNGROUPED_ID)
		for group in _model.groups:
			group_option.add_item(group.name, group.id)
		if z:
			group_option.select(group_option.get_item_index(z.group_id))
	for knob_name in knobs:
		var labeled := knobs[knob_name]
		labeled.knob.mouse_filter = Control.MOUSE_FILTER_STOP if z else Control.MOUSE_FILTER_IGNORE
		labeled.modulate.a = 1.0 if z else 0.4
		if z:
			labeled.knob.set_value_no_signal(float(z.get(KNOB_FIELDS[knob_name][0])))
	_syncing = false


func _on_knob_changed(value: float, knob_name: String) -> void:
	var z := zone()
	if _syncing or z == null:
		return
	var field: String = KNOB_FIELDS[knob_name][0]
	var v: Variant = value if field == "gain" else roundi(value)
	SamplerActions.set_zone_fields(device, z.id, {field: v})


func _on_knob_reset(knob_name: String) -> void:
	var knob := knobs[knob_name].knob
	knob.value = knob.value_default


func _commit_name() -> void:
	var z := zone()
	var text := name_edit.text.strip_edges()
	if _syncing or z == null or text.is_empty() or text == z.name:
		return
	var zone_id := z.id
	SamplerActions.edit(device, "Rename Sample", func(m: SamplerMultisample) -> void:
		m.set_zone_fields(zone_id, {"name": text}))


func _on_group_selected(index: int) -> void:
	var z := zone()
	if _syncing or z == null:
		return
	var group_id := group_option.get_item_id(index)
	if group_id != z.group_id:
		SamplerActions.move_to_group(device, [z.id], group_id)

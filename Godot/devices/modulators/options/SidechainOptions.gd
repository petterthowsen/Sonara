## Sidechain options: the Source channel menu (spec 036 REQ-006) above the filter and follower
## knobs. The menu lists "Device In" plus every project channel by name (master included,
## hardware outputs excluded), item metadata = channel id, and rebuilds when channels come or go.
class_name SidechainOptions extends ModulatorOptions

const SOURCE_PARAM := 40

@onready var source_menu: OptionButton = %SourceMenu

var _project = null


func setup(mod: Modulator) -> void:
	super.setup(mod)
	var channel = mod.owner().get_channel() if mod.owner() != null else null
	_project = channel.get_project() if channel != null else null
	if _project != null:
		_project.channel_added.connect(_on_channels_changed)
		_project.channel_removed.connect(_on_channels_changed)
	source_menu.item_selected.connect(_on_source_selected)
	_rebuild_source_menu()


func sync() -> void:
	super.sync()
	_sync_source_menu()


func _exit_tree() -> void:
	if _project != null:
		if _project.channel_added.is_connected(_on_channels_changed):
			_project.channel_added.disconnect(_on_channels_changed)
		if _project.channel_removed.is_connected(_on_channels_changed):
			_project.channel_removed.disconnect(_on_channels_changed)
	_project = null


func _on_channels_changed(_channel_or_id) -> void:
	_rebuild_source_menu()


## (Re)fill the menu; the selection follows the stored channel id.
func _rebuild_source_menu() -> void:
	source_menu.clear()
	source_menu.add_item("Device In")
	source_menu.set_item_metadata(0, 0)
	if _project != null:
		for ch in _project.channels:
			if ch.id >= AudioConfig.HARDWARE_OUTPUT_BASE:
				continue
			source_menu.add_item(ch.name)
			source_menu.set_item_metadata(source_menu.item_count - 1, ch.id)
	_sync_source_menu()


func _sync_source_menu() -> void:
	if modulator == null or source_menu == null or source_menu.item_count == 0:
		return
	var param := modulator.get_parameter(SOURCE_PARAM)
	var channel_id := -1
	if param != null:
		channel_id = int(round(param.normalized_to_value(modulator.get_param(SOURCE_PARAM))))
	else:
		channel_id = int(round(modulator.get_param(SOURCE_PARAM) * 999.0))
	var select_index := -1
	for i in source_menu.item_count:
		if int(source_menu.get_item_metadata(i)) == channel_id:
			select_index = i
			break
	if select_index < 0:
		# The stored id no longer exists (channel removed): show it as missing, keep the id.
		source_menu.add_item("(missing channel)")
		source_menu.set_item_metadata(source_menu.item_count - 1, channel_id)
		select_index = source_menu.item_count - 1
	source_menu.select(select_index)


func _on_source_selected(index: int) -> void:
	if modulator == null or modulator.owner() == null:
		return
	var channel_id := int(source_menu.get_item_metadata(index))
	var param := modulator.get_parameter(SOURCE_PARAM)
	# The engine's Source parameter is a channel id in normalized units (linear 0..999).
	var norm := param.value_to_normalized(float(channel_id)) if param != null else float(channel_id) / 999.0
	modulator.owner().set_modulator_param(modulator.mod_id, SOURCE_PARAM, norm)

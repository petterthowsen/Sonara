# test_note_fx_drop.gd
# Spec 027 (REQ-035): note effects go on non-master instrument channels and inside Chain, Layer slot
# and Drum Machine pad chains. They are refused on audio channels, buses, the master channel and
# inside Multiband FX bands, for dragged devices and for browser assets alike.
# Run: godot --headless --path Godot -s tests/test_note_fx_drop.gd -- --test
#
# The model and drop classes reference autoloads, so they are loaded with load() instead of named.
extends TestBase

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _asset_script: GDScript
var _drop_util: GDScript
var _note_fx: GDScript
var _project: Object


func suite_name() -> String:
	return "Note effect drop rules"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_asset_script = load("res://browser/Asset.gd")
	_drop_util = load("res://devices/DeviceDropUtil.gd")
	_note_fx = load("res://data/NoteFx.gd")
	_project = _project_script.new()
	_test_channels()
	_test_containers()
	_test_drum_pads()
	_test_note_fx_helpers()


## Registered fake device `device_id`.
func _device(device_id: String, category: int, container := false) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id, category, _device_script.DeviceType.BuiltIn)
		device.is_container = container
		registry._devices[device_id] = device
	return device


func _transpose() -> Object:
	return _device("sonara.builtin.transpose", _device_script.DeviceCategory.NoteEffect)


func _inst(device: Object, ch: Object) -> Object:
	return _device_instance_script.new(device, ch.id, -1)


func _asset_for(device: Object) -> Object:
	var asset: Object = _asset_script.new()
	asset.type = _asset_script.TYPE.Device
	asset.path = device.device_id
	return asset


## A container of `device_id` on `ch`, holding one Chain.
func _container(ch: Object, device_id: String) -> Array:
	var container := _inst(_device(device_id, _device_script.DeviceCategory.Utility, true), ch)
	ch.add_device(container)
	var chain := _inst(_device("sonara.builtin.chain", _device_script.DeviceCategory.Utility, true), ch)
	ch.add_device(chain, -1, container)
	return [container, chain]


func _test_channels() -> void:
	var inst_ch: Object = _project.create_instrument_track("Inst").channel
	var audio_ch: Object = _project.create_audio_track("Audio").channel
	var bus: Object = _project.create_bus_channel("Bus")
	var master: Object = _project.get_master_channel()
	var fx := _transpose()
	var asset := _asset_for(fx)
	_assert(_drop_util.device_fits_channel(fx, inst_ch), "Transpose fits an instrument channel")
	_assert(_drop_util.can_drop_asset_on_channel(inst_ch, asset), "Transpose asset drops on an instrument channel")
	for pair in [["audio channel", audio_ch], ["bus", bus], ["master", master]]:
		_assert(not _drop_util.device_fits_channel(fx, pair[1]), "Transpose refused on the %s" % pair[0])
		_assert(not _drop_util.can_drop_asset_on_channel(pair[1], asset), "Transpose asset refused on the %s" % pair[0])

	# A dragged instance: root of an instrument channel yes, root of an audio channel no.
	var moving := _inst(fx, inst_ch)
	inst_ch.add_device(moving)
	_assert(_drop_util.can_drop_instance_on_host(inst_ch, moving, null), "Transpose instance reorders on its channel")
	_assert(not _drop_util.can_drop_instance_on_host(audio_ch, moving, null), "Transpose instance refused on an audio channel")
	_assert(not _drop_util.can_transfer_to_channel(moving, bus), "Transpose instance can't move to a bus")
	var other_inst: Object = _project.create_instrument_track("Inst 2").channel
	_assert(_drop_util.can_transfer_to_channel(moving, other_inst), "Transpose instance can move to another instrument channel")


func _test_containers() -> void:
	var ch: Object = _project.create_instrument_track("Inst").channel
	var fx := _transpose()
	var asset := _asset_for(fx)

	# Chain and Layer slot: allowed.
	var chain_pair := _container(ch, "sonara.builtin.chain")
	_assert(_drop_util.can_drop_on_container(ch, chain_pair[0], asset), "Transpose asset drops into a Chain")
	var layer_pair := _container(ch, "sonara.builtin.layer")
	_assert(_drop_util.can_drop_on_container(ch, layer_pair[0], asset), "Transpose asset drops into a Layer")
	_assert(_drop_util.can_drop_on_container(ch, layer_pair[1], asset), "Transpose asset drops into a Layer slot chain")
	var dragged := _inst(fx, ch)
	ch.add_device(dragged)
	_assert(_drop_util.can_drop_instance_on_host(ch, dragged, layer_pair[1]), "Transpose instance moves into a Layer slot")
	_assert(_drop_util.can_drop_instance_on_host(ch, dragged, chain_pair[0]), "Transpose instance moves into a Chain")

	# Multiband band: refused, for the band chain, the Multiband itself and a Chain inside a band.
	var band_pair := _container(ch, "sonara.builtin.multiband")
	_assert(not _drop_util.can_drop_on_container(ch, band_pair[0], asset), "Transpose asset refused on a Multiband")
	_assert(not _drop_util.can_drop_on_container(ch, band_pair[1], asset), "Transpose asset refused in a band")
	_assert(not _drop_util.can_drop_instance_on_host(ch, dragged, band_pair[1]), "Transpose instance refused in a band")
	var nested := _inst(_device("sonara.builtin.chain", _device_script.DeviceCategory.Utility, true), ch)
	ch.add_device(nested, -1, band_pair[1])
	_assert(not _drop_util.can_drop_on_container(ch, nested, asset), "Transpose asset refused in a Chain inside a band")
	# A Chain holding a note effect can't go into a band either.
	var holder := _inst(_device("sonara.builtin.chain", _device_script.DeviceCategory.Utility, true), ch)
	ch.add_device(holder)
	ch.add_device(_inst(fx, ch), -1, holder)
	_assert(not _drop_util.can_drop_instance_on_host(ch, holder, band_pair[1]), "a Chain holding Transpose is refused in a band")

	# Audio effects are unaffected.
	var delay := _device("sonara.builtin.delay", _device_script.DeviceCategory.Effect)
	_assert(_drop_util.can_drop_on_container(ch, band_pair[1], _asset_for(delay)), "Delay asset still drops in a band")


func _test_drum_pads() -> void:
	var ch: Object = _project.create_instrument_track("Drums").channel
	var machine := _inst(_device("sonara.builtin.drum_machine", _device_script.DeviceCategory.Instrument, true), ch)
	ch.add_device(machine)
	var asset := _asset_for(_transpose())
	_assert(_drop_util.can_drop_on_drum_pad(asset, null, ch, machine, 36), "Transpose asset drops on an empty drum pad")
	var audio_ch: Object = _project.create_audio_track("Audio").channel
	_assert(not _drop_util.can_drop_on_drum_pad(asset, null, audio_ch, machine, 36), "Transpose asset refused on a pad of a non-instrument channel")
	var pad := _inst(_device("sonara.builtin.chain", _device_script.DeviceCategory.Utility, true), ch)
	pad.slot_note = 36
	ch.add_device(pad, -1, machine)
	_assert(_drop_util.can_drop_on_drum_pad(asset, pad, ch, machine, 36), "Transpose asset joins an occupied pad's chain")


func _test_note_fx_helpers() -> void:
	var ch: Object = _project.create_instrument_track("Helpers").channel
	var fx := _inst(_transpose(), ch)
	var synth := _inst(_device("test.synth", _device_script.DeviceCategory.Instrument), ch)
	var delay := _inst(_device("sonara.builtin.delay", _device_script.DeviceCategory.Effect), ch)
	_assert(_note_fx.leading_note_effect_count([fx, fx, synth, fx]) == 2, "two leading note effects")
	_assert(_note_fx.leading_note_effect_count([synth, fx]) == 0, "none before an instrument")
	_assert(_note_fx.leading_note_effect_count([]) == 0, "empty chain")
	_assert(not _note_fx.is_note_container(delay) and not _note_fx.is_note_container(null), "Delay is no note container")
	var pair := _container(ch, "sonara.builtin.note_layer")
	_assert(_note_fx.is_note_container(pair[0]), "Note Layer is a note container")
	_assert(_note_fx.is_note_branch(pair[1]) and not _note_fx.is_note_branch(pair[0]), "its chain is a branch")
	_assert(_note_fx.is_inside_note_container(pair[1]) and _note_fx.is_inside_note_container(pair[0]), "branch and container count as inside")
	_assert(not _note_fx.is_inside_note_container(null) and not _note_fx.is_inside_note_container(delay), "root is not inside")

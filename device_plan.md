# DevicePanel Multi-View Refactor

### Goals

- Add three optional view types per device: PanelView (right pane), LargeView (popup/native GUI), AuxiliaryView (right pane when LargeView is open).
- Keep left side tabs (Parameters/File) unchanged.
- Default: PanelView visible. LargeView toggle opens popup or native GUI. When LargeView is open and AuxiliaryView exists, show AuxiliaryView instead of PanelView in the right pane.
- Provide a registration API on `data/Device.gd` using `PackedScene` references (no runtime loads).

### Key Changes

#### 1) Data model: view registration API (PackedScene, no paths)

- File: `Godot/data/Device.gd`
- Add enum and PackedScene-backed properties with registration helpers:
```gdscript
enum ViewType { Panel, Large, Auxiliary, Compact }

# PackedScene references (null when unsupported)
var panel_view_scene: PackedScene = null
var large_view_scene: PackedScene = null
var auxiliary_view_scene: PackedScene = null
var compact_view_scene: PackedScene = null

# Registration (PackedScene only)
func register_panel_view(scene: PackedScene) -> void:
	panel_view_scene = scene

func register_large_view(scene: PackedScene) -> void:
	large_view_scene = scene

func register_auxiliary_view(scene: PackedScene) -> void:
	auxiliary_view_scene = scene

func register_compact_view(scene: PackedScene) -> void:
	compact_view_scene = scene

# Back-compat shim (transition only)
func register_visual_scene(scene: PackedScene) -> void:
	panel_view_scene = scene

# Availability checks
func has_panel_view() -> bool:
	return panel_view_scene != null

func has_large_view() -> bool:
	return large_view_scene != null

func has_auxiliary_view() -> bool:
	return auxiliary_view_scene != null
```

- Update built-ins to use `register_panel_view(preload(...))` (or load() to save memory)

#### 2) DeviceView base remains (with view_type)

- File: `Godot/components/device/DeviceView.gd`
- Keep as abstract base for all view types; add view_type and helpers:
```gdscript
var view_type: int = Device.ViewType.Panel

func set_view_type(t: int) -> void:
	view_type = t

func is_type(t : Device.ViewType) -> bool

func get_window_title() -> String:
	return device.device.name
```


#### 3) DevicePanel UI updates

- File: `Godot/device_lane/DevicePanel.tscn`
- Replace the current `Visual` tab button with a `Large` toggle button in `TabButtons` (initially hidden).
- Do not add a static `Window` node; Large popup windows will be created dynamically when toggled on.

#### 4) DevicePanel logic

- File: `Godot/device_lane/DevicePanel.gd`
- Add onready ref and state:
```gdscript
@onready var large_button: Button = $VBoxContainer/Header/HBox/TabButtons/Large

var _panel_view: DeviceView = null
var _aux_view: DeviceView = null
var _large_view: DeviceView = null
var _large_open: bool = false
```

- Bind flow updates:
```gdscript
func bind_to_device(dev: DeviceInstance):
	# PanelView (right pane default)
	if dev.device.has_panel_view():
		_load_panel_view(dev)
		_show_right_pane_current()
	else:
		_clear_panel_and_aux()

	# Large toggle visibility (native GUI or LargeView scene)
	large_button.visible = dev.device.has_gui() or dev.device.has_large_view()
	large_button.button_pressed = false
```

- Toggle handlers:
```gdscript
func _on_large_toggled(pressed: bool) -> void:
	if pressed:
		_open_large()
	else:
		_close_large()
```

- Large open/close (dynamic popup under Sonara.editor):
```gdscript
func _open_large() -> void:
	if device.device.has_gui():
		device.open_gui()
		_large_open = true
		_apply_large_state()
		return

	if device.device.has_large_view():
		var popup := Window.new()
		popup.unresizable = false
		popup.title = device.device.name
		# Create LargeView
		_large_view = device.create_view(Device.ViewType.Large)
		if _large_view:
			popup.add_child(_large_view)
			_large_view.bind_to_device(device)
			Sonara.editor.add_child(popup)
			popup.popup_centered()
			popup.close_requested.connect(_on_large_popup_closed)
			_large_open = true
			_apply_large_state()

func _on_large_popup_closed() -> void:
	if _large_view:
		_large_view.queue_free()
		_large_view = null
	_large_open = false
	_apply_large_state()
	large_button.button_pressed = false

func _close_large() -> void:
	if device.device.has_gui():
		device.close_gui()
		_large_open = false
		_apply_large_state()
		return
	_on_large_popup_closed()
```

- Right pane switching when Large is open:
```gdscript
func _apply_large_state() -> void:
	if _large_open and device.device.has_auxiliary_view():
		_load_aux_view(device)
		_show_aux_in_right()
	else:
		_hide_aux_show_panel()

func _show_right_pane_current() -> void:
	if _large_open and _aux_view:
		_show_aux_in_right()
	else:
		_show_panel_in_right()
```

- View loaders (use DeviceInstance factory):
```gdscript
func _load_panel_view(dev: DeviceInstance) -> void:
	_clear_panel_view()
	_panel_view = dev.create_view(Device.ViewType.Panel)
	if _panel_view:
		visual_container.add_child(_panel_view)
		_panel_view.bind_to_device(dev)

func _load_aux_view(dev: DeviceInstance) -> void:
	_clear_aux_view()
	_aux_view = dev.create_view(Device.ViewType.Auxiliary)
	if _aux_view:
		visual_container.add_child(_aux_view)
		_aux_view.bind_to_device(dev)
```

- Helper instantiator with DeviceView type check. Reuse existing lifecycle `_on_view_shown/_on_view_hidden` in the show/hide paths.

- Visual tab is removed. Right pane visibility is tied to whether Panel/Aux is present.

#### 5) Backward compatibility

- Path-based fields (`visual_scene_path`) are deprecated. Use preloaded `PackedScene` registration.
- Temporary shim: `register_visual_scene(scene: PackedScene)` maps to `panel_view_scene`.
- Providers should preload scenes and call the PackedScene registration helpers.
- Large button only appears if either `has_gui()` or `has_large_view()` is true.

### Registration examples

- Built-in Spectrum Analyzer (PanelView only today):
```gdscript
const SpectrumAnalyzerPanel := preload("res://devices/builtin/SpectrumAnalyzerVisual.tscn")
var dev = Device.new("sonara.builtin.spectrum_analyzer", "Spectrum Analyzer", Device.DeviceCategory.Utility)
dev.register_panel_view(SpectrumAnalyzerPanel)
```

- Hypothetical EQ with Large and Auxiliary views:
```gdscript
dev.register_panel_view(preload("res://devices/builtin/EQPanel.tscn"))
dev.register_large_view(preload("res://devices/builtin/EQLarge.tscn"))
dev.register_auxiliary_view(preload("res://devices/builtin/EQAux.tscn"))
```

- Compact view registration for future Mixer usage:
```gdscript
dev.register_compact_view(preload("res://devices/builtin/EQCompact.tscn"))
```


### Testing

- Confirm: PanelView shows by default; Large button visibility is correct.
- Toggle Large for built-in large view: a dynamic Window is created, added to `Sonara.editor`, and `popup_centered()` is called; right pane swaps to Auxiliary if provided.
- Toggle Large for CLAP plugin: native GUI open/close via existing OSC pathway; right pane behavior mirrors above.
- Ensure `_on_view_shown/_on_view_hidden` fire appropriately when right pane is shown/hidden and when Large is opened/closed.
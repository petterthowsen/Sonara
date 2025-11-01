# DevicePanel Visual Tab Integration Guide

## Overview

This document describes the changes needed to `DevicePanel.gd` and `DevicePanel.tscn` to support the new Visual tab system for device visualizations (spectrum analyzer, oscilloscope, etc.).

## Architecture

- **DeviceView Base Class**: Abstract base for all visual scenes (`components/device/DeviceView.gd`)
- **Device Registration**: Devices can register visual scenes via `Device.register_visual_scene(path)`
- **Subscription Lifecycle**: Visual scenes subscribe/unsubscribe to device data when shown/hidden
- **Popup Support**: Visual tabs can be popped out into separate windows

## Required Changes

### 1. DevicePanel.tscn Scene Updates

Add new UI elements to the scene:

**Tab Buttons** (in `$VBoxContainer/Header/HBox/TabButtons`):
- Add `Visual` button (Button node)
  - `name`: "Visual"
  - `toggle_mode`: true
  - `button_group`: Same as Parameters/File buttons
  - Initially hidden (visible = false)

**Content Containers** (in `$VBoxContainer/Content`):
- Add `Visual` container (Control node)
  - `name`: "Visual"
  - `custom_minimum_size`: Vector2(400, 200)
  - `size_flags_horizontal`: FILL_EXPAND
  - `size_flags_vertical`: FILL_EXPAND
  - Initially hidden (visible = false)

**Optional: Popup Button**:
- Add small button in header to pop out visual tab
  - Icon: "ExternalLink" or similar
  - Only visible when Visual tab is active

### 2. DevicePanel.gd Code Updates

#### Add Node References

```gdscript
@onready var visual_button: Button = $VBoxContainer/Header/HBox/TabButtons/Visual
@onready var visual_container: Control = $VBoxContainer/Content/Visual
```

#### Add State Variables

```gdscript
var _current_visual_scene: DeviceView = null
var _is_visual_popped_out: bool = false
var _popup_window: Window = null
```

#### Update `bind_to_device()`

```gdscript
func bind_to_device(dev: DeviceInstance):
	if device:
		_unbind_from_device(device)
	device = dev
	
	await ready
	device_light.bind_to_device_instance(dev)
	name_label.text = dev.get_display_name()
	
	# Configure Visual tab
	if dev.device.has_visual():
		visual_button.visible = true
		_load_visual_scene(dev.device.visual_scene_path)
	else:
		visual_button.visible = false
		_clear_visual_scene()
	
	# Configure Controls tab (future)
	# if dev.device.has_custom_controls():
	#     controls_button.visible = true
	#     _load_controls_scene(dev.device.controls_scene_path)
	
	# Parameters tab always visible
	_create_parameter_controls()
	_configure_file_loading()
	
	# Listen for parameter updates
	var channel = Sonara.editor.project.get_channel_by_id(dev.channel_id)
	if channel and not channel.device_parameters_updated.is_connected(_on_device_parameters_updated):
		channel.device_parameters_updated.connect(_on_device_parameters_updated)
```

#### Add Visual Scene Management

```gdscript
func _load_visual_scene(scene_path: String) -> void:
	"""Load and instantiate a visual scene for this device."""
	_clear_visual_scene()
	
	var scene = load(scene_path)
	if not scene:
		push_error("Failed to load visual scene: " + scene_path)
		return
	
	_current_visual_scene = scene.instantiate()
	if not _current_visual_scene is DeviceView:
		push_error("Visual scene must extend DeviceView: " + scene_path)
		_current_visual_scene.queue_free()
		_current_visual_scene = null
		return
	
	visual_container.add_child(_current_visual_scene)
	_current_visual_scene.bind_to_device(device)
	print("[DevicePanel] Loaded visual scene: ", scene_path)


func _clear_visual_scene() -> void:
	"""Clear the current visual scene."""
	if _current_visual_scene:
		if _current_visual_scene._on_view_hidden:
			_current_visual_scene._on_view_hidden()
		_current_visual_scene.queue_free()
		_current_visual_scene = null
```

#### Add Tab Switching

```gdscript
func _on_visual_tab_toggled(pressed: bool) -> void:
	if pressed:
		_show_visual_tab()


func _show_visual_tab() -> void:
	"""Show the Visual tab."""
	visual_container.visible = true
	parameters_scroll.visible = false
	file_box.visible = false
	
	if _current_visual_scene:
		_current_visual_scene._on_view_shown()


func _hide_visual_tab() -> void:
	"""Hide the Visual tab (called when switching to other tabs)."""
	if _current_visual_scene:
		_current_visual_scene._on_view_hidden()
	visual_container.visible = false
```

Connect the visual button in `_ready()`:
```gdscript
visual_button.toggled.connect(_on_visual_tab_toggled)
```

#### Add Popup Window Support (Optional)

```gdscript
func _on_popup_visual_pressed() -> void:
	"""Pop out the visual tab into a separate window."""
	if not _current_visual_scene or _is_visual_popped_out:
		return
	
	# Create popup window
	_popup_window = Window.new()
	_popup_window.title = "%s - Visual" % device.get_display_name()
	_popup_window.size = Vector2i(800, 600)
	_popup_window.unresizable = false
	
	# Move visual scene to popup
	visual_container.remove_child(_current_visual_scene)
	_popup_window.add_child(_current_visual_scene)
	_current_visual_scene._on_view_shown()
	
	# Handle popup close
	_popup_window.close_requested.connect(_on_popup_window_closed)
	
	# Add to scene tree and show
	get_tree().root.add_child(_popup_window)
	_popup_window.popup_centered()
	
	_is_visual_popped_out = true
	visual_button.disabled = true  # Prevent switching while popped out
	print("[DevicePanel] Visual popped out to window")


func _on_popup_window_closed() -> void:
	"""Handle popup window closing - return visual to panel."""
	if not _popup_window or not _current_visual_scene:
		return
	
	# Unsubscribe while moving
	_current_visual_scene._on_view_hidden()
	
	# Move visual back to panel
	_popup_window.remove_child(_current_visual_scene)
	visual_container.add_child(_current_visual_scene)
	
	# Clean up window
	_popup_window.queue_free()
	_popup_window = null
	
	_is_visual_popped_out = false
	visual_button.disabled = false
	
	# Re-subscribe if Visual tab is active
	if visual_button.button_pressed:
		_current_visual_scene._on_view_shown()
	
	print("[DevicePanel] Visual returned to panel")
```

#### Update Cleanup

```gdscript
func _unbind_from_device(_dev: DeviceInstance):
	"""Clean up when unbinding from device."""
	_clear_parameter_controls()
	_clear_visual_scene()
	
	# Close popup if open
	if _is_visual_popped_out and _popup_window:
		_popup_window.queue_free()
		_popup_window = null
		_is_visual_popped_out = false
```

## Testing Checklist

- [ ] Visual tab appears for spectrum analyzer device
- [ ] Visual tab hidden for devices without visuals
- [ ] Switching tabs properly subscribes/unsubscribes
- [ ] Spectrum visualization updates at ~20Hz
- [ ] FFT size parameter changes affect resolution
- [ ] Closing panel unsubscribes (check logs)
- [ ] Multiple analyzers work independently
- [ ] Popup window functionality (if implemented)
- [ ] No memory leaks when opening/closing panels

## Future Extensions

- **Custom Controls Tab**: Similar system for custom parameter UIs
- **Multiple Visuals**: Devices with multiple visualization modes
- **Dockable Windows**: Integrate with Godot's docking system
- **Visualization Presets**: Save/load visualization settings


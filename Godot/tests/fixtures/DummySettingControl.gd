# DummySettingControl.gd
# Minimal control_scene fixture for test_settings_registry.gd. Implements the
# custom control interface documented in SettingRow.gd without any real UI.
extends Control


signal value_edited(value)

var _value = null


func setup(_setting, value) -> void:
	_value = value


func set_value(value) -> void:
	_value = value


func get_value():
	return _value

# ParameterActions.gd
# Undoable device parameter edits made by the user (parameter list, simple view, device views).
#
# Every user-facing control calls `set_normalized` / `set_real` here instead of the DeviceInstance
# setters; the setter still does the sync (OSC + parameter_changed), this adds the history step.
# Engine echoes, modulation, automation, presets and AI tools never come through here, so they
# never record a step.
#
# Gestures: while a mouse button is held (a drag) or between begin_gesture()/end_gesture(), all
# edits of one parameter merge into one undo step. Anything else (typed value, toggle click,
# wheel notch) is its own step.
#
# Plugin parameters (#124): CLAP/VST3 instances are DeviceInstances too, so their parameter
# controls call these same functions and share the history. Nothing here is built-in specific.
class_name ParameterActions extends RefCounted

const DEFAULT_LABEL := "Set Parameter"
const EPSILON := 0.0001

## Loaded on first use, not referenced by name: scripts that use a view (and so this class) must
## compile where the autoloads HistoryUtil needs are not resolvable yet (headless tests).
static func _history_util() -> GDScript:
	return load("res://history/HistoryUtil.gd")


static func _command_script() -> GDScript:
	return load("res://history/commands/ParameterChangeCommand.gd")


static var _serial: int = 0
static var _explicit_depth: int = 0
static var _explicit_gesture: int = 0
static var _press_gesture: int = 0
static var _was_pressed: bool = false
static var _tracking: bool = false


## Set `param_id` of `inst` to `normalized` (0..1) as an undo step. Returns true when it changed.
static func set_normalized(inst: Object, param_id: int, normalized: float, label: String = DEFAULT_LABEL) -> bool:
	if inst == null:
		return false
	var old_value: float = inst.get_parameter_normalized(param_id)
	inst.set_parameter_normalized(param_id, normalized)
	var new_value: float = inst.get_parameter_normalized(param_id)
	if absf(new_value - old_value) <= EPSILON:
		return false
	var cmd: Command = _command_script().new(label, inst, param_id, old_value, new_value, current_gesture())
	_history_util().record(cmd)
	return true


## Same as `set_normalized` with a value in the parameter's own units.
static func set_real(inst: Object, param_id: int, real_value: float, label: String = DEFAULT_LABEL) -> bool:
	if inst == null:
		return false
	var param = inst.get_parameter(param_id)
	if param == null:
		return false
	return set_normalized(inst, param_id, param.value_to_normalized(real_value), label)


## Reset a parameter to its default as one step.
static func reset(inst: Object, param_id: int) -> bool:
	if inst == null:
		return false
	var param = inst.get_parameter(param_id)
	if param == null:
		return false
	return set_real(inst, param_id, param.default_value, "Reset Parameter")


## Reset every sound parameter of `inst` to its default as one undo step. Returns how many changed.
## MIDI controller parameters (CC tab, SFZ) are left alone.
static func reset_all(inst: Object) -> int:
	if inst == null:
		return 0
	var cmds: Array[Command] = []
	for param in inst.get_parameters():
		if inst.is_controller_parameter(param):
			continue
		var old_value: float = inst.get_parameter_normalized(param.id)
		inst.set_parameter_normalized(param.id, param.value_to_normalized(param.default_value))
		var new_value: float = inst.get_parameter_normalized(param.id)
		if absf(new_value - old_value) > EPSILON:
			cmds.append(_command_script().new("Reset Device", inst, param.id, old_value, new_value, 0))
	_history_util().record_many("Reset Device", cmds)
	return cmds.size()


## Start an explicit gesture (nestable). Edits until the matching end_gesture() merge per parameter.
static func begin_gesture() -> void:
	if _explicit_depth == 0:
		_serial += 1
		_explicit_gesture = _serial
	_explicit_depth += 1


static func end_gesture() -> void:
	_explicit_depth = maxi(0, _explicit_depth - 1)
	if _explicit_depth == 0:
		_explicit_gesture = 0


## Token of the gesture an edit made now belongs to; 0 when it is a discrete edit.
static func current_gesture() -> int:
	if _explicit_depth > 0:
		return _explicit_gesture
	_ensure_tracking()
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		if not _was_pressed or _press_gesture == 0:
			_serial += 1
			_press_gesture = _serial
			_was_pressed = true
		return _press_gesture
	_was_pressed = false
	_press_gesture = 0
	return 0


## Watch the button every frame so a release between two edits is never missed.
static func _ensure_tracking() -> void:
	if _tracking:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	_tracking = true
	tree.process_frame.connect(_on_frame)


static func _on_frame() -> void:
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_was_pressed = false
		_press_gesture = 0

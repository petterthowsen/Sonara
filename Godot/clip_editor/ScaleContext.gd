## Shared scale state for the clip editor views (spec 026). MidiEditor owns one and hands it to
## the lanes, piano header and note editors. The wrappers are no-ops (return their input) when
## scale snap is inactive, which includes no scale and Drum View (REQ-022).
## Keyswitch notes are the caller's concern: check is_keyswitch() and use plain row deltas.
class_name ScaleContext extends RefCounted

signal changed

var scale: MusicalScale = MusicalScale.new():
	set(v):
		scale = v if v != null else MusicalScale.new()
		changed.emit()
var snap_enabled: bool = false:
	set(v):
		if snap_enabled == v:
			return
		snap_enabled = v
		changed.emit()
var fold_enabled: bool = false:
	set(v):
		if fold_enabled == v:
			return
		fold_enabled = v
		changed.emit()
var drum_view: bool = false:
	set(v):
		if drum_view == v:
			return
		drum_view = v
		changed.emit()
var keyswitches: PackedInt32Array = PackedInt32Array():
	set(v):
		keyswitches = v
		changed.emit()


## Scale shading applies: a scale is set and the piano roll (not Drum View) is shown.
func highlight_active() -> bool:
	return not drum_view and not scale.is_none()


func snap_active() -> bool:
	return highlight_active() and snap_enabled


func fold_active() -> bool:
	return highlight_active() and fold_enabled


func is_keyswitch(pitch: int) -> bool:
	return keyswitches.has(pitch)


func pitch_classes() -> PackedInt32Array:
	return scale.pitch_classes()


func snap_pitch(pitch: int, prefer_up: bool) -> int:
	if not snap_active():
		return pitch
	return NoteTransforms.snap_pitch(pitch, scale.pitch_classes(), prefer_up)


func step(pitch: int, steps: int) -> int:
	if not snap_active():
		return pitch
	return NoteTransforms.step_in_scale(pitch, steps, scale.pitch_classes())


func steps_between(from: int, to: int) -> int:
	if not snap_active():
		return 0
	return NoteTransforms.scale_steps_between(from, to, scale.pitch_classes())

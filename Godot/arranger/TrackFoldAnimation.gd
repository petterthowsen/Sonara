# TrackFoldAnimation.gd
# Slide animation for folding a folder/group's children in the arranger. One animation per folder
# is shared by TrackList and Timeline: both call start() when the fold flag changes (the second
# call is a no-op) and both size their rows from AutomationRowOrder.fold_heights(), so header and
# timeline rows move together.
class_name TrackFoldAnimation extends RefCounted

## Emitted on every animation step and once when it finishes.
signal updated
signal finished

## Slide duration for a full fold or unfold, in seconds.
const DURATION := 0.18

## Running animations by folder track.
static var _running: Dictionary = {}

## Folder or group whose children slide.
var track: Track = null

## 0 = children fully hidden, 1 = fully shown.
var reveal: float = 1.0:
	set(value):
		reveal = value
		updated.emit()

var _target: float = 1.0
var _tween: Tween = null


## Animation currently running for `folder`, or null.
static func for_track(folder: Track) -> TrackFoldAnimation:
	return _running.get(folder)


## All running animations.
static func running() -> Array:
	return _running.values()


## Animate `folder` toward its is_folder_expanded state. Reuses (and reverses) a running one.
static func start(folder: Track) -> TrackFoldAnimation:
	if folder == null:
		return null
	var target := 1.0 if folder.is_folder_expanded else 0.0
	var anim: TrackFoldAnimation = _running.get(folder)
	if anim and is_equal_approx(anim._target, target):
		return anim
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	if anim == null:
		anim = TrackFoldAnimation.new()
		anim.track = folder
		anim.reveal = 1.0 - target
		_running[folder] = anim
	elif anim._tween:
		anim._tween.kill()
	anim._target = target
	var duration := DURATION * absf(target - anim.reveal)
	anim._tween = tree.create_tween()
	anim._tween.tween_property(anim, "reveal", target, maxf(duration, 0.01)) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	anim._tween.finished.connect(anim._on_finished)
	return anim


## Jump every running animation to its end (tests, project close).
static func finish_all() -> void:
	for anim in _running.values():
		if anim._tween:
			anim._tween.kill()
		anim.reveal = anim._target
		anim._on_finished()


func _on_finished() -> void:
	_tween = null
	_running.erase(track)
	finished.emit()

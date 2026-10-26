# AutomationLaneView.gd
# Strategy for "which automation lanes of a track are shown" (spec 055). The Arranger and the
# MIDI editor each keep their own answer, so the shared lane menu and the preset actions go
# through a view instead of touching `lane.visible` or `Track.clip_editor_lanes` directly.
#
# Subclasses: ArrangerLaneView (lane.visible) and ClipEditorLaneView (Track.clip_editor_lanes).
class_name AutomationLaneView extends RefCounted


## Whether `lane` is shown in this view.
func is_shown(_track: Object, _lane: Object) -> bool:
	return false


## Show or hide `lane`. Never deletes it, and never changes the other view.
func set_shown(_track: Object, _lane: Object, _on: bool) -> void:
	pass


## The shown lanes of `track`, in this view's order.
func shown_lanes(_track: Object) -> Array:
	return []


## Snapshot of the shown state, for undo. Opaque to callers: hand it back to `restore()`.
func capture(_track: Object) -> Variant:
	return null


## Put `track` back to a state returned by `capture()`.
func restore(_track: Object, _state: Variant) -> void:
	pass


## Make exactly `lanes` (in that order where the view has an order) the shown set.
func apply_shown(_track: Object, _lanes: Array) -> void:
	pass


## Called after a lane was newly created from this view's menu.
func on_lane_created(_track: Object, _lane: Object) -> void:
	pass

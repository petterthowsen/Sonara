# TrackDrag.gd
# Manages track drag and drop operations
class_name TrackDrag

## Payload for Godot GUI track-header drags, including the pre-drag layout snapshot.

signal drag_completed(data: TrackDrag)

var source: TrackItem = null
var destination: TrackItem = null
var track: Track = null
## Movable roots in visual order (selected tracks, minus descendants of other selected folders).
var tracks: Array[Track] = []
var preview: Control = null

## Layout snapshot taken when the drag started; restored on ESC/cancel.
var before_layout: Dictionary = {}

## True after a successful drop so TrackList does not revert on DRAG_END.
var did_commit: bool = false


## Bind the preview's lifetime so TrackList can revert if the drag is cancelled.
func _init(_source: TrackItem, _track: Track, _preview: Control, _tracks: Array[Track] = []):
	self.source = _source
	self.track = _track
	self.tracks = _tracks
	if self.tracks.is_empty() and _track:
		self.tracks = [_track]
	self.preview = _preview
	self.preview.tree_exiting.connect(_on_tree_exiting)


## Emitted when Godot destroys the drag preview (drop, Escape, or drag cancelled).
func _on_tree_exiting() -> void:
	drag_completed.emit(self)

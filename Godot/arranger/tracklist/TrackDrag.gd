# TrackDrag.gd
# Payload for a track header drag. Nothing moves until the drop; see TrackDropTarget.
class_name TrackDrag

signal drag_completed(data: TrackDrag)

var source: TrackItem = null
var track: Track = null
## Movable roots in visual order (selected tracks, minus descendants of other selected parents).
var tracks: Array[Track] = []
var preview: Control = null

## True after a drop changed the layout.
var did_commit: bool = false


## Bind the preview's lifetime so listeners hear when the drag ends.
func _init(_source: TrackItem, _track: Track, _preview: Control, _tracks: Array[Track] = []):
	self.source = _source
	self.track = _track
	self.tracks = _tracks
	if self.tracks.is_empty() and _track:
		self.tracks = [_track]
	self.preview = _preview
	if self.preview:
		self.preview.tree_exiting.connect(_on_tree_exiting)


## Emitted when Godot destroys the drag preview (drop, Escape, or drag cancelled).
func _on_tree_exiting() -> void:
	drag_completed.emit(self)

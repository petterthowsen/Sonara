# TrackDrag.gd
# Manages track drag and drop operations
class_name TrackDrag

signal drag_completed(data: TrackDrag)

var source: TrackItem = null
var destination: TrackItem = null
var track: Track = null
var preview: Control = null

func _init(_source: TrackItem, _track: Track, _preview: Control):
	self.source = _source
	self.track = _track
	self.preview = _preview
	self.preview.tree_exiting.connect(_on_tree_exiting)


func _on_tree_exiting() -> void:
	drag_completed.emit(self)


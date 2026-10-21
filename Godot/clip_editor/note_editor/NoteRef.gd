## A reference to one note, independent of any VisualNote node.
##
## Identity is the `MidiNoteData`: linked instances of a clip and the loop repeats of an
## instance all show the same data, so they are one note. A ref also remembers the `instance`
## it was selected through (for song positioning) and the loop `pass` the user grabbed it in
## (0 = the note itself, k >= 1 = the k-th repeat).
class_name NoteRef extends RefCounted

var instance: ClipInstance = null
var data: MidiNoteData = null
## Loop pass the note was reached through; 0 is the note itself.
var pass_index: int = 0


func _init(p_instance: ClipInstance = null, p_data: MidiNoteData = null, p_pass: int = 0) -> void:
	instance = p_instance
	data = p_data
	pass_index = p_pass


## The clip that owns the note.
var clip: Clip:
	get:
		return instance.clip if instance else null


## The track the note's instance sits on (null in a clip that is not on a track).
var track: Track:
	get:
		return instance.track if instance else null


## Where the note starts in song ticks, as played through `instance` in `pass_index`.
func song_start() -> int:
	return _song_span().x


## Where the note ends in song ticks (a loop repeat ends at the loop wrap).
func song_end() -> int:
	return _song_span().y


func _song_span() -> Vector2i:
	if data == null or instance == null:
		return Vector2i.ZERO
	if pass_index > 0:
		var segs := instance.get_loop_segments()
		if pass_index < segs.size():
			var span := NotePlacement.repeat_ticks(data, segs[pass_index])
			if span.y > span.x:
				return Vector2i(instance.start_ticks + span.x, instance.start_ticks + span.y)
	var origin := instance.content_origin_ticks()
	return Vector2i(origin + data.start_tick, origin + data.start_tick + data.duration_ticks)

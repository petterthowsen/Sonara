# ClipNaming.gd
# Automatic clip names: `<track name> <N>`, with N counted among that track's own clips. A clip
# remembers the track name its name was built from (`Clip.auto_name_track`); that is empty once
# the user typed a name, and such names are never changed automatically.
class_name ClipNaming extends RefCounted


## Next `<track> N` for a new clip on `track`: one past the highest N among the track's clips,
## skipping any name already in the pool (two tracks can share a name). `reserved` lists names
## handed out to clips not pooled yet.
static func next_name(project: Project, track: Track, reserved: PackedStringArray = PackedStringArray()) -> String:
	var prefix := track.name + " "
	var highest := 0
	for inst in track.clip_instances:
		if inst != null and inst.clip != null:
			highest = maxi(highest, _number_after(inst.clip.name, prefix))
	var taken := _pool_names(project, null)
	taken.append_array(reserved)
	var n := highest + 1
	while DeviceNaming.is_taken(taken, prefix + str(n)):
		n += 1
	return prefix + str(n)


## Name for `clip` once it belongs to `track` alone: its track name swapped for `track`'s. Falls
## back to the next free number when the swapped name is already taken. Empty when `clip` keeps
## its name (custom, or built from this track already).
static func name_after_track_change(project: Project, clip: Clip, track: Track) -> String:
	if not _is_retargetable(clip, track) or clip.auto_name_track == track.name:
		return ""
	var swapped := clip.name.replace(clip.auto_name_track, track.name)
	if DeviceNaming.is_taken(_pool_names(project, clip), swapped):
		return next_name(project, track)
	return swapped


## Name for a copy of `clip` that will live on `track`, or empty when the copy keeps the
## ordinary `unique_clip_name` treatment (custom name).
static func name_for_copy(project: Project, clip: Clip, track: Track) -> String:
	if not _is_retargetable(clip, track):
		return ""
	if clip.auto_name_track == track.name:
		return next_name(project, track)
	return name_after_track_change(project, clip, track)


static func _is_retargetable(clip: Clip, track: Track) -> bool:
	return clip != null and track != null and not clip.auto_name_track.is_empty() \
		and clip.name.contains(clip.auto_name_track)


static func _number_after(clip_name: String, prefix: String) -> int:
	if not clip_name.begins_with(prefix):
		return 0
	var tail := clip_name.substr(prefix.length())
	return int(tail) if tail.is_valid_int() else 0


static func _pool_names(project: Project, except: Clip) -> PackedStringArray:
	var names := PackedStringArray()
	for c in project.clips.values():
		if c is Clip and c != except:
			names.append(c.name)
	return names

# AudioClipTiming.gd
# Maths and undoable edits for an audio clip's stretch mode and tempo (spec 029).
class_name AudioClipTiming extends RefCounted

const MIN_BPM := 20.0
const MAX_BPM := 999.0
const MODE_BADGES: Array[String] = ["", "P", "S"]
const MODE_LABELS: Array[String] = ["Raw", "Repitch", "Stretch"]


## Short header badge for a mode: empty for Raw, `P` for Repitch, `S` for Stretch.
static func badge(mode: Clip.StretchMode) -> String:
	return MODE_BADGES[mode]


## Source frames covered by one timeline tick of an instance of `clip` that starts at
## `start_tick`, in `source_rate` frames per second. Matches the engine:
## - Raw reads the file at its own speed, so the project tempo at the instance start sets the
##   scale. A tempo change under the clip draws slightly off (the waveform is linear in ticks).
## - Repitch and Stretch use the clip tempo (Stretch plays like Repitch for now).
static func frames_per_tick(clip: Clip, start_tick: int, tempo_map: TempoMap, fallback_tempo: float,
		ppq: int, source_rate: float) -> float:
	var bpm := clip.recorded_bpm if clip.recorded_bpm > 0.0 else fallback_tempo
	if clip.stretch_mode == Clip.StretchMode.RAW:
		bpm = tempo_map.get_bpm_at_tick(float(start_tick), fallback_tempo) if tempo_map != null else fallback_tempo
	return source_rate * 60.0 / (maxf(1.0, bpm) * float(maxi(1, ppq)))


## Every instance of `clip` in `project`, across all tracks.
static func instances_of(project: Project, clip: Clip) -> Array[ClipInstance]:
	var out: Array[ClipInstance] = []
	for track in project.tracks:
		for inst in track.clip_instances:
			if inst.clip == clip or inst.clip_id == clip.id:
				out.append(inst)
	return out


## One undo step that sets `clip`'s tempo to `new_bpm`, rescales its content length and rescales
## every instance's duration, offset and loop region by `new_bpm / old_bpm`, so each instance
## still covers the same stretch of audio. Null when nothing changes.
static func tempo_change_command(project: Project, clip: Clip, new_bpm: float) -> Command:
	new_bpm = clampf(new_bpm, MIN_BPM, MAX_BPM)
	var old_bpm := clip.recorded_bpm
	if old_bpm <= 0.0 or is_equal_approx(old_bpm, new_bpm):
		return null
	var ratio := new_bpm / old_bpm
	var macro := MacroCommand.new("Set Clip Tempo")
	macro.add(PropertyCommand.new("Set Clip Tempo", clip, "set_recorded_bpm", old_bpm, new_bpm))
	var old_len := clip.content_length_ticks
	var new_len := clip.content_length_for_tempo(new_bpm, project.ppq)
	if new_len <= 0:
		new_len = maxi(1, roundi(float(old_len) * ratio))
	macro.add(PropertyCommand.new("Set Clip Tempo", clip, "set_content_length", old_len, new_len))
	for inst in instances_of(project, clip):
		var old_loop := [inst.loop_enabled, inst.loop_start_ticks, inst.loop_length_ticks]
		var new_loop := [inst.loop_enabled, roundi(float(inst.loop_start_ticks) * ratio),
				maxi(1, roundi(float(inst.loop_length_ticks) * ratio))]
		macro.add(ClipInstanceTransformCommand.new("Set Clip Tempo", inst,
				inst.start_ticks, inst.duration_ticks, inst.clip_offset,
				inst.start_ticks, maxi(1, roundi(float(inst.duration_ticks) * ratio)),
				roundi(float(inst.clip_offset) * ratio), old_loop, new_loop))
	return macro

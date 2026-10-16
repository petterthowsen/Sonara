## Key estimate from MIDI notes (spec 048 REQ-010..012). Duration-weighted pitch-class histogram,
## Pearson correlation against the Krumhansl-Kessler major and minor profiles on all 12 roots,
## best of 24 wins. Pure and scene-free. `collect` takes the project untyped on purpose: typing it
## would pull Project.gd (and its autoload references) in whenever this script is compiled.
class_name KeyDetector extends RefCounted

## Fewer notes or distinct pitch classes than this means "Not enough notes".
const MIN_NOTES := 4
const MIN_PCS := 3
## Confidence from the gap between the best and the runner-up correlation. Tunable.
const HIGH_MARGIN := 0.10
const MEDIUM_MARGIN := 0.04

## Track.TrackType.INSTRUMENT and Clip.ClipType.MIDI as plain ints: naming those classes here would
## compile Track.gd and Clip.gd (and the autoloads they use) with this script, which the headless
## tests load before the autoloads exist.
const TRACK_TYPE_INSTRUMENT := 1
const CLIP_TYPE_MIDI := 1

const NOT_ENOUGH_NOTES := "Not enough notes"

## Krumhansl-Kessler key profiles, index = semitones above the tonic.
const MAJOR_PROFILE: Array[float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
const MINOR_PROFILE: Array[float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]


## Pitch-class histogram (12 floats, index 0 = C). Each note adds its duration in ticks, or 1 when
## `weights_by_duration` is false.
static func histogram(notes: Array[MidiNoteData], weights_by_duration: bool = true) -> PackedFloat32Array:
	var hist := PackedFloat32Array()
	hist.resize(12)
	for n in notes:
		hist[posmod(n.note, 12)] += float(maxi(1, n.duration_ticks)) if weights_by_duration else 1.0
	return hist


## Histogram of `[pitch, duration]` pairs, as `collect` returns them.
static func histogram_from_pairs(pairs: Array) -> PackedFloat32Array:
	var hist := PackedFloat32Array()
	hist.resize(12)
	for pair: Array in pairs:
		hist[posmod(int(pair[0]), 12)] += float(maxi(1, int(pair[1])))
	return hist


## Estimate the key from a histogram. `note_count` is how many notes built it (the threshold
## counts notes, which a histogram of durations cannot tell). Returns
## `{ok, root, type_id, confidence: "High"/"Medium"/"Low", margin, reason}`. When `ok` is false
## `reason` is NOT_ENOUGH_NOTES and there is no result. The type is "major" or "natural_minor".
static func detect(hist: PackedFloat32Array, note_count: int = MIN_NOTES) -> Dictionary:
	var pcs := 0
	for v in hist:
		if v > 0.0:
			pcs += 1
	if note_count < MIN_NOTES or pcs < MIN_PCS:
		return {"ok": false, "reason": NOT_ENOUGH_NOTES}
	var best_score := -2.0
	var second_score := -2.0
	var best_root := 0
	var best_type := "major"
	for root in 12:
		for minor in [false, true]:
			var score := _correlation(hist, MINOR_PROFILE if minor else MAJOR_PROFILE, root)
			if score > best_score:
				second_score = best_score
				best_score = score
				best_root = root
				best_type = "natural_minor" if minor else "major"
			elif score > second_score:
				second_score = score
	var margin := best_score - second_score
	var confidence := "Low"
	if margin >= HIGH_MARGIN:
		confidence = "High"
	elif margin >= MEDIUM_MARGIN:
		confidence = "Medium"
	return {"ok": true, "root": best_root, "type_id": best_type, "confidence": confidence,
			"margin": margin, "reason": ""}


## Detect straight from notes (duration-weighted).
static func detect_notes(notes: Array[MidiNoteData]) -> Dictionary:
	return detect(histogram(notes), notes.size())


## Detect straight from `[pitch, duration]` pairs.
static func detect_pairs(pairs: Array) -> Dictionary:
	return detect(histogram_from_pairs(pairs), pairs.size())


## The song span a Detect on key change `change_id` looks at, as Vector2i(from_tick, to_tick) with
## to_tick -1 for the end of the song. Id 0 is the start key (the transport's Detect): it runs up
## to the first key change. A key change runs from its tick up to the next change. Returns
## Vector2i(-1, -1) for an unknown id.
static func span_for_change(project, change_id: int) -> Vector2i:
	var changes: Array = project.key_change_map.changes
	if change_id == 0:
		return Vector2i(0, int(changes[0]["tick"]) if not changes.is_empty() else -1)
	var index: int = project.key_change_map.index_of(change_id)
	if index < 0:
		return Vector2i(-1, -1)
	var next_tick := int(changes[index + 1]["tick"]) if index + 1 < changes.size() else -1
	return Vector2i(int(changes[index]["tick"]), next_tick)


## Detect the key of the notes of `project` over key change `change_id` (see span_for_change):
## the result of detect_pairs, or "Not enough notes" for an unknown id.
static func detect_for_change(project, change_id: int) -> Dictionary:
	var span := span_for_change(project, change_id)
	if span.x < 0:
		return detect_pairs([])
	return detect_pairs(collect(project, span.x, span.y))


## Pearson correlation of `hist` with `profile` rotated to start on `root`.
static func _correlation(hist: PackedFloat32Array, profile: Array[float], root: int) -> float:
	var mean_h := 0.0
	var mean_p := 0.0
	for i in 12:
		mean_h += hist[i]
		mean_p += profile[i]
	mean_h /= 12.0
	mean_p /= 12.0
	var cov := 0.0
	var var_h := 0.0
	var var_p := 0.0
	for i in 12:
		var h := hist[(root + i) % 12] - mean_h
		var p := profile[i] - mean_p
		cov += h * p
		var_h += h * h
		var_p += p * p
	if var_h <= 0.0 or var_p <= 0.0:
		return 0.0
	return cov / sqrt(var_h * var_p)


## `[pitch, song_duration]` pairs for every note that starts in the song span [from_tick, to_tick)
## (to_tick < 0 means the end of the song). Skips non-instrument tracks, tracks whose channel is in
## drum view (NoteMapResolver.wants_drum_view) and muted instances. A note counts only where the
## instance actually plays it (its first run, repeats of a loop are not counted twice); the pitch
## includes the instance's transpose and the duration is cut to the instance and to the span.
static func collect(project, from_tick: int, to_tick: int = -1) -> Array:
	var pairs: Array = []
	var resolver: GDScript = load("res://data/NoteMapResolver.gd")
	for track in project.tracks:
		if track.type != TRACK_TYPE_INSTRUMENT:
			continue
		if resolver.wants_drum_view(track.get_linked_channel()):
			continue
		for inst in track.clip_instances:
			if inst == null or inst.muted or inst.clip == null or inst.clip.type != CLIP_TYPE_MIDI:
				continue
			var window_start: int = inst.start_ticks
			var window_end: int = inst.get_end_ticks()
			var lo := maxi(from_tick, window_start)
			var hi := window_end if to_tick < 0 else mini(to_tick, window_end)
			var run: Vector2i = inst.first_run_range()
			for note: MidiNoteData in inst.clip.midi_notes:
				if note.start_tick < run.x or note.start_tick >= run.y:
					continue
				var start: int = inst.clip_to_song_ticks(note.start_tick)
				if start < lo or start >= hi:
					continue
				var end := mini(start + note.duration_ticks, hi)
				pairs.append([clampi(note.note + inst.transpose, 0, 127), maxi(1, end - start)])
	return pairs

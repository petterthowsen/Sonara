# AnalysisRoots.gd
# The `root` row of the analyze grid: per bar (or beat), the pitch class the lowest sounding note
# spends longest on, from the project's MIDI clips on pitched (non-drum) instrument tracks.
# Harmony comes from MIDI, not audio (docs/analyze-plan.md). Middle C = C3 = MIDI 60.
class_name AnalysisRoots extends RefCounted

const PITCH_CLASSES: PackedStringArray = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


## One entry per `[start, end)` span in ticks: a pitch class name, or "-" when nothing pitched sounds.
static func compute(project: Project, spans: Array) -> PackedStringArray:
	var notes := pitched_notes(project)
	var out: PackedStringArray = []
	for span in spans:
		out.append(root_in_span(notes, int(span.x), int(span.y)))
	return out


## Every sounding note on pitched instrument tracks as song-tick `Vector3i(start, end, pitch)`.
## Loops, trims, transpose and muted instances are honoured.
static func pitched_notes(project: Project) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for track in project.tracks:
		if track.type != Track.TrackType.INSTRUMENT or AiTool.track_prefers_drums(project, track):
			continue
		for inst in track.clip_instances:
			if inst == null or inst.muted or inst.clip == null or inst.clip.type != Clip.ClipType.MIDI:
				continue
			for run in inst.get_loop_segments():
				var content_from: int = run.z
				var content_to: int = content_from + (run.y - run.x)
				for n in inst.clip.midi_notes:
					var a := maxi(n.start_tick, content_from)
					var b := mini(n.get_end_tick(), content_to)
					if b <= a:
						continue
					var shift: int = inst.start_ticks + run.x - content_from
					out.append(Vector3i(a + shift, b + shift, clampi(n.note + inst.transpose, 0, 127)))
	return out


static func root_in_span(notes: Array[Vector3i], from: int, to: int) -> String:
	var inside: Array[Vector3i] = []
	var cuts: Array[int] = [from, to]
	for n in notes:
		if n.y <= from or n.x >= to:
			continue
		inside.append(n)
		cuts.append(clampi(n.x, from, to))
		cuts.append(clampi(n.y, from, to))
	if inside.is_empty():
		return "-"
	cuts.sort()
	var length := {}   # pitch class -> ticks the lowest note was on it
	var lowest := {}   # pitch class -> lowest pitch seen, breaks ties
	for i in cuts.size() - 1:
		var a := cuts[i]
		var b := cuts[i + 1]
		if b <= a:
			continue
		var low := 128
		for n in inside:
			if n.x <= a and n.y >= b:
				low = mini(low, n.z)
		if low == 128:
			continue
		var pc := low % 12
		length[pc] = int(length.get(pc, 0)) + (b - a)
		lowest[pc] = mini(int(lowest.get(pc, 128)), low)
	var best := -1
	for pc in length:
		if best < 0 or length[pc] > length[best] or (length[pc] == length[best] and lowest[pc] < lowest[best]):
			best = pc
	return PITCH_CLASSES[best] if best >= 0 else "-"

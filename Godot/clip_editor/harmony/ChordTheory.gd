## Chord theory for the harmony tools (spec 048): Roman numeral progressions, diatonic chords,
## voicing inside a note range, smooth voice leading and chord root detection. Pure static
## functions with no scene dependency. Pitch classes are 0..11 (0 = C); pitches are MIDI notes.
## Degrees are 0-based here: 0 = I, 1 = ii, ... (the parser maps numerals to this).
class_name ChordTheory extends RefCounted

enum Voicing { CLOSE, SPREAD }

## Named progressions for the Insert Chords dialog (`text` goes through parse_progression).
const PRESETS: Array[Dictionary] = [
	{"name": "I V vi IV (pop)", "text": "I V vi IV"},
	{"name": "I vi IV V (50s)", "text": "I vi IV V"},
	{"name": "ii V I (jazz)", "text": "ii7 V7 I7"},
	{"name": "I IV V I (blues-rock)", "text": "I IV V I"},
	{"name": "vi IV I V", "text": "vi IV I V"},
	{"name": "I IV vi V", "text": "I IV vi V"},
	{"name": "i VI III VII (minor)", "text": "i VI III VII"},
	{"name": "i iv v i (minor)", "text": "i iv v i"},
]

const _NUMERALS: Array[String] = ["i", "ii", "iii", "iv", "v", "vi", "vii"]

## Chord templates for root detection: intervals above the root. The fifth (index 2) may be
## missing from the played chord. Order is the final tie-break.
const _TEMPLATES: Array[Array] = [
	[0, 4, 7], [0, 3, 7], [0, 3, 6], [0, 4, 8],
	[0, 4, 7, 11], [0, 4, 7, 10], [0, 3, 7, 10], [0, 3, 6, 10], [0, 3, 6, 9],
]


# --- Progression parsing (REQ-033) ------------------------------------------------------------

## Parse "I V vi IV" / "ii7-V7-I" into `{steps: [{degree, seventh}], error: String, bad_token}`.
## Numerals are I..VII in any case with an optional trailing 7, separated by spaces, dashes or
## commas. `degree` is 0-based. On a bad token `steps` is empty, `bad_token` holds the token and
## `error` names it. Empty input is an error as well (nothing to insert).
static func parse_progression(text: String) -> Dictionary:
	var steps: Array[Dictionary] = []
	var normalized := text.replace("-", " ").replace(",", " ").replace("\t", " ")
	for token in normalized.split(" ", false):
		var body := token.to_lower()
		var seventh := body.ends_with("7")
		if seventh:
			body = body.left(body.length() - 1)
		var degree := _NUMERALS.find(body)
		if degree < 0:
			return {"steps": [] as Array[Dictionary], "error": "Unknown chord \"%s\"" % token, "bad_token": token}
		steps.append({"degree": degree, "seventh": seventh})
	if steps.is_empty():
		return {"steps": steps, "error": "Enter at least one chord", "bad_token": ""}
	return {"steps": steps, "error": "", "bad_token": ""}


# --- Diatonic chords (REQ-033) ----------------------------------------------------------------

## Scale pitch classes in scale order starting on the root (not sorted by value): the intervals
## above the root are ascending, so this is root, 2nd, 3rd, ...
static func scale_degrees(scale: MusicalScale) -> PackedInt32Array:
	var out := PackedInt32Array()
	for iv in MusicalScale.intervals_for(scale.type_id):
		out.append(posmod(scale.root + iv, 12))
	return out


## Pitch classes of the chord on 0-based `degree`, in stacking order (root first): every other
## scale note, so a triad (or four notes with `seventh`). Degrees and the stacking wrap mod the
## scale size, so scales that don't have 7 notes follow the same rule. Empty for no scale.
static func chord_tones(scale: MusicalScale, degree: int, seventh: bool = false) -> PackedInt32Array:
	var degrees := scale_degrees(scale)
	var out := PackedInt32Array()
	if degrees.is_empty():
		return out
	var n := degrees.size()
	for k in (4 if seventh else 3):
		out.append(degrees[posmod(degree + 2 * k, n)])
	return out


# --- Voicing (REQ-034) ------------------------------------------------------------------------

## Place the chord `tones` (pitch classes, stacking order) as MIDI pitches, ascending, inside
## `range` (Vector2i(lo, hi), inclusive). `bass_index` picks the inversion: that tone is the
## lowest, the rest follow upward in stacking order. CLOSE stacks the tones within an octave;
## SPREAD moves the middle tone of a triad (the 2nd and 4th of a seventh chord) up an octave.
## The bass is the lowest pitch >= range.x with its pitch class. Notes that still end up outside
## the range are folded by whole octaves, and `clamped` reports that it happened (a range too
## narrow for a pitch class is clamped to its nearest edge).
## Returns `{pitches: PackedInt32Array (ascending), clamped: bool}`.
static func voice_ex(tones: PackedInt32Array, bass_index: int, range: Vector2i,
		voicing: Voicing = Voicing.CLOSE) -> Dictionary:
	var bass := range.x + posmod(tones[bass_index] - range.x, 12)
	return _voice_from_bass(tones, bass_index, bass, range, voicing)


## `voice_ex(...).pitches`.
static func voice(tones: PackedInt32Array, bass_index: int, range: Vector2i,
		voicing: Voicing = Voicing.CLOSE) -> PackedInt32Array:
	return voice_ex(tones, bass_index, range, voicing).pitches


## Stack `tones` upward from the explicit `bass` pitch (its pitch class must be tones[bass_index]).
static func _voice_from_bass(tones: PackedInt32Array, bass_index: int, bass: int, range: Vector2i,
		voicing: Voicing) -> Dictionary:
	var pitches := PackedInt32Array()
	if tones.is_empty():
		return {"pitches": pitches, "clamped": false}
	var current := bass
	pitches.append(current)
	for i in range(1, tones.size()):
		var pc := tones[(bass_index + i) % tones.size()]
		current += posmod(pc - current, 12)
		if current == pitches[pitches.size() - 1]:
			current += 12
		pitches.append(current)
	if voicing == Voicing.SPREAD and pitches.size() >= 3:
		pitches[1] += 12
		if pitches.size() >= 4:
			pitches[3] += 12
		pitches.sort()
	var clamped := false
	for i in pitches.size():
		var p := pitches[i]
		if p >= range.x and p <= range.y:
			continue
		clamped = true
		while p > range.y and p - 12 >= range.x:
			p -= 12
		while p < range.x and p + 12 <= range.y:
			p += 12
		pitches[i] = clampi(p, range.x, range.y)
	pitches.sort()
	return {"pitches": pitches, "clamped": clamped}


## The inversion and octave placement of `tones` closest to the chord `prev` (MIDI pitches):
## every inversion, at every octave placement of its bass inside `range`, is voiced and the one
## with the smallest total movement wins. Candidates that needed clamping lose to any that fit.
## Ties go to the lower inversion, then the lower placement. Returns `{pitches, clamped}` as
## voice_ex does; with an empty `prev` it is the root position.
static func smooth_next_ex(prev: PackedInt32Array, tones: PackedInt32Array, range: Vector2i,
		voicing: Voicing = Voicing.CLOSE) -> Dictionary:
	if prev.is_empty() or tones.is_empty():
		return voice_ex(tones, 0, range, voicing)
	var best: Dictionary = {}
	var best_cost := INF
	for inversion in tones.size():
		var first_bass := range.x + posmod(tones[inversion] - range.x, 12)
		var bass := first_bass
		while bass <= range.y:
			var candidate := _voice_from_bass(tones, inversion, bass, range, voicing)
			var cost := _movement(prev, candidate.pitches) + (100000.0 if candidate.clamped else 0.0)
			if cost < best_cost:
				best_cost = cost
				best = candidate
			bass += 12
	if best.is_empty():
		return voice_ex(tones, 0, range, voicing)
	return best


## `smooth_next_ex(...).pitches`.
static func smooth_next(prev: PackedInt32Array, tones: PackedInt32Array, range: Vector2i,
		voicing: Voicing = Voicing.CLOSE) -> PackedInt32Array:
	return smooth_next_ex(prev, tones, range, voicing).pitches


## Total pitch distance between two chords: sorted voices are paired off, and when the sizes
## differ each extra voice of the bigger chord counts its distance to the nearest note of the other.
static func _movement(a: PackedInt32Array, b: PackedInt32Array) -> float:
	var small := a if a.size() <= b.size() else b
	var big := b if a.size() <= b.size() else a
	var small_sorted := Array(small)
	var big_sorted := Array(big)
	small_sorted.sort()
	big_sorted.sort()
	var total := 0
	for i in big_sorted.size():
		if i < small_sorted.size():
			total += absi(int(big_sorted[i]) - int(small_sorted[i]))
		else:
			var nearest := 127
			for s: int in small_sorted:
				nearest = mini(nearest, absi(int(big_sorted[i]) - s))
			total += nearest
	return float(total)


## Total movement of a list of chords (each PackedInt32Array), summed over neighbouring pairs.
static func total_movement(chords: Array) -> float:
	var total := 0.0
	for i in range(1, chords.size()):
		total += _movement(chords[i - 1], chords[i])
	return total


# --- Root detection (REQ-036) -----------------------------------------------------------------

## Pitch class of the root of the chord sounding `pitches` (MIDI notes). Each pitch class is tried
## as a root against major, minor, diminished and augmented triads and the maj7, 7, m7, m7b5 and
## dim7 chords: every played pitch class must belong to the chord, and only its fifth may be
## missing. Of several matches a complete chord beats one without its fifth, then a root equal to
## the lowest sounding note wins, then template order. Without a match, or for a major sixth
## chord (see below), the lowest note's pitch class is returned. -1 for no notes.
##
## Major sixth chords: a bass with its major third, fifth and major sixth above it (C E G A) reads
## as that bass (C6), not as the relative minor seventh (Am7), as design.md decides. The same
## shape is only treated this way for a major triad plus 6: other inversions (a dominant seventh
## over its third, a half-diminished seventh over its minor third) keep their real root.
static func detect_root(pitches: PackedInt32Array) -> int:
	if pitches.is_empty():
		return -1
	var lowest := pitches[0]
	for p in pitches:
		lowest = mini(lowest, p)
	var bass_pc := posmod(lowest, 12)
	var present := {}
	for p in pitches:
		present[posmod(p, 12)] = true
	if present.size() == 4 and present.has(posmod(bass_pc + 4, 12)) \
			and present.has(posmod(bass_pc + 7, 12)) and present.has(posmod(bass_pc + 9, 12)):
		return bass_pc
	var best_root := -1
	var best_key: Array = []
	for root: int in present.keys():
		for t in _TEMPLATES.size():
			var template: Array = _TEMPLATES[t]
			var tones := {}
			for iv: int in template:
				tones[posmod(root + iv, 12)] = true
			var fits := true
			for pc: int in present.keys():
				if not tones.has(pc):
					fits = false
					break
			if not fits:
				continue
			var missing := 0
			var ok := true
			for ti in template.size():
				var pc := posmod(root + int(template[ti]), 12)
				if not present.has(pc):
					missing += 1
					if ti != 2:
						ok = false
			if not ok or missing > 1:
				continue
			var key := [missing, 0 if root == bass_pc else 1, t]
			if best_key.is_empty() or _key_less(key, best_key):
				best_key = key
				best_root = root
	return best_root if best_root >= 0 else bass_pc


static func _key_less(a: Array, b: Array) -> bool:
	for i in a.size():
		if a[i] != b[i]:
			return a[i] < b[i]
	return false

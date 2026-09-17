## CompoundDetector.gd
## Merges parameters whose names share a stem into compound controls (REQ-005):
## `x`/`y` → xy, attack/decay/sustain/release → envelope, freq/gain/q → eq_band.
## Incomplete patterns stay single controls.

class_name CompoundDetector extends RefCounted

## Parts in `params` order; each part lists the name tokens that identify it.
const PATTERNS: Array[Dictionary] = [
	{"kind": SimpleControlKinds.XY, "label": "XY", "parts": [["x"], ["y"]]},
	{"kind": SimpleControlKinds.ENVELOPE, "label": "Envelope", "parts": [
		["attack", "att", "atk"], ["decay", "dec"], ["sustain", "sus"], ["release", "rel"]]},
	{"kind": SimpleControlKinds.EQ_BAND, "label": "EQ", "parts": [["freq", "frequency"], ["gain"], ["q"]]},
]

## Trailing unit words ignored when finding a parameter's part token ("Attack (ms)").
const UNIT_TOKENS := ["ms", "s", "sec", "hz", "khz", "db", "pct", "percent"]
const TIME_UNITS := ["s", "ms", "sec"]
## Envelope time parts without a unit need a range that looks like seconds.
const MAX_UNITLESS_SECONDS := 60.0
## Envelope parts (by index) that must look like times; sustain is a level.
const ENVELOPE_TIME_PARTS := [0, 1, 3]


## Turn classified entries (see `ParamClassifier.classify`) into generated items, keeping order.
## Each item: `{kind, params: Array[int], label, name, role, importance, module, index}`;
## a compound sits where its earliest parameter was.
static func detect(entries: Array[Dictionary]) -> Array[Dictionary]:
	# pattern index → stem → {part index → entry}
	var found: Array[Dictionary] = []
	for _p in PATTERNS:
		found.append({})
	for entry in entries:
		var param: DeviceParameter = entry.param
		if param.param_type != "float":
			continue
		var split := _stem_and_part(param.name)
		if split.is_empty():
			continue
		for p in range(PATTERNS.size()):
			var parts: Array = PATTERNS[p].parts
			for part in range(parts.size()):
				if split.part in parts[part]:
					var by_stem: Dictionary = found[p].get_or_add(split.stem, {})
					if not by_stem.has(part):
						by_stem[part] = entry

	var compound_at := {}  # index of first member → item
	var consumed := {}  # entry index → true
	for p in range(PATTERNS.size()):
		var pattern: Dictionary = PATTERNS[p]
		for stem in found[p]:
			var by_part: Dictionary = found[p][stem]
			if by_part.size() != pattern.parts.size():
				continue
			var members: Array[Dictionary] = []
			for part in range(pattern.parts.size()):
				members.append(by_part[part])
			if _any_consumed(members, consumed):
				continue
			if pattern.kind == SimpleControlKinds.ENVELOPE and not _looks_like_envelope(members):
				continue
			var item := _compound_item(pattern, stem, members)
			for m in members:
				consumed[m.index] = true
			compound_at[item.index] = item

	var items: Array[Dictionary] = []
	for entry in entries:
		if compound_at.has(entry.index):
			items.append(compound_at[entry.index])
		elif not consumed.has(entry.index):
			items.append(single_item(entry))
	return items


## Generated item for one classified parameter.
static func single_item(entry: Dictionary) -> Dictionary:
	return {
		"kind": entry.kind,
		"params": [entry.id],
		"label": "",
		"name": entry.param.name,
		"role": entry.role,
		"importance": entry.importance,
		"module": entry.module,
		"index": entry.index,
	}


## `{stem, part}` for a name: the last non-unit token is the part, the tokens before it the stem.
static func _stem_and_part(param_name: String) -> Dictionary:
	var tokens := ParamClassifier.name_tokens(param_name)
	if tokens.size() > 1 and tokens[-1] in UNIT_TOKENS:
		tokens.remove_at(tokens.size() - 1)
	if tokens.is_empty():
		return {}
	return {"stem": " ".join(tokens.slice(0, -1)), "part": tokens[-1]}


static func _any_consumed(members: Array[Dictionary], consumed: Dictionary) -> bool:
	for m in members:
		if consumed.has(m.index):
			return true
	return false


## Attack, decay and release must be times: a time unit, or no unit and a 0–60 range.
static func _looks_like_envelope(members: Array[Dictionary]) -> bool:
	for i in ENVELOPE_TIME_PARTS:
		var param: DeviceParameter = members[i].param
		if param.unit in TIME_UNITS:
			continue
		if not param.unit.is_empty() or param.min_value < 0.0 or param.max_value > MAX_UNITLESS_SECONDS:
			return false
	return true


static func _compound_item(pattern: Dictionary, stem: String, members: Array[Dictionary]) -> Dictionary:
	var params: Array = []
	var importance := 0.0
	var first: Dictionary = members[0]
	for m in members:
		params.append(m.id)
		importance = maxf(importance, m.importance)
		if m.index < first.index:
			first = m
	var label: String = pattern.label if stem.is_empty() else stem.capitalize()
	return {
		"kind": pattern.kind,
		"params": params,
		"label": label,
		"name": label,
		"role": members[0].role,
		"importance": importance,
		"module": first.module,
		"index": first.index,
	}

## NameSections.gd
## Finds the sections a device's parameter names spell out, for devices whose module paths don't
## group anything (REQ-006). "Oscillator 1 Volume" and "Oscillator 1 Pan" form section
## "Oscillator 1" with control labels "Volume" and "Pan"; "Filter Cutoff" and "Filter Drive" form
## "Filter". Works on generated items (see `CompoundDetector.detect`).

class_name NameSections extends RefCounted

## A numbered family with more instances than this ("Step 1" … "Step 16") is one section, not one
## per instance.
const MAX_INSTANCE_SECTIONS := 8
## A family is split into one section per instance only when instances average this many items.
const MIN_ITEMS_PER_INSTANCE := 2
## Names only group a device when sections cover at least this share of its items.
const MIN_COVERAGE := 0.5

static var _word := RegEx.create_from_string("[A-Za-z0-9]+")
## A word with an instance number glued on: "Osc1", "LFO2".
static var _glued := RegEx.create_from_string("^([A-Za-z]+)([0-9]+)$")
static var _leading_separators := RegEx.create_from_string("^[\\s:/|._-]+")


## Section per item index: `{index: {id, title, label, family, family_title?}}`, or {} when fewer
## than `MIN_COVERAGE` of the items would get one. `label` is the name without its section; `family`
## is shared by the instance sections of one family ("Oscillator 1", "Oscillator 2") so they can
## stay together, and those sections also carry the family's name (`family_title`, "Oscillator").
## Items without a section are left out.
static func find(items: Array[Dictionary]) -> Dictionary:
	var families := {}  # family key → Array of member descriptions
	var buckets := {}  # first word → Array of member descriptions
	for item in items:
		var info := _describe(item)
		if info.is_empty():
			continue
		if info.has("family"):
			families.get_or_add(info.family, []).append(info)
		else:
			buckets.get_or_add(info.words[0].lower, []).append(info)
	var result := {}
	for key in families:
		_assign_family(key, families[key], result)
	for key in buckets:
		_assign_bucket(buckets[key], result)
	if result.size() < MIN_COVERAGE * items.size():
		return {}
	return result


## Words of `text` with their positions: `[{text, lower, start, end}]`.
static func words(text: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for m in _word.search_all(text):
		var w := m.get_string()
		out.append({"text": w, "lower": w.to_lower(), "start": m.get_start(), "end": m.get_end()})
	return out


## `text` up to the end of its first `count` words ("Oscillator 1 Volume", 2 → "Oscillator 1").
static func prefix(text: String, word_list: Array[Dictionary], count: int) -> String:
	if count <= 0 or word_list.is_empty():
		return ""
	return text.left(word_list[mini(count, word_list.size()) - 1].end).strip_edges()


## `text` after its first `count` words, without leading separators ("Osc 1: Fine", 2 → "Fine").
static func rest(text: String, word_list: Array[Dictionary], count: int) -> String:
	if count <= 0:
		return text.strip_edges()
	if count >= word_list.size():
		return ""
	return _leading_separators.sub(text.substr(word_list[count - 1].end), "").strip_edges()


## How an item's name splits. Numbered: `{family, family_title, instance, section_title, label}`
## from the first instance number that has a word before it ("Mod Env 1 Attack" → family
## "mod env", instance 1). Otherwise `{words}` for grouping by leading words. Compounds (whose
## name is just their stem) may end at the number; a plain parameter needs a name after it.
static func _describe(item: Dictionary) -> Dictionary:
	var name := String(item.name)
	var w := words(name)
	if w.is_empty():
		return {}
	var is_compound := item.has("kind_label")
	var info := {"index": item.index, "name": name, "words": w, "compound": is_compound,
		"kind_label": String(item.get("kind_label", ""))}
	for k in range(w.size()):
		var family_end := -1
		var number := ""
		var m := _glued.search(w[k].text)
		if w[k].lower.is_valid_int() and k >= 1:
			family_end = w[k - 1].end
			number = w[k].lower
		elif m != null:
			family_end = w[k].start + m.get_string(1).length()
			number = m.get_string(2)
		else:
			continue
		if k + 1 >= w.size() and not is_compound:
			break  # "Matrix Amount 3": a numbered list, grouped by its leading words instead
		var family_title := name.left(family_end).strip_edges()
		info["family"] = " ".join(ParamClassifier.name_tokens(family_title))
		info["family_title"] = family_title
		info["instance"] = int(number)
		info["section_title"] = prefix(name, w, k + 1)
		info["label"] = rest(name, w, k + 1)
		return info
	return info


## One section per instance, or one for the whole family when it has many instances or few items
## each (then labels carry the number: "Pitch 3").
static func _assign_family(key: String, members: Array, result: Dictionary) -> void:
	var instances := {}
	for m in members:
		instances[m.instance] = instances.get(m.instance, m.section_title)
	var split := instances.size() <= MAX_INSTANCE_SECTIONS \
		and members.size() >= MIN_ITEMS_PER_INSTANCE * instances.size()
	if not split and members.size() < 2:
		return
	var family_id := _id(key)
	for m in members:
		var label := _label(m, m.label)
		if split:
			result[m.index] = {"id": "%s_%d" % [family_id, m.instance], "title": instances[m.instance],
				"label": label, "family": family_id, "family_title": members[0].family_title}
		else:
			result[m.index] = {"id": family_id, "title": members[0].family_title,
				"label": "%s %d" % [label, m.instance], "family": family_id}


## Items sharing a first word: their longest common leading words are the section. A section
## needs two items, and a name left with only a number ("Knob 7") keeps the word before it.
static func _assign_bucket(members: Array, result: Dictionary) -> void:
	if members.size() < 2:
		return
	var common: int = members[0].words.size()
	for m in members:
		common = mini(common, _common_words(members[0].words, m.words))
		if not m.compound:
			common = mini(common, m.words.size() - 1)
	var only_numbers := members.any(func(m): return not m.compound)
	for m in members:
		if not m.compound and not (m.words.size() == common + 1 and m.words[common].lower.is_valid_int()):
			only_numbers = false
	if only_numbers:
		common -= 1
	if common <= 0:
		return
	var title := prefix(members[0].name, members[0].words, common)
	var id := _id(" ".join(ParamClassifier.name_tokens(title)))
	for m in members:
		result[m.index] = {"id": id, "title": title, "label": _label(m, rest(m.name, m.words, common)),
			"family": id}


## Label for a member: the rest of its name, or its compound kind when nothing is left
## ("Amp" envelope in section "Amp" → "Envelope").
static func _label(member: Dictionary, text: String) -> String:
	if not text.is_empty():
		return text
	return member.kind_label if not member.kind_label.is_empty() else member.name


static func _common_words(a: Array, b: Array) -> int:
	var n := mini(a.size(), b.size())
	for i in range(n):
		if a[i].lower != b[i].lower:
			return i
	return n


static func _id(key: String) -> String:
	return "name_" + key.replace(" ", "_")

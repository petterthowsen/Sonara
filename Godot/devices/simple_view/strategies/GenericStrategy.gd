## GenericStrategy.gd
## Base Simple View generation rules: parameter roles from name keywords, an importance per role,
## and the groups roles fall into. Device-kind strategies extend this and override the tables.

class_name GenericStrategy extends RefCounted

const OTHER_ROLE := "other"
const OTHER_GROUP := {"id": "other", "title": "Controls"}


## Role → name keywords (see `ParamClassifier.matches_keyword`). The first matching role wins.
func role_keywords() -> Dictionary:
	return {
		"mix": ["mix", "dry", "wet", "blend", "balance"],
		"output": ["volume", "vol", "gain", "output", "out", "level", "master", "trim"],
		"frequency": ["freq*", "cutoff", "tone", "hz"],
		"resonance": ["res", "reso", "resonance", "q"],
		"time": ["time", "attack", "decay", "sustain", "release", "hold", "length"],
		"modulation": ["rate", "depth", "lfo", "mod", "modul*", "speed"],
	}


## Role → base importance, 0–1. Unlisted roles get `importance(OTHER_ROLE)`.
func role_weights() -> Dictionary:
	return {
		"mix": 0.8,
		"output": 0.7,
		"frequency": 0.6,
		"resonance": 0.5,
		"time": 0.5,
		"modulation": 0.4,
		OTHER_ROLE: 0.3,
	}


## Name keywords of primary controls ("Volume", "Amount", "Mix"): they come first in their group.
func primary_keywords() -> Array:
	return ["volume", "vol", "level", "gain", "amount", "mix", "output", "master", "drive",
		"depth", "intensity", "cutoff", "wave*", "waveform", "type"]


## Name keywords of fine-tuning controls ("Fine", "Detune", "Phase"): they come last in their group.
func fine_keywords() -> Array:
	return ["fine", "detune", "cents", "semi*", "offset", "phase", "bias", "trim", "skew", "curve",
		"slope", "smooth*", "jitter", "random*", "velocity", "vel*", "keytrack", "key*"]


## Order of an item inside its group: 0 primary, 1 ordinary, 2 fine-tuning. Judged by the item's
## (section-shortened) label, else its parameter name.
func priority_tier(item: Dictionary) -> int:
	var text := String(item.get("label", ""))
	if text.is_empty():
		text = String(item.get("name", ""))
	var tokens := ParamClassifier.name_tokens(text)
	if ParamClassifier.tokens_match(tokens, primary_keywords()):
		return 0
	if ParamClassifier.tokens_match(tokens, fine_keywords()):
		return 2
	return 1


## Roles whose float parameters are drawn as a tall `fader` instead of a knob. Empty by default:
## a fader is three rows tall, so only strategies for devices that suit it opt in.
func fader_roles() -> Array[String]:
	return []


## Compound control kinds (see `CompoundDetector`) this device kind uses; empty allows all.
func compound_kinds() -> Array[String]:
	return []


## Groups in display order: `{id, title, roles, page?}`. Roles not listed go to `OTHER_GROUP`.
## A group with a `page` title goes on that page instead of Main (keep these to broad sections).
func groups() -> Array[Dictionary]:
	return [
		{"id": "output", "title": "Output", "roles": ["mix", "output"]},
		{"id": "tone", "title": "Tone", "roles": ["frequency", "resonance"]},
		{"id": "time", "title": "Time", "roles": ["time"]},
		{"id": "modulation", "title": "Modulation", "roles": ["modulation"]},
	]


## Role of `param` from its name.
func role_for(param: DeviceParameter) -> String:
	var tokens := ParamClassifier.name_tokens(param.name)
	var table := role_keywords()
	for role in table:
		if ParamClassifier.tokens_match(tokens, table[role]):
			return role
	return OTHER_ROLE


## Base importance of `role`.
func importance(role: String) -> float:
	var weights := role_weights()
	return weights.get(role, weights.get(OTHER_ROLE, 0.3))


## `{id, title}` of the group `role` belongs to.
func group_for_role(role: String) -> Dictionary:
	for group in groups():
		if role in group.roles:
			return {"id": group.id, "title": group.title}
	return OTHER_GROUP.duplicate()


## `{id, title}` of the group a generated item (`{role, label, params, …}`) belongs to when the
## device has no module paths. Override for kinds that group by something other than role.
func group_for_item(item: Dictionary) -> Dictionary:
	return group_for_role(item.role)


## Optional annotation for one generated control, read when the view binds it (so it never needs
## to be saved in the layout): a strategy returns a copy carrying extra display keys, e.g. the
## Sync parameter a Time knob follows. `params` are the instance's parameters, for id lookups.
func decorate_control(control: Dictionary, _params: Array) -> Dictionary:
	return control


## Page title for a generated item: the `page` of the strategy group its role belongs to, or ""
## for Main.
func page_for_item(item: Dictionary) -> String:
	var id: String = group_for_item(item).id
	for group in groups():
		if group.id == id:
			return String(group.get("page", ""))
	return ""

## ParamClassifier.gd
## Gives each visible parameter a control kind (REQ-003), a role and an importance, using the
## device kind's strategy. Hidden, read-only and bypass parameters are left out (REQ-004).

class_name ParamClassifier extends RefCounted

## Extra importance for parameters listed early, scaled from this down to 0.
const ORDER_BONUS := 0.05
## Enums with up to this many values get a segmented control; more get a dropdown.
const MAX_SEGMENTS := 5

static var _non_alnum := RegEx.create_from_string("[^a-z0-9]+")


## True when the parameter belongs in a generated layout. Bypass is left out because the device
## header already has an enable button.
static func is_visible(param: DeviceParameter) -> bool:
	return not param.is_hidden and not param.is_read_only and not param.is_bypass


## Control kind for a single parameter.
static func control_kind(param: DeviceParameter) -> String:
	match param.param_type:
		"bool":
			return SimpleControlKinds.TOGGLE
		"enum":
			var n := param.enum_values.size()
			if n == 2:
				return SimpleControlKinds.TOGGLE
			if n >= 3 and n <= MAX_SEGMENTS:
				return SimpleControlKinds.SEGMENTED
			return SimpleControlKinds.DROPDOWN
		_:
			return SimpleControlKinds.KNOB


## Classify the visible parameters, keeping their order.
## Each entry: `{param, id, kind, role, importance, module, index}`.
static func classify(params: Array, strategy: GenericStrategy) -> Array[Dictionary]:
	var visible: Array[DeviceParameter] = []
	for param in params:
		if is_visible(param):
			visible.append(param)
	var entries: Array[Dictionary] = []
	var n := visible.size()
	for i in range(n):
		var param := visible[i]
		var role := strategy.role_for(param)
		entries.append({
			"param": param,
			"id": param.id,
			"kind": control_kind(param),
			"role": role,
			"importance": strategy.importance(role) + ORDER_BONUS * (1.0 - float(i) / float(n)),
			"module": param.module,
			"index": i,
		})
	return entries


## Lowercase alphanumeric words of `text` ("Band1_Freq (Hz)" → ["band1", "freq", "hz"]).
static func name_tokens(text: String) -> PackedStringArray:
	return _non_alnum.sub(text.to_lower(), " ", true).split(" ", false)


## True when a keyword matches one of `tokens`. A keyword ending in `*` matches any token
## starting with the rest; others must match a whole token.
static func matches_keyword(tokens: PackedStringArray, keyword: String) -> bool:
	if keyword.ends_with("*"):
		var prefix := keyword.left(-1)
		for token in tokens:
			if token.begins_with(prefix):
				return true
		return false
	return tokens.has(keyword)


## True when any of `keywords` matches `tokens`.
static func tokens_match(tokens: PackedStringArray, keywords: Array) -> bool:
	for keyword in keywords:
		if matches_keyword(tokens, keyword):
			return true
	return false

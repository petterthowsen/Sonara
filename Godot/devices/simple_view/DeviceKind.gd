## DeviceKind.gd
## Infers which Simple View generation rules fit a device: from its CLAP feature tags first,
## then its category, then keywords in its id and name.

class_name DeviceKind extends RefCounted

const SYNTH := "synth"
const REVERB := "reverb"
const DELAY := "delay"
const COMPRESSOR := "compressor"
const EQ := "eq"
const GENERIC := "generic"

## Feature tag → kind, checked in this order (reverbs sometimes also tag "delay").
const FEATURE_KINDS: Array[Array] = [
	["reverb", REVERB],
	["delay", DELAY],
	["compressor", COMPRESSOR],
	["limiter", COMPRESSOR],
	["equalizer", EQ],
	["instrument", SYNTH],
	["synthesizer", SYNTH],
]

## Kind → name/id keywords (see `ParamClassifier.matches_keyword`), checked in this order.
const NAME_KEYWORDS: Array[Array] = [
	[REVERB, ["reverb*", "verb", "hall", "plate", "room", "chamber"]],
	[DELAY, ["delay*", "echo*"]],
	[COMPRESSOR, ["compress*", "comp", "limiter", "leveler"]],
	[EQ, ["eq", "equali*", "equaliser"]],
	[SYNTH, ["synth*", "polysynth"]],
]


## Kind for `device`, `GENERIC` when nothing matches.
static func infer(device: Device) -> String:
	if device == null:
		return GENERIC
	for pair in FEATURE_KINDS:
		if device.features.has(pair[0]):
			return pair[1]
	if device.category == Device.DeviceCategory.Instrument:
		return SYNTH
	var tokens := ParamClassifier.name_tokens(device.device_id + " " + device.name)
	for pair in NAME_KEYWORDS:
		if ParamClassifier.tokens_match(tokens, pair[1]):
			return pair[0]
	return GENERIC

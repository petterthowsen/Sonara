# NameStyle.gd
# Naming convention for clips, tracks, channels and devices: "Capitalized Lower Case" (Title Case,
# e.g. `Bass Line`, `Drum Bus`, `Delay 2`). Lookups compare names by `key()`, so casing, underscores
# and repeated spaces don't matter (`bass_line` finds `Bass Line`).
class_name NameStyle extends RefCounted

static var _space_re := RegEx.create_from_string("[\\s_]+")


## Comparison key: lowercase, underscores as spaces, whitespace collapsed and trimmed.
static func key(name: String) -> String:
	return _space_re.sub(name, " ", true).strip_edges().to_lower()


## True when `a` and `b` name the same thing under `key()`.
static func same(a: String, b: String) -> bool:
	return key(a) == key(b)


## Title-case a name: underscores become spaces and each word (and each part of `Hi-hat`) is
## capitalized with the rest lower case. Kept as written: parts with digits (`TR-808`, `C#3`),
## mixed-case parts (`PolySynth`) and short all-caps acronyms (`FX`, `EQ`, `SFZ`).
static func format(name: String) -> String:
	var words: PackedStringArray = []
	for word in _space_re.sub(name, " ", true).strip_edges().split(" ", false):
		var parts: PackedStringArray = []
		for part in word.split("-"):
			parts.append(_format_part(part))
		words.append("-".join(parts))
	return " ".join(words)


static func _format_part(part: String) -> String:
	var upper := part.to_upper()
	var lower := part.to_lower()
	if upper == lower:
		return part  # no letters
	for c in part:
		if c >= "0" and c <= "9":
			return part
	if part != upper and part != lower:
		return part
	if part == upper and part.length() <= 3:
		return part
	return upper.substr(0, 1) + lower.substr(1)

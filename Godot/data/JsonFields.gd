# JsonFields.gd
# Table-driven copy of plain fields between a model and its JSON dictionary.
# A key missing from the JSON keeps the field's current value, so a freshly constructed model's
# initializers are the only defaults and from_json can't disagree with them.
# Arrays, enums stored by name, colors and nested models stay hand-written.
class_name JsonFields extends RefCounted


## `{key: source.key}` for each key.
static func write(source: Object, keys: Array[String]) -> Dictionary:
	var out := {}
	for key in keys:
		out[key] = source.get(key)
	return out


## Set each key present in `data` on `target` (through its setter), converted to the field's current type.
static func read(target: Object, data: Dictionary, keys: Array[String]) -> void:
	for key in keys:
		if not data.has(key):
			continue
		var current: Variant = target.get(key)
		var value: Variant = data[key]
		if current != null and typeof(value) != typeof(current):
			value = type_convert(value, typeof(current))
		target.set(key, value)

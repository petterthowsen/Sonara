## Colour cache for a custom-drawn control.
##
## The control's colour properties read through `get_color` and write through `set_color`. A write
## is a per-instance theme override (`add_theme_color_override`), so it survives theme changes,
## and a scene can also set it as `theme_override_colors/<item>`. The control calls `refresh` from
## `NOTIFICATION_THEME_CHANGED` and redraws; `_draw` only ever hits the cache.
class_name ThemedColors extends RefCounted

var _owner: Control
var _type: StringName
var _cache := {}


## `type` is the theme type that holds the items (`&"Fader"`, `&"RotaryKnob"`, …).
func _init(owner: Control, type: StringName) -> void:
	_owner = owner
	_type = type


func get_color(item: StringName) -> Color:
	var c = _cache.get(item)
	if c == null:
		# Godot only honours an override when the lookup type is the node's native class, which a
		# script class never is, so the override is checked first.
		if _owner.has_theme_color_override(item):
			c = _owner.get_theme_color(item)
		else:
			c = _owner.get_theme_color(item, _type)
		_cache[item] = c
	return c


func set_color(item: StringName, c: Color) -> void:
	_cache.erase(item)
	_owner.add_theme_color_override(item, c)
	_owner.queue_redraw()


## Drops the cached values; call on NOTIFICATION_THEME_CHANGED, then redraw.
func refresh() -> void:
	_cache.clear()

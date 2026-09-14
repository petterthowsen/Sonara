# WrappingRichText.gd
# Chat body text that wraps to the dock width instead of widening it.
class_name WrappingRichText extends RichTextLabel


## Default to wrapping, fit-height, selectable body text.
func _init() -> void:
	bbcode_enabled = false
	fit_content = true
	scroll_active = false
	selection_enabled = true
	autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


## Plain transcript text (thinking blocks, streaming fallback).
func set_plain_text(text: String) -> void:
	bbcode_enabled = false
	self.text = text


## BBCode body (JSON tools, formatted assistant replies).
func set_bbcode_text(bbcode: String) -> void:
	bbcode_enabled = true
	text = bbcode


## Ignore unwrapped line width so a narrow dock can shrink.
func _get_minimum_size() -> Vector2:
	return Vector2(0.0, get_content_height())

@tool
## Vertical variant of `CompactHSlider`: the same API, signals, drag model (vertical motion,
## Shift = fine, Ctrl/Cmd-click = reset, double-click = typed entry), theme colours (the
## `CompactSlider` theme type) and modulation surface, drawn as a vertical value bar on the
## right edge with the formatted value text vertically centered beside it. It extends `CompactSlider`, so
## `ModParamSlot` and `ModAssign` treat it as one. The bar fills from the bottom, or from the
## centre when the range spans negative and positive values.
class_name CompactVSlider extends CompactSlider

## Width reserved for the value text, in pixels (enough for "100 %").
const TEXT_WIDTH := 40.0
const MIN_BAR_LENGTH := 24.0
## Thickness of the vertical value bar (the horizontal slider's `BAR_HEIGHT` is too thin here).
const BAR_WIDTH := 8.0


func _get_minimum_size() -> Vector2:
	var font := get_theme_font(&"font", &"Label")
	if font == null:
		font = ThemeDB.fallback_font
	return Vector2(TEXT_WIDTH + BAR_WIDTH + 2.0, font.get_height(text_font_size) + MIN_BAR_LENGTH)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), bg_color, true, -1.0, true)
	var font := get_theme_font(&"font", &"Label")
	if font == null:
		font = ThemeDB.fallback_font
	var bar_x := size.x - BAR_WIDTH
	# Value text, vertically centered, in the area left of the bar.
	var text_y := (size.y - font.get_height(text_font_size)) * 0.5 + font.get_ascent(text_font_size)
	draw_string(font, Vector2(0, text_y), get_value_text(),
		HORIZONTAL_ALIGNMENT_CENTER, bar_x, text_font_size, text_color)

	draw_rect(Rect2(bar_x, 0, BAR_WIDTH, size.y), bar_bg_color, true, -1.0, true)
	if _bidirectional():
		var center_y := size.y * 0.5
		var fill_h := (_value_to_norm(_value) - 0.5) * size.y  # positive fills above centre
		draw_rect(Rect2(bar_x, center_y - maxf(fill_h, 0.0), BAR_WIDTH, absf(fill_h)),
			bar_fill_color, true, -1.0, true)
	else:
		var h := _norm_value() * size.y
		draw_rect(Rect2(bar_x, size.y - h, BAR_WIDTH, h), bar_fill_color, true, -1.0, true)

	_draw_modulation()


func _draw_modulation() -> void:
	var bar_x := size.x - BAR_WIDTH
	var base := _norm_value()
	for i in mod_ranges.size():
		var route := mod_ranges[i]
		var band := ModDisplay.span(base, float(route["amount"]), bool(route.get("bipolar", false)))
		if band.y - band.x < 0.002:
			continue
		draw_rect(Rect2(bar_x - MOD_BAR * (i + 1), (1.0 - band.y) * size.y,
			MOD_BAR, (band.y - band.x) * size.y), route["color"], true)
	for live in mod_live_values:
		draw_rect(Rect2(bar_x, (1.0 - clampf(live, 0.0, 1.0)) * size.y - 0.5, BAR_WIDTH, 1.5),
			mod_live_color, true)
	if mod_hint_active:
		ModDisplay.draw_fill(self, Rect2(Vector2.ZERO, size), mod_hint_color, ModDisplay.pulse_alpha())
	elif mod_assign_active:
		ModDisplay.draw_fill(self, Rect2(Vector2.ZERO, size), mod_assign_color)

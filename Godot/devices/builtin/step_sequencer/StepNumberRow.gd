@tool
## Step numbers over a step sequencer's lanes (same column geometry as `StepLane`), with the
## playhead column lit and the steps beyond `length` dimmed. Display only.
class_name StepNumberRow extends Control

@export var step_count := 16:
	set(n):
		step_count = maxi(n, 1)
		update_minimum_size()
		queue_redraw()
@export var group_size := 4:
	set(n):
		group_size = maxi(n, 1)
		update_minimum_size()
		queue_redraw()
var playhead := -1:
	set(p):
		if p != playhead:
			playhead = p
			queue_redraw()
var length := 16:
	set(n):
		length = n
		queue_redraw()


## As wide as the lanes' narrowest columns; `custom_minimum_size` still raises it.
func _get_minimum_size() -> Vector2:
	return Vector2(StepLane.min_width_for(step_count, group_size), 14.0)


func column_rect(k: int) -> Rect2:
	var gaps := maxi(ceili(float(step_count) / group_size) - 1, 0)
	var w := maxf((size.x - gaps * StepLane.GROUP_GAP) / step_count, 1.0)
	return Rect2(k * w + (k / group_size) * StepLane.GROUP_GAP, 0.0, w, size.y)


func _draw() -> void:
	var font := get_theme_default_font()
	var fs := 10
	var base := get_theme_color("font_color", "Label")
	for k in step_count:
		var r := column_rect(k)
		var c := base
		c.a = 1.0 if k == playhead else (0.35 if k >= length else 0.7)
		var text := str(k + 1)
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, Vector2(r.position.x + (r.size.x - w) * 0.5, size.y - 3.0), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, c)

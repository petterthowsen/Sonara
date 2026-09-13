# ShrinkWidthButton.gd
# Button that ellipsizes instead of widening a dock or other parent.
class_name ShrinkWidthButton extends Button


## Font plus stylebox height, ignoring the text width.
static func theme_min_height(control: Control) -> float:
	var font := control.get_theme_font("font")
	var font_size := control.get_theme_font_size("font_size")
	var height := font.get_height(font_size) if font else 16.0
	var style := control.get_theme_stylebox("normal")
	if style:
		height += style.get_minimum_size().y
	return height


## Report no preferred width so long labels cannot stretch ancestors.
func _get_minimum_size() -> Vector2:
	return Vector2(0.0, theme_min_height(self))

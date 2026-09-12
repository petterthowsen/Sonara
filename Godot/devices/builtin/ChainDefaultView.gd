## Chain has no custom UI: Volume lives in ParameterList, children live in the DevicePanel folder.
class_name ChainDefaultView extends DeviceView


func _get_minimum_size() -> Vector2:
	return Vector2.ZERO


func _on_bind() -> void:
	visible = false
	custom_minimum_size = Vector2.ZERO

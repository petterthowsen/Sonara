@tool
# ValueEditKind.gd
# How a value control's last change came about, so an owner can treat a drag (relative) differently
# from a typed entry or a reset (absolute), e.g. when several mixer channels are edited together.
class_name ValueEditKind extends RefCounted

enum Kind {
	DRAG,   ## Drag or click on the control
	TYPED,  ## Exact value typed in the FloatingValueEditor
	RESET,  ## Ctrl/Cmd-click back to the default
}

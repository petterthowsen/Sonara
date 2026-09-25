# PopupMessage.gd
# Reusable embedded message window: a title, a scrollable, selectable body and an
# Actions row with optional caller-supplied buttons plus Copy/Close.
#
# Show one with `show_message(title, body, actions)`, where each `actions` entry is
# {"text": String, "callback": Callable}. Buttons created for a previous call are
# freed on the next one; Copy/Close always ship with the scene.
class_name PopupMessage extends Window

## Emitted when the window is closed (Close button or the window's own close request).
signal closed

const POPUP_SIZE := Vector2i(640, 420)

var last_title: String = ""
var last_body: String = ""

@onready var title_label: Label = $MarginContainer/VBoxContainer/TitleLabel
@onready var body_scroll: ScrollContainer = $MarginContainer/VBoxContainer/BodyScroll
@onready var body: RichTextLabel = $MarginContainer/VBoxContainer/BodyScroll/Body
@onready var actions_box: HBoxContainer = $MarginContainer/VBoxContainer/Actions
@onready var copy_button: Button = $MarginContainer/VBoxContainer/Actions/CopyButton
@onready var close_button: Button = $MarginContainer/VBoxContainer/Actions/CloseButton

## Buttons generated from the last `show_message(actions)` call, freed on the next one.
var _generated_buttons: Array[Button] = []


func _ready() -> void:
	copy_button.pressed.connect(_on_copy_pressed)
	close_button.pressed.connect(_on_close_pressed)
	close_requested.connect(_on_close_pressed)


## Show a message. `actions` entries are {"text": String, "callback": Callable};
## one Button is created per entry in `Actions`, before Copy/Close.
func show_message(title: String, body_text: String, actions: Array = []) -> void:
	if not is_node_ready():
		await ready

	last_title = title
	last_body = body_text
	title_label.text = title
	body.text = body_text

	for old_button in _generated_buttons:
		if is_instance_valid(old_button):
			old_button.queue_free()
	_generated_buttons.clear()

	for spec in actions:
		if not (spec is Dictionary):
			continue
		var button := Button.new()
		button.text = str(spec.get("text", "Action"))
		actions_box.add_child(button)
		actions_box.move_child(button, copy_button.get_index())
		var callback = spec.get("callback", Callable())
		if callback is Callable and (callback as Callable).is_valid():
			button.pressed.connect(callback as Callable)
		_generated_buttons.append(button)

	copy_button.text = "Copy"
	popup_centered(POPUP_SIZE)
	body_scroll.scroll_vertical = 0


## The exact text the Copy button puts on the clipboard (title + blank line + body).
func get_copy_text() -> String:
	return last_title + "\n\n" + last_body


func _on_copy_pressed() -> void:
	DisplayServer.clipboard_set(get_copy_text())
	copy_button.text = "Copied"


func _on_close_pressed() -> void:
	hide()
	closed.emit()

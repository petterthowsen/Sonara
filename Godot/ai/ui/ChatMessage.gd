## One chat bubble: speaker, wrapping body, optional media attachments.
class_name ChatMessage extends PanelContainer

enum Kind { USER, ASSISTANT, LIMIT }

@export var user_color := Color(0.35, 0.45, 0.62, 0.35)
@export var assistant_color := Color(0.22, 0.22, 0.26, 0.55)
@export var limit_color := Color(0.45, 0.32, 0.18, 0.5)

@onready var _who: Label = $Column/Who
@onready var _body: RichTextLabel = $Column/Body
@onready var _media: VBoxContainer = $Column/Media

var _kind: Kind = Kind.ASSISTANT


## Fill speaker, body, panel color, and optional attachments.
func configure(kind: Kind, text: String, msg: ChatTypes.ORChatMessage = null) -> void:
	_kind = kind
	_who.text = _speaker_name()
	_body.text = text
	_apply_color()
	_fill_media(msg)


## Append streamed assistant text to the body.
func append_text(text: String) -> void:
	_body.text += text


## Speaker label for the current kind.
func _speaker_name() -> String:
	match _kind:
		Kind.USER:
			return "You"
		Kind.LIMIT:
			return "Limit"
		_:
			return "Assistant"


## Recolor a duplicated panel style so instances do not share one box.
func _apply_color() -> void:
	var base := get_theme_stylebox("panel")
	if not base is StyleBoxFlat:
		return
	var style := (base as StyleBoxFlat).duplicate() as StyleBoxFlat
	match _kind:
		Kind.USER:
			style.bg_color = user_color
		Kind.LIMIT:
			style.bg_color = limit_color
		_:
			style.bg_color = assistant_color
	add_theme_stylebox_override("panel", style)


## Attach image and audio previews from message content parts.
func _fill_media(msg: ChatTypes.ORChatMessage) -> void:
	for child in _media.get_children():
		child.queue_free()
	if msg == null or not msg.content is Array:
		_media.visible = false
		return
	var added := false
	for part in msg.content:
		if not part is ChatTypes.ORContentPart:
			continue
		if part.kind == "image_url" or part.kind == "output_image":
			var tex := MediaEncode.image_from_data_uri(part.url)
			if tex:
				var rect := TextureRect.new()
				rect.texture = tex
				rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				rect.custom_minimum_size = Vector2(0, 80)
				_media.add_child(rect)
				added = true
		elif part.kind == "input_audio" or part.kind == "output_audio":
			var hint := Label.new()
			hint.text = "Audio (%s)" % part.audio_format
			hint.add_theme_font_size_override("font_size", 11)
			_media.add_child(hint)
			added = true
	_media.visible = added

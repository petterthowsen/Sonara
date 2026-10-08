# HelpBar.gd
# The one-line bar at the bottom of the editor: the hotkeys and mouse gestures for whatever the
# pointer is over, rebuilt when the help context, the held modifiers or a binding changes.
#
# With no modifier held it lists the entries that need none, plus one "Shift ..." hint per
# modifier that unlocks more. With modifiers held it lists only the entries for exactly that
# modifier set, like Blender's status bar.
#
# build() is pure (context, modifiers, width in, bbcode out) so tests don't need a scene.
class_name HelpBar
extends RichTextLabel

const SETTING_KEY := "appearance/show_help_bar"
const KEYBOARD_SETTING_KEY := "midi/virtual_keyboard/enabled"
const SEPARATOR := "  "
const ELLIPSIS := "…"

const _MODS := [
	["Ctrl", KEY_MASK_CTRL],
	["Shift", KEY_MASK_SHIFT],
	["Alt", KEY_MASK_ALT],
	["Meta", KEY_MASK_META],
]
const _INPUT_WORDS := {
	"click": "Click",
	"double_click": "Double-click",
	"right_click": "Right-click",
	"drag": "Drag",
	"right_drag": "Right-drag",
	"middle_drag": "Middle-drag",
	"wheel": "Wheel",
}


## Autoloads by node path: a script compiled before they exist (the headless test runner)
## can't resolve their global names.
static func _hk() -> Node:
	return (Engine.get_main_loop() as SceneTree).root.get_node("Hotkeys")


static func _settings() -> Node:
	return (Engine.get_main_loop() as SceneTree).root.get_node("Settings")


## Theme roles as bbcode colours, read per build (builds are rare, so no cache to invalidate).
static func _chip_color() -> String:
	return "#" + UiColors.role(&"accent_primary").to_html(false)


static func _dim_color() -> String:
	return "#" + UiColors.role(&"text_dim").to_html(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_rebuild()


func _ready() -> void:
	_hk().help_context_changed.connect(func(_c, _m): _rebuild())
	_hk().bindings_changed.connect(func(_id): _rebuild())
	_hk().hint_changed.connect(func(_t): _rebuild())
	_hk().conditions_changed.connect(_rebuild)
	_settings().setting_changed.connect(_on_setting_changed)
	resized.connect(_rebuild)
	_apply_visibility()
	_rebuild()


func _on_setting_changed(key: String, _value) -> void:
	if key == SETTING_KEY:
		_apply_visibility()
	elif key == KEYBOARD_SETTING_KEY or key == "midi_editor/note_drag_modifiers":
		_rebuild()


func _apply_visibility() -> void:
	var box := get_parent() as Control
	if box:
		box.visible = _settings().get_value(SETTING_KEY)


func show_hint(text: String, owner: Object) -> void:
	_hk().show_hint(text, owner)


func clear_hint(owner: Object) -> void:
	_hk().clear_hint(owner)


func _rebuild() -> void:
	if size.x <= 0.0:
		return
	var hint: String = _hk().current_hint()
	var bb: String
	if hint.is_empty():
		bb = build(_hk().help_context, _hk().help_modifiers, size.x,
				get_theme_font("normal_font"), get_theme_font_size("normal_font_size"),
				extra_contexts())
	else:
		bb = _escape(hint)
	if bb != text:
		text = bb


## bbcode for *ctx* with *mods* (a KEY_MASK_* mask) held, fitted to *width* pixels. Entries are
## dropped from the end, never split, and a dim "…" marks the cut.
static func build(ctx: String, mods: int, width: float, font: Font = null, font_size: int = 14,
		extras: Array[String] = []) -> String:
	if ctx == "text":
		return ""
	if font == null:
		font = ThemeDB.fallback_font
	var all := collect(ctx, extras)
	var shown: Array[Dictionary] = []
	var unlock := 0
	for e in all:
		if e.mask == mods:
			shown.append(e)
		elif mods == 0:
			unlock |= e.mask
	shown.sort_custom(func(a, b): return a.sort < b.sort)

	var hints: Array[Dictionary] = []
	for m in _MODS:
		if unlock & m[1]:
			hints.append({"plain": m[0] + " " + ELLIPSIS,
					"bb": _chip(m[0]) + " " + ELLIPSIS})

	var sep_w := _width(font, font_size, SEPARATOR)
	var hints_w := 0.0
	for h in hints:
		hints_w += sep_w + _width(font, font_size, h.plain)
	var ellipsis_w := sep_w + _width(font, font_size, ELLIPSIS)

	var parts: Array[String] = []
	var used := 0.0
	var dropped := false
	for i in shown.size():
		var w := _width(font, font_size, shown[i].plain) + (sep_w if used > 0.0 else 0.0)
		var tail := ellipsis_w if i < shown.size() - 1 else 0.0
		if used + w + tail + hints_w > width:
			dropped = true
			break
		used += w
		parts.append(shown[i].bb)
	if dropped:
		parts.append("[color=%s]%s[/color]" % [_dim_color(), ELLIPSIS])
	for h in hints:
		parts.append(h.bb)
	return SEPARATOR.join(parts)


## Contexts added to every chain right now: the computer keyboard while it is enabled.
static func extra_contexts() -> Array[String]:
	var extras: Array[String] = []
	var s := _settings()
	if s.get_value(KEYBOARD_SETTING_KEY):
		extras.append("computer_keyboard")
	return extras


## Every help entry for *ctx*'s chain, regardless of held modifiers: bound actions with
## help != false, and the declared gestures. Each is { mask, plain, bb, sort }.
static func collect(ctx: String, extras: Array[String] = []) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var chain := HotkeyActions.context_chain(ctx)
	# Extra contexts (the computer keyboard) apply everywhere, after the real chain.
	for extra in extras:
		if not chain.has(extra):
			chain.append(extra)
	for i in HotkeyActions.ACTIONS.size():
		var a: Dictionary = HotkeyActions.ACTIONS[i]
		var depth := chain.find(a.context)
		if depth < 0 or not a.get("help", true):
			continue
		if a.has("requires") and not _hk().has_condition(a.requires):
			continue
		var chords: Array[String] = _hk().get_chords(a.id)
		if chords.is_empty():
			continue
		var physical: bool = a.get("physical", false)
		var ev := KeyChord.parse(chords[0], physical)
		if ev == null:
			continue
		var mask := _mask_of(ev)
		var chips := _chord_chips(KeyChord.display(chords[0], physical))
		var suffix := " ×2" if HotkeyActions.is_double_tap(a.id) else ""
		entries.append(_entry(mask, chips, _lower_first(a.label), suffix,
				[a.get("priority", 0), depth, 0, i]))
	for i in HotkeyActions.GESTURES.size():
		var g: Dictionary = HotkeyActions.GESTURES[i]
		var depth := chain.find(g.context)
		if depth < 0 or not g.get("help", true):
			continue
		if g.has("setting") and _settings().get_value(g.setting) != g.equals:
			continue
		var mask := 0
		var chips: Array[String] = []
		for m in _MODS:
			if m[0] in g.mods.split("+"):
				mask |= m[1]
				chips.append(m[0])
		if g.input != "":
			chips.append(_INPUT_WORDS[g.input])
		entries.append(_entry(mask, chips, g.label, "", [0, depth, 1, i]))
	return entries


static func _entry(mask: int, chips: Array[String], label: String, suffix: String, sort: Array) -> Dictionary:
	var bb_chips: Array[String] = []
	for c in chips:
		bb_chips.append(_chip(c))
	var plain := "+".join(chips) + suffix + " " + label
	var bb := "+".join(bb_chips)
	if suffix != "":
		bb += " [color=%s]%s[/color]" % [_dim_color(), suffix.strip_edges()]
	bb += " " + _escape(label)
	return {"mask": mask, "plain": plain, "bb": bb, "sort": sort}


static func _chip(key: String) -> String:
	return "[color=%s]%s[/color]" % [_chip_color(), _escape(key)]


static func _escape(s: String) -> String:
	return s.replace("[", "[lb]")


static func _width(font: Font, font_size: int, s: String) -> float:
	return font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x


static func _mask_of(ev: InputEventKey) -> int:
	return ((KEY_MASK_CTRL if ev.ctrl_pressed else 0) | (KEY_MASK_SHIFT if ev.shift_pressed else 0)
			| (KEY_MASK_ALT if ev.alt_pressed else 0) | (KEY_MASK_META if ev.meta_pressed else 0))


## "Ctrl+Shift+Up" -> ["Ctrl", "Shift", "Up"]. The key may itself be "+" ("Ctrl++").
static func _chord_chips(display: String) -> Array[String]:
	var chips: Array[String] = []
	var rest := display
	var stripped := true
	while stripped:
		stripped = false
		for m in _MODS:
			if rest.begins_with(m[0] + "+") and rest.length() > m[0].length() + 1:
				chips.append(m[0])
				rest = rest.substr(m[0].length() + 1)
				stripped = true
	chips.append(rest)
	return chips


static func _lower_first(s: String) -> String:
	if s.length() > 1 and s[1] == s[1].to_upper() and s[1] != s[1].to_lower():
		return s
	return s[0].to_lower() + s.substr(1)

# Settings.gd
# Registry for user-facing settings, layered on top of the Sonara config store.
# Every user preference is declared here exactly once, with its default, type
# and constraints. This is the only place setting defaults live.
#
# Layers (each calls only the one below it):
#   Consumers -> Settings.get_value / set_value
#   Settings  -> Sonara.get_config / set_config / save_config (plain JSON store)
# Only internal, unregistered UI state (dock layout, browser state) may use
# Sonara.get_config / set_config directly.
#
# Usage:
#   Settings.get_value("midi/virtual_keyboard/transpose")   -> 0
#   Settings.set_value("midi/virtual_keyboard/transpose", 12)  -> validates, saves, emits
#   Settings.setting_changed.connect(...)  ->  react to live changes
#
# Registered as an autoload before any consumer autoload in project.godot.
extends Node


## Setting type enum — drives which editor widget the dialog uses.
enum Type { BOOL, INT, FLOAT, STRING, CHOICE, CHOICE_MULTI, PATH, PATH_ARRAY, SECRET, TEXT }


## Data class describing one registered setting.
class Setting:
	var key: String
	var label: String
	var type: Type
	var default
	var category: String
	var description: String = ""
	var min_val: float = 0.0
	var max_val: float = 0.0
	var step: float = 1.0
	var options: Array = []

	func _init(p_key: String, p_label: String, p_type: Type, p_default, p_category: String, p_description: String = ""):
		key = p_key
		label = p_label
		type = p_type
		default = p_default
		category = p_category
		description = p_description


signal setting_changed(key: String, value)


# ---------------------------------------------------------------------------
# REGISTRY
# ---------------------------------------------------------------------------

const CATEGORY_AUDIO = "Audio"
const CATEGORY_BEHAVIOR = "Behavior"
const CATEGORY_APPEARANCE = "Appearance"
const CATEGORY_SHORTCUTS = "Shortcuts"
const CATEGORY_AI = "AI"

var _settings: Dictionary = {}


func _init() -> void:
	# Register in _init so the registry is usable as soon as the node exists.
	_register_all_settings()


func _ready() -> void:
	_migrate_renamed_keys()


## Keys that were renamed: old -> new. Old values are copied once if the new key is unset.
const _RENAMED_KEYS := {
	"appearence/color_timeline_by_track": "appearance/color_timeline_by_track",
}


func _migrate_renamed_keys() -> void:
	var migrated := false
	for old_key in _RENAMED_KEYS:
		var old_val = Sonara.get_config(old_key)
		if old_val != null and Sonara.get_config(_RENAMED_KEYS[old_key]) == null:
			Sonara.set_config(_RENAMED_KEYS[old_key], old_val)
			migrated = true
	if migrated:
		Sonara.save_config()


func _register_all_settings() -> void:
	"""Populate the registry. Called once at init."""

	# --- Behavior: MIDI virtual keyboard ---
	_register(Setting.new(
		"midi/virtual_keyboard/enabled",
		"Enable Computer Keyboard",
		Type.BOOL,
		true,
		CATEGORY_BEHAVIOR,
		"Use the computer keyboard as a MIDI input device.\n\n"
		+ "Tip: caps-lock toggles this setting at runtime."
	))
	_register(Setting.new(
		"midi/virtual_keyboard/transpose",
		"Transpose (semitones)",
		Type.INT,
		0,
		CATEGORY_BEHAVIOR,
		"Transpose the virtual keyboard up or down.",
	))
	_register(Setting.new(
		"midi/virtual_keyboard/velocity",
		"Default Velocity",
		Type.INT,
		100,
		CATEGORY_BEHAVIOR,
		"Default MIDI velocity for virtual keyboard notes.",
	))
	# min/max/step for the two INT settings above
	_settings["midi/virtual_keyboard/transpose"].min_val = -24
	_settings["midi/virtual_keyboard/transpose"].max_val = 24
	_settings["midi/virtual_keyboard/transpose"].step = 1
	_settings["midi/virtual_keyboard/velocity"].min_val = 1
	_settings["midi/virtual_keyboard/velocity"].max_val = 127
	_settings["midi/virtual_keyboard/velocity"].step = 1

	# --- Behavior: Asset scanning ---
	_register(Setting.new(
		"assets/scan_interval_seconds",
		"Asset Scan Interval",
		Type.FLOAT,
		30.0,
		CATEGORY_BEHAVIOR,
		"How often (in seconds) the browser rescans asset directories.",
	))
	_settings["assets/scan_interval_seconds"].min_val = 1.0
	_settings["assets/scan_interval_seconds"].max_val = 120.0
	_settings["assets/scan_interval_seconds"].step = 1.0

	_register(Setting.new(
		"assets/enabled_providers",
		"Enabled Asset Providers",
		Type.CHOICE_MULTI,
		["filesystem", "devices", "sfz"],
		CATEGORY_BEHAVIOR,
		"Which asset providers are active in the browser.",
	))
	_settings["assets/enabled_providers"].options = ["filesystem", "devices", "sfz"]

	_register(Setting.new(
		"assets/samples/paths",
		"Audio/MIDI Search Paths",
		Type.PATH_ARRAY,
		["~/Music"],
		CATEGORY_BEHAVIOR,
		"Directories to scan for audio and MIDI files.",
	))

	_register(Setting.new(
		"assets/sfz/paths",
		"SFZ Instrument Search Paths",
		Type.PATH_ARRAY,
		["~/Music/libs/SFZ"],
		CATEGORY_BEHAVIOR,
		"Directories to scan for SFZ instrument files.",
	))

	_register(Setting.new(
		"arranger/record_arm_follows_active_track",
		"Record Arm Follows Active Track",
		Type.BOOL,
		true,
		CATEGORY_BEHAVIOR,
		"When enabled, changing the active track record-arms that track and disarms the others.",
	))
	_register(Setting.new(
		"arranger/markers/rename_on_create",
		"Rename New Markers",
		Type.BOOL,
		true,
		CATEGORY_BEHAVIOR,
		"When enabled, a newly created marker opens its name for editing (after the mouse is released).",
	))

	# --- Appearance ---
	_register(Setting.new(
		"appearance/color_timeline_by_track",
		"Color Timeline by Track",
		Type.BOOL,
		true,
		CATEGORY_APPEARANCE,
		"Use the track color as the timeline background tint.",
	))
	_register(Setting.new(
		"appearance/automation_lane_height",
		"Automation Lane Height",
		Type.INT,
		40,
		CATEGORY_APPEARANCE,
		"Row height, in pixels, for a newly created automation lane.",
	))
	_settings["appearance/automation_lane_height"].min_val = 20
	_settings["appearance/automation_lane_height"].max_val = 200
	_settings["appearance/automation_lane_height"].step = 1

	# --- Audio (placeholder — engine does not expose OSC config yet) ---

	# --- AI / OpenRouter ---
	_register(Setting.new(
		"ai/openrouter/api_key",
		"OpenRouter API Key",
		Type.SECRET,
		"",
		CATEGORY_AI,
		"API key from openrouter.ai. Stored in plaintext in ~/.config/sonara/config.json (mode 0600). The OPENROUTER_API_KEY environment variable takes precedence."
	))
	_register(Setting.new(
		"ai/openrouter/base_url",
		"OpenRouter Base URL",
		Type.STRING,
		"https://openrouter.ai/api/v1",
		CATEGORY_AI,
		"Override for proxies. Default is the official OpenRouter Chat Completions API."
	))
	_register(Setting.new(
		"ai/openrouter/model",
		"Model",
		Type.STRING,
		"anthropic/claude-sonnet-4.5",
		CATEGORY_AI,
		"OpenRouter model id, e.g. anthropic/claude-sonnet-4.5"
	))
	_register(Setting.new(
		"ai/chat/temperature",
		"Temperature",
		Type.FLOAT,
		0.7,
		CATEGORY_AI,
		"Sampling temperature for chat completions."
	))
	_settings["ai/chat/temperature"].min_val = 0.0
	_settings["ai/chat/temperature"].max_val = 2.0
	_settings["ai/chat/temperature"].step = 0.1
	_register(Setting.new(
		"ai/chat/max_tokens",
		"Max Output Tokens",
		Type.INT,
		4096,
		CATEGORY_AI,
		"Cap on tokens the model may generate per request (each tool round is a separate request). Thinking tokens count toward it. Does not limit the context sent."
	))
	_settings["ai/chat/max_tokens"].min_val = 256
	_settings["ai/chat/max_tokens"].max_val = 32000
	_settings["ai/chat/max_tokens"].step = 256
	_register(Setting.new(
		"ai/chat/max_tool_rounds",
		"Max Tool Rounds",
		Type.INT,
		64,
		CATEGORY_AI,
		"How many tool-call rounds the assistant may run in one turn before it must stop and reply."
	))
	_settings["ai/chat/max_tool_rounds"].min_val = 8
	_settings["ai/chat/max_tool_rounds"].max_val = 256
	_settings["ai/chat/max_tool_rounds"].step = 8
	_register(Setting.new(
		"ai/chat/reasoning",
		"Show Thinking",
		Type.BOOL,
		false,
		CATEGORY_AI,
		"Request model reasoning tokens and show them as a collapsible block in chat."
	))
	_register(Setting.new(
		"ai/chat/reasoning_effort",
		"Thinking Effort",
		Type.CHOICE,
		"medium",
		CATEGORY_AI,
		"How much reasoning the model should do when Show Thinking is on."
	))
	_settings["ai/chat/reasoning_effort"].options = ["low", "medium", "high"]
	_register(Setting.new(
		"ai/chat/user_instructions",
		"Custom Instructions",
		Type.TEXT,
		"",
		CATEGORY_AI,
		"Extra instructions added to the assistant's system prompt via {user_instructions}."
	))
	_register(Setting.new(
		"ai/audio/voice",
		"Audio Voice",
		Type.STRING,
		"alloy",
		CATEGORY_AI,
		"Voice id for chat audio output (and later TTS)."
	))
	_register(Setting.new(
		"ai/audio/format",
		"Audio Format",
		Type.CHOICE,
		"wav",
		CATEGORY_AI,
		"Audio format for chat audio output. wav plays natively in Godot."
	))
	_settings["ai/audio/format"].options = ["wav", "mp3"]
	_register(Setting.new(
		"ai/debug/keep_exchanges",
		"Keep Request Logs",
		Type.INT,
		200,
		CATEGORY_AI,
		"How many raw request/response JSON records to keep per conversation (next to the chat files) for the request viewer. 0 turns logging off. Each record holds the full request, so long chats use several MB."
	))
	_settings["ai/debug/keep_exchanges"].min_val = 0
	_settings["ai/debug/keep_exchanges"].max_val = 2000
	_settings["ai/debug/keep_exchanges"].step = 50


func _register(s: Setting) -> void:
	_settings[s.key] = s


# ---------------------------------------------------------------------------
# ACCESSORS
# ---------------------------------------------------------------------------

func get_categories() -> Array[String]:
	"""Return the ordered list of category names."""
	return [CATEGORY_AUDIO, CATEGORY_BEHAVIOR, CATEGORY_APPEARANCE, CATEGORY_AI, CATEGORY_SHORTCUTS]


func get_settings_for_category(category: String) -> Array[Setting]:
	"""All registered settings in *category*, in registration order."""
	var result: Array[Setting] = []
	for s in _settings.values():
		if s.category == category:
			result.append(s)
	return result


func get_all_keys() -> Array[String]:
	"""Return all registered setting keys."""
	return _settings.keys()


func get_setting(key: String) -> Setting:
	"""Look up a Setting definition by key. Returns null if unknown."""
	return _settings.get(key)


func get_value(key: String):
	"""Read a value from config, falling back to the registered default."""
	var s = _settings.get(key)
	if s == null:
		push_warning("Settings: no registration for key '%s'" % key)
		return null
	return Sonara.get_config(key, s.default)


func set_value(key: String, value) -> void:
	"""Validate a value, write it to config, save, and emit the change signal."""
	var s = _settings.get(key)
	if s == null:
		push_warning("Settings: no registration for key '%s'" % key)
		return
	value = _coerce(s, value)
	var current = Sonara.get_config(key, s.default)
	if current == value:
		return
	Sonara.set_config(key, value)
	Sonara.save_config()
	setting_changed.emit(key, value)


func save() -> void:
	"""Persist all config values to disk. set_value already saves; kept for batch callers."""
	Sonara.save_config()


func _coerce(s: Setting, value):
	"""Convert *value* to the setting's type and clamp it to its range."""
	match s.type:
		Type.BOOL:
			return bool(value)
		Type.INT:
			var i := int(value)
			if s.max_val > s.min_val:
				i = clampi(i, int(s.min_val), int(s.max_val))
			return i
		Type.FLOAT:
			var f := float(value)
			if s.max_val > s.min_val:
				f = clampf(f, s.min_val, s.max_val)
			return f
		Type.STRING, Type.PATH, Type.SECRET, Type.TEXT:
			return str(value)
		Type.CHOICE:
			if not s.options.is_empty() and value not in s.options:
				push_warning("Settings: invalid choice '%s' for '%s'" % [value, s.key])
				return s.default
			return value
		Type.CHOICE_MULTI, Type.PATH_ARRAY:
			return (value as Array).duplicate() if value is Array else s.default.duplicate()
	return value


func reset_to_defaults() -> void:
	"""Reset every registered setting to its default, then save."""
	for key in _settings.keys():
		var s = _settings[key]
		var def = s.default.duplicate() if s.default is Array else s.default
		Sonara.set_config(key, def)
		setting_changed.emit(key, def)
	Sonara.save_config()


# ---------------------------------------------------------------------------
# SHORTCUTS (read-only view of Godot's InputMap)
# ---------------------------------------------------------------------------

func get_shortcut_list() -> Array[Dictionary]:
	"""Return a list of user-defined input actions grouped by function.

	Each entry is { category, action, display }.
	Keyboard note keys (keyboard_c3, etc.) are excluded.
	"""
	var groups: Array[Dictionary] = [
		{ "name" = "Transport", "actions" = ["play", "pause", "pause_here", "stop_here", "toggle_computer_keyboard"] },
		{ "name" = "View", "actions" = ["switch_view", "switch_extra_view", "toggle_clip_editor", "toggle_secondary_mixer", "toggle_device_lane", "toggle_assistant"] },
		{ "name" = "Edit", "actions" = ["ui_undo", "ui_redo", "ui_duplicate", "ui_delete"] },
		{ "name" = "Keyboard", "actions" = ["keyboard_transpose_up", "keyboard_transpose_down", "keyboard_velocity_up", "keyboard_velocity_down"] },
	]

	var result: Array[Dictionary] = []
	for group in groups:
		for action in group.actions:
			if not InputMap.has_action(action):
				continue
			var events: Array[InputEvent] = InputMap.action_get_events(action)
			if events.is_empty():
				continue
			var parts: Array[String] = []
			for ev in events:
				var lbl = _event_to_string(ev)
				if not lbl.is_empty():
					parts.append(lbl)
			if parts.is_empty():
				continue
			result.append({
				category = group.name,
				action = action,
				display = " + ".join(parts),
			})
	return result


func _event_to_string(event: InputEvent) -> String:
	"""Human-readable representation of one InputEventKey."""
	if event is InputEventKey:
		var key := event as InputEventKey
		var mods: Array[String] = []
		if key.ctrl_pressed:
			mods.append("Ctrl")
		if key.shift_pressed:
			mods.append("Shift")
		if key.alt_pressed:
			mods.append("Alt")
		if key.meta_pressed:
			mods.append("Cmd")
		var key_name: String
		if key.physical_keycode:
			key_name = OS.get_keycode_string(key.physical_keycode)
		else:
			key_name = OS.get_keycode_string(key.keycode)
		if key_name.is_empty():
			key_name = "?"
		mods.append(key_name)
		return " + ".join(mods)
	elif event is InputEventMouseButton:
		return "Mouse " + str((event as InputEventMouseButton).button_index)
	return ""

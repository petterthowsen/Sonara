# HotkeyActions.gd
# The one table of rebindable keyboard actions: id, label, group, context and default
# chords. Settings builds its "shortcuts/<id>" settings from ACTIONS, and Hotkeys applies
# the stored bindings to InputMap. Static data only (no autoload), because Settings
# registers its settings in _init, before any other autoload exists.
#
# To add an action: add one row to ACTIONS and call Hotkeys.pressed(event, "<id>") in the
# handler. See docs/hotkeys-and-help-bar-plan.md.
#
# Per-action fields:
#   id, label, group, context, defaults   required. defaults are chord strings ("Ctrl+Shift+Z")
#   description                           optional help text (shown in Settings)
#   physical    bool, default false       bind the physical key (piano layout), not the logical one
#   help        bool, default true        show in the help bar
#   exclusive_with  String                action id that shares this action's chord on purpose: the two
#                                         apply in disjoint states, so it isn't reported as a conflict
#   requires    String                    help-bar condition that must be set (Hotkeys.set_condition),
#                                         e.g. "clip_selection": hidden while it is not met
#   priority    int                       sort order in the help bar
#   allow_echo  bool, default false       fire on key repeat (nudge actions)
#   double_tap_of  String                 parent action id. No keys of its own: it follows the
#                                         parent's binding and fires on a quick second press
class_name HotkeyActions

const ACTIONS := [
	# --- Transport ---
	{ "id": "transport_play", "label": "Play", "group": "Transport", "context": "global",
		"defaults": ["Space"], "help": false, "exclusive_with": "transport_pause",
		"description": "Start playback at the playhead." },
	{ "id": "transport_pause", "label": "Pause", "group": "Transport", "context": "global",
		"defaults": ["Space"], "help": false, "exclusive_with": "transport_play",
		"description": "Pause playback where it is." },
	{ "id": "transport_play_from_start", "label": "Play from start position", "group": "Transport", "context": "global",
		"defaults": [],
		"description": "Move the playhead to the blue start position and play." },
	{ "id": "transport_pause_to_start", "label": "Pause and go to start position", "group": "Transport", "context": "global",
		"defaults": ["Shift+Space"],
		"description": "Pause and move the playhead to the blue start position." },
	{ "id": "transport_pause_to_origin", "label": "Pause and reset start to bar 0", "group": "Transport", "context": "global",
		"defaults": [],
		"description": "Pause, move the start position to bar 0 and the playhead with it." },
	{ "id": "transport_stop_cycle", "label": "Stop (cycle)", "group": "Transport", "context": "global",
		"defaults": ["Ctrl+Space"],
		"description": "While playing: stop and return to the start position. While stopped, each press goes one step further: playhead to the start position, then start position to the nearest Marker, then to bar 0." },
	{ "id": "transport_loop_toggle", "label": "Toggle loop", "group": "Transport", "context": "global",
		"defaults": ["L"],
		"description": "Loop playback over the loop region. With no region yet, it is created from the selected time range." },

	# --- Edit ---
	{ "id": "edit_undo", "label": "Undo", "group": "Edit", "context": "global",
		"defaults": ["Ctrl+Z"], "help": false },
	{ "id": "edit_redo", "label": "Redo", "group": "Edit", "context": "global",
		"defaults": ["Ctrl+Shift+Z", "Ctrl+Y"], "help": false },
	{ "id": "edit_copy", "label": "Copy", "group": "Edit", "context": "workspace",
		"defaults": ["Ctrl+C", "Ctrl+Insert"], "help": false },
	{ "id": "edit_cut", "label": "Cut", "group": "Edit", "context": "workspace",
		"defaults": ["Ctrl+X", "Shift+Delete"], "help": false },
	{ "id": "edit_paste", "label": "Paste", "group": "Edit", "context": "workspace",
		"defaults": ["Ctrl+V", "Shift+Insert"], "help": false },
	{ "id": "edit_duplicate", "label": "Duplicate", "group": "Edit", "context": "workspace",
		"defaults": ["Ctrl+D"] },
	{ "id": "edit_delete", "label": "Delete", "group": "Edit", "context": "workspace",
		"defaults": ["Delete", "Backspace"], "help": false },
	{ "id": "edit_select_all", "label": "Select all", "group": "Edit", "context": "workspace",
		"defaults": ["Ctrl+A"] },
	{ "id": "edit_select_all_tracks", "label": "Select all (all tracks)", "group": "Edit", "context": "arranger",
		"double_tap_of": "edit_select_all",
		"description": "Press the Select all key twice quickly to select the clips on every track." },

	# --- Arranger ---
	{ "id": "arranger_move_left", "label": "Move clips left", "group": "Arranger", "context": "arranger",
		"requires": "clip_selection",
		"defaults": ["Left"], "allow_echo": true },
	{ "id": "arranger_move_right", "label": "Move clips right", "group": "Arranger", "context": "arranger",
		"requires": "clip_selection",
		"defaults": ["Right"], "allow_echo": true },
	{ "id": "arranger_move_track_up", "label": "Move clips to track above", "group": "Arranger", "context": "arranger",
		"requires": "clip_selection",
		"defaults": ["Up"], "allow_echo": true },
	{ "id": "arranger_move_track_down", "label": "Move clips to track below", "group": "Arranger", "context": "arranger",
		"requires": "clip_selection",
		"defaults": ["Down"], "allow_echo": true },
	{ "id": "arranger_range_end_right", "label": "Grow selection range end", "group": "Arranger", "context": "arranger",
		"requires": "arranger_range",
		"defaults": ["Ctrl+Right"], "allow_echo": true, "description": "Moves the range end later by the snap interval." },
	{ "id": "arranger_range_end_left", "label": "Shrink selection range end", "group": "Arranger", "context": "arranger",
		"requires": "arranger_range",
		"defaults": ["Ctrl+Left"], "allow_echo": true, "description": "Moves the range end earlier by the snap interval." },
	{ "id": "arranger_range_start_left", "label": "Grow selection range start", "group": "Arranger", "context": "arranger",
		"requires": "arranger_range",
		"defaults": ["Ctrl+Shift+Left"], "allow_echo": true, "description": "Moves the range start earlier by the snap interval." },
	{ "id": "arranger_range_start_right", "label": "Shrink selection range start", "group": "Arranger", "context": "arranger",
		"requires": "arranger_range",
		"defaults": ["Ctrl+Shift+Right"], "allow_echo": true, "description": "Moves the range start later by the snap interval." },

	# --- Clip Editor ---
	{ "id": "notes_nudge_left", "label": "Nudge notes left", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_selection",
		"defaults": ["Left"], "allow_echo": true, "description": "By the snap interval." },
	{ "id": "notes_nudge_right", "label": "Nudge notes right", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_selection",
		"defaults": ["Right"], "allow_echo": true, "description": "By the snap interval." },
	{ "id": "notes_transpose_up", "label": "Transpose notes up", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_selection",
		"defaults": ["Up"], "allow_echo": true, "description": "One semitone." },
	{ "id": "notes_transpose_down", "label": "Transpose notes down", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_selection",
		"defaults": ["Down"], "allow_echo": true, "description": "One semitone." },
	{ "id": "notes_octave_up", "label": "Transpose notes up an octave", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_selection",
		"defaults": ["Ctrl+Up"], "allow_echo": true },
	{ "id": "notes_octave_down", "label": "Transpose notes down an octave", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_selection",
		"defaults": ["Ctrl+Down"], "allow_echo": true },
	{ "id": "notes_range_end_right", "label": "Grow selection range end", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_range",
		"defaults": ["Ctrl+Right"], "allow_echo": true, "description": "Moves the range end later by the smallest visible snap increment." },
	{ "id": "notes_range_end_left", "label": "Shrink selection range end", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_range",
		"defaults": ["Ctrl+Left"], "allow_echo": true, "description": "Moves the range end earlier by the smallest visible snap increment." },
	{ "id": "notes_range_start_left", "label": "Grow selection range start", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_range",
		"defaults": ["Ctrl+Shift+Left"], "allow_echo": true, "description": "Moves the range start earlier by the smallest visible snap increment." },
	{ "id": "notes_range_start_right", "label": "Shrink selection range start", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_range",
		"defaults": ["Ctrl+Shift+Right"], "allow_echo": true, "description": "Moves the range start later by the smallest visible snap increment." },
	{ "id": "notes_move_by_selection_left", "label": "Move selection left by its length", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_selection",
		"defaults": ["Shift+Left"], "allow_echo": true,
		"description": "The selection range (or, without one, the span of the selected notes) moves back by its own length." },
	{ "id": "notes_move_by_selection_right", "label": "Move selection right by its length", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_selection",
		"defaults": ["Shift+Right"], "allow_echo": true,
		"description": "The selection range (or, without one, the span of the selected notes) moves forward by its own length." },
	{ "id": "notes_velocity_up", "label": "Raise velocity", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_selection",
		"defaults": ["Alt+Up"], "allow_echo": true, "description": "By a few MIDI velocity steps." },
	{ "id": "notes_velocity_down", "label": "Lower velocity", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_selection",
		"defaults": ["Alt+Down"], "allow_echo": true, "description": "By a few MIDI velocity steps." },
	{ "id": "notes_length_grow", "label": "Lengthen notes", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_selection",
		"defaults": ["Alt+Right"], "allow_echo": true, "description": "By the snap interval." },
	{ "id": "notes_length_shrink", "label": "Shorten notes", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_selection",
		"defaults": ["Alt+Left"], "allow_echo": true, "description": "By the snap interval, never below one snap interval." },
	{ "id": "notes_quantize", "label": "Quantize notes", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_selection",
		"defaults": ["Ctrl+Q"], "description": "Move the selected notes toward the grid, using the strength and mode set in the Quantize options." },
	{ "id": "notes_flip_vertical", "label": "Flip notes vertically", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_selection",
		"defaults": ["Ctrl+Shift+V"], "description": "Invert the pitches of the selected notes around the middle of their pitch range. Not in Drum View." },
	{ "id": "notes_flip_horizontal", "label": "Flip notes horizontally", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_selection",
		"defaults": ["Ctrl+Shift+H"], "description": "Reverse the selected notes in time, within the selection range (or the span of the notes)." },
	{ "id": "notes_strum", "label": "Strum chords", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_selection",
		"defaults": ["Ctrl+Shift+S"], "description": "Spread the chords among the selected notes using the spread, direction and velocity ramp set in the Strum options. Note ends stay put. Not in Drum View." },
	{ "id": "toggle_scale_snap", "label": "Toggle scale snap", "group": "Clip Editor", "context": "clip_editor",
		"defaults": [], "description": "Snap placed and moved notes to the project scale. Needs a scale and the piano roll." },
	{ "id": "toggle_fold_to_scale", "label": "Toggle fold to scale", "group": "Clip Editor", "context": "clip_editor",
		"defaults": [], "description": "Show only the in-scale rows (plus the pitches in use). Needs a scale and the piano roll." },
	{ "id": "notes_conform_to_scale", "label": "Conform notes to scale", "group": "Clip Editor", "context": "clip_editor",
		"requires": "note_selection",
		"defaults": [], "description": "Move out-of-scale selected notes to the nearest in-scale pitch (ties go down). Keyswitches stay." },
	{ "id": "toggle_note_value_lanes", "label": "Toggle note value lanes", "group": "Clip Editor", "context": "clip_editor",
		"defaults": [] },

	# --- Mixer ---
	{ "id": "mixer_select_prev", "label": "Select previous channel", "group": "Mixer", "context": "mixer",
		"defaults": ["Left"], "allow_echo": true },
	{ "id": "mixer_select_next", "label": "Select next channel", "group": "Mixer", "context": "mixer",
		"defaults": ["Right"], "allow_echo": true },
	{ "id": "mixer_volume_up", "label": "Fader up", "group": "Mixer", "context": "mixer",
		"defaults": ["Up"], "allow_echo": true },
	{ "id": "mixer_volume_down", "label": "Fader down", "group": "Mixer", "context": "mixer",
		"defaults": ["Down"], "allow_echo": true },
	{ "id": "mixer_volume_up_fine", "label": "Fader up (fine)", "group": "Mixer", "context": "mixer",
		"defaults": ["Shift+Up"], "allow_echo": true },
	{ "id": "mixer_volume_down_fine", "label": "Fader down (fine)", "group": "Mixer", "context": "mixer",
		"defaults": ["Shift+Down"], "allow_echo": true },
	{ "id": "mixer_rename", "label": "Rename channel", "group": "Mixer", "context": "mixer",
		"defaults": ["Enter", "Kp Enter"] },

	# --- View ---
	{ "id": "switch_view", "label": "Next view", "group": "View", "context": "global",
		"defaults": ["Tab"] },
	{ "id": "switch_extra_view", "label": "Previous view", "group": "View", "context": "global",
		"defaults": ["Shift+Tab"] },
	{ "id": "toggle_device_lane", "label": "Show device lane", "group": "View", "context": "global",
		"defaults": ["D"] },
	{ "id": "toggle_device_frame", "label": "Toggle device frame", "group": "View", "context": "global",
		"defaults": [] },
	{ "id": "toggle_assistant", "label": "Toggle assistant", "group": "View", "context": "global",
		"defaults": ["Ctrl+Shift+A"] },

	# --- Computer Keyboard (physical keys, a piano layout on any keyboard layout) ---
	{ "id": "toggle_computer_keyboard", "label": "Toggle computer keyboard", "group": "Computer Keyboard", "context": "global",
		"defaults": ["CapsLock"], "physical": true,
		"description": "Play notes with the computer keyboard." },
	{ "id": "keyboard_c3", "label": "Note C3", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["Q"], "physical": true, "help": false },
	{ "id": "keyboard_c#3", "label": "Note C#3", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["2"], "physical": true, "help": false },
	{ "id": "keyboard_d3", "label": "Note D3", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["W"], "physical": true, "help": false },
	{ "id": "keyboard_d#3", "label": "Note D#3", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["3"], "physical": true, "help": false },
	{ "id": "keyboard_e3", "label": "Note E3", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["E"], "physical": true, "help": false },
	{ "id": "keyboard_f3", "label": "Note F3", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["R"], "physical": true, "help": false },
	{ "id": "keyboard_f#3", "label": "Note F#3", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["5"], "physical": true, "help": false },
	{ "id": "keyboard_g3", "label": "Note G3", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["T"], "physical": true, "help": false },
	{ "id": "keyboard_g#3", "label": "Note G#3", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["6"], "physical": true, "help": false },
	{ "id": "keyboard_a3", "label": "Note A3", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["Y"], "physical": true, "help": false },
	{ "id": "keyboard_a#3", "label": "Note A#3", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["7"], "physical": true, "help": false },
	{ "id": "keyboard_b3", "label": "Note B3", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["U"], "physical": true, "help": false },
	{ "id": "keyboard_c4", "label": "Note C4", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["I"], "physical": true, "help": false },
	{ "id": "keyboard_c#4", "label": "Note C#4", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["9"], "physical": true, "help": false },
	{ "id": "keyboard_d4", "label": "Note D4", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["O"], "physical": true, "help": false },
	{ "id": "keyboard_d#4", "label": "Note D#4", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["0"], "physical": true, "help": false },
	{ "id": "keyboard_transpose_down", "label": "Keyboard octave down", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["Z"], "physical": true },
	{ "id": "keyboard_transpose_up", "label": "Keyboard octave up", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["X"], "physical": true },
	{ "id": "keyboard_velocity_down", "label": "Keyboard velocity down", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["C"], "physical": true },
	{ "id": "keyboard_velocity_up", "label": "Keyboard velocity up", "group": "Computer Keyboard", "context": "computer_keyboard",
		"defaults": ["V"], "physical": true },

	# --- Devices ---
	{ "id": "zones_delete", "label": "Delete zones", "group": "Devices", "context": "sampler_zones",
		"defaults": ["Delete"] },
	{ "id": "zones_select_all", "label": "Select all zones", "group": "Devices", "context": "sampler_zones",
		"defaults": ["Ctrl+A"] },
	{ "id": "layers_delete", "label": "Delete layers", "group": "Devices", "context": "layer_mapping",
		"defaults": ["Delete", "Backspace"] },
	{ "id": "layers_shift_up", "label": "Shift selected notes up", "group": "Devices", "context": "layer_mapping",
		"defaults": ["Up"] },
	{ "id": "layers_shift_down", "label": "Shift selected notes down", "group": "Devices", "context": "layer_mapping",
		"defaults": ["Down"] },
	{ "id": "layers_shift_octave_up", "label": "Shift selected notes up an octave", "group": "Devices", "context": "layer_mapping",
		"defaults": ["Shift+Up"] },
	{ "id": "layers_shift_octave_down", "label": "Shift selected notes down an octave", "group": "Devices", "context": "layer_mapping",
		"defaults": ["Shift+Down"] },
]

## Context tree: id -> parent id. "" is the root. Two actions conflict only when they share a
## chord and one context is the other or an ancestor of it.
## `workspace` groups the panels that share the edit commands (copy, paste, delete, ...).
const CONTEXTS := {
	"global": "",
	"workspace": "global",
	"arranger": "workspace",
	"clip_editor": "workspace",
	"mixer": "global",
	"device_panel": "global",
	"sampler_zones": "device_panel",
	"layer_mapping": "global",
	"computer_keyboard": "global",
	"value_lanes": "clip_editor",
	"automation_lane": "arranger",
	"control_knob": "global",
	# A text control has focus: the help bar shows nothing but Escape/Enter hints.
	"text": "global",
}

## Interaction states (a gesture in progress, see Hotkeys.begin_state): id -> parent context.
## A state's chain is the state itself followed by its parent context's chain.
const STATES := {
	"clip_drag": "arranger",
	"clip_resize": "arranger",
	"box_select": "workspace",
	"note_hover": "clip_editor",
	"note_drag": "clip_editor",
	"note_drag_alt": "clip_editor",
	"value_lane_draw": "clip_editor",
}

const CONTEXT_LABELS := {
	"global": "Global",
	"workspace": "Editing",
	"arranger": "Arranger",
	"clip_editor": "Clip Editor",
	"mixer": "Mixer",
	"device_panel": "Devices",
	"sampler_zones": "Sampler zones",
	"layer_mapping": "Layer mapping",
	"computer_keyboard": "Computer keyboard",
	"value_lanes": "Value lanes",
	"automation_lane": "Automation lane",
	"control_knob": "Control",
	"text": "Text input",
}

## Mouse gestures and held modifiers for the help bar. Read-only: they can't be rebound.
## `context` is a CONTEXTS or STATES id, `mods` a "+"-joined subset of Ctrl/Shift/Alt/Meta ("" =
## none), `input` one of GESTURE_INPUTS ("" = only the modifier is held during a state).
## `"setting"` + `"equals"` show a gesture only while that setting has that value.
## `"help": false` keeps a fundamental gesture (scroll, pan) out of the help bar.
## Each row mirrors the code named in its comment. Where code and label disagree, the code wins.
const GESTURE_INPUTS := ["click", "double_click", "right_click", "drag", "right_drag",
		"middle_drag", "wheel", ""]

const GESTURES := [
	# --- Arranger: Arranger._on_scroll_gui_input, Arranger._input, Timeline/TimelineTrack/TimelineClip ---
	{ "context": "arranger", "mods": "", "input": "wheel", "label": "scroll", "help": false },
	{ "context": "arranger", "mods": "Shift", "input": "wheel", "label": "zoom horizontally" },
	{ "context": "arranger", "mods": "Ctrl", "input": "wheel", "label": "track height" },
	{ "context": "arranger", "mods": "Alt", "input": "wheel", "label": "scroll horizontally" },
	{ "context": "arranger", "mods": "", "input": "middle_drag", "label": "pan", "help": false },
	{ "context": "arranger", "mods": "", "input": "click", "label": "select clip / set playhead" },
	{ "context": "arranger", "mods": "", "input": "drag", "label": "move clips" },
	{ "context": "arranger", "mods": "", "input": "double_click", "label": "open clip / add instance" },
	{ "context": "arranger", "mods": "", "input": "right_click", "label": "menu" },
	{ "context": "arranger", "mods": "Shift", "input": "click", "label": "add to selection" },
	{ "context": "arranger", "mods": "Ctrl", "input": "click", "label": "toggle selection" },
	{ "context": "arranger", "mods": "Ctrl", "input": "drag", "label": "box select" },
	# --- Clip move / resize in progress: Timeline._handle_clip_drag_input, TimelineClip._gui_input ---
	{ "context": "clip_drag", "mods": "Shift", "input": "", "label": "move freely (no snap)" },
	{ "context": "clip_resize", "mods": "Shift", "input": "", "label": "resize freely (no snap)" },
	# --- Automation lane: AutomationLaneRow._gui_input ---
	{ "context": "automation_lane", "mods": "", "input": "double_click", "label": "add point" },
	{ "context": "automation_lane", "mods": "Shift", "input": "click", "label": "toggle point" },
	{ "context": "automation_lane", "mods": "Ctrl", "input": "drag", "label": "select range" },
	# --- Clip editor: MidiEditor._gui_input and the left/right press handlers ---
	{ "context": "clip_editor", "mods": "", "input": "wheel", "label": "scroll", "help": false },
	{ "context": "clip_editor", "mods": "Shift", "input": "wheel", "label": "zoom horizontally" },
	{ "context": "clip_editor", "mods": "Ctrl", "input": "wheel", "label": "zoom vertically" },
	{ "context": "clip_editor", "mods": "Alt", "input": "wheel", "label": "scroll horizontally" },
	{ "context": "clip_editor", "mods": "", "input": "middle_drag", "label": "pan", "help": false },
	{ "context": "clip_editor", "mods": "Shift", "input": "middle_drag", "label": "zoom horizontally" },
	{ "context": "clip_editor", "mods": "", "input": "click", "label": "place / move note" },
	{ "context": "clip_editor", "mods": "Ctrl", "input": "click", "label": "toggle note selection" },
	{ "context": "clip_editor", "mods": "Ctrl", "input": "drag", "label": "box select / duplicate note" },
	# --- Pointer over a note: MidiEditor._update_note_hover ---
	{ "context": "note_hover", "mods": "", "input": "drag", "label": "move (note end: resize)" },
	{ "context": "note_hover", "mods": "Shift", "input": "drag", "label": "move / resize without grid or scale snap" },
	# Which of these shows depends on midi_editor/note_drag_modifiers ("setting" + "equals").
	{ "context": "note_hover", "mods": "Alt", "input": "drag", "label": "length (sideways) / velocity (up, down)",
		"setting": "midi_editor/note_drag_modifiers", "equals": "Alt: length and velocity" },
	{ "context": "note_hover", "mods": "Alt", "input": "drag", "label": "velocity (up, down)",
		"setting": "midi_editor/note_drag_modifiers", "equals": "Ctrl: length, Alt: velocity" },
	{ "context": "note_hover", "mods": "Ctrl", "input": "drag", "label": "duplicate" },
	{ "context": "clip_editor", "mods": "", "input": "right_drag", "label": "erase" },
	{ "context": "clip_editor", "mods": "Alt", "input": "right_click", "label": "hear chord (hold)" },
	# --- Note drag in progress: NoteEditor._on_drag_updated ---
	# "note_drag" is the Ctrl-length scheme, "note_drag_alt" the Alt length/velocity one
	# (setting midi_editor/note_drag_modifiers).
	{ "context": "note_drag", "mods": "Ctrl", "input": "", "label": "change length" },
	{ "context": "note_drag", "mods": "Shift", "input": "", "label": "move freely (no grid or scale snap)" },
	{ "context": "note_drag", "mods": "Alt", "input": "", "label": "change velocity" },
	{ "context": "note_drag_alt", "mods": "Alt", "input": "", "label": "length (sideways) / velocity (up, down)" },
	{ "context": "note_drag_alt", "mods": "Shift", "input": "", "label": "move freely (no grid or scale snap)" },
	# --- Value lanes: ValueLaneStemArea._begin / _on_motion ---
	{ "context": "value_lanes", "mods": "", "input": "drag", "label": "paint values" },
	{ "context": "value_lanes", "mods": "Ctrl", "input": "drag", "label": "straight line" },
	{ "context": "value_lanes", "mods": "Alt", "input": "drag", "label": "offset values" },
	{ "context": "value_lanes", "mods": "Ctrl+Alt", "input": "drag", "label": "scale values" },
	{ "context": "value_lanes", "mods": "", "input": "double_click", "label": "exact value" },
	{ "context": "value_lane_draw", "mods": "Shift", "input": "", "label": "fine adjust" },
	# --- Knobs and sliders: RotaryKnob/Fader/HorSlider/HDualSlider._gui_input, FineDrag ---
	{ "context": "control_knob", "mods": "", "input": "drag", "label": "change value" },
	{ "context": "control_knob", "mods": "Shift", "input": "drag", "label": "fine adjust" },
	{ "context": "control_knob", "mods": "", "input": "double_click", "label": "type value" },
	{ "context": "control_knob", "mods": "Ctrl", "input": "click", "label": "reset to default" },
]


static var _by_id: Dictionary = {}


## Declare *control*'s help context from a script that can be compiled before the autoloads
## exist (a headless test script), where the `Hotkeys` global name does not resolve.
static func declare_context(control: Node, ctx: String) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree and tree.root.has_node("Hotkeys"):
		tree.root.get_node("Hotkeys").set_context(control, ctx)


## The action definition for *id*, or {} when unknown.
static func get_action(id: String) -> Dictionary:
	if _by_id.is_empty():
		for a in ACTIONS:
			_by_id[a.id] = a
	return _by_id.get(id, {})


## True for an action that follows its parent's keys instead of having its own.
static func is_double_tap(id: String) -> bool:
	return get_action(id).has("double_tap_of")


## *ctx*, its parent, ... up to "global". Empty for an unknown context. A state id comes first,
## followed by its parent context's chain.
static func context_chain(ctx: String) -> Array[String]:
	var chain: Array[String] = []
	if STATES.has(ctx):
		chain.append(ctx)
		ctx = STATES[ctx]
	while CONTEXTS.has(ctx):
		chain.append(ctx)
		ctx = CONTEXTS[ctx]
	return chain


## True when one context is the other or an ancestor of it.
static func contexts_overlap(a: String, b: String) -> bool:
	return a in context_chain(b) or b in context_chain(a)

# Hotkeys and context help bar

Implementation plan in two phases:

1. **Hotkey system.** One registry of rebindable actions, with defaults, labels and contexts. Bindings can be changed in Settings › Shortcuts.
2. **Help bar.** The placeholder `InfoText` at the bottom of `Editor.tscn` becomes a live bar. It shows the hotkeys and mouse gestures for whatever the pointer is over, and changes while a modifier is held.

Phase 2 depends on Phase 1. The help bar reads its labels, contexts and current bindings from the Phase 1 registry, so it never shows a stale key.

## Checklist

- [ ] Phase 1a: Action registry + `Hotkeys` autoload (bindings applied to `InputMap` from Settings)
- [ ] Phase 1b: Migrate call sites to registry actions (no behavior change)
- [ ] Phase 1c: Settings › Shortcuts page with key capture and conflict warnings
- [ ] Phase 2a: Context resolution (hover + focus + interaction state)
- [ ] Phase 2b: Gesture declarations and the `HelpBar` component
- [ ] Phase 2c: Wire contexts into the editors and generic controls

Run `Godot/tests/run_all.sh` after each sub-phase. Phase 1b is a pure refactor, so after it every existing shortcut must still behave exactly as before. Mark items `[x?]` when done, never `[x]`.

## What exists today (read before starting)

| Where | What |
|---|---|
| `Godot/project.godot` `[input]` | ~40 custom actions (transport, view toggles, `ui_duplicate`, `ui_delete`, 16 `keyboard_*` note keys, keyboard transpose/velocity). Most bind `physical_keycode`. `toggle_assistant` binds the logical `keycode`. |
| `Godot/settings/Settings.gd` | Settings registry. `CATEGORY_SHORTCUTS` exists but is hidden because it has no settings. `get_shortcut_list()` and `_event_to_string()` (bottom of the file) are a read-only InputMap dump with no UI. Phase 1 replaces both. |
| `Godot/settings/SettingRow.gd`, `SettingsDialog.gd` | Rows support custom control scenes (`Setting.scene()`, contract: `value_edited` signal, `setup`, `set_value`, `get_value`). The dialog has sub-category headers, fuzzy search, and a Cancel snapshot over `get_all_keys()`. `SettingRow.Type` must mirror `Settings.Type` (a test checks this). |
| `Godot/editor/Editor.gd:339` `_unhandled_input` | Global actions: undo/redo, play/pause, `pause_here`, view switches, device lane/frame, assistant. It has two workarounds that exact matching makes unnecessary. `play` and `pause_here` are both Space, so it checks `shift_pressed` by hand. `toggle_device_lane` (D) and `ui_duplicate` (Ctrl+D) collide, so it checks `get_modifiers_mask() == 0`. |
| `Godot/arranger/Arranger.gd:545` `_handle_input` | Copy, cut, paste, duplicate and delete use the Godot `ui_*` actions. Ctrl+A is hardcoded and double-tapping it selects all tracks. Arrows move clips by ticks or tracks. The panel is gated by "pointer over the timeline". |
| `Godot/clip_editor/note_editor/NoteEditor.gd:190` `handle_key_input` | Same edit actions. Ctrl+A is hardcoded. Up/Down transpose (Ctrl = octave) and Left/Right nudge by the snap interval. |
| `Godot/clip_editor/ClipEditor.gd:224` | `toggle_note_value_lanes` (no binding yet). |
| `Godot/mixer/Mixer.gd:500` `_input` | Hardcoded: Left/Right select the adjacent channel, Up/Down nudge the fader (Shift = fine), Enter renames. Gated by pointer over the mixer. |
| `Godot/midi/MidiManager.gd:199` `_input` | `toggle_computer_keyboard`, the 16 note actions, transpose/velocity. Runs in `_input` and skips text editing via `_is_gui_text_editing()`. |
| `Godot/devices/builtin/sampler/MultisampleEditor.gd:198`, `devices/container/layer_mapping/LayerMappingWindow.gd:405` | Hardcoded Delete and Ctrl+A, plus Up/Down list navigation. |
| Mouse gestures | Arranger wheel (`Arranger.gd:411`: Shift = horizontal zoom, Ctrl = track height, Alt = horizontal scroll), middle-drag pan (`Arranger.gd:513`), clip drag/resize modifiers (`TimelineClip.gd:578-640`), clip editor wheel and click modifiers (`MidiEditor.gd:878-1106`), note drag modifiers (`NoteEditor.gd:404-500`), value-lane gestures (`ValueLaneStemArea.gd:272-315`), automation points (`AutomationLaneRow.gd:400`), multi-select modifiers across the tracklist, mixer and drum pads. |
| `Editor.tscn` `.../Bottom/InfoPanel/HBoxContainer/InfoBox/InfoText` | A `RichTextLabel` with bbcode and the static text `[color="gold"]ctrl[/color] to zoom`. Nothing writes to it. |
| Dead actions | `pause`, `stop_here`, `toggle_clip_editor` and `toggle_secondary_mixer` are bound in `project.godot`, but no code handles them. |

## Design decisions

These are settled. Don't re-open them during implementation without asking.

- **Scope of "rebindable".** Keyboard shortcuts for app commands can be rebound. Mouse gestures (wheel and drag modifiers) are declared for the help bar but can't be rebound in this plan. Dialog-local keys stay hardcoded: Escape cancels and Enter confirms in `SmartLineEdit`, `ChatComposer`, `FloatingValueEditor`, `ZoneGroupChip`, `TimeSignatureItem`, `MarkerTrack` and the settings search.
- **App commands stop using Godot's built-in `ui_*` actions.** `ui_copy`, `ui_paste`, `ui_undo`, `ui_left` and the rest also drive `LineEdit`/`TextEdit`. If a user rebound Copy, text fields would change too. The plan adds Sonara actions (`edit_copy`, `edit_paste`, …) and leaves `ui_*` alone.
- **Defaults live in one table, in code** (`HotkeyActions.gd`), next to each action's label, group, context and description. `project.godot` keeps no app actions, so there is no second source. Settings registers one setting per action from that table. Settings stays the only owner of defaults, as `godot-config-system.md` requires, and every binding change goes through `Settings.set_value`.
- **Exact matching.** Registry actions always match with `exact_match = true`, so Space ≠ Shift+Space and D ≠ Ctrl+D. That removes the modifier workarounds in `Editor.gd`.
- **Contexts form a tree.** `global` is the root. Two actions conflict only when they share a chord and one context is the other or an ancestor of it. For example, Up in `arranger` and Up in `mixer` can coexist, but Ctrl+D in `global` and Ctrl+D in `arranger` conflict.
- **Phase 1 doesn't change where handlers run.** Each handler keeps its current gating (hover checks, focus, `_input` vs `_unhandled_input`) and only swaps its matching to registry actions. Phase 2 adds runtime context resolution for the help bar. Moving dispatch onto that resolution is a possible follow-up and is out of scope here.
- **Up to two bindings per action** (primary + secondary). That covers today's `ui_delete`, which binds Delete, Backspace and KP-Delete. Map those to Delete + Backspace and drop KP-Delete.
- **Double taps are actions that reuse their parent's key.** A double tap is declared as an action with `double_tap_of: "<parent id>"`. It has no keys of its own and always follows the parent's binding, so if select-all is rebound to Ctrl+L, Ctrl+L, L still selects all tracks. The first tap always runs the parent action, because the system can't wait to see whether a second tap is coming without making every single tap feel slow. So a double tap is only allowed for an action that extends the first tap's result, the way select-all-tracks extends select-all-in-track. One window, `Hotkeys.DOUBLE_TAP_MS`, applies everywhere.
- **Physical vs logical keys are decided per action, not per binding.** The computer-keyboard note keys and transpose/velocity keys are `physical: true`, so they stay a piano layout on any keyboard layout. Everything else binds the logical key, so Ctrl+Z follows the user's layout.

## Phase 1a: Action registry and `Hotkeys` autoload

New directory `Godot/input/`.

**`Godot/input/HotkeyActions.gd`** (`class_name HotkeyActions`, static data only, no autoload). `Settings` builds its registry in `_init`, before other autoloads exist, so this must be a plain class.

```gdscript
## One rebindable action. `defaults` are chord strings ("Ctrl+Shift+A", "Space").
const ACTIONS := [
	{ "id": "transport_play_toggle", "label": "Play / Stop", "group": "Transport",
	  "context": "global", "defaults": ["Space"],
	  "description": "Start playback, or stop and return to the start position." },
	{ "id": "transport_pause_here", "label": "Pause / Resume here", "group": "Transport",
	  "context": "global", "defaults": ["Shift+Space"] },
	# …
	{ "id": "keyboard_c3", "label": "Note C3", "group": "Computer Keyboard",
	  "context": "computer_keyboard", "defaults": ["Q"], "physical": true, "help": false },
]

## Context tree: id -> parent id. "" = root.
const CONTEXTS := {
	"global": "",
	"arranger": "global",
	"clip_editor": "global",
	"mixer": "global",
	"device_panel": "global",
	"sampler_zones": "device_panel",
	"layer_mapping": "global",
	"computer_keyboard": "global",
}
const CONTEXT_LABELS := { "arranger": "Arranger", … }

static func get_action(id: String) -> Dictionary
static func context_chain(ctx: String) -> Array[String]   # ctx, parent, …, "global"
static func contexts_overlap(a: String, b: String) -> bool
```

Optional per-action fields: `physical` (bool), `help` (bool, default true: shown in the help bar), `priority` (int, sort order in the help bar), `allow_echo` (bool, default false: key repeat, for the nudge actions), `double_tap_of` (String: parent action id, see Design decisions). A double-tap action has no `defaults`. Its `context` must be the parent's context or one of its descendants. Its parent must not have `allow_echo`, because key repeat would count as a second tap.

Action list. Keep existing ids where they already exist so `MidiManager`'s note loop and the tests keep working. Rename the `ui_*` ones.

| Group | Context | Actions (default) |
|---|---|---|
| Transport | global | `play` → id `transport_play_toggle` (Space), `pause_here` → `transport_pause_here` (Shift+Space) |
| Edit | global | `edit_undo` (Ctrl+Z), `edit_redo` (Ctrl+Shift+Z, Ctrl+Y). Match the current `ui_undo`/`ui_redo` defaults in Godot 4.7 and check them in the editor first. |
| Edit | arranger, clip_editor | `edit_copy` (Ctrl+C), `edit_cut` (Ctrl+X), `edit_paste` (Ctrl+V), `edit_duplicate` (Ctrl+D), `edit_delete` (Delete, Backspace), `edit_select_all` (Ctrl+A), plus `edit_select_all_tracks` (context `arranger`, `double_tap_of: "edit_select_all"`). These are declared once with context `global`. Each panel handles them only while it has its own gating, the same as today. Declaring them at `global` makes conflict detection treat them as reserved everywhere. |
| Arranger | arranger | `arranger_move_left` / `_right` (Left/Right, allow_echo), `arranger_move_track_up` / `_down` (Up/Down, allow_echo) |
| Clip Editor | clip_editor | `notes_nudge_left` / `_right` (Left/Right), `notes_transpose_up` / `_down` (Up/Down), `notes_octave_up` / `_down` (Ctrl+Up/Ctrl+Down), `toggle_note_value_lanes` (unbound) |
| Mixer | mixer | `mixer_select_prev` / `_next` (Left/Right), `mixer_volume_up` / `_down` (Up/Down), `mixer_volume_up_fine` / `_down_fine` (Shift+Up/Down), `mixer_rename` (Enter, KP Enter) |
| View | global | `switch_view` (Tab), `switch_extra_view` (Shift+Tab), `toggle_device_lane` (D), `toggle_device_frame` (unbound), `toggle_assistant` (Ctrl+Shift+A) |
| Computer Keyboard | computer_keyboard | `toggle_computer_keyboard` (context `global`, Caps Lock, `physical_keycode=4194329` today), the 16 `keyboard_*` notes, `keyboard_transpose_up/down` (X/Z), `keyboard_velocity_up/down` (V/C). All `physical: true`. |
| Devices | sampler_zones, layer_mapping | `zones_delete` (Delete), `zones_select_all` (Ctrl+A), `layers_delete` (Delete, Backspace), `layers_select_prev/next` (Up/Down) |

Don't register the dead actions (`pause`, `stop_here`, `toggle_clip_editor`, `toggle_secondary_mixer`). Add a TODO.md line for each one that seems worth implementing later. A binding with no handler shouldn't appear in Settings.

**Chord strings.** `Godot/input/KeyChord.gd` (`class_name KeyChord`, static):
- `to_string(ev: InputEventKey, physical: bool) -> String` → `"Ctrl+Shift+A"`. Order the modifiers Ctrl, Shift, Alt, Meta. Use `OS.get_keycode_string()` on the plain keycode, or on the physical keycode when `physical` is set.
- `parse(s: String, physical: bool) -> InputEventKey` (null if invalid). Split on `+` yourself rather than relying on `OS.find_keycode_from_string` to handle modifiers. Watch out for the key named `+` (`"Ctrl++"`): split off the last segment manually. Set `keycode` or `physical_keycode` according to `physical`.
- `display(s: String) -> String` gives a human label for the UI. It's the same as the stored form except for symbols such as `"Up"` → `"↑"`. For physical bindings, it shows the user's layout label via `DisplayServer.keyboard_get_label_from_physical`.
- `from_event(ev: InputEventKey, physical: bool) -> String` for capture. It returns `""` for a modifier-only press.

**`Settings.gd`.**
1. Add `Type.SHORTCUT` to `Settings.Type` and `SettingRow.Type`, in the same position in both. The existing enum-parity test enforces this.
2. Add `_register_shortcut_settings()`, called at the end of `_register_all_settings()`. For each action except double-tap actions (they have no binding to store), register `Setting.new("shortcuts/" + id, label, Type.SHORTCUT, defaults.duplicate(), CATEGORY_SHORTCUTS, description).sub(group).scene("res://settings/ShortcutControl.tscn")`. Put the context label in the description ("Arranger: …") so search finds it.
3. `_coerce` for `SHORTCUT`: the value must be an Array of strings that `KeyChord.parse` accepts (with the action's `physical` flag), at most 2, de-duplicated. Drop invalid entries with a `push_warning`. An empty array is valid and means unbound. It is distinct from the default.
4. Delete `get_shortcut_list()` and `_event_to_string()`. Grep first to confirm nothing else calls them.
5. `get_categories()` will now include Shortcuts automatically.

**`Godot/input/Hotkeys.gd`** (autoload `Hotkeys`, registered in `project.godot` right after `Settings` and before `MidiManager`):
- `_ready()`: for every action, `InputMap.add_action(id)` (erase it first if it exists), then add the events parsed from `Settings.get_value("shortcuts/" + id)`. Connect `Settings.setting_changed`. For keys with the `shortcuts/` prefix, rebuild that one action and emit `bindings_changed(id)`.
- `signal bindings_changed(action_id: String)`
- `pressed(event: InputEvent, id: String) -> bool` → `event.is_action_pressed(id, allow_echo, true)`, returning false while `capturing` is true.
- `matches(event: InputEvent, id: String) -> bool` → `event.is_action(id, true)` for press-and-release handlers (the MidiManager note keys).
- `const DOUBLE_TAP_MS := 400`. It replaces `Arranger.SELECT_ALL_DOUBLE_TAP_MS`, which is 400 today.
- `double_tapped(event: InputEvent, id: String) -> bool`, where `id` is the double-tap action. It is true when the parent action is pressed and the previous press of the parent came within `DOUBLE_TAP_MS`. When it returns true, it resets the parent's last-press time, so a third tap counts as a new first tap. Track the last-press time per parent in `Hotkeys`, recorded inside `pressed()`. The handler checks `double_tapped` **before** `pressed` for the same event. Make the clock injectable (`var _now_msec := Time.get_ticks_msec` as a Callable) so tests don't need to sleep.
- `get_chords(id) -> Array[String]`, `get_display(id) -> String` (primary chord's display label, `""` if unbound). For a double-tap action, both return the parent's chords, and `get_display` appends ` ×2` (`"Ctrl+A ×2"`).
- `get_double_taps(parent_id) -> Array[String]`: the double-tap action ids for a parent, used by the Settings row and the help bar.
- `find_conflicts(id: String, chord: String) -> Array[String]`: the other actions bound to the same chord whose contexts overlap.
- `var capturing := false`. The Settings key capture sets it so that pressing a chord to bind it doesn't also run the action. `MidiManager._input` must check it too.
- Test mode: nothing here does I/O. `Settings.get_value` returns defaults under `--test`, so tests see the default bindings.

**`project.godot`.** Remove every app action from `[input]`: everything listed above, plus the dead ones and `ui_duplicate`/`ui_delete`. Keep the overrides of real Godot `ui_*` actions (`ui_accept`, `ui_select`, `ui_focus_*`, `ui_text_completion_*`) as they are. Edit the file as text and keep the `[input]` section valid. Then open the project headless once to check that it parses.

**Tests** (`Godot/tests/test_hotkeys_registry.gd`):
- Every action id is unique. Every `context` is in `CONTEXTS`, and every context's parent chain ends at `global`.
- Every default chord parses, and `to_string(parse(s)) == s`. Include `Shift+Space`, `Ctrl+Shift+Z`, `Ctrl++` and a physical `Q`.
- No two actions conflict by default, using `contexts_overlap` and the registry. This test protects against the Space and Ctrl+D problems coming back.
- After `Hotkeys._ready`, `InputMap.action_get_events(id)` matches the defaults. A synthesized Shift+Space event is `pressed` for `transport_pause_here` and not for `transport_play_toggle`. Ctrl+D triggers `edit_duplicate` and not `toggle_device_lane`.
- `_coerce` drops garbage, caps the array at 2 entries and keeps `[]`.
- Double tap: every `double_tap_of` names an existing action whose own `double_tap_of` is empty (no chains). Its context is the parent's context or below it, and the parent has no `allow_echo`. No setting is registered for `shortcuts/edit_select_all_tracks`. With an injected clock, two Ctrl+A presses 100 ms apart make `double_tapped(…, "edit_select_all_tracks")` true on the second press. At 500 ms apart it stays false. A third quick press is false again. After rebinding `edit_select_all` to Ctrl+L, a double tap of Ctrl+L triggers the double-tap action.
- No registry id appears as `input/<id>` in `ProjectSettings`, so the table is the only source.

## Phase 1b: Migrate call sites

This is a mechanical swap. Behavior must stay identical. For each file, replace `event.is_action_pressed("ui_x")`, the hardcoded `KEY_*` checks and the manual modifier checks with `Hotkeys.pressed(event, "…")`:

1. `editor/Editor.gd` `_unhandled_input`: remove the `shift_pressed` branches around play/pause_here and the `get_modifiers_mask() == 0` guard on `toggle_device_lane`. Exact matching now covers both. Keep the behavior itself. Play toggles. When it stops, it seeks to `project.start_position_ticks`. Pause-here pauses without seeking, or plays if stopped.
2. `arranger/Arranger.gd` `_handle_input`: edit actions and the arrow moves. For select-all, check `Hotkeys.double_tapped(event, "edit_select_all_tracks")` (select every track) before `Hotkeys.pressed(event, "edit_select_all")` (active track, or all tracks when none is active). Split `_select_all_clips()` into those two paths, and remove `_last_select_all_msec` and `SELECT_ALL_DOUBLE_TAP_MS`. `test_select_all.gd` must pass unchanged apart from how it fakes the timing. Remove the redundant `event.keycode == KEY_RIGHT or …` checks.
3. `clip_editor/note_editor/NoteEditor.gd` `handle_key_input`: edit actions, select-all, nudge, transpose and octave. The octave behavior comes from the separate `notes_octave_*` actions instead of `ctrl_pressed`.
4. `clip_editor/ClipEditor.gd`: `toggle_note_value_lanes`.
5. `mixer/Mixer.gd` `_input`: replace the `match key.keycode` block with action checks. Keep the "pointer over mixer, no text focus" gate. Drop the "any modifier → return" early-out. Exact matching makes it unnecessary, and the Shift-fine variants need Shift to get through.
6. `midi/MidiManager.gd`: use `Hotkeys.matches` in the note-action loop, `Hotkeys.pressed` for toggle/transpose/velocity, and return early when `Hotkeys.capturing` is set. The note ids are unchanged.
7. `devices/builtin/sampler/MultisampleEditor.gd` `handle_shortcut` and `devices/container/layer_mapping/LayerMappingWindow.gd:405`: the device actions.
8. `arranger/timeline/Timeline.gd:570`, `TimelineTrack.gd:69`, `TimelineClip.gd:596`: these read `Input.is_action_pressed("ui_select")` as an additive-select modifier. `ui_select` is a joypad button here, so it is effectively dead. Leave it alone (it isn't an app shortcut) and add a note to TODO.md.

Then grep `Godot/` (excluding `addons/` and `tests/`) for `is_action_pressed("ui_` and `keycode == KEY_`. Only the dialog-local Escape/Enter/Tab cases from Design decisions may remain.

**Tests.** The existing `test_select_all.gd`, `test_midi_editor_clip_paste.gd` and `test_range_select_settings.gd` synthesize key events. Update them where they relied on `ui_*` actions, then run the full suite. Add `test_hotkeys_dispatch.gd`. It sends Shift+Space and Space through `Editor._unhandled_input` on a test editor instance (see how existing editor tests build one) and asserts that pause versus play was chosen. If building an Editor headless is too heavy, test the dispatch at the `Hotkeys.pressed` level, as Phase 1a does, and note this in the test.

**Manual check (ask the user).** Space, Shift+Space, Tab, D, Ctrl+D in arranger and clip editor, arrows in all three panels, computer-keyboard notes with Caps Lock.

## Phase 1c: Settings › Shortcuts page

**`Godot/settings/ShortcutControl.tscn` + `.gd`** is the custom row control and follows the `Setting.scene()` contract:
- Layout: two `Button`s (primary, secondary) showing `KeyChord.display` or a dim "—", a small reset-to-default icon button (disabled when the value equals the default), and a hidden warning `Label` below.
- Click a binding button → it shows "Press keys…" and grabs focus. It sets `Hotkeys.capturing = true` and handles `_gui_input`/`_input` key events itself:
  - A modifier-only press updates the label live ("Ctrl+…").
  - The first non-modifier press builds the chord with `KeyChord.from_event(ev, physical)`, writes it into that slot, emits `value_edited`, and leaves capture.
  - Escape cancels. Escape can't be bound; that is deliberate.
  - Clicking elsewhere or losing focus cancels.
  - Always call `set_input_as_handled()` and reset `capturing` on exit, including in `_exit_tree`.
- Right-clicking a binding button clears that slot. Also add a tooltip that says so.
- After every edit, run `Hotkeys.find_conflicts`. If it finds any, show the warning: "Also used by **Duplicate** (Arranger)" with a "Unbind there" link-button that removes the chord from the other action through `Settings.set_value`. Don't block saving; conflicts are allowed but visible.
- If the action has double taps (`Hotkeys.get_double_taps`), show one dim read-only line per double tap under the buttons, e.g. "Ctrl+A ×2 · Select all (all tracks)". It updates live when the parent's binding changes.
- `set_value` must not emit, per the custom-scene contract.

**Dialog.**
- Shortcuts appears as a category with sub-category headers per group, in table order.
- Search already matches labels and descriptions. Also match the bound chord text, so typing "ctrl+d" finds Duplicate. Do it by including the display chords in whatever string `_apply_search` scores, or by adding a `search_extra` callable on `Setting` if scoring only reads label and description.
- Cancel restores bindings through the existing snapshot (`_capture_snapshot` already deep-copies arrays), and `setting_changed` makes `Hotkeys` re-apply them.
- Add a "Reset all shortcuts" button at the top of the Shortcuts page only. It resets just the `shortcuts/` keys. Defaults keeps resetting everything.

**Tests** (`test_shortcut_control.gd`, modelled on the existing custom-scene test): instantiate a row for `shortcuts/edit_duplicate`, synthesize a capture (click → Ctrl+Shift+D), and assert that `get_value()` holds `["Ctrl+Shift+D"]` and `Hotkeys.capturing` is false afterwards. Rebind `edit_duplicate` to `D` and assert that the warning names "Show device lane". Check that Escape during capture leaves the value unchanged.

Update `docs/subsystems/godot-config-system.md` with a short "Shortcuts" section on how to add an action: one row in `HotkeyActions.ACTIONS` and a `Hotkeys.pressed` call in the handler. Add a `docs/adr/0017-hotkey-registry.md` recording the decisions above: no `ui_*` for app commands, defaults in code rather than `project.godot`, exact matching, the context tree, and double taps as parent-key actions that only extend the first tap.

## Phase 2a: Context resolution

Add to `Hotkeys` (or a small `Godot/input/HelpContext.gd` helper owned by it):

- **Declaring a context.** `Hotkeys.set_context(control: Control, ctx: String)` stores `control.set_meta("hotkey_context", ctx)`. Call it once in each panel's `_ready`.
- **Resolving it.** Use `get_viewport().gui_get_hovered_control()` (already used in `MidiEditor.gd:1522` and `Timeline.gd:687`) and walk up the parents to the first node with `hotkey_context` meta. With no match the context is `global`. Overrides, in priority order:
  1. A text control (`LineEdit`/`TextEdit`) has focus → context `text`, which the help bar treats as "show nothing except Escape/Enter hints".
  2. An active interaction state, see below.
  3. The hovered context.
- **Interaction states** cover gestures in progress, such as dragging a clip, box-selecting or resizing. `Hotkeys.begin_state(owner: Object, state: String)` / `end_state(owner)` keep a small stack. The top entry wins over hover, so the bar keeps showing the drag's modifiers even when the pointer leaves the panel mid-drag. States are ids in `HotkeyActions.STATES` (for example `clip_drag`, `clip_resize`, `note_drag`, `box_select`, `value_lane_draw`), each with a parent context. Guard against leaks: `end_state` tolerates unknown owners, and states whose owner was freed are removed during resolution.
- **When to re-resolve.** Re-resolve on mouse motion in `Hotkeys._input`, throttled to once per 50 ms or when the hovered control changes, on focus change (`get_viewport().gui_focus_changed`), on begin/end state, and on any modifier key press or release.
- `signal help_context_changed(ctx: String, modifiers: int)`, emitted only when the pair changes. `modifiers` is a key mask of the currently held Ctrl/Shift/Alt/Meta.
- Device windows are separate `Window`s with their own viewport. In Phase 2 the bar only follows the main window. When a device window has focus, resolve to `device_panel`. Read `DeviceWindowManager` to find the focused window.

**Tests:** build a small tree of Controls with contexts set, use `Hotkeys._resolve_for(control)` (factor the walk so it can be tested without real hover), and assert the nearest-ancestor result, the text-focus override, and state-stack priority including the freed-owner cleanup.

## Phase 2b: Gestures and the HelpBar

**Gesture declarations** go in `HotkeyActions.GESTURES`. They are read-only and can't be rebound:

```gdscript
const GESTURES := [
	{ "context": "arranger", "mods": "Shift", "input": "wheel", "label": "zoom horizontally" },
	{ "context": "arranger", "mods": "Ctrl",  "input": "wheel", "label": "track height" },
	{ "context": "arranger", "mods": "Alt",   "input": "wheel", "label": "scroll horizontally" },
	{ "context": "arranger", "mods": "",      "input": "middle_drag", "label": "pan" },
	{ "context": "clip_drag", "mods": "Shift", "input": "", "label": "move freely (no snap)" },
	# …
]
```

`input` is one of `click`, `double_click`, `right_click`, `drag`, `right_drag`, `middle_drag`, `wheel`, or `""` (a modifier held during a state). Fill the table by reading each source listed under "Mouse gestures" in the table at the top. Copy the real behavior and don't guess. Where the code and a label disagree, the code wins. Add a test that every gesture's context or state exists.

**`Godot/editor/HelpBar.gd`** attaches to the existing `InfoText` RichTextLabel (or to `InfoBox`, replacing `InfoText`'s placeholder text with `""` in the `.tscn`).
- It listens to `Hotkeys.help_context_changed` and `Hotkeys.bindings_changed`, and to `Settings.setting_changed` for its own visibility setting.
- It gathers entries for the current context's chain, most specific first: actions whose context is in the chain and that have `help != false` and at least one binding, plus gestures for the chain.
  - **No modifier held:** show entries that need no modifier, plus one hint per modifier that unlocks entries ("Shift …", "Ctrl …").
  - **Modifier(s) held:** show only the entries whose modifier set equals the held mask. This works like Blender's status bar, and is what makes "Ctrl to zoom"-style hints useful.
- Sort by `priority`, then specificity (deepest context first), then table order.
- Render each entry as key chips plus a label: `[color=gold]Ctrl[/color]+[color=gold]Wheel[/color] track height`, with two spaces between entries. Read the chip colour from one constant or theme colour, not a literal in every string. Double-tap actions are normal entries. They render as the parent's chord followed by a dim `×2` (`[color=gold]Ctrl[/color]+[color=gold]A[/color] ×2 all tracks`), and they're filtered by modifier like their parent. Use `KeyChord.display` for keys and fixed words for mouse inputs (`Click`, `Drag`, `Wheel`, `Middle-drag`, …).
- Fit to width: measure each entry with the label's font (`get_theme_font("normal_font").get_string_size(...)`), add entries until the next one would overflow, and end with a dim `…` when some were dropped. Re-fit on `resized`. Don't wrap; the bar is one line.
- **Transient hint.** `HelpBar.show_hint(text: String, owner: Object)` / `clear_hint(owner)` lets a control show a one-off line, such as "Drop to add sampler zone". It overrides the computed text while it's set. Reach it through `Hotkeys.show_hint` so components don't need an Editor reference, and have HelpBar connect to it.
- Text is rebuilt only when the inputs change, never per frame.

**Setting.** Register `appearance/show_help_bar` (BOOL, default true, sub-category "Editor") and hide `InfoBox` when it is off.

**Tests** (`test_help_bar.gd`): feed contexts and modifier masks directly into the HelpBar's build function, kept pure so it takes context, mods and width and returns bbcode. Assert three things:
- In arranger with no mods, it lists Space play/stop and shows "Shift …".
- With Shift held, it lists "zoom horizontally" and not "track height".
- After rebinding `transport_play_toggle` to `P`, the text shows `P` (this goes through `bindings_changed`).
- With Ctrl held in the arranger, the text lists `Ctrl+A ×2`. After rebinding `edit_select_all`, the double-tap entry shows the new chord.

Also test that a narrow width truncates with `…` and never splits an entry.

## Phase 2c: Wire contexts into the editors

1. Call `Hotkeys.set_context` in each panel's `_ready`: `Arranger` (timeline area) → `arranger`, `ClipEditor`/`MidiEditor` → `clip_editor`, `Mixer` → `mixer`, the device panel/lane container → `device_panel`, `MultisampleEditor` → `sampler_zones`, `LayerMappingWindow` root → `layer_mapping`.
2. Add `begin_state`/`end_state` around the existing gestures: clip move/resize/loop-drag in `TimelineClip.gd`, box selection in `Timeline.gd` and `MidiEditor.gd`, note drag and resize in `NoteEditor.gd`, and value-lane draw in `ValueLaneStemArea.gd`. Put `end_state` on every exit path that resets the existing interaction mode, including the right-release "safety handler" in `MidiEditor._unhandled_input`.
3. Generic controls declare their own context so hovering one explains it: `RotaryKnob`/sliders → `control_knob` with gestures such as "Drag change", "Shift+Drag fine", "Double-click reset" (copy the real modifiers from the component code and `godot-ui-components.md`), and `ModAssign` targets. Add these contexts under `global` in `CONTEXTS`.
4. Computer keyboard: while it's enabled, `computer_keyboard` is added as an extra context in every chain (the bar shows "Z/X octave, C/V velocity"). Expose `MidiManager.virtual_keyboard_enabled` changes through a signal if one doesn't exist.
5. Update `docs/subsystems/godot-ui-components.md` (short HelpBar section: `set_context`, states, `show_hint`) and `godot-architecture.md` (the `Hotkeys` autoload in the autoload list). Update the AGENTS.md autoload list too.

**Manual check (ask the user).** Hover the arranger, clip editor, mixer and a knob. Hold Shift/Ctrl/Alt in each. Drag a clip and hold Shift mid-drag. Rebind Play in Settings and confirm the bar updates without a restart.

## Out of scope

- Rebinding mouse gestures and modifiers.
- Chord sequences (Emacs-style multi-key bindings) and per-project bindings.
- Moving handler dispatch onto the Phase 2 context resolver, which would unify the hover gating that is now duplicated in each panel. It's worth doing later, once contexts exist everywhere.
- Shortcut display in context menus. No menu sets accelerators today. When one does, it should read `Hotkeys.get_display(id)`.

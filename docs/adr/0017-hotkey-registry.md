# 0017 — Hotkey registry

Status: accepted.

## Context

App shortcuts were spread over `project.godot` actions, Godot's built-in `ui_*` actions and
hardcoded `KEY_*` checks in each panel. Nothing could be rebound, two handlers worked around
Space vs Shift+Space and D vs Ctrl+D by hand, and the planned help bar would have had no single
place to read keys from.

## Decision

- **One table in code.** `HotkeyActions.ACTIONS` holds every rebindable action with its label,
  group, context and default chords. `project.godot` keeps no app actions. `Settings` registers
  one `shortcuts/<id>` setting per action, so Settings stays the only owner of defaults and every
  binding change goes through `Settings.set_value`. The `Hotkeys` autoload mirrors the stored
  chords into `InputMap`.
- **No `ui_*` actions for app commands.** `ui_copy`, `ui_paste`, `ui_left` and the others also
  drive `LineEdit`/`TextEdit`. Rebinding Copy would change text fields too. Sonara uses its own
  `edit_*` actions and leaves `ui_*` alone.
- **Exact matching.** Registry actions match with `exact_match = true`, so extra modifiers never
  trigger an action and the manual modifier checks are gone.
- **Contexts form a tree** rooted at `global`. Two actions conflict only when they share a chord
  and one context is the other or an ancestor of it. Conflicts are shown in Settings but never
  block saving.
- **Double taps are actions that reuse their parent's key** (`double_tap_of`). They store no chord
  and follow the parent's binding. The first tap always runs the parent, so a double tap may only
  extend the first tap's result (select all in a track, then all tracks).
- **Physical vs logical keys per action.** The computer-keyboard note keys are `physical` (a
  piano layout on any keyboard layout). Everything else binds the logical key.
- **Scope.** Mouse gestures are not rebindable. Dialog-local keys (Escape, Enter) stay hardcoded.
  Handlers keep their existing gating; only the matching moved to the registry.
- **Capture.** Settings key capture sets `Hotkeys.capturing` so the chord being bound doesn't run
  its action. Escape cancels a capture and can't be bound.

## Consequences

- Adding a shortcut is one table row plus a `Hotkeys.pressed` call.
- The help bar (phase 2) reads labels, contexts and live bindings from the same registry.
- A binding with no handler must not be registered, because it would show up in Settings.

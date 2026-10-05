# 020 — Drum Machine pads: implementation plan

Status: draft 2026-10-05, awaiting approval of the decisions below. This is a single phased
plan, following the format of 011–013.

Goal: make the Drum Machine panel a place where you can mix and arrange a kit. That means a pad
context menu with **per-pad choke targets**, a **channel strip** for the selected pad (a mini UI
for its return channel), **pads that look like the rest of the app**, and **multi-pad select
and move**. It also fixes the bug that currently stops pads from moving at all.

Inputs:
- `Godot/devices/builtin/DrumMachineDefaultView.gd/.tscn`: the 4×4 paged grid, one open slot
  at a time (`open_slot_keys()`), which pads use as their "selected" pad.
- `Godot/devices/container/DrumPad.gd`: pad chrome, click-to-play, drag, drops, right-click
  (`context_requested`, which today opens the generic `DeviceContextMenu`).
- `Engine/src/audio/devices/drum_machine.rs`: `DrumSlot { device, note, choke_group }`. It
  routes by note and mixes slots in parallel. On a root chain, each slot writes its own extra
  output bus, which feeds the pad's return channel (`AuxReturnSync`).
- `DeviceInstance` already carries `slot_volume` / `slot_mute` / `slot_solo` and
  `_send_layer_slot()` for Layer, plus `choke_group`, `set_choke_group()`, `set_slot_color()`
  and the stable child `id` that projects persist.
- ADR 0012 (choke groups), `docs/subsystems/osc-protocol.md` (Drum Machine and Layer
  sections), `components/meter/Meter.gd` (stereo meter with built-in fader, `volume_changed`),
  `mixer/PanControl.gd`, and the `ContextMenu` / `ContextMenuList` theme type variations
  (`DeviceContextMenu.tscn`, `ChannelContextMenu.tscn`).

## Decisions (need approval)

1. **Choke targets replace choke groups. This contradicts ADR 0012.** A group is symmetric:
   everyone in it chokes everyone else. Targets are directed: pad A can choke B without B
   choking A. Directed targets can express every group, so we replace groups instead of
   keeping two systems. A new **ADR 0015** supersedes 0012. It keeps 0012's `choke(frame_offset)`
   seam and the 3 ms `DrumHost` fade unchanged; only the relationship model changes.
2. **"Choked by" is derived, not stored.** Each pad stores only its targets. "Choked by" on
   pad P lists every pad whose targets include P. Ticking "choked by X" on P adds P to X's
   targets. This keeps one source of truth.
3. **Godot stores targets by child `id`. The engine receives them as a 128-bit note mask.**
   Ids survive pad moves, reorders and save/load. Notes are what the engine routes on, and a
   fixed `u128` is real-time safe, needs no allocation, and does not care about slot index
   changes. Whenever any pad's note changes, Godot re-sends every pad's mask.
4. **Old projects migrate on load.** A non-zero `choke_group` expands into mutual targets
   among the pads in that group, then the field is dropped. `DrumKit` (hats in group 1) is
   rewritten to use targets.
5. **The strip is a mini UI for the pad's return channel.** On a root-chain Drum Machine every
   pad already feeds its own return (child) channel (`AuxReturnSync`, spec 001), and that channel
   has volume, pan, mute, solo and meters. The strip binds to that `Channel` and calls its
   setters, the way a `MixerChannel` does. There is no per-pad mix inside the Drum Machine and no
   new OSC. Editing the strip and editing the pad's channel in the mixer are the same edit.
6. **Pan uses `PanControl`**, the mixer's pan strip, so all four pan modes and their undo work
   unchanged. The meter already carries the fader.
7. **The strip follows the primary pad**: the one whose slot is open (the last pad clicked
   without a modifier, or the last pad ctrl-clicked into the selection). For an empty pad, or a
   Drum Machine nested in another device (which has no pad returns), the strip shows but is
   disabled.
8. **Moving several pads keeps their spacing**: every selected pad shifts by the same number of
   notes. If any destination is off the 0–127 range, or holds a pad that is not part of the
   move, the drop is refused. There is no partial move and no multi-swap. Dropping one pad onto
   another still swaps them, as it does today.
9. **The pad menu also keeps Remove pad** at the bottom, below a separator. The brief lists
   only color, name and the choke menus, but replacing `DeviceContextMenu` would otherwise lose
   Remove. Drop it if that is not wanted.

---

## Phase 0: fix moving pads (Godot)

Symptom (`Godot/logs/last.log`): moving a pad sends `/slot/{n}/note`, then
`DevicePanel.gd:809 @ _update_view_pane_visibility` fails with "Invalid access to property or
key 'visible' on a base object of type 'Nil'". The failing expression is
`view_button.visible`: an `@onready` var that is still null.

Likely cause: open-slot keys are note-based (`pad_slot_key(note)`). Moving a pad changes its
note, so the open slot key changes and the device lane rebuilds its panels. A `DevicePanel`
coroutine (`bind_to_device` → `await _load_panel_view`, or `_show_panel_view` →
`await _panel_view.ready`) then resumes on a panel that is no longer the live one, or that was
never entered into the tree.

Tasks:
- Reproduce headless. Bind a Drum Machine with two pads, open one, and call
  `DeviceDropUtil.drop_on_drum_pad` to move it onto an empty note. Add logging around the panel
  rebuild and the awaits in `DevicePanel` to confirm which coroutine resumes on which instance.
- Fix the root cause, not only the symptom:
  - `set_slot_note` must carry the open-slot and slot-color entries across the key change (the
    same re-keying `_migrate_slots_to_chains` already does), so moving a pad does not close and
    reopen its slot.
  - `DevicePanel` coroutines must bail out after each `await` when the panel was unbound or
    rebound in the meantime (`device != dev`) or is not inside the tree.
- Test: `Godot/tests/test_drum_pad_move.gd`. Move a pad onto an empty note and swap two pads,
  each with its slot open. Assert no script errors, the moved pad is still the open slot, and
  its color follows it.

Done when: pads move and swap from the UI with no error, and the open slot follows the pad.

---

## Phase 1: pad look (Godot)

- In `DrumPad._make_style`, use a dark gray fill, corner radius 2 (down from 4), and a 1 px
  light gray border.
- States:
  - Idle (empty): darkest gray.
  - Filled: slightly lighter gray. The name label carries the content, so the fill no longer
    turns blue.
  - Selected: same fill, with a white (or light) border. Reuse the border color `DevicePanel`
    uses for its selection, so selection looks the same across the app.
  - Hit (sounding): brighter fill flash, border unchanged.
- Take the colors from theme constants or colors where the theme has them (check `DevicePanel`
  and `MixerChannel` for the selected-border color), instead of new literals.
- Pad slot color (`set_slot_color`), set from the Phase 4 menu: draw it as a thin strip along
  the pad's top edge, so it never fights the selection border.
- Update the drag preview to the same style.

Done when: a screenshot of the panel next to a selected `DevicePanel` looks like one design.

---

## Phase 2: multi-select and group move (Godot)

Selection lives in `DrumMachineDefaultView` (view state, not persisted):
`_selected_notes: Array[int]` plus `_primary_note`.

- Click: selects only that pad and opens its slot (today's behavior).
- Ctrl-click: toggles the pad in or out of the selection. A pad added this way becomes primary
  and its slot opens.
- Shift-click: selects the range of notes from the primary pad to the clicked pad, so a range
  can span pages.
- Clicking a pad still plays it whatever the modifiers. `DrumPad` passes the modifier state
  with its `activated(note, modifiers)` signal; the view decides what it means.
- `DrumPad.set_selected(on, primary)`: every selected pad gets the light border, and the
  primary pad gets the white one.
- Paging keeps the selection. Removing a pad drops it from the selection.

Group move:
- `DrumPad._get_drag_data`: when the dragged pad is in the selection, build the `DeviceDrag`
  with `devices` = every selected child. `DeviceDrag` already supports a co-selected list.
- `DeviceDropUtil.drop_on_drum_pad`: when the drag carries more than one device and they all
  come from this Drum Machine, compute `delta = target_note - dragged.slot_note` and apply
  decision 8. Run it as one undo step:
  `HistoryUtil.execute_many("Move Drum Pads", [...set_slot_note commands])`. Apply the moves in
  an order that never puts two children on the same note at once (or give every moved child a
  temporary free note first), because the engine rejects duplicate notes.
- `_can_drop_data` must show the refusal while hovering, using the same validity check as the
  drop, so the drop is never silently refused.
- After the move, the selection follows the moved pads.

Tests: `test_drum_pad_select.gd` covers click, ctrl and shift selection across pages.
`test_drum_pad_move.gd` (from Phase 0) gains group move, an out-of-range refusal, a refusal on
collision with an unselected pad, and a single undo restoring every note.

Done when: you can select 3 pads, drag them up a row, and undo the move in one step.

---

## Phase 3: choke targets (engine + Godot model)

### Engine (`drum_machine.rs`)
- `DrumSlot.choke_group: u8` → `choke_targets: u128`, where bit *k* means "a note-on here
  chokes the slot on note *k*".
- In `send_note_event`, on a note-on, scan the slots and call `choke(frame_offset)` on every
  slot `i != index` whose note bit is set in the triggering slot's mask. It is the same
  fixed-cost scan as today, with no allocation.
- `set_slot_choke_targets(index, mask) -> bool` replaces `set_slot_choke_group`.
- `AudioCommand::SetDrumSlotChoke { group }` → `SetDrumSlotChokeTargets { mask: u128 }`, wired
  through `command_worker.rs`.
- OSC: `/channel/{id}/device/{path}/slot/{n}/choke_targets <b:16 bytes>`, a little-endian
  `u128` (notes 0–127). Any other length is logged and ignored, like `note_map`. Remove the
  `/slot/{n}/choke` handler.
- Tests (replace the two group tests):
  - A chokes B but not C, at the triggering frame offset.
  - The relation is directed: B's note-on does not choke A unless B targets A.
  - A slot's own bit is ignored.
  - A note-off never chokes.
  - Masks keep working after `move_child` reorders the slots (they are note-based).

### Godot model (`DeviceInstance.gd`)
- `choke_group` / `set_choke_group` / `choke_group_changed` →
  `choke_targets: PackedStringArray` (child ids),
  `set_choke_targets(ids)`, `toggle_choke_target(id, on)` and `choke_targets_changed`.
- Container helpers:
  - `choked_by(child) -> Array[DeviceInstance]`, which derives decision 2.
  - `choke_mask_for(child) -> PackedByteArray`, which turns ids into notes and notes into 16
    bytes.
  - `resend_choke_masks()`, which sends every pad's mask.
- Re-send triggers: a pad's targets change, any pad's `slot_note` changes (that includes Phase
  2 moves and swaps), a child is added or removed (removal also prunes its id from every
  pad's targets), and `sync_to_engine()` / reload (replacing the current per-pad `choke`
  re-send at `DeviceInstance.gd:1834`).
- Undo: target edits go through `HistoryUtil.execute_property` (or a small command that
  stores the before and after id arrays).
- Serialization: `"choke_targets"` replaces `"choke_group"` in `to_dict` and `from_dict`, the
  `DevicePreset` copied-field list, and preset drops.
- Migration (decision 4): in `from_dict` for a Drum Machine, after loading its children, if
  any child has a legacy `choke_group > 0`, give each pad in the group every other member of
  that group as a target.
- `DrumKit.gd`: the hat entries get `"choke": ["Open Hat"]` / `["Closed Hat"]` (resolved to ids
  after the pads are created) in place of `choke_group: 1`.
- DAWproject: `DawProjectExporter` counts pads with non-empty targets.
  `TransferReport.DRUM_CHOKE_GROUP` is renamed `DRUM_CHOKE` and its text updated. Round-trip
  through Sonara's own `State` JSON.

### Tests
- Rewrite `test_drum_choke.gd` for targets: set and toggle, derived choked-by, mask bytes,
  re-send after a pad move, pruning when a pad is removed, undo.
- Add a migration case: a legacy project with group 1 on two pads loads as mutual targets.
- Update `test_drum_kit.gd`, `test_dawproject_roundtrip.gd`, `test_device_presets.gd` and
  `test_preset_load.gd` wherever they assert `choke_group`.

### Docs
- ADR 0015 "Drum Machine choke targets" supersedes 0012. Mark 0012's status as superseded.
- `osc-protocol.md`: Drum Machine section and address table.
- `CONTEXT.md`: replace "choke group" with "choke target" / "choked by".

Done when: closed and open hats choke each other in the Synth Kit, an old project with groups
loads with the same behavior, and `cargo test drum_machine` plus the Godot choke tests pass.

---

## Phase 4: pad context menu (Godot)

New `Godot/devices/container/DrumPadContextMenu.tscn/.gd`, a `PopupPanel` with
`theme_type_variation = &"ContextMenu"`, laid out like `DeviceContextMenu`:

1. **Name**: a `SmartLineEdit` that renames the pad (the pad's slot chain, the same call
   `DeviceContextMenu._on_label_changed` makes).
2. **Color**: colorpicker button like our other context menus.
3. **Choke targets ▸**: a submenu, `PopupMenu` with `ContextMenuList` and
   `hide_on_checkable_item_selection = false`. It has one check item per *other occupied* pad,
   labeled "C1 · Kick" and ordered by note. Toggling one calls
   `pad.toggle_choke_target(other.id, on)`.
4. **Choked by ▸**: the same list, checked from `container.choked_by(pad)`. Toggling item X
   calls `X.toggle_choke_target(pad.id, on)`.
5. Separator, then **Remove pad** (decision 9), the same behavior as
   `DeviceContextMenu.removes_drum_pad`.

Wiring:
- `DrumMachineDefaultView._on_pad_context` opens this menu at the mouse position, and no longer
  emits `child_context_menu_requested`.
- Right-click on a pad outside the selection selects it first. With several pads selected, the
  choke submenus act on the primary pad only; say so in the menu header ("C1 · Kick").
- Remove the `choke_group` `OptionButton` from `DeviceContextMenu`. "Load kit" stays where it
  is (the Drum Machine's own menu).
- Pad tooltip (`_pad_tooltip`): "Chokes: Open Hat" / "Choked by: Closed Hat" in place of the
  group line.

Test: `test_drum_pad_menu.gd` checks that the menu lists only the other occupied pads, that a
targets toggle and a choked-by toggle each write to the right pad, and that rename and color
reach the model.

Done when: you can set up a hat pair from the menu alone, and the tooltip shows it.

---

## Phase 5: selected pad channel strip (Godot)

There is no engine work. The strip edits the pad's return channel (decision 5). An earlier draft
added per-slot volume, pan, mute, solo and a `pad_meter` stream to `drum_machine.rs`, which would
have duplicated the return channel.

UI: new `Godot/devices/container/DrumPadStrip.tscn/.gd`, a narrow `VBoxContainer` placed to the
right of `Grid` in `DrumMachineDefaultView.tscn` (the grid and the strip sit in an
`HBoxContainer`, and the view's minimum width grows by the strip's width). From top to bottom:
1. **Pan**: `PanControl` (`bind_to_channel`), with its mode menu and undo.
2. **Stereo meter with fader**: the `Meter` component.
   - `volume_changed` → `channel.set_volume()`, recorded with
     `HistoryUtil.record_property` and `last_edit_kind` as in `MixerChannel._on_volume_changed`,
     so one fader drag is one undo step. Ctrl-click resets to `channel.get_default_volume()`.
   - `channel.peak_updated` feeds `set_peak_levels` / `set_rms_levels`. Channel meters already
     arrive for every channel, so no stream subscription is needed.
3. **Solo** and **Mute**: toggle buttons styled like `MixerChannel`'s, through
   `HistoryUtil.execute_property` (mixer solo semantics: soloing a pad solos its return channel).

Behavior:
- Binds to the primary pad's return channel (`pad.return_channel_id`). It rebinds when the
  selection changes or a pad moves. The lookup is deferred, because a new pad's return is created
  after `child_added` fires. It updates from the channel's signals.
- When there is no pad, the pad is empty, or the pad has no return channel, the controls are
  disabled and the meter shows 0.
- With several pads selected, the controls edit the primary pad only. A multi-pad edit is out of
  scope here.

Test: `test_drum_pad_strip.gd` checks that the strip binds to the primary pad's return channel
and follows selection changes, and that the fader, pan, solo and mute reach that channel with
undo. It also checks that the strip is disabled for an empty pad and that it unbinds on unbind.

Done when: playing a kit shows the selected pad's meter moving, and solo, mute, fader and pan
change the same channel the mixer shows for that pad.

---

## Wrap-up

- Live pass: build the Synth Kit, then set up choke targets from the menu, move a row of pads,
  and mix one pad from the strip. Check that save, reload and undo restore everything.
- `docs/subsystems/godot-device-views.md`: a Drum Machine section covering the selection
  model, the strip and the pad menu.
- `TODO.md`: mark items `[x?]` per phase as they are implemented.
- Run `Godot/tests/run_all.sh` and `cargo test`.

Suggested order: Phase 0 → 1 → 2 can ship on their own (Godot only). Phase 3 → 4 is the choke
feature. Phase 5 is the strip (Godot only).

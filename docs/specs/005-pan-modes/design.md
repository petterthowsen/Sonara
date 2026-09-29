# Pan Modes — Design

Implements [requirements.md](./requirements.md).

## Context

- `Engine/src/audio/types.rs`
  - `PanMode`: the 0–3 enum, with `From<i32>` and `Default` currently set to `StereoCombined`.
  - `Channel`: fields `pan`, `pan_left`, `pan_right`, `pan_mode`, `automation_pan`.
  - `Channel::effective_pan()`: the automation override if set, otherwise `pan`.
  - `Channel::get_pan_coefficients()`: builds the 2×2 `PanCoefficients` matrix per mode.
- `Engine/src/audio/mixing.rs`: the audio callback uses the pan matrix in three places. The
  fader pass inside `mix_and_output` calls `get_pan_coefficients()` once per channel per buffer.
  `apply_pan()` handles route targets, and `route_channel()` reads it too. None of these change,
  because only the matrix is different.
- `Engine/src/audio/commands.rs`
  - `AudioCommand::SetChannelPan { id, pan_left, pan_right: Option<f32> }`. One value sets
    `pan` and two set the Dual handles.
  - `SetChannelPanMode { id, mode: i32 }`.
  - Both are applied on the command thread under the state lock by plain field writes.
- `Engine/src/osc/server.rs`: the handlers for `["channel", id, "pan"]` and
  `["channel", id, "pan_mode"]`.
- `Engine/src/audio/automation.rs`: `AutomationTarget::ChannelPan` writes
  `channel.automation_pan`. The test `automation_overrides_base_but_preserves_it` uses
  `PanMode::StereoCombined` and asserts that `right_to_right` rises under an override. The new
  Combined math breaks that assertion.
- `Godot/data/Channel.gd`
  - `PanMode`: same order as the engine.
  - Setters: `set_pan_mode()` (hard-resets the Dual handles to −1/+1) and `set_pan(pan_l, pan_r)`,
    which ignores Balance and Mono.
  - Signals: `pan_changed(pan_left, pan_right)` and `pan_mode_changed`.
  - `sync_to_engine()`.
  - Persistence: `to_json()` writes `pan_mode` as the enum key name, `JSON_FIELDS` includes
    `pan`/`pan_left`/`pan_right`, and `from_json()` reads them.
- `Godot/data/JsonFields.gd`: `write()` emits every listed key, so a newly saved project always
  has every field in `JSON_FIELDS`.
- `Godot/mixer/PanControl.gd`: the mixer pan strip. It holds `_combined_slider: HorSlider`,
  `_dual_slider: HDualSlider`, a `PanModePopup` defined in `Godot/mixer/MixerChannel.tscn` with
  two items, and a value label. Undo is `PropertyCommand` on `set_pan` with `set_unpack_array`
  and `set_mergeable`.
- `Godot/components/HDualSlider.gd`: two values (`a_value`, `b_value`). On click it picks the
  nearest handle (`DragMode.A_VALUE`/`B_VALUE`), uses `FineDrag` for Shift, and draws
  `alt_fill_color` when the handles cross.
- `Godot/history/commands/PropertyCommand.gd` and `Godot/history/HistoryUtil.gd`:
  `execute`/`execute_many` apply and push a command, and `record` pushes one that was already
  applied. Mergeable commands keep the first old value.
- `Godot/data/AutomationTarget.gd`: `current_normalized_value()` seeds a pan lane from
  `channel.pan`. That stays correct, because `pan` is the position in every single-position mode.
- AI:
  - `Godot/ai/tools/SetMixerTool.gd`: `set_mixer`.
  - `Godot/ai/tools/AiTool.gd`: `compact_channel()` is used by `list_channels`.
  - `Godot/ai/prompt/PromptContext.gd`: the mixer table.
  - `Godot/ai/chat/SelectionContext.gd`: the channel description line.
- Docs: `docs/subsystems/osc-protocol.md` covers `/channel/{id}/pan` and `/pan_mode`, and
  `CONTEXT.md` has the fader/pan glossary entry. ADR 0010 (automation overrides base values)
  and ADR 0006 (self-synchronizing models) both still hold. Nothing here contradicts them.

## Approach

**Engine.** Keep the `PanMode` numbers stable, change `Default` to `StereoBalance`, and add
`Channel::pan_width: f32`, which defaults to 1.0. `get_pan_coefficients()` gets one private
helper, `dual_matrix(l, r)`, which is today's Dual formula. Dual calls it with
`pan_left`/`pan_right`. Combined calls it with `clamp(pos − width)` and `clamp(pos + width)`,
where `pos = effective_pan()`, so pan automation drives the Combined position for free
(REQ-012). Mono halves today's coefficients to make the sum (L+R)/2. Balance is unchanged. A
new OSC message, `/channel/{id}/pan_width f:width`, becomes
`AudioCommand::SetChannelPanWidth`.

*Rejected:* putting width in as a third argument of `/channel/{id}/pan`. The message already
changes meaning with its argument count (one value means position, two mean Dual handles), and
a third variant would make it three messages in one.

**Godot model.** A channel's whole pan setup becomes one value object, a "pan state"
Dictionary: `{mode, pan, width, left, right}`.
- Getting and setting: `get_pan_state()` returns it and `set_pan_state(state)` applies it.
  Undo for any pan change is a `PropertyCommand` on `set_pan_state` with old and new snapshots,
  which covers mode switches too. That gives an exact restore (REQ-008) without a separate
  command for each field.
- Mode conversion: a static `Channel.convert_pan_state(state, mode)` implements REQ-007, so the
  mixer and the AI tool compute the new state the same way before applying it.
- Per-value setters: `set_pan(position)`, `set_pan_width(w)` and `set_pan_dual(l, r)` replace
  today's two-argument `set_pan`.
- Engine sync: the engine keeps every pan field whatever the mode. So each setter sends only
  what it changed, and `sync_to_engine()` sends everything: mode, position, width and handles.
  The mode logic in `set_pan` goes away.

**Mixer UI.** `HDualSlider` gets a third drag mode, `BOTH`:
- **Starting a drag:** a click on the fill between the handles, farther than the grab radius
  from either handle, drags both. So does a click on handles that overlap (both within the grab
  radius), unless Alt is held. Alt picks the handle on the side the mouse moves toward.
- **Drag output:** in `BOTH` the slider emits `pair_dragged(delta)`, the unclamped value offset
  from where the drag began. It also moves `a`/`b` by that delta, each clamped, and emits
  `values_changed`. A single-handle drag emits `handle_dragged(which, value)` alongside the
  existing signals.

`PanControl` uses the dual slider for both Dual and Combined:
- **Dual:** `values_changed` maps to `set_pan_dual`.
- **Combined:** the control computes from the model, not from the clamped handles. A pair drag
  sets position = start position + delta. A handle drag sets width = `b − position` (or
  `position − a`). The slider is then redrawn from the model's clamped handles. This keeps the
  position free while a handle sits pinned at an edge.

*Rejected:* making the slider mirror the handles itself. The slider only sees the clamped
values, so the width would drift whenever a handle hits an edge.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `Channel::pan_width` (new `f32`) | command thread writes it (`SetChannelPanWidth`) under the state lock | audio callback reads it in `get_pan_coefficients()` under its existing `try_lock` | yes: a plain field, no allocation |
| `Channel::pan_mode` default | set in `Channel::new` | same as today | yes |

The matrix is still computed once per channel per buffer at the same call sites. It uses a few
more `sin`/`cos` calls in Combined, the same count as Dual.

## Data and protocol changes

**OSC**
- **New:** `/channel/{id}/pan_width f:width`, from Godot to the engine. The width is −1.0..1.0,
  clamped in the command handler. It's applied as `AudioCommand::SetChannelPanWidth { id, width }`.
- **Changed meaning:** `/channel/{id}/pan_mode i:mode`. The numbers stay the same, but 0 is now
  the Cubase-style Combined panner and the default becomes 2 (Balance).
- **Unchanged:** `/channel/{id}/pan`. One value is the position (Balance, Combined, Mono) and
  two are the Dual handles.

**Godot model (`Channel.gd`)**
- New field `pan_width: float = 1.0`. The default `pan_mode` becomes `PanMode.STEREO_BALANCE`.
- `pan_changed` keeps its signature. Listeners read the model, and both existing listeners
  already ignore the arguments. `pan_mode_changed` is unchanged.
- New: `get_pan_state()`, `set_pan_state(state)`, `static convert_pan_state(state, mode)`,
  `set_pan(position)`, `set_pan_width(w)`, `set_pan_dual(l, r)`.
- `set_pan_mode(mode)` becomes `set_pan_state(convert_pan_state(get_pan_state(), mode))`.

**Persisted (`.sonara`)**
- `pan_width` is added to `JSON_FIELDS`.
- Migration in `from_json()`: if `pan_mode == "STEREO_COMBINED"` and the dictionary has no
  `pan_width` key, the channel loads as `STEREO_BALANCE`. Only projects saved before this
  change lack the key, because `JsonFields.write` always writes it.

## File-by-file change list

| File | Change |
|---|---|
| `Engine/src/audio/types.rs` | `PanMode::default()` becomes `StereoBalance`. Doc comments on each variant. Add the `pan_width` field (init 1.0). Add `dual_matrix()`. New Combined and Mono arms in `get_pan_coefficients()`. Unit tests in a `mod tests` block for REQ-002/003/004/005/012 |
| `Engine/src/audio/commands.rs` | `AudioCommand::SetChannelPanWidth { id, width }` plus its handler (clamped to −1..1) |
| `Engine/src/osc/server.rs` | `["channel", id_str, "pan_width"]` handler |
| `Engine/src/audio/automation.rs` | `automation_overrides_base_but_preserves_it`: switch to `StereoBalance` and assert `left_to_left` drops under the override |
| `Godot/data/Channel.gd` | New field, default mode, the pan-state API and per-value setters from above. `sync_to_engine()` sends all pan values. `JSON_FIELDS` gains `pan_width`. Migration in `from_json()` |
| `Godot/components/HDualSlider.gd` | `DragMode.BOTH`, grab radius, the overlap and Alt rule, `pair_dragged(delta)` and `handle_dragged(which, value)` signals |
| `Godot/mixer/PanControl.gd` | Per-mode slider visibility and wiring as described above. Mode menu with four items. Undo through `PropertyCommand` on `set_pan_state` (mergeable for drags, plain `HistoryUtil.execute` for mode changes). Value label formats `30R`, `L 100L / R 20R`, `C, W 60%` |
| `Godot/mixer/MixerChannel.tscn` | `PanModePopup`: four items with ids equal to the `PanMode` values (Stereo Balance, Stereo Combined, Stereo Dual, Mono) |
| `Godot/ai/tools/AiTool.gd` | `compact_channel()` reports `pan_mode` plus that mode's values. Add a static `describe_pan(c)` for one-line text such as `balance 0.30`, `combined 0.00 w1.00`, `dual L-1.00 R0.20` |
| `Godot/ai/prompt/PromptContext.gd` | The mixer table's pan column uses `AiTool.describe_pan()` |
| `Godot/ai/chat/SelectionContext.gd` | The channel description uses `AiTool.describe_pan()` |
| `Godot/ai/tools/SetMixerTool.gd` | New parameters: `pan_mode` (`balance`/`combined`/`dual`/`mono`), `pan`, `pan_width`, `pan_left`, `pan_right`. Build the new state with `convert_pan_state` and overlay the values. Refuse values that don't fit the mode. One `PropertyCommand` on `set_pan_state` inside the existing `execute_many` |
| `docs/subsystems/osc-protocol.md` | `/pan_width` row. Rewrite the `/pan_mode` row with the new meanings and default |
| `CONTEXT.md` | Glossary entries for the pan modes, position and width |
| `TODO.md` | Backlog entry pointing to this spec |

## Migration and compatibility

- **Old "Stereo Combined" (the only mode the old UI saved besides Dual):** loads as Balance
  with the same `pan`. Centered stereo channels get 3 dB louder, which is the fix we want.
- **Old Dual:** loads unchanged. The Dual math and fields are the same.
- **Old projects with a stray Balance or Mono:** these keep their mode. The old UI couldn't set
  them, so they don't occur in practice.
- **Engine↔Godot skew:** they ship together. An old engine ignores `/pan_width`, and a new engine
  talking to an old Godot gets mode 0 for "combined" at the default width of 1.0. That sounds like
  unity balance at center.

## Test plan

- **Unit (engine):** `cargo test pan_`, in a new `mod tests` block in `Engine/src/audio/types.rs`.
  - `pan_balance_coefficients`: REQ-002 examples.
  - `pan_combined_coefficients`: REQ-003 examples, including the negative-width swap and the
    clamped handle.
  - `pan_dual_coefficients_unchanged`: REQ-004, compared against the formula.
  - `pan_mono_sums_half`: REQ-005 example.
  - `pan_combined_automation_moves_position`: REQ-012. Override at 1.0 with width 0.5 gives
    handles 0.5/1.0, and `pan_width` stays untouched.
  - `pan_mode_default_is_balance`: `Channel::new` defaults.
  - The updated `automation_overrides_base_but_preserves_it` stays green.
- **Godot:** `godot --headless --path Godot -s tests/test_channel_pan.gd -- --test` (new).
  - REQ-006: setters per mode change values and emit `pan_changed`.
  - REQ-007: every mode transition, including the Dual −1.0/+0.2 round trip.
  - REQ-008: `PropertyCommand` undo and redo of a mode change.
  - REQ-010: an old-format dictionary migrates to Balance, and an old Dual one stays Dual.
  - REQ-011: `to_json`/`from_json` round trip in all four modes.
- **Godot:** `godot --headless --path Godot -s tests/test_hdual_slider.gd -- --test` (new).
  Synthesized mouse events check that a fill-drag emits `pair_dragged` with an unclamped delta,
  a handle-drag emits `handle_dragged`, and an overlap drag goes to `BOTH` without Alt and to a
  handle with Alt.
- **Godot:** `godot --headless --path Godot -s ai/tests/test_set_mixer_pan.gd -- --test` (new).
  - REQ-013: `compact_channel` and `describe_pan` per mode.
  - REQ-014: set each mode and its values, undo, and refuse `pan_width` on a Balance channel
    with the channel unchanged.
- **Live (REQ-009, and REQ-001 in the UI):** with the engine and Godot running, cycle one channel
  through the four modes. Drag the fill and the handles in Combined and Dual, and Alt-drag
  overlapping handles. Listen for L/R placement on a stereo source, and check the
  `/channel/{id}/pan*` lines in `Engine/logs/last_info.log`. Load a project saved before the
  change: its "Stereo Combined" channels should show Balance.

## Risks

| Risk | Mitigation |
|---|---|
| Old projects get 3 dB louder at center and users hear a jump | This is intended (REQ-010). Say so in the commit message |
| `set_pan(l, r)` callers not updated after the signature change | Only `PanControl.gd` and `SetMixerTool.gd` call it (grep verified). Both are in the change list |
| Mergeable drag undo merges across a mode change | Mode changes use a non-mergeable command, and `PropertyCommand.can_merge` requires both commands to be mergeable |
| Hit-testing on a small strip makes the fill hard to grab | The grab radius scales with `handle_width`. Overlapped handles default to `BOTH`, so a drag always does something |

## Open questions

- none

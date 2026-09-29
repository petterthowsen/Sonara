# Pan Modes — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

## Phase 1 — Engine: pan math and width end to end

- [x?] **T-001** [REQ-001, REQ-002, REQ-003, REQ-004, REQ-005] Pan matrix per mode.
  - _Files_: `Engine/src/audio/types.rs`
  - _Output_:
    - `PanMode::default()` returns `StereoBalance`, and each variant has a doc comment.
    - `Channel::pan_width: f32` exists and `Channel::new` sets it to 1.0.
    - A private `dual_matrix(l, r)` helper exists.
    - The Combined arm uses clamped `pos ∓ width` handles, the Mono arm uses a (L+R)/2 sum, and
      Balance and Dual are unchanged.
  - _Verify_: `cargo test pan_` passes `pan_balance_coefficients`, `pan_combined_coefficients`,
    `pan_dual_coefficients_unchanged`, `pan_mono_sums_half` and `pan_mode_default_is_balance`
    (new `mod tests` in `types.rs`), with the REQ examples as asserts.
  - _Depends on_: —

- [x?] **T-002** [REQ-012] Automation drives the Combined position, and the existing test is updated.
  - _Files_: `Engine/src/audio/types.rs`, `Engine/src/audio/automation.rs`
  - _Output_:
    - `pan_combined_automation_moves_position` test: override 1.0 with width 0.5 gives handles
      0.5/1.0, and `pan_width` is untouched.
    - `automation_overrides_base_but_preserves_it` uses `StereoBalance` and asserts that
      `left_to_left` drops.
  - _Verify_: `cargo test automation` and `cargo test pan_` pass.
  - _Depends on_: T-001

- [x?] **T-003** [REQ-003, REQ-006] `/channel/{id}/pan_width` OSC message.
  - _Files_: `Engine/src/audio/commands.rs`, `Engine/src/osc/server.rs`
  - _Output_:
    - `AudioCommand::SetChannelPanWidth { id, width }`, applied with a clamp to −1..1.
    - A `["channel", id_str, "pan_width"]` handler in `server.rs`.
  - _Verify_: A new `mod tests` in `commands.rs` with `pan_width_command_clamps`, which calls
    `process_command` with `SetChannelPanWidth` at 3.0 and checks that 1.0 is stored.
    `cargo build --release`, `cargo test` and `cargo fmt --check` are all clean.
  - _Depends on_: T-001

## Phase 2 — Godot model

- [x?] **T-004** [REQ-001, REQ-006, REQ-007] Pan state API on `Channel`.
  - _Files_: `Godot/data/Channel.gd`
  - _Output_:
    - `pan_width = 1.0`, and `pan_mode` defaults to `STEREO_BALANCE`.
    - `get_pan_state()`, `set_pan_state(state)`, `static convert_pan_state(state, mode)`.
    - `set_pan(position)`, `set_pan_width(w)`, `set_pan_dual(l, r)`.
    - `set_pan_mode()` goes through `convert_pan_state`.
    - `sync_to_engine()` sends the mode, `/pan [pan]`, `/pan [l, r]` and `/pan_width [w]`.
  - _Verify_: `godot --headless --path Godot -s tests/test_channel_pan.gd -- --test` passes its
    setter and mode-transition cases, including the Dual −1.0/+0.2 → Combined −0.4/w0.6 → Dual
    round trip.
  - _Depends on_: T-003

- [x?] **T-005** [REQ-008] Undo through `set_pan_state` snapshots.
  - _Files_: `Godot/tests/test_channel_pan.gd`
  - _Output_: Test cases: a `PropertyCommand` on `set_pan_state` undoes and redoes a mode change
    exactly, and a mergeable drag command doesn't merge into a mode-change command.
  - _Verify_: the same test script passes the undo cases.
  - _Depends on_: T-004

- [x?] **T-006** [REQ-010, REQ-011] Persistence and migration.
  - _Files_: `Godot/data/Channel.gd`, `Godot/tests/test_channel_pan.gd`
  - _Output_:
    - `pan_width` is in `JSON_FIELDS`.
    - `from_json()` maps `STEREO_COMBINED` with no `pan_width` key to `STEREO_BALANCE`.
  - _Verify_: The test script passes the round trip in all four modes, the old Combined
    migration (`{"pan_mode": "STEREO_COMBINED", "pan": 0.3}` gives Balance at 0.3), and old Dual
    staying Dual.
  - _Depends on_: T-004

## Phase 3 — Mixer UI

- [x?] **T-007** [REQ-009] `HDualSlider` pair drag.
  - _Files_: `Godot/components/HDualSlider.gd`, `Godot/tests/test_hdual_slider.gd`
  - _Output_:
    - `DragMode.BOTH`, grab radius, and the overlap and Alt rule.
    - `pair_dragged(delta)` (unclamped) and `handle_dragged(which, value)` signals.
    - Existing single-handle behavior unchanged.
  - _Verify_: `godot --headless --path Godot -s tests/test_hdual_slider.gd -- --test`:
    - a fill drag emits `pair_dragged` with a delta past the edge while `a`/`b` clamp
    - a handle drag emits `handle_dragged`
    - an overlap drag goes to `BOTH`, and Alt picks a handle
  - _Depends on_: —

- [x?] **T-008** [REQ-001, REQ-008, REQ-009] `PanControl` for four modes.
  - _Files_: `Godot/mixer/PanControl.gd`, `Godot/mixer/MixerChannel.tscn`
  - _Output_:
    - `PanModePopup` has four items with ids equal to the `PanMode` values.
    - Balance and Mono use the single slider, and Dual and Combined use the dual slider.
    - Combined maps `pair_dragged` to position and `handle_dragged` to width, computed from the
      model.
    - A mode change is one non-mergeable `set_pan_state` command, and drags are mergeable ones.
    - Value label formats per mode.
  - _Verify_: The scene loads headless without errors (`Godot/tests/run_all.sh` stays green). The
    behavior is checked live in T-013.
  - _Depends on_: T-005, T-007

## Phase 4 — AI assistant

- [x?] **T-009** [REQ-013] Pan in AI channel summaries.
  - _Files_: `Godot/ai/tools/AiTool.gd`, `Godot/ai/prompt/PromptContext.gd`,
    `Godot/ai/chat/SelectionContext.gd`, `Godot/ai/tests/test_set_mixer_pan.gd`
  - _Output_:
    - `AiTool.describe_pan(c)`.
    - `compact_channel()` includes `pan_mode` and that mode's values.
    - The prompt table and the selection line use `describe_pan`.
  - _Verify_: `godot --headless --path Godot -s ai/tests/test_set_mixer_pan.gd -- --test` passes
    the summary cases for all four modes.
  - _Depends on_: T-004

- [x?] **T-010** [REQ-014] `set_mixer` pan mode and values.
  - _Files_: `Godot/ai/tools/SetMixerTool.gd`, `Godot/ai/tests/test_set_mixer_pan.gd`
  - _Output_:
    - The `pan_mode`/`pan`/`pan_width`/`pan_left`/`pan_right` parameters.
    - New state built with `convert_pan_state` and the given values, as one `set_pan_state`
      command in the existing `execute_many`.
    - Values that don't fit the mode are refused with no change.
  - _Verify_:
    - The same test script passes: set each mode and its values, then undo.
    - `pan_width` on a Balance channel is refused and the channel is unchanged.
    - `ai/tests/test_names_and_delete.gd` still passes.
  - _Depends on_: T-005, T-009

## Phase 5 — Docs

- [ ] **T-011** [REQ-003, REQ-001] OSC protocol doc.
  - _Files_: `docs/subsystems/osc-protocol.md`
  - _Output_: A `/channel/{id}/pan_width f:width` row. The `/pan_mode` row describes 0 = Combined
    (width + position), 1 = Dual, 2 = Balance (default), 3 = Mono.
  - _Verify_: Both rows are present and match `server.rs`.
  - _Depends on_: T-003

- [ ] **T-012** [REQ-all] Glossary and backlog.
  - _Files_: `CONTEXT.md`, `TODO.md`
  - _Output_: Glossary entries for the pan modes, position and width. The `TODO.md` entry is
    updated as the tasks land.
  - _Verify_: The entries exist, and the `TODO.md` marker matches the state of this file.
  - _Depends on_: T-010, T-011

## Phase 6 — Live verification

- [ ] **T-013** [REQ-001, REQ-003, REQ-009, REQ-010] Verify with the engine and Godot running.
  - _Files_: —
  - _Output_: The `TODO.md` entry is marked `[x]`, and `STATUS.md` notes what was and wasn't
    checked.
  - _Verify_:
    1. New channel → the mode menu shows Stereo Balance checked, with four items.
    2. On a stereo source, check each mode by ear: Balance hard right silences the left. In
       Combined, a fill-drag keeps the stereo image while it moves, a handle-drag narrows it,
       and crossing the handles swaps the sides. Dual handles move independently. Mono at
       center sums to the middle.
    3. Alt-drag at width 0 spreads the handles.
    4. Each change is one undo step.
    5. Load a project saved before this change, and confirm its Combined channels show Balance.
    6. `Engine/logs/last_info.log` shows no errors.
  - _Depends on_: T-008, T-010, T-012

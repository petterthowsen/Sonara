# CompactHSlider and EQ view controls — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

## Phase 1 — CompactHSlider component

- [x] **T-001** [REQ-001, REQ-002, REQ-003] Build `CompactSlider`: value text line + thin bar,
  vertical drag (FineDrag, Shift = fine), Ctrl/Cmd-click reset, double-click `FloatingValueEditor`
  entry, `step`/`logarithmic`/bidirectional bar, `value_text_callback`/`unit` formatting.
  - _Files_: `Godot/components/CompactHSlider.gd`
  - _Output_: the component with `class_name CompactSlider`, `HotkeyActions` `control_knob` context,
    `ValueEditKind` on every change
  - _Verify_: `cd Godot && godot --headless --path . -s tests/test_compact_hslider.gd -- --test`
  - _Depends on_: —

- [x] **T-002** [REQ-004, REQ-005] Add the modulation surface (`mod_ranges`, `mod_live_values`,
  `mod_hint_*`, `mod_assign_*`, `mod_amount_changed`, assign tooltip) and
    `ThemedColors(&"CompactSlider")` theming (`text`, `bar_bg`, `bar_fill`, `mod_live`).
  - _Files_: `Godot/components/CompactHSlider.gd`
  - _Output_: `ModAssign.attach()` works on a `CompactSlider` the same as on a `RotaryKnob`
  - _Verify_: same test run as T-001 (mod cases)
  - _Depends on_: T-001

- [x] **T-003** [REQ-001–REQ-005] Write `tests/test_compact_hslider.gd`: formatting, drag
  sensitivity and Shift fine drag, reset, entry editor spawn, snapping, log mapping,
  bidirectional fill, mod surface.
  - _Files_: `Godot/tests/test_compact_hslider.gd`
  - _Output_: passing headless test
  - _Verify_: `cd Godot && godot --headless --path . -s tests/test_compact_hslider.gd -- --test`
    (exit 0)
  - _Depends on_: T-002

## Phase 2 — shared EQ helpers

- [x] **T-004** [REQ-006] Add `EqTypeIcon.texture(type: int, color: Color) -> ImageTexture`
  rendering the same curve as the control.
  - _Files_: `Godot/devices/builtin/EqTypeIcon.gd`
  - _Output_: icons for all 8 `EqResponse.Type` values
  - _Verify_: covered by `test_eq_view.gd` (extended, T-007) asserting non-empty textures
  - _Depends on_: —

- [x] **T-005** [REQ-007] Add `EqKnobs.make_compact` / `configure_compact` and generalize
  `dim_gain` → `dim_value_control` (knob and slider).
  - _Files_: `Godot/devices/builtin/EqKnobs.gd`
  - _Output_: a `CompactSlider` binds to a device parameter with range/log/default/format and
    `ModAssign.attach`, incl. the freq `FreqAxis.format_hz` text callback
  - _Verify_: exercised by the footer (T-006) and `test_eq_view.gd` (T-007)
  - _Depends on_: T-002

- [x] **T-006** [REQ-007 assets] Download Lucide `power.svg` into `Godot/assets/icons/` (speaker
  `volume-2.svg` already present); let Godot import it.
  - _Files_: `Godot/assets/icons/power.svg` (+ generated `.import`)
  - _Output_: `preload("res://assets/icons/power.svg")` resolves
  - _Verify_: footer buttons (T-007) render both icons; import produces no errors
  - _Depends on_: —

## Phase 3 — EQ footer and companion view

- [x] **T-007** [REQ-007, REQ-009] Rework the `EqDefaultView` footer: band selector dropdown
  (always a band selected, synced with the curve editor selection), solo toggle (`volume-2.svg`,
  `LISTEN_BAND`), enabled toggle (`power.svg`, `P_ENABLED`), type dropdown with
  `EqTypeIcon.texture` icons (`P_TYPE`),
  `CompactSlider`s for Freq/Gain/Q; keep the output knob.
  - _Files_: `Godot/devices/builtin/EqDefaultView.gd`, `Godot/devices/builtin/EqDefaultView.tscn`
    (if it holds footer nodes)
  - _Output_: footer per design; `_refresh_band_controls` covers solo/enabled/type/selector
  - _Verify_: `cd Godot && godot --headless --path . -s tests/test_eq_view.gd -- --test`
    — including REQ-009: disabling the selected band keeps every footer control interactive
    (a Freq drag still writes `P_FREQ`), and the selector never reaches a none/-1 state
  - _Depends on_: T-004, T-005, T-006

- [x] **T-008** [REQ-008] Rework `EqBandsCompanionView` strips: per-band solo `ToggleButton`
  (speaker icon, `LISTEN_BAND` n+1/0 toggle) and type `OptionButton` (band-colour icons) replacing
  the static icon; `_refresh_band` reads `LISTEN_BAND` for every strip.
  - _Files_: `Godot/devices/builtin/EqBandsCompanionView.gd`
  - _Output_: companion strips with solo + adjustable type
  - _Verify_: `test_eq_view.gd` (extended, T-009) covers companion solo/type writes and refresh
  - _Depends on_: T-004, T-006

- [x] **T-009** [REQ-007, REQ-008, REQ-009] Extend `test_eq_view.gd`: footer parameter
  writes/refresh, band selector sync (incl. disabled-band interactivity, REQ-009), gain dimming,
  `EqTypeIcon.texture` non-empty for all types, companion solo/type behaviour.
  - _Files_: `Godot/tests/test_eq_view.gd`
  - _Output_: passing headless test
  - _Verify_: `cd Godot && godot --headless --path . -s tests/test_eq_view.gd -- --test` and
    `tests/run_all.sh eq compact`
  - _Depends on_: T-007, T-008

## Phase 4 — gallery and docs

- [x?] **T-010** [REQ-001] Add the `CompactHSliderCard` to the component gallery with a live
  demo value and Preview-set mod properties.
  - _Files_: `Godot/components/gallery/ComponentGallery.tscn` (and `.gd` if the preview needs code)
  - _Output_: the card previews the component in-editor, drag/entry/reset functional
  - _Verify_: open the gallery scene in the Godot editor (live; note in STATUS.md)
  - _Depends on_: T-002

- [x] **T-011** [REQ-all] Document `CompactSlider` (interaction contract, theme keys) and
  `EqTypeIcon.texture` in `docs/subsystems/godot-ui-components.md`; note the EQ footer/companion
  changes in `docs/subsystems/godot-device-views.md`.
  - _Files_: `docs/subsystems/godot-ui-components.md`, `docs/subsystems/godot-device-views.md`
  - _Output_: both docs describe the new controls
  - _Verify_: docs mention every new public symbol
  - _Depends on_: T-003, T-008

## Phase 5 — live verification

- [ ] **T-012** [REQ-all] Verify live with the engine and Godot running.
  - _Files_: —
  - _Output_: STATUS.md notes what was and wasn't checked
  - _Verify_: engine + editor running: add an EQ, select/solo/enable bands in the footer and
    companion view, drag freq/gain/Q (Shift fine, Ctrl reset, double-click entry), check the
    gallery card and a theme switch re-colouring, and listen that solo isolates the band
  - _Depends on_: T-009, T-010, T-011

# CompactHSlider and EQ view controls — Design

Implements [requirements.md](./requirements.md).

## Context

- `Godot/components/RotaryKnob.gd` — the interaction model to copy: vertical drag with
  `FineDrag`, `ValueEditKind`, Ctrl/Cmd-click reset, `last_edit_kind`, `HotkeyActions.declare_context(
  self, "control_knob")`, double-click value entry via `FloatingValueEditor`, `value_text_callback`
  formatting, `logarithmic` mapping, and the full modulation surface (`mod_ranges`,
  `mod_live_values`, `mod_hint_*`, `mod_assign_*`, `mod_amount_changed`, assign tooltip via
  `ValueTooltip` + `ModDisplay`.
- `Godot/components/ThemedColors.gd` — per-component theme colors with a class prefix
  (here `&"CompactSlider"`).
- `Godot/components/FineDrag.gd`, `FloatingValueEditor.gd`, `ValueTooltip.gd`, `ModDisplay.gd`,
  `ModAssign` (in `Godot/devices/modulators/`) — reused as-is.
- `Godot/devices/builtin/EqKnobs.gd` — `make_knob` / `configure(knob, device, param_id, …)` /
  `dim_gain`: binds a value control to a device parameter (range, log curve, default, format,
  `ModAssign.attach`).
- `Godot/devices/builtin/EqDefaultView.gd` — panel view; footer (`_build`, lines ~100–123) with
  `_band_label`, `_type_option` (text-only `OptionButton`), three `LabeledKnob`s, output knob.
- `Godot/devices/builtin/EqBandsCompanionView.gd` — companion view; per-band strip = `CheckBox`,
  static `EqTypeIcon`, three knobs; `_refresh_band(band)` reads `P_ENABLED`, `P_TYPE`.
- `Godot/devices/builtin/EqTypeIcon.gd` — **procedural** icon: draws the band type's magnitude
  curve via `EqResponse.band_filter`/`filter_db` in `EqCurveEditor.band_color(band)`.
- `Godot/devices/builtin/EqResponse.gd` — parameter ids: `P_ENABLED`(0), `P_TYPE`(1), `P_FREQ`(2),
  `P_GAIN`(3), `P_Q`(4), `BAND_STRIDE`(10), `BAND_COUNT`(8), `OUTPUT_GAIN`(80), `LISTEN_BAND`(81);
  `TYPE_NAMES`, `MIN/MAX_FREQ`, `MIN/MAX_Q`, `MAX_GAIN`.
- `Engine/src/audio/devices/effects/eq.rs` — `LISTEN_BAND` (param 81, enum `Off, 1..8`) already
  soloes a band in the engine (band-pass "listen" path). **No engine change.**
- `Godot/assets/icons/` — Lucide SVGs, used via `preload("res://assets/icons/<name>.svg")` and
  `BaseButton.icon`. `volume-2.svg` (speaker) exists; `power.svg` does not — download from Lucide.
- `Godot/components/gallery/ComponentGallery.tscn` (+ `.gd`) — the in-editor component gallery;
  cards are scene nodes with live previews.

## Approach

**CompactHSlider** (`Godot/components/CompactHSlider.gd`, `class_name CompactSlider extends Control`)
is a text-first slider: one line of formatted value text, one thin horizontal bar (~3 px) under it.
Total height ~20 px. Its input handling is a port of `RotaryKnob`'s with the drag axis rotated:
vertical relative motion (`-relative.y`) mapped through `FineDrag` (Shift = fine) and
`logarithmic`, `step` snapping accumulated underneath like the knob. Ctrl/Cmd-click resets to
`default_value` (`reset_requested`, `ValueEditKind.RESET`); double-click opens
`FloatingValueEditor` prefilled with the current value (float parse through the same editor used by
the knob). The bar draws like `HorSlider`: unidirectional fill from the left, or fill from the
centre when the range spans zero. Modulation drawing is `HorSlider`'s `_draw_modulation()` scaled
to the thin bar: route bars in `MOD_BAR` rows on the bar's top edge, `mod_live_values` markers
across the bar, `ModDisplay` fill overlays for hint/assign. Themed via
`ThemedColors(…, &"CompactSlider")` with `text`, `bar_bg`, `bar_fill`, `mod_live`.

Why a new component instead of reusing `HorSlider`: `HorSlider` drags horizontally, has no value
text, no typed entry, no log mapping, and draws a full-height bar — none of that is what the footer
wants, and retrofitting it would change every existing user. The modulation plumbing, however, is
copied verbatim so `ModAssign.attach()` works on both.

**Footer rework** (`EqDefaultView._build`): the `bottom` HBox keeps `STRIP_HEIGHT`-ish minimum but
now holds, left to right: band selector `OptionButton` (items 1–8, colour-coded via
`EqCurveEditor.band_color`, synced both ways with `editor.selected_band`), solo `ToggleButton`
(`volume-2.svg` icon, pressed when `LISTEN_BAND == band + 1`, writes `set_parameter_real(
EqResponse.LISTEN_BAND, band + 1 / 0)`), enabled `ToggleButton` (`power.svg`, writes the band's
`P_ENABLED`), type `OptionButton` with `EqTypeIcon.texture(type, color)` item icons (writes
`P_TYPE`), then three `CompactSlider`s (Freq, Gain, Q) replacing the knobs, spacer, and the
existing output `LabeledKnob`. The selector always has a band picked (REQ-009): on view setup it
falls back to the first enabled band, else band 1, and a curve-editor selection of `-1` never
clears it — the footer's `_band` is the selector's, and the editor follows when the footer picks.
A disabled band dims its footer strip but every control stays interactive (same dimming the
companion strips already use). `_refresh_band_controls()` gains the solo/enabled state and the
band selector selection; `dim_gain` becomes `dim_control` for the gain slider. `EqKnobs` grows
`configure_compact(slider, device, param_id, format_cb)` mirroring `configure` (range, log curve,
default, `value_text_callback`, `ModAssign.attach`) — a duck-typed merge of the two was considered
and rejected: the two controls share no base class and a Callable-heavy shim is more code than the
~15 duplicated lines.

**Type icons** stay procedural (`EqTypeIcon`) — confirmed by source. `EqTypeIcon.texture(type,
color) -> ImageTexture` renders the same `SAMPLES`-point curve offscreen by rasterizing the
identical polyline (the exact raster path — a `RenderingServer` canvas item baked into an
`ImageTexture`, or `Image`-level line drawing — is a task-level detail; the acceptance test only
requires non-empty icons per type). In the companion view the static icon slot is *replaced* by
the type dropdown (icon-only items, band colour, tooltip = type name): it both saves strip height
and makes the type adjustable.

**Companion view**: each strip's `CheckBox` row becomes `HBox` [number `CheckBox`, solo
`ToggleButton` (speaker icon)], and the static icon slot becomes the type `OptionButton`
(REQ-008). Solo semantics: pressing band n's solo sets `LISTEN_BAND = n + 1`; pressing the
currently soloed band's button sets it back to 0 (Off). `_refresh_band` additionally reads
`LISTEN_BAND` (device-level, refreshed for every strip since it is one parameter).

**Gallery**: a `CompactHSliderCard` in `ComponentGallery.tscn` beside the `HorSlider` card, with
a live demo (formatted "2.4 kHz"-style value, drag/double-click/ctrl-reset all functional in the
gallery) and Preview-set mod properties mirroring the knob card so the modulation look is visible.

## Thread and ownership

Godot-only; no new threads, no engine state.

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `LISTEN_BAND`/`P_*` parameters | engine command thread (existing) | existing OSC param path, unchanged | unchanged |

## Data and protocol changes

None. All controls write existing EQ parameters through `DeviceInstance.set_parameter_real`
(`P_ENABLED`, `P_TYPE`, `LISTEN_BAND`, `P_FREQ`, `P_GAIN`, `P_Q`), and read them through
`_on_device_parameter_changed` / `get_parameter_real` exactly like the current knobs. No OSC
addresses, no docs/subsystems updates beyond the UI components doc.

## File-by-file change list

| File | Change |
|---|---|
| `Godot/components/CompactHSlider.gd` | New: `CompactSlider` component (value text + thin bar, knob-style drag/reset/entry, modulation surface, theming) |
| `Godot/components/gallery/ComponentGallery.tscn` | New `CompactHSliderCard` with live preview and mod Preview properties |
| `Godot/assets/icons/power.svg` (+ `.import`) | Download Lucide `power.svg` (speaker `volume-2.svg` already present) |
| `Godot/devices/builtin/EqTypeIcon.gd` | Add `static func texture(type: int, color: Color) -> ImageTexture` |
| `Godot/devices/builtin/EqKnobs.gd` | Add `make_compact(text, on_changed)` and `configure_compact(slider, device, param_id, format, unit_suffix)`; generalize `dim_gain` → `dim_value_control` (works for knob and slider) |
| `Godot/devices/builtin/EqDefaultView.gd` | Footer rework per REQ-007: band selector, solo/enabled icon toggles, icon type dropdown, CompactSliders for F/G/Q; `_refresh_band_controls` extended |
| `Godot/devices/builtin/EqBandsCompanionView.gd` | Per-band solo button + type dropdown; `_refresh_band` reads `LISTEN_BAND` |
| `Godot/tests/test_compact_hslider.gd` | New: formatting, drag/reset/entry, log mapping, bidirectional fill, mod surface |
| `Godot/tests/test_eq_view.gd` | Extend: footer controls parameter writes/refresh; companion solo/type |
| `docs/subsystems/godot-ui-components.md` | Document `CompactSlider` (interaction contract, theming keys) and `EqTypeIcon.texture` |

## Migration and compatibility

Nothing is persisted. Device frames resize to the new footer height automatically. The old text
`_type_option` and `LabeledKnob`s are removed cleanly — no shims, no fallback path.

## Test plan

- **Godot unit:** `godot --headless --path Godot -s tests/test_compact_hslider.gd -- --test` —
  formatted text incl. `value_text_callback`, vertical drag changes value (Shift slows it),
  Ctrl+click reset emits `reset_requested` and restores default, double-click opens
  `FloatingValueEditor` (spawned node present with prefilled text), `step` snapping, log mapping,
  bidirectional fill geometry (drawn x-positions via internal norm funcs), `mod_ranges`/
  `mod_assign_active` drag emits `mod_amount_changed` and doesn't change `value`.
- **Godot unit:** `test_eq_view.gd` (extended) — footer: band selector syncs with
  `editor.selected_band`; solo toggle writes `LISTEN_BAND` (n+1 / 0); enabled toggle writes the
  band's `P_ENABLED`; type dropdown writes `P_TYPE` and `EqTypeIcon.texture` items exist for all 8
  types; gain slider dims for cut/notch/band-pass types; companion: per-band solo and type
  dropdown writes + `_on_device_parameter_changed` refresh (incl. `LISTEN_BAND` refreshing every
  strip).
- **Live (cannot be headless):** visual check of drag feel, gallery card, theme switch re-colour,
  icon crispness at the footer size; audio check that solo mutes the other bands
  (`./test_osc.sh` then set `LISTEN_BAND`). Hand to user.

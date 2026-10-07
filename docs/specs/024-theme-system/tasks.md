# Theme system — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Test command form: `godot --headless --path Godot -s tests/<script>.gd -- --test`
(`Godot/tests/run_all.sh theme` runs every `test_theme_*`).

## Phase 1 — Foundation: settings, palette, builder

- [x?] **T-001** [REQ-001] Audit the current theme, extract the font, and add the backlog entry.
  - _Files_: `docs/specs/024-theme-system/theme-audit.md` (new),
    `Godot/assets/fonts/OpenSans-SemiBold.woff2` (new), `TODO.md`
  - _Output_:
    - A throwaway headless script lists every item in `Sonara_Theme.tres` that differs from
      `ThemeDB.get_default_theme()`. Each item is marked *keep*, with the role it maps to, or
      *drop*, in `theme-audit.md`.
    - The embedded "Open Sans SemiBold" `FontFile_j1xew` is saved as a font file (it is WOFF2
      data, so `OpenSans-SemiBold.woff2`; see `theme-audit.md`).
    - `TODO.md` gets an entry linking this spec.
  - _Verify_:
    - `theme-audit.md` has a keep or drop verdict for every listed item.
    - The font loads with `load()` and reports `font_name == "Open Sans SemiBold"`.
  - _Depends on_: —

- [x?] **T-002** [REQ-003, REQ-020] Add the `COLOR` setting type.
  - _Files_: `Godot/settings/Settings.gd`, `Godot/settings/SettingRow.gd`,
    `Godot/tests/test_settings_registry.gd`
  - _Output_:
    - `Type.COLOR`, and its `_coerce` branch: accepts a `Color` or an `"#rrggbb"` string; an
      invalid value warns and returns the default.
    - A `ColorPickerButton` widget (`edit_alpha = false`) that builds, reads, applies and edits.
  - _Verify_: `test_settings_registry.gd` passes, with new cases: a `Color` in gives a hex
    string, `"#abc123"` is unchanged, and `"nope"` gives the default.
  - _Depends on_: —

- [x?] **T-003** [REQ-020, REQ-021] Register the eight theme settings and add `reset_theme()`.
  - _Files_: `Godot/settings/Settings.gd`, `Godot/tests/test_settings_registry.gd`
  - _Output_: the `appearance/theme/*` keys with the defaults and ranges from the design table
    (sub-category `"Theme"`), and `reset_theme()`.
  - _Verify_: `test_settings_registry.gd` passes, including a case where `reset_theme()`
    restores all eight keys after they were changed.
  - _Depends on_: T-002

- [x?] **T-004** [REQ-001, REQ-003, REQ-004, REQ-022] `ThemePalette`.
  - _Files_: `Godot/core/theme/ThemePalette.gd` (new), `Godot/tests/test_theme_palette.gd` (new)
  - _Output_: `ThemePalette.from_settings(values)`, which produces every role in the design
    table. It clamps the main colour, applies per-key fallback, and includes `unit` and
    `radius`.
  - _Verify_: `test_theme_palette.gd` passes. It checks:
    - the default roles
    - `#c0c0c0` clamps to HSV value 0.35 with the same hue and saturation
    - an invalid colour and radius 9 fall back to their defaults
    - the RGB spread of `app_bg` is ≤ 0.01
  - _Depends on_: T-003

- [x?] **T-005** [REQ-001, REQ-008, REQ-010, REQ-011, REQ-013, REQ-015, REQ-025] `ThemeBuilder`:
  defaults, Godot base types and variations.
  - _Files_: `Godot/core/theme/ThemeBuilder.gd` (new), `Godot/tests/test_theme_builder.gd` (new)
  - _Output_:
    - The default font and size 14 (headers 20, 24 and 28).
    - The Godot types and variations from the design.
    - The `Sonara` custom type: role colours, plus `unit` and `radius` constants.
    - The audit's *keep* items.
  - _Verify_: `test_theme_builder.gd` passes. It checks:
    - every variation exists with its base type
    - radius 0, 2 and 4 on every generated `StyleBoxFlat`
    - margins and separations at unit 1, 2 and 4
    - the nest overlay is black with α in (0, 0.25]
    - font sizes
    - the button pressed style uses the accent, and `Record`/`Solo`/`MuteButton` use their
      colours
  - _Depends on_: T-001, T-004

- [x?] **T-006** [REQ-013, REQ-014, REQ-016, REQ-018] `ThemeBuilder`: component theme types.
  - _Files_: `Godot/core/theme/ThemeBuilder.gd`, `Godot/tests/test_theme_builder.gd`
  - _Output_: the `RotaryKnob`, `Fader`, `VolumeSlider`, `HorSlider`, `HDualSlider`, `Meter`,
    `LevelMeter`, `Volumeter`, `LightButton`, `SegmentedControl`, `XYSlider`,
    `EnvelopeControl` and `Ruler` types, with items mapped from roles.
  - _Verify_: the test checks a sample per type: `Fader/fill == accent_primary`,
    `HDualSlider/alt_fill == accent_secondary`, `LevelMeter/warn == UiColors.METER_WARN`,
    `XYSlider/bg == well`.
  - _Depends on_: T-005

- [x?] **T-007** [REQ-002, REQ-004] `UiTheme` autoload.
  - _Files_: `Godot/core/theme/UiTheme.gd` (new), `Godot/project.godot`
  - _Output_:
    - Builds and merges into the project theme on `_ready`.
    - Sets the clear colour.
    - Coalesces `setting_changed` for `appearance/theme/*` into one rebuild per frame and emits
      `theme_applied`.
    - Registered after `Settings`; `default_clear_color` updated.
  - _Verify_:
    - `godot --headless --path Godot -s tests/test_theme_palette.gd -- --test` still passes,
      which shows the autoload starts cleanly.
    - The app starts with no theme errors in `Godot/logs/last.log`.
  - _Depends on_: T-006

- [x?] **T-008** [REQ-023] Generate `Sonara_Theme.tres`.
  - _Files_: `Godot/core/theme/build_theme_resource.gd` (new), `Godot/assets/Sonara_Theme.tres`,
    `Godot/tests/test_theme_resource_fresh.gd` (new)
  - _Output_: the regenerated `.tres` with the same UID (`uid://c77m063o570pp`), much smaller
    than 6,800 lines.
  - _Verify_:
    - `godot --headless --path Godot -s core/theme/build_theme_resource.gd` writes the file.
    - `test_theme_resource_fresh.gd` passes.
    - `git diff --stat` shows the shrink.
  - _Depends on_: T-007

## Phase 2 — Surfaces and layout

- [x?] **T-009** [REQ-004, REQ-005] Editor sections.
  - _Files_: `Godot/editor/Editor.tscn`, `Godot/ai/ui/AssistantPanel.tscn`,
    `Godot/editor/docks/DockPanel.gd`, `Godot/devices/frame/DeviceFrame.gd`,
    `Godot/tests/test_theme_usage.gd` (new)
  - _Output_:
    - The root uses `AppRoot` and the main VBox uses `SectionStack`.
    - `Top` is wrapped in a `Header` `SectionPanel`.
    - `Primary`, `Secondary`, `Inspector`, `BrowserPanel`, `AssistantPanel` and `InfoPanel` use
      `SectionPanel`.
    - Dock and frame title bars use `SectionHeader`.
    - Redundant overrides are removed, and no `PrimaryPanel` or `DarkPanel` references remain.
  - _Verify_:
    - `test_theme_usage.gd` (sections part) passes.
    - `grep -rn "PrimaryPanel\|DarkPanel" Godot --include=*.tscn --include=*.gd` finds nothing.
  - _Depends on_: T-008

- [x?] **T-010** [REQ-006, REQ-012] Device cards.
  - _Files_: `Godot/devices/device_lane/DevicePanel.gd` + `.tscn`,
    `Godot/devices/compact/CompactDevicePanel.gd` + `.tscn`, `Godot/tests/test_theme_usage.gd`
  - _Output_:
    - `DeviceCard`, `DeviceCardHeader` and `DeviceCardSelected` are used by both panels.
    - The compact panel's root becomes a `PanelContainer`, with `%Header` / `%Parameters`.
    - The `BORDER_COLOR*` constants and the duplicated styleboxes are removed.
  - _Verify_: `test_theme_usage.gd` (cards part) and `test_compact_device_panel.gd` pass.
  - _Depends on_: T-009

- [x?] **T-011** [REQ-009] Floating surfaces.
  - _Files_: `Godot/components/ValueTooltip.gd`, `Godot/components/LabelOverlay.gd`,
    `Godot/tests/test_theme_usage.gd`
  - _Output_: both use `Floating`, and the plain `ValueTooltip` keeps an empty style.
    `ContextMenu` / `ContextMenuList` get the floating look from the builder.
  - _Verify_: `test_theme_usage.gd` (floating part) and `test_value_controls.gd` pass.
  - _Depends on_: T-008

## Phase 3 — Colour roles

- [ ] **T-012** [REQ-001] `UiColors` becomes a facade over the theme.
  - _Files_: `Godot/core/UiColors.gd`, plus every caller of the removed constants (found by
    `grep -rn "UiColors\." Godot`)
  - _Output_:
    - `UiColors.role(name)`.
    - `PRIMARY`, `PRIMARY_ALT`, `TRACK_BG` and `HANDLE` are removed, and their callers migrated.
    - `METER_WARN`, `METER_CLIP` and `METER_HOLD` stay.
  - _Verify_: the project parses without errors (`godot --headless --path Godot --quit` with no
    script errors), and `run_all.sh theme compressor` passes.
  - _Depends on_: T-007

- [ ] **T-013** [REQ-013, REQ-014, REQ-018] Value controls take their colours from the theme.
  - _Files_: `Godot/components/RotaryKnob.gd`, `Fader.gd`, `VSlider.gd`, `HSlider.gd`,
    `HDualSlider.gd`, `XYSlider.gd`, `EnvelopeControl.gd`, `SegmentedControl.gd`,
    `LightButton.gd`
  - _Output_: the colour `@export`s become override-backed properties with a cache, refreshed
    on `NOTIFICATION_THEME_CHANGED` with a redraw.
  - _Verify_: `test_value_controls.gd`, `test_envelope_control.gd` and the new
    `test_theme_live.gd` (component part: resolved defaults, and an override surviving a
    change) pass.
  - _Depends on_: T-006, T-012

- [ ] **T-014** [REQ-013, REQ-016, REQ-018] Meters and rulers take their colours from the theme.
  - _Files_: `Godot/components/meter/Meter.gd`, `meter/LevelMeter.gd`,
    `Godot/components/Volumeter.gd`, `Godot/components/Ruler.gd`, `RealTimeRuler.gd`,
    `BaseRuler.gd`
  - _Output_: the same pattern as T-013. Rulers cache their colours instead of reading them in
    `_draw`.
  - _Verify_: `test_level_meter.gd` and `test_theme_live.gd` (meter part: the safe zone follows
    the accent, warn and clip stay fixed) pass.
  - _Depends on_: T-013

- [ ] **T-015** [REQ-007, REQ-018] Wells, and the sweep of colours baked into scenes.
  - _Files_: `Godot/mixer/device_list/ChannelDeviceList.tscn`, `Godot/mixer/MixerChannel.tscn`,
    `Godot/components/gallery/ComponentGallery.tscn`, plus any other `*.tscn` setting the old
    colour exports
  - _Output_:
    - The `ChannelDeviceList` panel uses `Well`.
    - Colour values that only repeat a role are deleted.
    - Deliberate looks become `theme_override_colors/<item>`.
  - _Verify_:
    - `test_theme_usage.gd` (wells part) passes.
    - `grep -rnE "(knob|fill|value_arc|bar|handle|track|selected|idle|hover)_color" Godot --include=*.tscn`
      lists only reviewed exceptions, which are noted in this task when it is marked done.
  - _Depends on_: T-014

- [ ] **T-016** [REQ-012] Neutral selection borders on track items and mixer strips.
  - _Files_: `Godot/mixer/MixerChannel.gd`, `Godot/arranger/tracklist/TrackItem.gd`,
    `Godot/clip_editor/tracklist/ClipEditorTrackListItem.gd`, `Godot/tests/test_theme_usage.gd`
  - _Output_:
    - The `border_color*` exports are removed.
    - Border colour and width come from `Sonara` / `DeviceCard` and are refreshed on theme
      change.
    - A selected `TrackItem` adds a 1 px `border_selected` border and keeps its tint.
  - _Verify_:
    - `test_theme_usage.gd` (selection part: same border colour across all five kinds) passes.
    - `test_track_item_height_sync.gd`, `test_mixer_keyboard_selection.gd` and the
      `clip_editor` tests pass.
  - _Depends on_: T-010

- [ ] **T-017** [REQ-015, REQ-017] Status colours.
  - _Files_: `Godot/arranger/tracklist/TrackItem.tscn`, `Godot/mixer/MixerChannel.tscn`,
    `Godot/clip_editor/tracklist/ClipEditorTrackListItem.gd`, `Godot/tests/test_theme_usage.gd`,
    `Godot/tests/test_theme_live.gd`
  - _Output_:
    - The arm, solo and mute toggles use `RecordButton` / `SoloButton` / `MuteButton`, and
      their scene styleboxes and colour overrides are removed.
    - `SOLO_COLOR` is replaced by `UiColors.role(&"solo")`.
  - _Verify_:
    - `test_theme_usage.gd` (status part: each toggle pressed in both places shows its
      colour) passes.
    - `test_theme_live.gd` (changing the accent leaves a track's colour unchanged) passes.
  - _Depends on_: T-016

- [ ] **T-018** [REQ-019] Device views: instruments.
  - _Files_: the polysynth, sampler, sfizz and drum view scripts and scenes under
    `Godot/devices/builtin/`, `Godot/tests/test_theme_literals.gd` (new)
  - _Output_:
    - Accent literals become cached `UiColors.role(...)` lookups.
    - Fixed colours carry `# theme-exempt: <reason>`.
    - The literal-scan test exists, with an allowlist that temporarily covers the effects not
      yet swept.
  - _Verify_: `test_theme_literals.gd` passes for the instrument files.
  - _Depends on_: T-013

- [ ] **T-019** [REQ-019] Device views: effects and utility.
  - _Files_: the views for the spec 012 effects, compressor, multiband and utility under
    `Godot/devices/builtin/`
  - _Output_: the same as T-018. The temporary allowlist is removed.
  - _Verify_: `test_theme_literals.gd` passes over all of `devices/builtin/`.
  - _Depends on_: T-018

- [ ] **T-020** [REQ-002] Live update across the whole editor.
  - _Files_: `Godot/tests/test_theme_live.gd`
  - _Output_: test cases for the editor scene:
    - an accent change updates a knob and a fader after one frame
    - ten `set_value` calls in one frame cause one `theme_applied`
  - _Verify_: `test_theme_live.gd` passes.
  - _Depends on_: T-017

## Phase 4 — Settings UI

- [ ] **T-021** [REQ-020, REQ-021] "Reset theme" button on the Appearance page.
  - _Files_: `Godot/settings/SettingsDialog.gd`
  - _Output_: the button, shown when the category is Appearance, following
    `_add_reset_shortcuts_button`.
  - _Verify_: live: the Appearance page shows the Theme rows and the button. Pressing it
    restores the defaults, and Cancel reverts.
  - _Depends on_: T-003, T-007

## Phase 5 — Docs

- [ ] **T-022** [REQ-024] Documentation and ADR.
  - _Files_: `docs/subsystems/godot-ui-components.md`, `docs/subsystems/godot-config-system.md`,
    `docs/adr/0018-theme-generated-from-settings.md` (new), `AGENTS.md`
  - _Output_:
    - The components guide's §5 is rewritten (roles, variations, spacing, the component colour
      pattern, `theme_override_colors/<item>` overrides), the Shared pieces `UiColors` row is
      updated, and the gallery path is fixed.
    - The config doc covers the COLOR type and the theme keys.
    - The ADR is added.
    - The `UiTheme` autoload is added to the autoload list in `AGENTS.md`.
  - _Verify_: every variation and role in the design appears in the components guide, and the
    ADR is listed in `docs/adr/`.
  - _Depends on_: T-019, T-021

## Phase 6 — Visual pass and live verification

- [ ] **T-023** [REQ-004, REQ-005, REQ-025] Visual pass and layout fixes.
  - _Files_: whichever scenes need layout fixes after the 14 px font and the new spacing
  - _Output_: screenshots with default settings of the whole editor, the arranger with tracks,
    the mixer with devices, the device lane, the clip editor, a context menu and the Settings
    dialog. No clipped or overlapping text.
  - _Verify_: the screenshots are reviewed with the user, and the fixes are committed.
  - _Depends on_: T-020

- [ ] **T-024** [REQ-002, REQ-020, REQ-023] Live verification.
  - _Files_: `TODO.md`
  - _Output_: the TODO entry is marked `[x]`.
  - _Verify_:
    1. Change each of the eight theme settings and watch it apply, including in an open device
       window.
    2. Cancel and confirm the revert. Change again, OK, restart, and confirm it persisted.
    3. Reset theme.
    4. Open `editor/Editor.tscn` and `components/gallery/ComponentGallery.tscn` in the Godot
       editor and confirm they match the running app.
    5. `Godot/tests/run_all.sh` passes in full.
  - _Depends on_: T-022, T-023

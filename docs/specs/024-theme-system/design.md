# Theme system — Design

Implements [requirements.md](./requirements.md).

## Context

- `Godot/assets/Sonara_Theme.tres` is the project theme (`gui/theme/custom="uid://c77m063o570pp"` in
  `Godot/project.godot`). It is a 6,800-line copy of Godot's default theme with edits.
  - It embeds images and an "Open Sans SemiBold" `FontFile` (`FontFile_j1xew`), which every
    control type uses.
  - `default_font` points to `assets/fonts/Inter-VariableFont_opsz,wght.ttf`, but no control type
    uses it.
  - Most types set `font_size = 16`, while `default_font_size = 14`.
  - The variations it defines are `PrimaryPanel`, `ContextMenu`, `ContextMenuList`, `FlatButton`,
    `FlatMenuButton`, `HeaderSmall`, `HeaderMedium` and `HeaderLarge`. `DarkPanel` is used by
    `editor/docks/DockPanel.gd`, `devices/frame/DeviceFrame.gd` and `editor/Editor.tscn`, but is
    not defined.
  - The custom `Ruler` type (colours plus a `normal` stylebox) is read by `components/Ruler.gd`,
    `RealTimeRuler.gd`, `BaseRuler.gd` and `arranger/ruler/*Track.gd`. These are the existing
    examples of a custom control taking its colours from the theme.
- The blue tint comes from `environment/defaults/default_clear_color=Color(0.094, 0.098, 0.122)` in
  `project.godot`, plus the default `PanelContainer` style (`StyleBoxFlat_rbbp4`,
  `bg_color = Color(0.125, 0.125, 0.165, 0.35)`).
- `Godot/core/UiColors.gd` holds the colour constants (`PRIMARY #624d99`, `PRIMARY_ALT`,
  `TRACK_BG`, `HANDLE`, `METER_*`). It is used by `Fader`, `LevelMeter`, `SegmentedControl`, the
  compressor view and one other file. Its header already says the theme follow-up will replace it.
- `Godot/settings/Settings.gd` is the autoload `Settings`.
  - It has `enum Type` (no colour type yet), `Setting` with `range`, `choices`, `sub` and
    `scene`, and `get_value`, `set_value`, `setting_changed`, `reset_to_defaults`,
    `reset_shortcuts` and `_coerce`.
  - `settings/SettingRow.gd` builds the editing widget per type in `_build_widget`. Every edit
    calls `_write_value`, which calls `Settings.set_value`, so changes already apply live.
  - `settings/SettingsDialog.gd` snapshots the values on open (`_capture_snapshot`) and restores
    them on Cancel. `_add_reset_shortcuts_button` is the existing pattern for a reset button
    scoped to one category.
- Editor layout (`editor/Editor.tscn`):
  - Root `Editor` (MarginContainer, margins 4), then `VBoxContainer` with `Top`, `Middle` and
    `Bottom`.
  - `Top` is a bare HBoxContainer holding `MainMenu`, `Transport`, `EnginePanel` and
    `WindowButtons`.
  - `Middle` → `LeftRightSplit` → `LeftCenterSplit` → `LeftDock/Inspector` (PrimaryPanel) and
    `MiddleCenter`. `MiddleCenter` holds `Primary` (PrimaryPanel: Arranger, Mixer, ClipEditor)
    and `Secondary` (PrimaryPanel: DeviceLane).
  - `RightDock` holds `BrowserPanel` (PrimaryPanel) and `AssistantPanel` (the
    `ai/ui/AssistantPanel.tscn` root, PrimaryPanel).
  - `Bottom/InfoPanel` (PrimaryPanel) holds the help bar (`editor/HelpBar.gd` extends
    RichTextLabel).
  - Split separation is 12 and the VBox separation is 8.
- Device cards:
  - `devices/device_lane/DevicePanel.gd` (`class_name DevicePanel extends PanelContainer`) and
    `devices/compact/CompactDevicePanel.gd` (root VBoxContainer with `$Header` and
    `$Parameters` PanelContainers) each duplicate a scene-local stylebox.
  - Both swap `border_color` to their own `BORDER_COLOR_SELECTED := Color("#999999")` when
    selected.
- `mixer/MixerChannel.gd` (`extends PanelContainer`) has `border_color` and
  `border_color_selected` exports (`#333` / `#999`). Its device area is
  `mixer/device_list/ChannelDeviceList.tscn`, with a scene-local `bg_color 0.094` stylebox.
- `arranger/tracklist/TrackItem.gd` (`extends PanelContainer`) marks selection only by the
  brightness of the track tint (`_update_header_style`, `Utils.header_color`).
  `clip_editor/tracklist/ClipEditorTrackListItem.gd` uses a white 2 px border and
  `SOLO_COLOR := Color("#ffb13b")`.
- Record, solo and mute buttons: `ArmToggle`, `SoloToggle` and `MuteToggle` (plain `Button`s
  with scene-local `theme_override_styles` and colour overrides) live in
  `arranger/tracklist/TrackItem.tscn` and `mixer/MixerChannel.tscn`. The clip editor track list
  has no arm, solo or mute buttons. Its visible and editable toggles use `SOLO_COLOR` for the
  soloed state.
- Reusable controls and their colour `@export`s:

  | Control | Script | Colour exports |
  |---|---|---|
  | `RotaryKnob` | `components/RotaryKnob.gd` | `knob_color`, `shadow_color`, `knob_line_color`, `value_arc_bg`, `value_arc_color` |
  | `Fader` | `components/Fader.gd` | `fill_color`, `track_color`, `handle_color`, `overlay_color` |
  | `VolumeSlider` | `components/VSlider.gd` | `bg_color`, `fill_color`, `handle_color` |
  | `HorSlider` | `components/HSlider.gd` | `bg_color`, `fill_color`, `handle_color` |
  | `HDualSlider` | `components/HDualSlider.gd` | `bg_color`, `fill_color`, `alt_fill_color`, `handle_color` |
  | `Meter` | `components/meter/Meter.gd` | `bar_*`, `tick_*`, `zero_db_color`, `fader_*` |
  | `LevelMeter` | `components/meter/LevelMeter.gd` | `safe_color`, `warn_color`, `clip_color`, `background_color`, `hold_color` |
  | `Volumeter` | `components/Volumeter.gd` | `bg_color`, `handle_color`, `bar_color_*` |
  | `LightButton` | `components/LightButton.gd` | `light_color`, `bg_color`, `border_color` |
  | `SegmentedControl` | `components/SegmentedControl.gd` | `selected_color`, `idle_color`, `hover_color` |
  | `XYSlider` | `components/XYSlider.gd` | `handle_color`, `bg_color`, `axis_line_color`, `value_label_color` |
  | `EnvelopeControl` | `components/EnvelopeControl.gd` | `bg_color`, `line_color`, `grid_color`, `handle_color`, `handle_color_hover` |

- `components/ValueTooltip.gd` and `components/LabelOverlay.gd` (both extend PanelContainer)
  each build their own floating `StyleBoxFlat`.
- `Godot/tests/TestBase.gd` is the base for every headless test, and `Godot/tests/run_all.sh`
  runs them. Related tests already exist: `test_settings_registry.gd`, `test_value_controls.gd`,
  `test_level_meter.gd` and `test_compact_device_panel.gd`.

## Approach

**Build the theme in code from a few inputs, the way Godot's own editor does
(`EditorThemeManager`).** The build has three layers:

1. `ThemePalette` turns the eight theme settings into named colours and sizes. It is a pure
   function, so it is easy to test.
2. `ThemeBuilder` turns a palette into a complete `Theme`.
3. The `UiTheme` autoload reads the settings, builds the theme, and merges it into the project
   theme in memory (`ThemeDB.get_project_theme().merge_with(built)`).

Theme lookups resolve on every call. Changing the project theme emits `changed`, which reaches
every Control and Window in the tree as `NOTIFICATION_THEME_CHANGED`, including separate device
`FrameWindow`s. So a settings change restyles everything live without any per-view wiring.

**`Sonara_Theme.tres` becomes generated output.**
- `core/theme/build_theme_resource.gd`, run headless, writes the default build, so the Godot
  editor previews the default look (REQ-023).
- A test fails if the committed file no longer matches the builder.
- Anything the builder doesn't set falls back to Godot's default theme, so the 6,800 lines
  shrink to what Sonara actually customises.

**Semantic styles are theme type variations.**
- Scenes say *what* a panel is (`SectionPanel`, `DeviceCard`, `Well`) and never how it looks.
- Selection swaps the variation (`DeviceCard` ↔ `DeviceCardSelected`) instead of copying and
  editing a stylebox.
- Panels that are tinted per track (track item, mixer strip header) keep their own stylebox for
  the tint. They read the border colour and width from the theme.

**Custom-drawn controls get their own theme type.** For example,
`RotaryKnob/colors/value_arc` and `Fader/colors/fill` are filled from palette roles, in the same
way as the existing `Ruler` type.
- Each control caches its colours on `NOTIFICATION_THEME_CHANGED` and redraws. It never looks
  them up in `_draw`.
- The colour `@export`s become plain properties backed by Godot's theme override:
  - **Setter:** `add_theme_color_override(name, c)`.
  - **Getter:** the cached resolved colour.
- So `knob.value_arc_color = X` in code still overrides that one instance (REQ-018). A scene
  can override through `theme_override_colors/<name>`.
- Because the properties are no longer exported, scenes stop baking in copies of the default
  colours. That is the reason today's colours don't follow anything.

**Rejected alternatives:**
- **Hand-editing the `.tres` with more variations.** It can't be customised at runtime, and it
  keeps two sources of truth: the `.tres` and the colours in code.
- **Setting a built theme on the root `Window.theme`.** It works at runtime, but the Godot
  editor would keep previewing the stale `.tres`, and windows created outside the root's
  subtree would be missed.
- **Keeping colour `@export`s with a "transparent means use the theme" sentinel.** Transparent
  is a valid colour, and the sentinel would have to be explained in every inspector.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| Theme settings (`appearance/theme/*`) | Godot main thread (`Settings`) | `UiTheme` on `setting_changed` | n/a (UI only) |
| Built theme, merged into the project theme | Godot main thread (`UiTheme`) | Every Control through theme lookup | n/a (UI only) |

There is no engine or audio-thread involvement.

## Data and protocol changes

No OSC changes.

**New setting type.** `Settings.Type.COLOR`:
- Stored in `config.json` as an `"#rrggbb"` string, since the store is JSON.
- `_coerce` accepts a `Color` or a string. IF `Color.html_is_valid(value)` is false, it warns and
  returns the default (REQ-003).
- `SettingRow._build_widget` creates a `ColorPickerButton` with `edit_alpha = false`. Its
  `color_changed` signal calls `_on_edited`.
- `get_current_value` and `_apply_value_to_widget` convert with `Color.to_html(false)` and
  `Color.html()`.

**New settings.** All are in `CATEGORY_APPEARANCE`, sub-category `"Theme"`:

| Key | Type | Default | Range |
|---|---|---|---|
| `appearance/theme/main_color` | COLOR | `#2b2b2b` | the palette clamps HSV value to ≤ 0.35 (REQ-022) |
| `appearance/theme/accent_primary` | COLOR | `#624d99` (current `UiColors.PRIMARY`) | |
| `appearance/theme/accent_secondary` | COLOR | `#36d99e` (current `PRIMARY_ALT`) | |
| `appearance/theme/record_color` | COLOR | `#d43c3c` | |
| `appearance/theme/solo_color` | COLOR | `#ffb13b` (current `SOLO_COLOR`) | |
| `appearance/theme/mute_color` | COLOR | `#5c6670` | |
| `appearance/theme/corner_radius` | INT | 2 | 0–4 |
| `appearance/theme/spacing` | INT | 2 | 1–4 (base unit, px) |

`Settings.reset_theme()` resets every key with the `appearance/theme/` prefix, following the
`reset_shortcuts` pattern (REQ-021).

**Palette roles.** `ThemePalette` derives these from the settings. The colour arithmetic is
`Color.darkened` / `lightened`. Defaults are in brackets.

| Role | Derivation | Used by |
|---|---|---|
| `app_bg` | main.darkened(0.6) [≈ #111] | clear colour, gaps between sections |
| `section` | main | `SectionPanel` |
| `section_header` | main.darkened(0.15) | `SectionHeader` (dock and frame title bars) |
| `card` | main.lightened(0.05) | `DeviceCard` body |
| `card_header` | main.lightened(0.10) | `DeviceCardHeader` |
| `well` | main.darkened(0.35) | `Well`, `XYSlider`/`EnvelopeControl` bg, `LineEdit`/`TextEdit`/`SpinBox` field |
| `nest_overlay` | `Color(0, 0, 0, 0.15)` | default `Panel` / `PanelContainer` |
| `floating` | main.darkened(0.45), alpha 0.96 | `Floating`, popups, tooltips |
| `border` | main.lightened(0.12) | card, input and floating borders |
| `border_selected` | `Color(0.6, 0.6, 0.6)`, fixed and neutral (REQ-012) | all selection borders |
| `control_bg` / `control_hover` | main.lightened(0.08) / (0.14) | buttons, knob body, slider track |
| `text` / `text_dim` / `text_disabled` | 0.875 / 0.6 / 0.875 at α 0.5 | fonts |
| `editor_bg` | = `app_bg` | arranger, clip editor and device graph backgrounds |
| `grid_line` | `Color(1, 1, 1, 0.06)` | editor grids |
| `handle` | `Color.WHITE_SMOKE` | slider, fader and envelope handles |
| `accent_primary`, `accent_secondary` | the settings | REQ-013, REQ-014 |
| `record`, `solo`, `mute` | the settings | REQ-015 |
| `meter_warn`, `meter_clip` | fixed `UiColors` values (REQ-016) | meters |
| `unit` | the spacing setting | separations and margins |
| `radius` | the corner radius setting | every generated stylebox |

`ThemeBuilder` writes every role as a colour of the custom type `Sonara`
(`Sonara/colors/accent_primary`, …), and `unit` and `radius` as constants. Code that isn't a
themed control reads them through `UiColors.role(&"accent_primary")`, which reads
`ThemeDB.get_project_theme()`.

**Generated theme content.**
- **Defaults:**
  - The font is Open Sans SemiBold, extracted from the current `.tres` to
    `assets/fonts/OpenSans-SemiBold.woff2`, so the look doesn't change.
  - Every type's font size is 14 (REQ-025), except `HeaderSmall`/`HeaderMedium`/`HeaderLarge`
    at 20, 24 and 28.
- **Default Godot types:**
  - `Panel` and `PanelContainer` use `nest_overlay`.
  - `Button`, `MenuButton`, `OptionButton` and `MenuBar`: normal, hover and disabled use
    `control_bg` / `control_hover`, and pressed uses `accent_primary`.
  - `LineEdit`, `TextEdit` and `SpinBox` use `well`.
  - `PopupMenu`, `PopupPanel` and `TooltipPanel` use `floating`.
  - Also styled: `TabBar` / `TabContainer`, `ItemList` / `Tree` (selected = `accent_primary` at
    α 0.35), scrollbars, and `HSlider` / `VSlider`.
  - `BoxContainer`, `HBoxContainer`, `VBoxContainer`, `GridContainer` and the `FlowContainer`s
    get a separation of `unit`.
  - `SplitContainer` separation is `2·unit`.
  - `MarginContainer` margins are 0.
  - Everything else is reproduced from the item audit (T-001) or left to Godot's defaults.
- **Variations:**

  | Variation | Base type | Look |
  |---|---|---|
  | `SectionPanel` | PanelContainer | `section`, content margin `2·unit` |
  | `SectionHeader` | PanelContainer | `section_header`, margin `unit` |
  | `SectionStack` | VBoxContainer | separation `2·unit` |
  | `AppRoot` | MarginContainer | margins `2·unit` |
  | `DeviceCard` | PanelContainer | `card`, 1 px `border`, margin `unit` |
  | `DeviceCardSelected` | DeviceCard | border `border_selected` |
  | `DeviceCardHeader` | PanelContainer | `card_header`, margin `unit` |
  | `Well` | PanelContainer | `well`, margin `unit` |
  | `Floating` | PanelContainer | `floating`, 1 px `border` |
  | `ContextMenu` | PopupPanel | `floating`, 1 px `border` |
  | `ContextMenuList` | PopupMenu | `floating`, 1 px `border` |
  | `FlatButton`, `FlatMenuButton` | as today | |
  | `RecordButton`, `SoloButton`, `MuteButton` | Button | pressed bg = `record` / `solo` / `mute`; pressed font is dark or light by `Utils.contrasting_text_color` |
  | `HeaderSmall`/`Medium`/`Large` | Label | font sizes 20, 24, 28 |

  `PrimaryPanel` and `DarkPanel` are removed. Their users move to `SectionPanel` or
  `SectionHeader`.
- **Component types:** `RotaryKnob`, `Fader`, `VolumeSlider`, `HorSlider`, `HDualSlider`,
  `Meter`, `LevelMeter`, `Volumeter`, `LightButton`, `SegmentedControl`, `XYSlider`,
  `EnvelopeControl` and `Ruler`.
  - Each has one colour item per property in the Context table, named without the `_color`
    suffix (e.g. `Fader/colors/fill`).
  - Each item is filled from a role: fills, arcs and selected segments use `accent_primary`;
    `HDualSlider.alt_fill` and `Meter`'s alternate fill use `accent_secondary`; tracks use
    `control_bg`; backgrounds use `well`; handles use `handle`; meter low uses
    `accent_primary`, and warn and clip use the fixed values.

**App background.**
- `UiTheme` calls `RenderingServer.set_default_clear_color(palette.app_bg)`.
- `project.godot`'s `default_clear_color` is set to the default `app_bg`, so the splash screen
  and the editor match (REQ-004).

## File-by-file change list

| File | Change |
|---|---|
| `Godot/core/theme/ThemePalette.gd` (new) | `class_name ThemePalette extends RefCounted`. `static func from_settings(values: Dictionary) -> ThemePalette`. It holds the role colours, `unit` and `radius`; clamps the main colour (REQ-022); and falls back per key (REQ-003). |
| `Godot/core/theme/ThemeBuilder.gd` (new) | `class_name ThemeBuilder`. `static func build(p: ThemePalette) -> Theme` creates every item listed above, with helpers `_box(bg, border, margin)` and `_button_styles(...)`. |
| `Godot/core/theme/UiTheme.gd` (new autoload `UiTheme`, after `Settings`) | Builds from `Settings` in `_ready` and merges into the project theme. It sets the clear colour and listens to `Settings.setting_changed` for `appearance/theme/` keys, coalescing to one rebuild per frame (`call_deferred` and a dirty flag). It also exposes `palette` and the signal `theme_applied`. |
| `Godot/core/theme/build_theme_resource.gd` (new) | `extends SceneTree`. Writes `ThemeBuilder.build(ThemePalette.from_settings({}))` to `res://assets/Sonara_Theme.tres` with the same UID. |
| `Godot/assets/Sonara_Theme.tres` | Regenerated by the script above (generated output). |
| `Godot/assets/fonts/OpenSans-SemiBold.woff2` (new) | Extracted from the current embedded `FontFile_j1xew` (T-001). |
| `Godot/project.godot` | Register the `UiTheme` autoload after `Settings`. Set `default_clear_color` to the default `app_bg`. |
| `Godot/core/UiColors.gd` | Remove `PRIMARY`, `PRIMARY_ALT`, `TRACK_BG` and `HANDLE`. Keep `METER_WARN`, `METER_CLIP` and `METER_HOLD` as the fixed values the builder uses. Add `static func role(name: StringName) -> Color`. |
| `Godot/settings/Settings.gd` | Add `Type.COLOR` and its `_coerce` branch. Register the eight `appearance/theme/*` settings. Add `reset_theme()`. |
| `Godot/settings/SettingRow.gd` | COLOR widget: build, read, apply and edit (as in Data). |
| `Godot/settings/SettingsDialog.gd` | Add a "Reset theme" button when the category is Appearance, following `_add_reset_shortcuts_button`. |
| `Godot/editor/Editor.tscn` | Root uses `AppRoot`. The `VBoxContainer` uses `SectionStack`. `Top` is wrapped in a `Header` PanelContainer (`SectionPanel`). `Primary`, `Secondary`, `Inspector`, `BrowserPanel` and `InfoPanel` use `SectionPanel`. Remove the separation, margin and stylebox overrides that the theme now provides. |
| `Godot/ai/ui/AssistantPanel.tscn` | Root uses `SectionPanel`. |
| `Godot/editor/docks/DockPanel.gd`, `Godot/devices/frame/DeviceFrame.gd` | Use `SectionHeader` instead of `"DarkPanel"`. |
| `Godot/devices/device_lane/DevicePanel.gd` + `.tscn` | The root uses `DeviceCard` and `TopHeader` uses `DeviceCardHeader`. Selection swaps to `DeviceCardSelected`. Remove `BORDER_COLOR*`, `_panel_style` and the scene styleboxes. |
| `Godot/devices/compact/CompactDevicePanel.gd` + `.tscn` | The root becomes a `PanelContainer` (`DeviceCard`) wrapping a VBox. `Header` uses `DeviceCardHeader`. Node references switch to unique names (`%Header`, `%Parameters`). Selection swaps the variation on the root. Remove `BORDER_COLOR_SELECTED`, `_header_style` and the scene styleboxes. |
| `Godot/mixer/device_list/ChannelDeviceList.tscn` | The panel uses `Well`. Remove the scene stylebox. |
| `Godot/mixer/MixerChannel.gd` + `.tscn` | Remove the `border_color*` exports. Read `border` / `border_selected` from `Sonara` on theme change. The arm, solo and mute toggles use `RecordButton`, `SoloButton` and `MuteButton`; remove their scene styleboxes and colour overrides. Remove the colour literals in the scene that only repeat the default roles. |
| `Godot/arranger/tracklist/TrackItem.gd` + `.tscn` | The header stylebox keeps the track tint. When selected, it adds a 1 px `border_selected` border (REQ-012). The arm, solo and mute toggles use the status variations. |
| `Godot/clip_editor/tracklist/ClipEditorTrackListItem.gd` | `SOLO_COLOR` is replaced by `UiColors.role(&"solo")`, refreshed on theme change. The selected border uses `border_selected` with the 1 px card border width. |
| The 12 component scripts in the Context table | Each colour `@export` becomes a non-exported property: the setter calls `add_theme_color_override`, the getter returns the cached value. Add `_notification(NOTIFICATION_THEME_CHANGED)`, which refreshes the cache and calls `queue_redraw()`. Keep the property names, so callers don't change. |
| `Godot/components/ValueTooltip.gd`, `LabelOverlay.gd` | Use the `Floating` variation instead of their own stylebox (the plain `ValueTooltip` mode keeps an empty one). |
| `Godot/components/Ruler.gd`, `RealTimeRuler.gd`, `BaseRuler.gd` | Cache the `Ruler` items on theme change instead of reading them in `_draw`. |
| Scenes that set the old colour exports (grep `knob_color\|fill_color\|value_arc_color\|bg_color\|…` in `*.tscn`) | Delete values that only repeat a role. Keep deliberate per-instance looks as `theme_override_colors/<item>`. |
| `Godot/devices/builtin/**` | Accent literals become `UiColors.role(&"accent_primary"/"accent_secondary")` (cached on theme change in `DeviceView`s). Any remaining literal carries a `# theme-exempt: <reason>` comment (REQ-019). |
| `docs/subsystems/godot-ui-components.md` | Rewrite §5 "One visual system": roles, variations, spacing and the component colour pattern. Update the `UiColors` row in Shared pieces. |
| `docs/subsystems/godot-config-system.md` | Document the COLOR setting type and the `appearance/theme/*` keys. |
| `docs/adr/0018-theme-generated-from-settings.md` (new) | Records the decision and the rejected alternatives. |
| `Godot/tests/test_theme_palette.gd`, `test_theme_builder.gd`, `test_theme_live.gd`, `test_theme_usage.gd`, `test_theme_literals.gd`, `test_theme_resource_fresh.gd` (new) | See the test plan. |
| `Godot/tests/test_settings_registry.gd` | Add COLOR coercion cases. |
| `Godot/components/gallery/ComponentGallery.tscn` | Remove colour overrides, so it shows the theme defaults. |
| `TODO.md` | Add a backlog entry. |

## Migration and compatibility

- **`config.json`:** gains new keys only. A missing key reads as its default, and an invalid one
  falls back with a warning.
- **Projects (`.sonara`):** not affected.
- **Scenes:** the change removes baked default colours. The look changes on purpose, which is
  the point of the spec.
- **Code:** any external code that set the old exports keeps working, because the property names
  stay.
- **Fonts:** default sizes go from 16 to 14, so a few fixed-size layouts (header labels, tight
  mixer rows) may need adjusting. These are found during the visual pass (T-023).

## Test plan

All the new tests extend `TestBase` and run with
`godot --headless --path Godot -s tests/<script>.gd -- --test` or `Godot/tests/run_all.sh theme`.

- **`test_theme_palette.gd`:**
  - default roles
  - the main colour clamp (`#c0c0c0` → value 0.35, same hue and saturation)
  - invalid colour and out-of-range radius fall back to defaults (REQ-003, REQ-022)
  - the app background's RGB spread is ≤ 0.01 at defaults (REQ-004)
- **`test_theme_builder.gd`:**
  - every variation exists with the right base type
  - radius 0, 2 and 4 applied to all generated `StyleBoxFlat`s
  - margins and separations at unit 1, 2 and 4
  - the nest overlay is black with α in (0, 0.25]
  - font sizes are 14 except the headers
  - button pressed uses the accent, and the status buttons use their colours
  - covers REQ-001, 008, 010, 011, 013 (button), 015 (styles), 025
- **`test_theme_live.gd`:**
  - `Settings.set_value("appearance/theme/accent_primary", …)` updates, after one frame, a
    `RotaryKnob`'s and a `Fader`'s resolved colours
  - an explicit `value_arc_color` survives a change
  - a `TrackItem`'s track colour is unchanged
  - ten `set_value` calls in one frame cause exactly one rebuild (`theme_applied` emitted once)
  - `reset_theme` restores every key
  - covers REQ-002, 017, 018, 021 and the coalescing rule from the performance requirement
- **`test_theme_usage.gd`:**
  - instantiates `editor/Editor.tscn` and checks the section variations on the header, Primary,
    Secondary, BrowserPanel, AssistantPanel and InfoPanel
  - `DevicePanel` and `CompactDevicePanel` both resolve `DeviceCard`
  - the `ChannelDeviceList` panel and the `XYSlider`/`EnvelopeControl` backgrounds use the
    well colour
  - `ValueTooltip`, `LabelOverlay` and `ContextMenu` use the floating style
  - selecting one of each selectable item gives the same border colour
  - the arm, solo and mute toggles in `TrackItem` and `MixerChannel` show their colours when
    pressed
  - covers REQ-005, 006, 007, 009, 012, 013, 014, 015
- **`test_theme_literals.gd`:** scans `devices/builtin/**/*.gd` and `*.tscn` for `Color(` or
  `Color("#` without `theme-exempt` (REQ-019).
- **`test_theme_resource_fresh.gd`:** builds the defaults and compares them, item by item, with
  the loaded `Sonara_Theme.tres` (REQ-023).
- **Existing tests:** run the full `Godot/tests/run_all.sh`, because `test_compact_device_panel.gd`,
  `test_value_controls.gd`, `test_level_meter.gd` and the mixer tests touch the restyled scenes.
- **Live:**
  - take screenshots with default settings: the whole editor, a mixer strip with devices, the
    device lane, and a context menu
  - change each theme setting in Settings and watch it apply, then Cancel and confirm the
    revert, then restart and confirm it persisted
  - open `Editor.tscn` and `ComponentGallery.tscn` in the Godot editor (REQ-020, REQ-023)

## Risks

| Risk | Mitigation |
|---|---|
| `Theme.merge_with` emits `changed` per item, so a rebuild is slow (seconds) | Accepted: there is no time budget. Rebuilds are coalesced to one per frame, so dragging a colour picker never queues a backlog. If dragging feels too sluggish, apply colour pickers on release instead. |
| Dropping the 6,800-line copy silently loses a deliberate customisation (scrollbar arrows hidden with an empty texture, `SplitContainer` grabbers, `CheckBox` icons) | T-001 audits every item that differs from `ThemeDB.get_default_theme()` and lists it as kept or dropped before the builder is written. |
| The 16 → 14 px font change breaks fixed-size layouts | Visual pass task with screenshots of every main view. Layouts are fixed in the same task. |
| Per-instance colour overrides no longer appear in the inspector (custom theme items aren't listed for script classes) | Few should remain after the sweep. Document the `theme_override_colors/<item>` form in the components guide. |
| Device views with heavy custom drawing (133 literals in `devices/builtin`) take long to sweep | Split into T-018 (instruments) and T-019 (effects); `theme-exempt` stays available for genuinely fixed colours (e.g. the spectrum gradient). |

## Open questions

None.

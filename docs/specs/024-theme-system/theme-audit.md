# Theme audit (T-001)

Every item in `Godot/assets/Sonara_Theme.tres` that differs from `ThemeDB.get_default_theme()`,
produced by a throwaway headless script (315 lines of output, 264 differing items). The verdict
says what `ThemeBuilder` does with it. Roles refer to the palette table in [design.md](./design.md).

## Findings that change the plan

- **The embedded font is WOFF2, not TTF.** `FontFile_j1xew` stores `wOF2` data (46,392 bytes).
  It was saved unchanged as `Godot/assets/fonts/OpenSans-SemiBold.woff2`, which Godot loads
  natively (`font_name == "Open Sans SemiBold"`). The design's `.ttf` name is therefore `.woff2`.
- **Items that look different but aren't a customisation.** All `DPITexture` icons (checkboxes,
  arrows, file dialog, colour picker, graph edit, …) and the "focus" styleboxes are the default
  theme's own resources, compared by identity or at a different border width. They are **dropped**:
  the builder doesn't set them, so Godot's defaults apply.
- **Focus style:** the file's focus styleboxes have border width 0 (default: 2). Godot's default
  focus ring is hidden by this on purpose, so the builder sets `focus` to an empty box on
  `Button`, `MenuButton`, `OptionButton`, `LineEdit`, `TextEdit`, `ItemList`, `Tree`, `Label` and
  the other types listed below.

## Verdicts

| Item(s) | Today | Verdict |
|---|---|---|
| `default_font` | Inter variable font; no control type uses it | **drop**: default font is Open Sans SemiBold |
| `default_font_size` | 14 | **keep**, role `font size 14` (REQ-025) |
| `*/fonts/font` on every type | Open Sans SemiBold | **keep** via `default_font` only (no per-type copies) |
| `*/font_sizes/font_size = 16` (`Label`, `TooltipLabel`, `GraphNodeTitleLabel`, …) | 16 | **drop**: 14 from the default (REQ-025) |
| `HeaderSmall/Medium/Large` font size | 20 / 24 / 28 | **keep** (variations of `Label`) |
| `RichTextLabel` `normal_font`, `mono_font` | the Open Sans font | **drop**: default font |
| `RichTextLabel` `bold_font`, `bold_italics_font`, `italics_font` | `FontVariation` (embolden 1.2, skew 0.2) of Open Sans | **keep**: built from the extracted font |
| `Button`, `MenuButton`, `MenuBar`, `ColorPickerButton`, `Tree` `button_*`, `SpinBox` arrows, `TabBar` `button_*`, `ColorPicker` | translucent greys + blue pressed (`1e335c`) | **keep**, role `control_bg` / `control_hover`; pressed = `accent_primary` |
| `Button` `font_color`, `font_disabled_color`, `font_pressed_color` | 0.67 / 0.56 α0.5 / 0.80 | **keep**, roles `text`, `text_disabled`, `text_bright` (hover, focus and pressed) |
| `Panel/panel` | `0d0d0d` α0.5, radius 3 | **keep**, role `nest_overlay` |
| `PanelContainer/panel` | `20202a` α0.35 (the blue tint), margins 3/2 | **keep**, role `nest_overlay`, margins 0 (REQ-004, REQ-008) |
| `PopupPanel/panel` | `262626` α0.75, 1 px border, radius 0 | **keep**, role `floating` |
| `PopupMenu/panel` | `232430`, 2 px border | **keep**, role `floating` |
| `PopupMenu` separators (`StyleBoxLine`, `labeled_separator_*`) | grey 0.5, margin 4 | **keep**, role `border`, margin `2·unit` |
| `PopupMenu` constants (`h_separation 4`, `v_separation 4`, `indent 10`, `item_*_padding 2`) | as listed | **keep**, scaled by `unit` |
| `PopupMenu` colours | 0.875 text, 0.4 disabled | **keep**, roles `text`, `text_disabled` |
| `ContextMenu` (PopupPanel) / `ContextMenuList` (PopupMenu) | `161616` α0.5, 2 px border `252525`, radius 2 | **keep**, role `floating` + `border` |
| `PrimaryPanel` | `2b2b2b`, 2 px border `131419`, radius 4, margins 6/4 | **drop**: replaced by `SectionPanel` |
| `DarkPanel` | used in code but **not defined** | **drop**: replaced by `SectionHeader` |
| `FlatButton`, `FlatMenuButton` | empty normal/hover/disabled, pressed `StyleBoxFlat` | **keep** (variations of `Button` / `MenuButton`) |
| `Ruler` colours (`bar_line`, `beat_line`, `start_arrow`, `subdivision_line`) and `normal` | `1b1b1b` | **keep**: custom type `Ruler`, `normal` = `editor_bg` |
| `HSeparator`, `VSeparator` `separator` | `StyleBoxLine` grey 0.5, margins 4 | **keep**, role `border` |
| `HSplitContainer`, `VSplitContainer`, `SplitContainer` | separation 12, `minimum_grab_thickness 6`, `autohide 1`, empty `split_bar_background`, grabbers hidden | **keep**: separation `2·unit` per the design, rest as today; grabber icons **drop** (default) |
| `BoxContainer`, `HBoxContainer`, `VBoxContainer` separation | 4 | **keep**, `unit` (REQ-010) |
| `MarginContainer` margins | 0 | **keep** |
| `GraphNodeTitleLabel`, `TooltipLabel` | copies of default with size 16 | **drop** |
| `Label` `focus` stylebox, `normal` empty | focus border width 0 | **keep** (`StyleBoxEmpty` both) |
| `AcceptDialog/panel`, `buttons_separation 10` | `StyleBoxFlat_s1na5` margins 8, bg 0.25 | **keep**, role `floating`, margins `4·unit` |
| `HScrollBar` / `VScrollBar` arrows (`increment*`, `decrement*`) | empty `ImageTexture` (arrows hidden) | **keep**: empty `ImageTexture` |
| `SpinBox` `updown` | empty `ImageTexture` (native up/down hidden) | **keep** |
| `RichTextLabel` `horizontal_rule` | 1×1 `ImageTexture` | **keep** |
| `HSlider` / `VSlider` grabbers and ticks | default `DPITexture` copies | **drop** |
| `CheckBox`, `CheckButton`, `PopupMenu`, `Tree` check icons | default copies | **drop** |
| `TabBar`, `TabContainer` icons | default copies | **drop** |
| `FileDialog`, `GraphEdit`, `GraphNode`, `GraphFrame`, `CodeEdit`, `FoldableContainer`, `Window`, `Icons`, `ColorPicker*` icons | default copies | **drop** |
| `Window` `title_font`, `close*` | copies | **drop** |
| `Icons/close` | default `DPITexture` copy | **drop** (no code or scene uses the `Icons` type) |
| `ProgressBar`, `ItemList`, `LinkButton`, `Tree`, `TextEdit`, `LineEdit`, `OptionButton`, `CheckBox`, `CheckButton`, `CodeEdit` fonts | the Open Sans font | **drop**: `default_font` |
| `ItemList`, `Tree` `cursor`, `cursor_unfocused`, `focus` | border width 0 | **keep** as empty boxes (selection is `accent_primary` α0.35 per the design) |
| `ItemList` / `Tree` / `TextEdit` / `LineEdit` / `CheckBox` / `CheckButton` / `CodeEdit` / `GraphEdit` / `GraphNode` / `HScrollBar` / `VScrollBar` / `OptionButton` / `ColorPresetButton` / `ColorPicker` `focus`-like boxes | border width 0 | **keep** as empty boxes where the type is in the builder, otherwise **drop** |

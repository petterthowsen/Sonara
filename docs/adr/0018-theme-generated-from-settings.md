# 0018 — Theme generated from settings

Status: accepted.

## Context

`Sonara_Theme.tres` was a 6,800-line copy of Godot's default theme with edits. Panels, cards and
buttons each carried their own styleboxes and colours in scenes. Custom-drawn controls had colour
`@export`s whose defaults were baked into every scene that used them. Nothing could change the
look, and the blue tint came from a clear colour plus a translucent default panel.

## Decision

- **Build the theme in code from eight settings**, the way Godot's own editor does. `ThemePalette`
  (pure function) derives named roles, `ThemeBuilder` produces the `Theme`, and the `UiTheme`
  autoload merges it into the project theme and rebuilds once per frame when a setting changes.
  Theme lookups resolve on every call, so a change reaches every Control and Window, including
  device windows, with no per-view wiring.
- **`Sonara_Theme.tres` is generated output** (`core/theme/build_theme_resource.gd`), so the Godot
  editor previews the default look. `test_theme_resource_fresh.gd` fails if it drifts.
- **Scenes use type variations** (`SectionPanel`, `DeviceCard`, `Well`, `Floating`, status
  buttons) and never carry colours for what the theme provides.
- **Custom-drawn controls get their own theme types.** Their colour properties are backed by
  per-instance theme overrides (`components/ThemedColors.gd`) and cached on
  `NOTIFICATION_THEME_CHANGED`.
- **Selection is one neutral border** (`border_selected`) on every selectable item.
- **Meter warn and clip colours are fixed**, so the accent can never make a loud signal look safe.

## Rejected alternatives

- **Hand-editing the `.tres` with more variations.** It cannot be customised at runtime and keeps
  two sources of truth.
- **Setting a built theme on the root `Window.theme`.** The Godot editor would keep previewing the
  stale `.tres`, and windows outside the root's subtree would be missed.
- **Keeping colour `@export`s with a "transparent means use the theme" sentinel.** Transparent is a
  valid colour, and the sentinel would need explaining in every inspector.

## Consequences

- Scenes lose baked colours, so the look changes on purpose (for example, mixer meters follow the
  accent instead of yellow-green).
- Per-instance colours no longer show in the inspector. Use `theme_override_colors/<item>`.
- Rebuilds are not free (`Theme.merge_with` notifies per item), hence the one-per-frame coalescing.

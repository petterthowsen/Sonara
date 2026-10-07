# Theme system — Requirements

## Problem

The UI's look comes from a hand-edited copy of Godot's default theme. On top of it sit about
600 colour literals and 22 scripts that build their own styleboxes. Panels, borders, padding and
corner radii differ from view to view. The selection border, solo colour and accent are each
defined in several places with different values. The background behind the main sections has an
unintended blue tint. Nothing is adjustable: a user can't change the accent, the main colour,
roundness or spacing, and a developer changing the look has to hunt through scenes and scripts.

## Scope

| | |
|---|---|
| Subsystem | Godot |
| Touches real-time audio thread | no |
| Adds or changes an OSC message | no |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | yes: new `appearance/theme/*` keys in `config.json`. They are new keys, so no migration is needed; a missing key reads as its default. |

## Terms

- **Main colour:** the single colour panels are derived from.
- **Section:** a top-level area of the editor window: the header (menu bar and transport), the
  arranger, the mixer, the device lane, the browser dock, the AI assistant dock and the help bar.
- **Device card:** the frame around one device: a device panel in the device lane, or a compact
  device panel in a mixer strip.
- **Well:** a darkened inset area that holds other elements, such as the device list area of a
  mixer strip, the XY pad background and the envelope (ADSR) background.
- **Floating surface:** anything drawn above the layout: context menus, popup menus, tooltips,
  value tooltips and label overlays.
- **Primary / secondary accent:** the two highlight colours for active state and for
  visualisation. The first visualised element uses the primary, the second uses the secondary.
- **Status colours:** record arm, solo and mute. They are separate from the accents.

## Requirements

### Single source

#### REQ-001 — Theme derived from settings

All panel, button, border and text colours, corner radii and spacing in the editor shall derive
from one set of theme settings: the main colour, the primary and secondary accents, the record,
solo and mute colours, the corner radius and the spacing.

- **Acceptance:** a headless test builds the theme from non-default settings and checks that the
  section, device card, well, default panel and floating styles and the button pressed styles
  reflect them.
- **Example:** main colour `#303030` → the section style's background is `#303030`; corner radius
  0 → every generated stylebox has 0 px corners.

#### REQ-002 — Live update

WHEN a theme setting changes, the editor shall restyle every open view, including separate
device windows, without a restart and without reopening the project.

- **Acceptance:** live: change the primary accent in Settings, and the mixer fader fill, knob
  arcs and a pressed toggle button change at once. Headless: a test changes the setting and
  checks a component's resolved colour.

#### REQ-003 — Invalid settings fall back

IF a stored theme setting is missing or invalid (an unparsable colour, or a radius out of
range), THEN the editor shall use that setting's default and log a warning, and it shall not
fail to start.

- **Acceptance:** a headless test with a corrupt config value gets the default.

### Layout and surfaces

#### REQ-004 — App background

The area behind the sections shall be a near-black colour derived from the main colour. Between
sections it shall show only as narrow gaps that read as dark borders. With the default settings
it shall have no visible blue tint (its red, green and blue values differ by at most 0.01).

- **Acceptance:** live screenshot with default settings; a headless check of the clear colour.

#### REQ-005 — Section style

The header (menu bar and transport), arranger, mixer, device lane, browser dock, AI assistant
dock and help bar shall share one section style, with the main colour as background.

- **Acceptance:** a headless test instantiates the editor and checks that each of these nodes
  uses the section style; live screenshot.

#### REQ-006 — Device card style

Device panels in the device lane and compact device panels in mixer strips shall share one
device card style.

- **Acceptance:** a headless test checks that both resolve to the same style.

#### REQ-007 — Well style

The device list area of a mixer strip, the XY pad background, the envelope editor background and
other inset areas shall share one well style, darker than its surroundings.

- **Acceptance:** a headless test checks these nodes; live screenshot of a mixer strip.

#### REQ-008 — Nested panels darken progressively

A plain panel with no named style shall draw a translucent darkening over its parent, so each
level of nesting reads slightly darker than the one around it.

- **Acceptance:** a headless test checks that the default panel background is translucent black,
  with alpha above 0 and at most 0.25.

#### REQ-009 — Floating surface style

Context menus, popup menus, tooltips, value tooltips and label overlays shall share one floating
surface style.

- **Acceptance:** a headless test checks the context menu, the tooltip panel, `ValueTooltip` and
  `LabelOverlay`.

#### REQ-010 — Spacing

Spacing shall come from one numeric base unit, adjustable from 1 to 4 px (default 2). Sections
shall be two units apart and have two units of inner padding. Device cards and wells shall have
one unit of padding, and items inside them shall be one unit apart. So by default, sections are
4 px apart with 4 px padding, and cards and wells use 2 px.

- **Acceptance:** a headless test checks the generated margins and separations at the default
  setting and at a non-default one.

#### REQ-011 — Corner radius

Generated styles shall use a 2 px corner radius by default, adjustable from 0 to 4 px.

- **Acceptance:** covered by REQ-001's test at radius 0, 2 and 4.

### Colour roles

#### REQ-012 — Neutral selection border

A selected device panel, compact device panel, arranger track item, clip editor track item or
mixer strip shall show its selection through one neutral, light border colour. The colour is
not an accent, and it shall be the same everywhere.

- **Acceptance:** a headless test selects one of each and compares their border colours.

#### REQ-013 — Primary accent

Pressed toggle buttons, fader and slider fills, knob value arcs, the safe zone of level meters
and the first curve or fill in device visualisations shall use the primary accent.

- **Acceptance:** a headless test checks the button pressed style and the resolved colours of
  `RotaryKnob`, `Fader`, `LevelMeter` and `Meter`; live screenshot.

#### REQ-014 — Secondary accent

The second visualised element in a control or device view shall use the secondary accent. One
example is the second fill of a mixer fader.

- **Acceptance:** a headless test on the mixer strip's alternate fill colour.

#### REQ-015 — Status colours

The record-arm, solo and mute buttons in the arranger track header, mixer strip and clip editor
track list shall use their own colours when on. The defaults are red for record, yellow-orange for
solo, and a muted tone for mute that reads as "off".

- **Acceptance:** a headless test toggles each button in each of the three places and checks
  its colour.

#### REQ-016 — Fixed meter warning colours

The warn and clip colours of level meters shall stay fixed and not follow the accents.

- **Acceptance:** covered by REQ-013's meter test.

#### REQ-017 — Track colours unaffected

Track and clip colours chosen by the user shall not change when theme settings change.

- **Acceptance:** a headless test changes the primary accent and checks a track item's colour.

#### REQ-018 — Reusable components follow the theme

`RotaryKnob`, `Fader`, `VolumeSlider`, `HorSlider`, `HDualSlider`, `Meter`, `LevelMeter`,
`Volumeter`, `LightButton`, `SegmentedControl`, `XYSlider` and `EnvelopeControl` shall take their
default colours from the theme. A colour set explicitly on one instance shall still override the
theme for that instance only.

- **Acceptance:** a headless test checks each one's default against the theme, and that an
  explicit override survives a theme change.

#### REQ-019 — Builtin device views follow the theme

The views of the built-in devices (polysynth, sampler, drums, the spec 012 effects, utility)
shall draw their accent elements with the primary and secondary accents. They shall not use
hard-coded accent colours.

- **Acceptance:** after the change, no hard-coded accent colour literal remains in
  `devices/builtin/`, checked by grep against the design's literal allowlist. Live screenshot.

#### REQ-025 — One base font size

Controls shall use a 14 px base font size. Only the named header styles (`HeaderSmall`,
`HeaderMedium`, `HeaderLarge`) and explicit per-control overrides may differ.

- **Acceptance:** a headless test checks that the generated theme's default and per-type font
  sizes are 14, apart from the header styles.

### Customisation

#### REQ-020 — Appearance settings

The Settings dialog's Appearance category shall have a Theme section to edit the main colour,
the primary and secondary accents, the record, solo and mute colours, the corner radius and the
spacing. Each change shall preview live, per REQ-002, and persist across restarts.

- **Acceptance:** live: change each setting, restart, and the value is still applied.

#### REQ-021 — Reset to defaults

The Theme section shall offer one action that restores every theme setting to its default.

- **Acceptance:** a headless test calls the reset and checks every key.

#### REQ-022 — Main colour limited to dark range

WHILE light mode is not supported, the main colour setting shall accept only dark colours (HSV
value at most 0.35), so text and custom-drawn editors stay readable.

- **Acceptance:** a headless test stores a light colour; the applied main colour is clamped to
  value 0.35 with the same hue and saturation.

### Development

#### REQ-023 — Editor preview

WHEN a scene is opened in the Godot editor, it shall show the default theme. A developer shall
not need to run the app to see the default look.

- **Acceptance:** live: open `editor/Editor.tscn` and `components/gallery/ComponentGallery.tscn` in the
  Godot editor, and they match the running app with default settings.

#### REQ-024 — Documented system

The UI components guide shall describe the styles, colour roles and spacing rules, and how a new
component reads theme colours.

- **Acceptance:** `docs/subsystems/godot-ui-components.md` is updated, and an ADR records the
  decision.

## Non-functional

- **Real-time safety:** not affected; this is UI only.
- **Performance:** applying a theme change has no strict time budget; a few seconds is
  acceptable, like the Godot editor. Rapid changes, such as dragging a colour picker, shall cause
  at most one rebuild per frame and never queue a backlog. Components shall not look up theme
  colours on every draw; they cache them when the theme changes.
- **Compatibility:** existing `config.json` files load unchanged. Projects (`.sonara`) are not
  affected.

## Out of scope

- Light mode, and main colours above the REQ-022 limit. The colour roles are designed so light
  mode can come later.
- Named presets, and importing or exporting themes.
- Recolouring icons.
- UI scale and font settings, other than standardising the base font size (REQ-025).
- Redesigning clip, note and velocity visuals. They only switch to theme colours where they
  currently hard-code a selection border, text or background colour.
- Behaviour changes to any control.

## Resolved questions

- [x] **Base font size:** standardise on 14 px (REQ-025).
- [x] **Help bar:** it is its own section (REQ-005).
- [x] **Spacing setting shape:** a numeric base unit (REQ-010).

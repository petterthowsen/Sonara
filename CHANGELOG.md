# Changelog

All notable user-visible changes to Sonara are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/) with pre-release tags.

## [Unreleased]

### Added

- Arranger: new setting Appearance > Arranger > Color Clips by Track fills each clip with its track color and leaves the timeline background neutral.
- Mixer: Ctrl+scroll sets the width of all strips freely (the Narrow/Medium/Wide button follows the closest preset, and the Devices toggle is disabled while strips are that narrow), and the bottom fader height can be dragged from a grip above it (double-click resets). The per-strip right-edge drag handle is removed, and the bottom meter no longer has a larger minimum width than the big meter.
- View > Toggle Info Panel shows or hides the bottom bar with the Arrange / Mix / Edit buttons (#147).
- Mixer channel strips show the max-peak dB readout above the bottom meter too, like the big meter (#140).
- Value lanes: selected notes get handles. The top-left and top-right handles tilt the start or end of the selection's values, and the bottom-right handle compresses or expands them around their mean, with a +/- readout while dragging (#80).
- UI scale setting (Settings > Appearance > Editor): Auto or 75% to 200%, applied live to the main window and floating device windows. Auto follows the desktop scale on Wayland.
- The main window remembers its screen, position, size and maximized state between launches (position is not restored on Wayland).
- A desktop notification (and a taskbar attention request) when an audio export finishes or fails while Sonara is in the background.
- Mixer: empty space at the end of each pane (right of the left pane, left of the right pane) as a drop area for new devices.

### Changed

- Arranger: the grid lines draw above the clips instead of behind them, so they stay visible over clips filled with their track color.
- The active Arrange / Mix / Edit button is filled with the theme's primary color (#138).
- Value lanes: with notes selected, unselected stems are dimmed to 50% and painting only edits the selected stems; Alt+drag adjusts all selected notes together (#80).
- Lower CPU use when idle: the UI only redraws when something changes.
- MIDI editor: a note's pitch label is hidden when the note is too short to hold it, so zoomed-out dense passages are less cluttered (#151).
- MIDI editor: notes narrower than 14 px have no resize handle, so clicking their right edge moves the note instead of resizing it.
- The main window's minimum width is larger (1280 px) so the transport bar is no longer cut off at the smallest size.
- Grid subdivision and snapping now use different pixel thresholds for different subdivisions.

### Fixed

- Mixer: dragging the splitter no longer scrolls the right pane; its right edge (Master) stays put.
- Audition while dragging (note pitch, value lane velocity): the throttle now plays the latest value when the interval ends, so the final position always sounds.
- Value lanes: deselecting notes updates the stem highlight, and the highlight follows the stem being adjusted while you drag (#80).
- Dragging the main window by its title bar now uses the window manager, which works on Wayland.
- Piano roll and drum view: snapping now always matches the visible grid lines at every zoom level, including when bars are grouped far out. Grid lines appear at half strength instead of fading in from invisible (#118).

## [0.1.0-beta.1] - 2026-10-15

The first public beta. Linux x86_64 only.

### Added

- Initial release

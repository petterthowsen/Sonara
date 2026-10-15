# Changelog

All notable user-visible changes to Sonara are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/) with pre-release tags.

## [Unreleased]

### Added

- UI scale setting (Settings > Appearance > Editor): Auto or 75% to 200%, applied live to the main window and floating device windows. Auto follows the desktop scale on Wayland.
- The main window remembers its screen, position, size and maximized state between launches (position is not restored on Wayland).
- A desktop notification (and a taskbar attention request) when an audio export finishes or fails while Sonara is in the background.

### Changed

- Lower CPU use when idle: the UI only redraws when something changes.
- MIDI editor: a note's pitch label is hidden when the note is too short to hold it, so zoomed-out dense passages are less cluttered (#151).
- MIDI editor: notes narrower than 14 px have no resize handle, so clicking their right edge moves the note instead of resizing it.
- The main window's minimum width is larger (1280 px) so the transport bar is no longer cut off at the smallest size.
- Grid subdivision and snapping now use different pixel thresholds for different subdivisions.

### Fixed

- Dragging the main window by its title bar now uses the window manager, which works on Wayland.
- Piano roll and drum view: snapping now always matches the visible grid lines at every zoom level, including when bars are grouped far out. Grid lines appear at half strength instead of fading in from invisible (#118).

## [0.1.0-beta.1] - 2026-10-15

The first public beta. Linux x86_64 only.

### Added

- Initial release

# Changelog

All notable user-visible changes to Sonara are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/) with pre-release tags.

## [Unreleased]

## [0.1.0-beta.2] - 2026-10-16

### Added

- Key detection: a Detect button in the scale picker estimates the key of the notes in the span you are editing (from a pitch-class histogram) and shows it with a confidence; it never changes the scale by itself (#153).
- MIDI editor chord inversion: Invert chords up / down (Ctrl+Shift+Up / Down) move the lowest note of each selected chord to the top, or the highest to the bottom, in octaves (#153).
- MIDI editor Harmony menu in the tools bar: Select Voices (Top, Bottom or Voice N of every chord), Harmonize (add scale-step intervals such as a 3rd above, with a velocity offset), Insert Chords (a Roman numeral progression or preset, voiced in a range) and Insert Bassline (sustained, pulse or root-fifth pattern under the chords). They follow the scale in effect at each note, and each is one undo step (#153).
- Transfer Notes moves the selected notes to another instrument track at the same positions, and Split Voices spreads the voices of chords over the selected instrument tracks, top voice first (#153).
- Track List panel (View > Track List, docked left above the Inspector): every track in a tree with an eye toggle, color and name. Drag over the eyes to hide or show many tracks in one undo step, Shift-click to show only a track and its folders, click to select (synced with the arranger and mixer), double-click to rename, and a context menu for color, hide and enable. Visibility presets (saved with the project) store which tracks are hidden, with Add / Rename / Delete / Move, Save (also creates a preset from a Custom state) and Reset, and hotkeys Ctrl+1 to Ctrl+9 (apply preset), Ctrl+0 (show all) and rebindable Next / Previous preset actions.
- Right-clicking a dock panel's title bar or tab opens a context menu with Close.
- View > Show Left Dock / Show Right Dock check items hide or show a whole side dock, with rebindable hotkeys (default Alt+1 / Alt+2); the state is saved with the dock layout.
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

- Mixer: output routing and sends can no longer create a feedback loop through other channels (e.g. Bus 2 → Bus, then Bus → Bus 2). The output menu shows a looping target disabled with a tooltip, the send knob for such a bus is blocked, and a multi-selection route or send skips the channels it would loop. A send turned down to -inf no longer counts as a connection, so it doesn't block a route back (#117).
- Startup with a startup or command-line project no longer initializes the engine twice (and rotates its logs twice); only the project that ends up open handshakes with the engine (#92).
- Solo and mute in the arranger track list are now undoable, and drag-toggling them across several tracks or channels is one undo step instead of one per channel (#152).
- Mixer: dragging the splitter no longer scrolls the right pane; its right edge (Master) stays put.
- Audition while dragging (note pitch, value lane velocity): the throttle now plays the latest value when the interval ends, so the final position always sounds.
- Value lanes: deselecting notes updates the stem highlight, and the highlight follows the stem being adjusted while you drag (#80).
- Dragging the main window by its title bar now uses the window manager, which works on Wayland.
- Piano roll and drum view: snapping now always matches the visible grid lines at every zoom level, including when bars are grouped far out. Grid lines appear at half strength instead of fading in from invisible (#118).

## [0.1.0-beta.1] - 2026-10-15

The first public beta. Linux x86_64 only.

### Added

- Initial release

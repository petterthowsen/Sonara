# Changelog

All notable user-visible changes to Sonara are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/) with pre-release tags.

## [Unreleased]

### Added

- Device windows of a channel show the channel name with Solo/Mute toggles in the title bar, beside the device tabs. In a narrow window they wrap onto a second line within the title bar.
- Clip names follow their track: new clips are named "Track name N", numbered among that track's own clips. Moving a clip to another track, or making it unique per track, swaps the track name in the name. Names you type yourself are never changed automatically.
- New appearance setting "Mixer Strip Tint" sets how strongly Colored Mixer Strips take on the channel color (0–1, default 0.8).
- New behavior setting "Toggle Visibility Groups While Modifier Is Held": Ctrl+1, then 2, 3… combines visibility groups, and pressing a number again removes that group, until the modifier (Ctrl, or Shift/Alt/Meta if rebound) is released.

### Changed

- Track context menu: "Visible" and "Enabled" toggles sit side by side at the top (Visible replaces Hidden, inverted), every action has an icon of the same size, Delete is last, and the button labels are set in the scene.

### Fixed

- Reordering tracks in the arranger now reorders the mixer strips to match, and reordering strips in the mixer reorders the arranger tracks.
- Soloing a track inside a soloed group now plays only that track; before, the group's solo kept every other track in the group playing.
- The MIDI editor track list no longer shows hidden tracks (#166).
- Merging clips across several tracks gives each merged clip its own unique name (#164).
- SFZ instruments no longer sometimes miss their keyswitches and mapped key ranges: Godot now re-requests them from the engine when the first message is dropped while a project loads.
- Simple View: PascalCase parameter names (CloudReverb's "LateLineDecay") are split into words, so controls are grouped and labelled properly.
- SFZ Sampler: turning the device off and on again reloads its SFZ and keeps the CC values; before, it stayed silent after being re-enabled.
- The file name and Load File button of SFZ and sample devices sit above the device view instead of on a separate File tab.
- Improved drag and drop of tracks in the Arranger's TrackList.

### Added

- Layer: each layer's volume knob is a modulation target (#160).
- Device preset menu has a Reset option that returns all sound parameters to their defaults as one undo step (#161).
- Every modulator has an Amount knob (0–100 %, default 100 so existing projects sound the same) that scales its output, and another modulator can modulate it, so modulators can be chained (#156).
- Pitch Shifter effect: transposes audio ±24 semitones without changing its length, with Fine (cents), Grain (Hz or tempo-synced), Jitter, Feedback (for shimmer and rising repeats), Spread (a micro-pitch stereo doubler) and Mix. It can sit in a channel chain, in the Delay's FB FX or in a Multiband FX band.

### Changed

- The MIDI CC modulator's CC Number is a dropdown listing each controller's number and common name (#155).

### Fixed

- MIDI editor: the playhead is relative to the clip instance that is playing, so a duplicated clip shows the right position at each of its places, and it stays correct when the clip is moved, trimmed or looped while the editor is open (#163).
- Resizing several selected notes now changes every note's length by the same grid-snapped amount as the dragged note, instead of staggering them off the grid (#162).
- A Bipolar Knob modulator reads -1 to +1 with 0 in the middle of the sweep, and its value arc starts from the middle (#125).

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

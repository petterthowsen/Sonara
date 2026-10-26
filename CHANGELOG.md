# Changelog

All notable user-visible changes to Sonara are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/) with pre-release tags.

## [Unreleased]

### Added

- The Drum Machine's Synth Kit now has 13 pads on GM notes: Kick, Rimshot, Snare, Clap, Closed and Open Hat, Low/Mid/High Tom, Crash, Ride, Cowbell and Shaker (spec 056).
- New built-in drum instrument Shaker (spec 056): shaped, filtered noise for maracas and shakers, with Attack, Decay, Tone, Ring and a Grain control that adds a beads texture.
- New built-in drum instrument Rimshot (spec 056): a tick rings two tuned resonators (the 808 pair) through a high-pass and drive for the snap; with high Ring and Tone it also makes claves.
- New built-in drum instrument Cowbell (spec 056): the 808 recipe of two pulse oscillators through a resonant band-pass, with a Strike control that mixes a sharp attack into the tail.
- New built-in drum instrument Cymbal (spec 056): an 808-style metal cymbal with separately decaying low, mid and high bands, Bloom, Trash, Diffusion and a Stick transient. The defaults make a crash; Grab chokes it on note-off, and Tune, Decay and Tone reach splash, ride and china.
- New built-in drum instrument Tom (spec 056): a tuned membrane with a pitch sweep, a second membrane mode and a skin layer. Tune is the pitch of note 45, with optional Keytrack; one device covers low, mid and high toms and, with a short Decay, congas and bongos.
- The MIDI editor shows automation lanes in track mode (spec 055). The Automation toggle in the toolbar opens a pane under the note area with the focused track's lanes, lined up with the notes; the + button lists the track's lanes and adds a new one, and Ctrl+C / X / V / D and Delete act on the lane you last clicked. Open lanes and their heights are saved with the project.
- With two or more automation points selected, handles tilt the selection from either end or compress it toward its middle, in the arranger and in the MIDI editor; each drag is one undo step.
- Automation lane presets: the lane menu (arranger and MIDI editor) can save the shown lanes under a name and load, replace or delete a preset. Loading shows the preset's lanes, creates missing ones and is one undo step; device parameters are found again if the device moved.
- A track or channel created by dropping a device or sample onto the arranger or the mixer is selected right away, like one made from the add menus (#165).
- Right-click a mixer meter (the big meter or the compact one) for its options: Centered Scale draws the dB scale between the left and right bars, Show Fader turns the meter's fader on or off, and Show Fader Handle Only on Hover hides the handle until the pointer is over the meter. Each kind of meter keeps its own options for all channels; they are also under Settings > Appearance > Mixer.
- The fader inside a mixer meter is a darker shade of the accent color, so it stands apart from the meter bars; with Centered Scale it fills the scale column and the labels sit inside it.
- The clip editor has a clip strip under the ruler (spec 054). In track mode it shows the focused track's clips with their names: drag a clip to move it, drag either end to trim or resize it, double-click empty space to add a clip, and click to select, Shift+click to select a range from the last clicked clip, Ctrl/Cmd+click to toggle. With the strip focused, Ctrl+C / Ctrl+V copy and paste the selected clips, Ctrl+D duplicates them right after themselves (overwriting what is there), and Ctrl/Cmd+drag drags copies while the originals stay. Right-click opens the arranger's clip menu, so every clip action works without going back to the arranger. In clip mode it shows the bound clip's played window (the loop region for a looped clip) and its right end can be dragged to change the length or the loop length. Drags snap to the grid (Shift for free), and each gesture is one undo step; moving a clip also moves the automation under it when "automation follows clips" is on.
- A link icon marks a clip that has more than one instance, in the arranger's clip header and in the clip strip; it goes away after Make Unique.
- Every action in the clip context menu has an icon now, and Make Unique and Make Unique Per Track use a broken link.
- Dragging a device over a layer in a Layer's list for a second opens that layer, so you can drop the device inside it; the layer closes again if you let go elsewhere (#159).

- Drag the divider above a mixer strip's sends well past their smallest height and let go to turn the sends off, as the Sends toggle does; they come back at the height they had before the drag.
- The device lane slides open and shut (about 300 ms), whether from the hotkey, a double-click on a track, or a compact device. It is always as tall as its devices: dragging the divider above it no longer resizes it, and dragging it well down and letting go closes the lane.

### Changed

- The clip editor's ruler no longer shades the clips; the clip strip below it shows them.
- A new track or channel is selected as soon as it is created (#165).
- Opening the clip editor with several clips selected shows the piano roll, unless the channel has drum rows (#150).
- Compact devices in the mixer show their state in the card (#172), and the on/off light only when the device is at least 80 px wide: a disabled device is muted (background, title and border), an inactive one has a red border, and a failed or crashed plugin a red border too. The device context menu has Enabled and Active toggles.
- The mixer pan mode button shows a cuboid icon instead of the text "Stage" in Stage mode, so narrow channel strips can shrink further (#178).

### Fixed

- The Synth Kit's open hat now rings: the kit set the hat's Metal control instead of its Decay, so both hats had the same short decay.
- Clicking or dragging a note in the note editor now makes its length the length of new notes, not only resizing it.
- Dragging a track or a device over a folder or group track in the arranger tracklist no longer makes the drop line jump before or after the whole folder when the pointer is near the left edge of a child track; the line stays in the gap under the pointer (#185).
- Automation at a loop's start now applies when the loop wraps, not one audio buffer later: notes at the loop start no longer play with the loop end's value (for example a PolySynth cutoff ramp). PolySynth and CLAP plugins switch at the exact sample; other devices switch at the start of the buffer that contains the wrap.
- The mixer's sends panel keeps each page of send knobs centered between its page buttons, the last page included, and paging back lands on the previous page. A page button now hides when there is nothing more in its direction, and the knobs and buttons appear and disappear without fading.
- Notes no longer get stuck playing when you edit clips during playback. Merging clips, deleting or moving a clip, deleting, shortening or transposing a note, muting a clip, changing its loop, or rerouting its track now releases any note the playhead no longer plays (#186).
- Moving the playhead during playback onto a note that starts there no longer leaves a note effect (such as the Step Sequencer) holding that note forever: it now stops when the clip note ends.

## [0.2.0] - 2026-10-23

### Added

- Metronome (spec 053): a toggle and a settings button in the transport bar play a click on the beat while the transport is playing, with a hotkey you can bind (Toggle metronome). The popup has a step grid for the time signature at the playhead: pick a resolution and paint each step Off or level 1 to 4 (each level has its own colour); every time signature keeps its own pattern, saved with the project and covered by undo, and Reset returns it to the default. Choose the Beep or Wood sound and shape it with Tune, Decay, Tone, Level, Accent Volume and Accent Pitch. While stopped, changes play a preview click. The click follows tempo ramps, time signature changes and loops, plays after the master fader, and is never in exports. The beats-ruler toggle in the track list header now has a ruler icon.
- Stage mic setups (spec 052): the Stage listener can record with a stereo mic array instead of the plain panner: XY, Blumlein, Mid/Side, AB, ORTF or a Decca tree. Spaced arrays (AB, ORTF, Decca tree) add arrival-time differences to the direct sound and every reflection. Pan stays the default and sounds as before. Blumlein and Mid/Side use figure-8 microphones and are not mono compatible.
- Stage view rectangles, sections and snapping (spec 052): sources are drawn as rectangles with a Depth you can drag by the front and back edges. A source can be shown as a Section with a player count (1 to 64) and one person icon per player; its rectangle never gets smaller than its players need. Drags snap to 1 m and 15 degrees by default (Shift for 0.1 m and 1 degree) with a Snap toggle.
- Virtual Stage (spec 051): a new Stage pan mode places an instrument, audio or group channel in one shoebox room per project instead of panning it. Each source has an X/Y/Z position, a width and rotation for stereo sources, direct sound by distance and direction, early reflections and a shared late tail on an automatically created Stage return bus. Five room presets, editable surfaces and listener, a Has room flag for sources recorded with their own room, Full / Reflections only / Direct only output modes, a top-down Stage view, and automation of position, size and rotation. Rendering is pooled across processing threads and exports match playback.
- MIDI Send in Children mode: a checkbox beside each child lets you send to only some of the children. Children nested later send by default.
- Saturator: new Flutter and Drift controls beside Wow in the Tape group. Flutter is a fast, slightly irregular flutter and Drift a slow random pitch wander. Wow, Flutter and Drift use a curved taper, so subtle settings get most of the knob (saved Wow settings sound subtler).
- Reverb has its own panel view: a decay map (time against frequency, with Pre-Delay, early reflections that blur into the tail as Diffusion rises, the Decay EQ contour, the cuts and Freeze) whose handles you can drag to edit Decay, Decay EQ, Pre-Delay and the cuts, a live input and wet level strip underneath, and all controls and both slot tiles laid out in signal order. The Simple toggle still gives the generated view (spec 050).
- Note Editor Harmony menu: Make Legato (extend each selected note to the start of the next) and Merge Same Notes (join touching notes of the same pitch). The clip context menu in the arranger gets Make Legato, Merge Same and Split to Tracks for all notes of the selected MIDI clips. The Transfer Notes target list is now a small scrollable tree in arranger order with foldable groups that highlights the track being edited (#169).
- MIDI Send, a new note device: it forwards the notes reaching a channel to other channels in the same block, either to the channels nested under it (Children) or to a list you choose, with a Thru/Consume switch. Rows for targets that would make a MIDI loop are marked and ignored. Notes it started always end when a target is removed, the mode changes or the send is bypassed or removed.
- Group tracks can hold MIDI clips (draw, move, copy, paste, open in the MIDI editor); audio clips are refused on a group. Add a MIDI Send to the group to play its clips on the tracks inside it.
- New group record-arm choice "Record arm the group if it has a note device" for both group-arm settings.
- MIDI editor: group tracks that hold MIDI clips or have a note or instrument device now appear in the track-mode track list, and work as Transfer Notes and Split Voices sources and targets. New Harmony > Split Into Child Tracks spreads the voices of a group's clip over the group's child tracks.
- DAWproject export lists each MIDI Send and the group MIDI clips in the transfer report.
- Layer rows: right-click a layer for Duplicate Layer / Remove Layer; the row light now matches the device panel light; removing the last device of a layer removes the layer too.
- Chord has its own panel view: a keyboard of intervals around middle C. Click a key to add or remove that note from the chord; zoom shows up to three octaves and the arrows page between octaves. Enabled keys use the secondary color and light up in the primary color while notes are held.
- EQ window: a vertical line follows the mouse and shows the frequency under it with its note and cents ("440 Hz  A3 +0¢"); the piano strip is taller and has a toggle in the header. In the companion band strips, the enabled and solo toggles sit side by side, a slope box (6 to 48 dB/oct) sits next to the type box for the Low Cut and High Cut types, and the knobs show their values.
- Multiband FX shows a faint spectrum of its input behind the crossover strip, to help place the band splits.
- Knobs (`LabeledKnob`) can show the value under the knob, alone or above the caption.
- Step Sequencer: a "Pitch range" toggle switches the Pitch lane between +-24 and +-12 semitones (remembered).
- Chain has a real dry/wet Mix knob (0 = dry input, 1 = fully processed); its old "MIX" knob was the output volume and is now labeled VOL. Layer gets the same Mix knob. Both are clamped to 0–1.
- PolySynth has a Pan control for each of Oscillator 1 and 2, and a global output Pan.
- Device windows of a channel show the channel name with Solo/Mute toggles in the title bar, beside the device tabs. In a narrow window they wrap onto a second line within the title bar.
- With "Color Clips by Track" on, MIDI notes and waveforms take the track's hue, lighter on a dark clip and darker on a near-white one, instead of plain white.
- Clip names follow their track: new clips are named "Track name N", numbered among that track's own clips. Moving a clip to another track, or making it unique per track, swaps the track name in the name. Names you type yourself are never changed automatically.
- New appearance setting "Mixer Strip Tint" sets how strongly Colored Mixer Strips take on the channel color (0–1, default 0.8).
- New behavior setting "Toggle Visibility Groups While Modifier Is Held": Ctrl+1, then 2, 3… combines visibility groups, and pressing a number again removes that group, until the modifier (Ctrl, or Shift/Alt/Meta if rebound) is released.
- Layer: each layer's volume knob is a modulation target (#160).
- Device preset menu has a Reset option that returns all sound parameters to their defaults as one undo step (#161).
- Every modulator has an Amount knob (0–100 %, default 100 so existing projects sound the same) that scales its output, and another modulator can modulate it, so modulators can be chained (#156).
- Pitch Shifter effect: transposes audio ±24 semitones without changing its length, with Fine (cents), Grain (Hz or tempo-synced), Jitter, Feedback (for shimmer and rising repeats), Spread (a micro-pitch stereo doubler) and Mix. It can sit in a channel chain, in the Delay's FB FX or in a Multiband FX band.

### Changed

- Stage view: sources of hidden channels are no longer listed unless you turn on the temporary Show hidden toggle (#179), and the long always-visible tooltip over the view is gone (#180).
- Track list: Space no longer hides the selected track, so it toggles play/pause there like everywhere else (#181).
- MIDI editor: closing the project now clears its tracklist and notes (#182).
- Arranger: with the tempo lane hidden, the ruler header collapses to its minimum height and its divider is locked; the dragged height returns when the lane is shown again.
- Arranger: the key lane no longer shows the start key name twice.
- Arranger: the loop triangles on the time ruler now hang from the top edge, and every ruler row has a bottom border so the rows are easier to tell apart.
- Track list: disabled tracks get a darker row background, so they no longer look like hidden ones.
- Saturator: Tube now has its own asymmetric curve, so it sounds different from Soft without touching Bias. Bias is now ±100 % on a curved taper with a smaller, more usable range (saved Bias settings sound milder). Input now affects the dry signal too. Low Cut and High Cut are 12 dB/oct. Tape HF loss now reacts to Drive as well as the input level. The Tone knob shows its real ±9 dB range.
- Step Sequencer: steps are 20% wider and the Velocity/Chance lane is about 40% shorter.
- Mid/Side Split and L/R Split: each group stretches to the full height of the device, with its knobs centered.
- Closing a device's View (collapsing its controls) in the device lane now also hides the devices in its slots, nested slots included (PolySynth, Delay, Reverb, Mid/Side and L/R Split, Chain, Layer, Drum Machine). Opening the View brings them back exactly as they were, including their own collapsed state, and hidden devices stop streaming their meters and displays.
- Every knob, slider and parameter value in a time unit now switches dynamically between milliseconds and seconds (for example "250 ms" and "1.20 s"), like the envelope control; typed values accept an "s" or "ms" suffix.
- Clip editor, track mode: notes of several editable tracks can be selected together. A box select (also the ruler's Ctrl+drag range) and the pitch header pick the notes of every editable track, Ctrl+click on a note of another track adds it to the selection without leaving your track, and Ctrl+Alt+A selects all notes of all editable tracks. Switching tracks keeps the selection; hiding a track or turning off its pencil takes its notes out. Delete, cut, the arrow-key edits and the selection tools (quantize, flip, strum, harmonize and the rest) act on all selected notes as one undo step. Transfer Notes and Split Voices need notes of a single track. Dragging, resizing and the Alt velocity drag move the whole selection across tracks, starting from a note of any track, and Esc cancels them. Copying notes of several tracks pastes each note back onto its own track at the new position (a note whose track is no longer editable goes to your track), Ctrl+drag duplicates a multi-track selection onto each note's own track, and the length-scale handle appears for a selection across tracks. The value lanes (velocity, release and the other note values) edit the selected notes of every track in one undo step.
- Track context menu: "Visible" and "Enabled" toggles sit side by side at the top (Visible replaces Hidden, inverted), every action has an icon of the same size, Delete is last, and the button labels are set in the scene.
- Reverb: Plate is now a full Dattorro tank, with all-passes inside the decay loop and output taps spread over it, so its tail keeps getting denser instead of repeating every few hundred milliseconds. When frozen it holds a smooth, dense pad instead of two short loops. Long, bright tails keep their highs (High Mult ×1 now really decays the highs like the mids). Early reflections follow Size, are decorrelated left/right (no comb filtering in mono) and are equally loud in every algorithm. Low Cut and High Cut are 12 dB/oct, and Diffusion also shapes the plate's input diffusion.
- The MIDI CC modulator's CC Number is a dropdown listing each controller's number and common name (#155).

### Removed

- The old Spectrum Analyzer device. Projects that still contain it load without it (the device is skipped).

### Fixed

- Saturator: Mix settings between 0 and 100 % no longer comb-filter the high end (the dry signal is now phase-matched to the oversampled wet signal).
- Saturator: switching Quality back and forth quickly no longer leaves the wrong oversampling active, and rapid Type changes no longer click.
- Saturator: the Noise knob shows its real level in dBFS (it read "0 dB" when off), and the Low Cut knob follows its curved taper.
- Saturator: Dynamics no longer causes zipper noise on transients, and the DC blocker no longer moves with the sample rate.
- MIDI editor: the track list no longer shows disabled tracks (or tracks inside a disabled folder), unless the arranger is set to show disabled tracks (#171).
- MIDI editor: clicking inside a grid cell places the note in that cell again, in the piano roll and Drum View. It used to land on the next grid line when you clicked in the right half of a cell (#170).
- MIDI editor: dragging a note that sits off the grid now snaps it to the current grid; the rest of the selection moves by the same amount and keeps its spacing. Hold Shift to move freely (#170).
- Reverb: changing the Algorithm crossfades smoothly instead of clicking, and switching back to an algorithm no longer brings back its old tail. Freeze engages and releases without a click. Mix, Width, Early and Ducking glide smoothly under automation and modulation at large buffer sizes. Re-enabling a bypassed reverb starts clean instead of resuming the tail it was cut off with.
- Sampler: dragging the amp envelope in one Sampler no longer changes Attack, Decay, Sustain and Release on other Samplers whose views are open (the views shared one envelope).
- Arpeggiator: with Octaves above 1, the held notes in the extra octaves are now colored like the base octave.
- PolySynth: pressing the same key again no longer cuts off the previous note; it rings out its release while the repeat plays on a new voice.
- Plugins with many parameters (such as Vital, 900+ CLAP / 2900+ VST3) now show all of them in the Simple View. Most of the parameter list was lost on the way from the engine to the UI.
- Clicks in an embedded JUCE plugin GUI (such as Vital, CLAP and VST3) no longer land offset by the height of the device tab bar, by the scroll position, or after the window moves.
- PolySynth: the Random modulator now gives each note its own value, including notes generated by an Arpeggiator in the Note FX chain; before, every voice drew the same sequence, so arp notes on different voices shared one value.
- Reordering tracks in the arranger now reorders the mixer strips to match, and reordering strips in the mixer reorders the arranger tracks.
- Soloing a track inside a soloed group now plays only that track; before, the group's solo kept every other track in the group playing.
- The MIDI editor track list no longer shows hidden tracks (#166).
- Merging clips across several tracks gives each merged clip its own unique name (#164).
- SFZ instruments no longer sometimes miss their keyswitches and mapped key ranges: Godot now re-requests them from the engine when the first message is dropped while a project loads.
- Simple View: PascalCase parameter names (CloudReverb's "LateLineDecay") are split into words, so controls are grouped and labelled properly.
- SFZ Sampler: turning the device off and on again reloads its SFZ and keeps the CC values; before, it stayed silent after being re-enabled.
- The file name and Load File button of SFZ and sample devices sit above the device view instead of on a separate File tab.
- Improved drag and drop of tracks in the Arranger's TrackList.
- PolySynth: the Noise Color control now changes the noise sound; before, it had no effect.
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

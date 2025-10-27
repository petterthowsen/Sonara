# Project Status

## Current Task: Track-Mode for MidiEditor

### Overview
Implement track-mode for MidiEditor to enable editing multiple clips across different tracks simultaneously. When multiple clips spanning different tracks are selected, the ClipEditor should switch to track-mode with a song-relative ruler instead of clip-local positioning.

### Implementation Plan

#### Phase 0: Refactor MidiEditor Selection Architecture ✓ COMPLETED
- [x] Move selection UI and rendering logic from NoteEditor to MidiEditor
  - [x] Extract visual selection box rendering to MidiEditor._draw()
  - [x] Extract selection boundary/highlight rendering to MidiEditor._draw()
  - [x] Extract playhead rendering to MidiEditor._draw()
  - [x] Keep NoteSelection data management in NoteEditor
  - [x] MidiEditor handles all input and delegates operations to NoteEditor(s)
  - [x] NoteEditor exposes public API for MidiEditor to call
  - [x] This enables MidiEditor to orchestrate multiple layered NoteEditors in track-mode

**Changes:**
- **NoteEditor.gd**: Removed `_gui_input()`, `_unhandled_input()`, and `_draw()` overrides. Added public API methods for MidiEditor to call.
- **MidiEditor.gd**: Added `_gui_input()` with input delegation, and `_draw()` for selection/playhead rendering with coordinate transformation.
- **NoteContainer.gd**: Removed playhead drawing from `_draw()`.
- **NoteSelectionManager.gd**: Removed `draw_selection()` method.

#### Phase 1: Multi-Clip Selection in Timeline
- [x] Create ClipSelection class (similar to NoteSelection)
  - [x] Track selected ClipInstances
  - [x] Manage selection state and signals
  - [x] Support for box-select range tracking

- [x] Add multi-clip selection support in Timeline
  - [x] Click to select single clip
  - [x] Ctrl+Click to add/remove clips from selection
  - [ ] Shift+Click for range selection
  - [x] Ctrl+Click-and-drag for box-select
  - [x] Visual feedback in _draw() (selection box, clip highlights/outlines)
  - [x] Drag selected clips horizontally/vertically (multi-clip aware)

#### Phase 2: Clipboard & Edit Operations
- [x] Implement clipboard system for clips
  - [x] Data structure to hold copied/cut clip data
  - [x] Preserve clip properties (position, track, content)
  
- [x] Cut operation
  - [x] Remove selected clips and store in clipboard
  - [x] Send delete commands to audio engine
  
- [x] Copy operation
  - [x] Copy selected clips to clipboard without removing
  
- [x] Paste operation
  - [x] Insert clipboard clips at playhead/cursor position
  - [x] Handle track assignment for pasted clips
  - [x] Create new ClipInstances and send to engine
  
- [x] Duplicate operation
  - [x] Copy and immediately paste at offset position
  - [x] Or duplicate in place with slight offset
  
- [x] Keyboard shortcuts using Godot UI actions
  - [x] ui_cut for cut operation
  - [x] ui_copy for copy operation
  - [x] ui_paste for paste operation
  - [x] ui_duplicate for duplicate operation
  
- [x] Clip movement with arrow keys
  - [x] ui_left/ui_right for horizontal movement
  - [x] ui_up/ui_down for vertical movement (track changes)

#### Phase 3: Track-Mode Detection & Activation
- [ ] Detect when selection spans multiple tracks
  - [ ] Track which tracks are represented in selection
  - [ ] Trigger track-mode when count > 1
  
- [ ] ClipEditor track-mode flag/state
  - [ ] Pass track-mode boolean to ClipEditor
  - [ ] Pass selected clips data structure
  - [ ] Pass track references/IDs

#### Phase 4: Track-Mode MidiEditor
- [ ] Update Ruler for song-relative positioning
  - [ ] Switch from clip-local to project-global timeline
  - [ ] Show absolute song position instead of clip offset
  
- [ ] MidiEditor track-mode rendering
  - [ ] Display notes from multiple clips
  - [ ] Visual distinction between clips/tracks (colors, lanes)
  - [ ] Handle overlapping clips
  
- [ ] Track-mode editing behavior
  - [ ] Notes edited in correct clip context
  - [ ] Handle notes that span clip boundaries
  - [ ] Maintain clip instance references for edits

#### Phase 5: Integration & Polish
- [ ] Update UI to indicate track-mode is active
- [ ] Handle edge cases (empty selection, single track multi-clip)
- [ ] Test OSC communication for multi-clip scenarios
- [ ] Update documentation

### Working
- **Phase 0 Complete**: MidiEditor now orchestrates input and rendering
  - Input handling: MidiEditor receives all mouse/keyboard events and delegates to NoteEditor
  - Rendering: Selection box, range markers, and playhead rendered by MidiEditor._draw()
  - Coordinate transformation: Proper mapping between NoteEditor and MidiEditor spaces
  - Clipping: Selection visuals clipped to note_area (exclude VPiano)
  - Architecture ready for multi-track editing: Multiple NoteEditors can be layered and controlled

### Not Working / Blocked
- **Phase 0 requires testing** before proceeding to Phase 1:
  - [x] Test box selection (Ctrl+drag)
  - [x] Test note placement, dragging, resizing
  - [x] Test erase mode (right-click)
  - [x] Test keyboard shortcuts (copy/paste/delete/arrows)
  - [x] Test zoom and scroll behavior
  - [x] Verify playhead rendering
  - [x] Verify selection markers appear correctly
- Timeline shift+click range selection still pending implementation (Phase 1)

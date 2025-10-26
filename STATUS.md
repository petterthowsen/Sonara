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
- [ ] Create ClipSelection class (similar to NoteSelection)
  - [ ] Track selected ClipInstances
  - [ ] Manage selection state and signals
  - [ ] Support for box-select range tracking

- [ ] Add multi-clip selection support in Timeline
  - [ ] Click to select single clip
  - [ ] Ctrl+Click to add/remove clips from selection
  - [ ] Shift+Click for range selection
  - [ ] Ctrl+Click-and-drag for box-select
  - [ ] Visual feedback in _draw() (selection box, clip highlights/outlines)
  
#### Phase 2: Clipboard & Edit Operations
- [ ] Implement clipboard system for clips
  - [ ] Data structure to hold copied/cut clip data
  - [ ] Preserve clip properties (position, track, content)
  
- [ ] Cut operation
  - [ ] Remove selected clips and store in clipboard
  - [ ] Send delete commands to audio engine
  
- [ ] Copy operation
  - [ ] Copy selected clips to clipboard without removing
  
- [ ] Paste operation
  - [ ] Insert clipboard clips at playhead/cursor position
  - [ ] Handle track assignment for pasted clips
  - [ ] Create new ClipInstances and send to engine
  
- [ ] Duplicate operation
  - [ ] Copy and immediately paste at offset position
  - [ ] Or duplicate in place with slight offset
  
- [ ] Keyboard shortcuts using Godot UI actions
  - [ ] ui_cut for cut operation
  - [ ] ui_copy for copy operation
  - [ ] ui_paste for paste operation
  - [ ] ui_duplicate for duplicate operation
  
- [ ] Clip movement with arrow keys
  - [ ] ui_left/ui_right for horizontal movement
  - [ ] ui_up/ui_down for vertical movement (track changes)

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

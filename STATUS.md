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

#### Phase 3: Track-Mode Detection & Activation ✓ COMPLETED
- [x] Detect when selection spans multiple tracks
  - [x] Track which tracks are represented in selection
  - [x] Trigger track-mode when count > 1
  
- [x] ClipEditor track-mode flag/state
  - [x] Pass track-mode boolean to ClipEditor
  - [x] Pass selected clips data structure
  - [x] Pass track references/IDs

**Changes:**
- **Editor.gd**: Added `clips_selected(clips, multi_track)` signal, updated `_on_arranger_clips_selected()` to emit new signal
- **ClipEditor.gd**: Added `track_mode` flag, `selected_clips` and `selected_tracks` arrays, replaced single-clip handler with `_on_editor_clips_selected()`
- **ClipEditor.gd**: Added `_bind_track_mode()` and `_bind_clip_mode()` to handle both modes (track-mode defers to Phase 4 for full implementation)

#### Phase 4: Track-Mode MidiEditor
- [x] Update Ruler for song-relative positioning
  - [x] Switch from clip-local to project-global timeline
  - [x] Show absolute song position instead of clip offset
  
- [x] MidiEditor track-mode rendering
  - [x] Display notes from multiple clips
  - [x] Create NoteEditor instances for each clip
  - [x] Bind clips to editors with track colors
  - [x] Current track selection system (z-index, opacity)
  - [x] Track selector integration to switch active track
  - [x] Song-relative note positioning (position_offset_ticks applied to each editor)
  - [ ] Handle overlapping clips gracefully
  
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

- **Phase 3 Complete**: Track-mode detection and ClipEditor wiring
  - Multi-clip selection signal flow: Timeline → Arranger → Editor → ClipEditor
  - ClipEditor receives array of selected clips and multi_track flag
  - ClipEditor extracts unique tracks from selection
  - Mode detection: track_mode = true when clips span multiple tracks
  - Track selector populated with selected tracks in track-mode

- **Phase 4 Partial - NEEDS REDESIGN**: Song-relative ruler and multi-clip rendering
  - ✅ Ruler shows absolute song ticks (not clip-local) when track_mode = true
  - ✅ Playhead conversion skips clip offset subtraction in track-mode
  - ✅ Cursor position interpreted as song-relative in track-mode
  - ✅ Song-relative positioning: notes offset by clip.start_ticks
  - ✅ Active track system with opacity and z-index
  - ✅ Track selector integration
  
  - ❌ **CRITICAL ISSUE**: Currently only shows SELECTED clips
    - Should show ALL clips from selected tracks across entire timeline
    - Example: Track 1 has 5 clips, user selects 1 → should display all 5
    - Current approach: one NoteEditor per selected clip
    - Needed approach: one NoteEditor per TRACK, showing all that track's clips
    - Need to refactor bind_to_clips() to iterate tracks, not clips
    - Each NoteEditor needs to handle multiple clips from its track

### Not Working / Blocked
- **Phase 4 Track-Mode Architecture Issue**:
  - Current implementation shows only selected clips, not all track clips
  - Need to redesign NoteEditor/NoteContainer to handle multiple clips per track
  - Options:
    1. Single NoteEditor per track, iterate all track.clip_instances
    2. Multiple NoteEditors per track (one per clip), managed differently
    3. Virtual composite clip approach
  - This blocks full track-mode completion

- **Phase 0 testing complete** ✓
- Timeline shift+click range selection still pending implementation (Phase 1)

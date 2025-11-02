# Project Status

## AudioFileService (async decode + waveform) - ✅ COMPLETE

**Overview:** Async multi-format audio decoding and progressive waveform generation service.

**✅ Completed:**
- **Core Implementation:** Symphonia-based decoder supporting WAV/FLAC/OGG/MP3 with offline resampling
- **Waveform Cache:** Binary cache format with progressive multi-resolution levels (min/max/rms)
- **Worker Pool:** 4-thread async service with job queue and event system
- **OSC Integration:** Complete control-plane API (`/audiofile/*` routes)
- **Backward Compatibility:** Legacy WAV loading migrated to Symphonia while maintaining existing API
- **Testing:** Unit tests for service creation, cache keys, error handling, and integration framework

**🛠️ Architecture:**
- **Control Plane:** OSC messages for job submission and event streaming
- **Data Plane:** File-based waveform consumption via byte offsets
- **Worker Pool:** Non-blocking decode off main thread, never touches audio callback
- **Caching:** Smart cache keys with file metadata validation

**📋 Remaining (Godot-side):**
- Integrate Godot UI to request decode/waveform via OSC
- Implement waveform rendering from cache files using provided byte offsets
- Handle progressive level updates (coarse → fine) for smooth UX

**🔧 Dependencies Added:**
- `symphonia` (multi-format audio decoding)
- `rubato` (high-quality offline resampling)
- `bincode`, `byteorder`, `tempfile` (cache I/O)
- `dirs` (cross-platform cache directory)

**🧪 Testing:**
```bash
cargo test --lib audio_file_service  # Service and cache tests
cargo check                          # Full compilation verification
```

**🔍 Recent Diagnostics:**
- Added structured `tracing` spans in `audio_file_service.rs` and `osc/server.rs` to log cache hits, waveform-level emissions, and OSC relays. Enable with `RUST_LOG=info,engine=debug` while reproducing missing-waveform issues; Godot console should now mirror decode/waveform events.

**📚 Documentation:**
- OSC protocol updated with `/audiofile/*` routes
- Cache format specification included
- Complete API documentation in code

## Clip Audio Load Lifecycle & Playback (engine-side) - ✅ COMPLETE

**Overview:** Engine clips now perform asynchronous audio loading via AudioFileService, exposing deterministic load state updates to Godot. Audio playback correctly handles seek offsets and clip trimming.

**✅ Completed:**
- Added `ClipLoadState` metadata (`unloaded/loading/ready/failed`) plus `audio_source_path`/`waveform_cache_key` tracking
- Refactored OSC server to submit decode jobs, map `req_id` → clip, and fan-out AudioFileService events
- Engine dispatches `ClipLoadStateChanged` status messages which Godot receives as `/clip/{id}/load_state`
- Updated `OSC_PROTOCOL.md` to document the new request/response contract
- **Fixed seek offset calculation:** Playback position now correctly combines `clip_offset` (trim) + current playhead position when seeking into clips

**🐛 Gotchas & Solutions:**

1. **MP3 Resampling Artifacts (48kHz → 44.1kHz)**
   - **Problem:** MP3 decoder naturally produces 1152-frame chunks but Rubato's FFT resampler requires fixed 4096-frame input chunks
   - **Error:** `Insufficient buffer size 1152 for input channel 0, expected 4096`
   - **Solution:** Added input buffering layer in `decoder.rs` that accumulates MP3 frames until 4096-frame chunks available, then processes through resampler with proper flushing
   - **Key Changes:**
     - Increased FFT chunk size from 1024 to 4096 for spectral quality
     - Implemented `input_buffer` to batch decode chunks
     - Multi-pass flushing with zero-padding for partial final chunks
   - **Result:** Clean MP3 playback with proper time-stretching

2. **Clip Seek Offset Not Applied**
   - **Problem:** Seeking into the middle of a clip and playing would restart from the beginning of the audio file
   - **Root Cause:** Playback position initialization only applied `clip_offset` (trim from left edge) and ignored the current playhead position within the clip instance
   - **Solution:** Changed offset calculation in `processing.rs:168` from:
     ```rust
     let offset_samples = ticks_to_samples(instance.clip_offset, ...)
     ```
     to:
     ```rust
     let total_offset_ticks = instance.clip_offset + current_pos_in_instance;
     let offset_samples = ticks_to_samples(total_offset_ticks, ...)
     ```
   - **Result:** Seeking now plays from correct position while respecting clip trimming

**📋 Remaining (Godot-side):**
- Verify new data-model wiring for load states & waveform ingestion (waveforms still not visible)
- Ensure progressive waveform levels update UI once cache pages land
- Add explicit error/progress surfacing in arranger components if decode fails

**🔮 Follow-up Ideas:**
- Optionally migrate clips to stream PCM from cache files instead of storing full `Vec<f32>` in-engine (`migrate_to_cache_keys` todo)
- Add load-progress relays if UI needs finer-grained feedback (`/audiofile/progress`)


### Modifying Data and Syncing to Audio Engine

**The pattern** (object-oriented, self-synchronizing):
1. UI calls data object setter (e.g., `channel.set_volume(-6.0)`)
2. Data object updates internal state
3. Data object sends OSC message to audio engine
4. Data object emits signal (e.g., `volume_changed.emit(-6.0)`)
5. UI listens to signal and updates display

**Adding a new syncable property:**
1. Add property to data class (e.g., `Channel.gd`)
2. Add signal: `signal property_changed(value)`
3. Add setter method that sends OSC and emits signal
4. Add to `sync_to_engine()` method
5. UI connects to signal in `bind_to_channel()`

### Device Visualization Data
- Use `AudioEngineOSC.subscribe_device_data(device.osc_path(), data_type)` / `unsubscribe_device_data(...)` to toggle analyzer streams; they send `{osc_path}/data/subscribe|unsubscribe` with the target type (e.g., `"spectrum"`). Nested devices use `/channel/{id}/device/{n}/child/{n}` paths.
- Incoming `{osc_path}/data` messages emit `device_data_received(osc_path, data_type, blob)` so views can decode custom payloads; FFT analyzers also emit `device_spectrum_received(osc_path, spectrum)` with a ready-to-use `PackedFloat32Array`. Compare `osc_path` to `DeviceInstance.osc_path()`.
- Device visuals extend `DeviceView`, subscribe in `_on_view_shown()`, and must disconnect in `_on_view_hidden()` to avoid leaving the audio engine in a subscribed state when the UI hides the scene.

### Engine Log Relay
- The audio engine forwards WARN/ERROR records via `/log` with `[String level, String message]`; level is `"warn"` or `"error"`.
- `AudioEngineOSC` emits `engine_log_message(level, message)` on receipt and mirrors WARN/ERROR into the Godot output log so designers see runtime issues without tailing files.

### Audio Clip Loading & Waveforms
- Audio clips are created via `/clip/create [clip_id, "audio", name]`; when a clip has `audio_file_path` set, `Project.gd::_sync_clip_to_engine()` sends `/clip/{id}/load_audio_file [abs_path, sample_rate_hint, channels_hint]`.
- `/clip/{id}/load_state [state, req_id, source_path, cache_key, sample_rate, channels, message]` drives the Godot-side `Clip.LoadState` enum. `Project.gd` records `req_id` ↔ `clip_id` so follow-up messages can be routed.
- Metadata arrives asynchronously through `/audiofile/decode/ready [req_id, cache_key, channels, frames, sample_rate, duration_seconds]`; clips apply it via `Clip.set_audio_metadata()` and recompute content length.
- Progressive waveform levels stream through `/audiofile/waveform/level [req_id, level, block_size, num_blocks, cache_path, byte_offset, byte_len]`. `Clip.ingest_waveform_level_from_cache()` opens the cache via `WaveformCacheReader` and emits `waveform_level_updated`.
- Partial progress and failures surface with `/audiofile/progress [req_id, progress_0_1]` and `/audiofile/error [req_id, code, message]`. Always clear the stored request mapping when a load finishes or fails so retries produce fresh IDs.

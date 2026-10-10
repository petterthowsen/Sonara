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

**Modulation live values** (spec 018 Phase 9) ride the same channel with `data_type`
`"modulation"`: `ModLive` (in `devices/modulators/`) subscribes the device's stream and every
ancestor's that has modulators while any view of the device is shown, decodes the payload
(`ModLive._decode` documents the format) and pushes `mod_live_value`/`mod_live_values` to the
controls registered by `ModAssign.attach`. The arc returns to the knob's set value whenever
the stream reports nothing for the parameter. Views don't subscribe this stream themselves;
`DeviceView.show_view`/`hide_view` drive it. Only device views (Simple View and the custom panel
and window views) do today; the Parameters/CCs lists and the compact panels don't subscribe yet.
The decoder (`ModLive._decode`) walks the counted
kind 0/1 records and, for spec 033 payloads, then reads the trailing block: a `u16 ext_count`
followed by `{u8 kind, u8 len, len bytes}` records — kind 2 is a modulator's display state
(mod id, envelope stage 0 idle/1 attack/2 decay/3 sustain/4 release with 0 for non-envelope
kinds, x, value) and kind 3 a mod→mod parameter offset (mod id, param id, offset). Unknown
kinds are skipped by `len`, so old decoders survive new record types.

### Engine Log Relay
- The audio engine forwards WARN/ERROR records via `/log` with `[String level, String message]`; level is `"warn"` or `"error"`.
- `AudioEngineOSC` emits `engine_log_message(level, message)` on receipt and mirrors WARN/ERROR into the Godot output log so designers see runtime issues without tailing files.

### Audio Clip Loading & Waveforms
- Audio clips are created via `/clip/create [clip_id, "audio", name]`; when a clip has `audio_file_path` set, `Project.gd::_sync_clip_to_engine()` sends `/clip/{id}/load_audio_file [abs_path, sample_rate_hint, channels_hint]`.
- `/clip/{id}/load_state [state, req_id, source_path, cache_key, sample_rate, channels, message]` drives the Godot-side `Clip.LoadState` enum. `Project.gd` records `req_id` ↔ `clip_id` so follow-up messages can be routed.
- Metadata arrives asynchronously through `/audiofile/decode/ready [req_id, cache_key, channels, frames, sample_rate, duration_seconds, sample_count]`; `AudioSourceInfo.apply_decode_ready()` stores it and the clip recomputes its content length.
- Once the peak file is complete, `/audiofile/waveform/ready [req_id, peak_file_path]` arrives (once). `AudioSourceInfo.apply_waveform_ready()` gets the shared `WaveformData` from `WaveformRegistry`, which loads it off the main thread, then emits `waveform_ready` (re-emitted as `Clip.waveform_ready(clip)`). Saved projects don't store the cache key or path: the engine recomputes the key on load and finds the peak file as a cache hit.
- At deep zoom `WaveformView` asks for raw samples with `/audiofile/samples [req_id, cache_key, channel, start_frame, count]`; replies are `/audiofile/samples/data [req_id, channel, start_frame, blob]`. `WaveformSampleWindow` routes them by its own `wfs:` request IDs, so `Project` ignores them.
- Partial progress and failures surface with `/audiofile/progress [req_id, progress_0_1]` and `/audiofile/error [req_id, code, message]`. Always clear the stored request mapping when a load finishes or fails so retries produce fresh IDs.

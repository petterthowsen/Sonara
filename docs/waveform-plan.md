# Waveforms: peak cache v2 and shader rendering

Implementation plan for TODO.md › "5. Waveforms". It replaces the waveform cache format and the whole Godot waveform drawing path. Audio clips and the Sampler view both use the result.

## Checklist

- [x] Phase 1: Engine peak builder and cache format v2
- [x] Phase 2: Engine cache robustness and a simpler AudioFileService
- [x] Phase 3: Godot `WaveformData` loader and registry
- [x] Phase 4: `WaveformView` shader and arranger integration
- [x] Phase 5: Appearance settings
- [x] Phase 6: Sampler view, then remove the old code
- [x?] Phase 7 (optional): raw samples at deep zoom

Do the phases in order. Run `cargo test` (from `Engine/`) after each engine phase and `Godot/tests/run_all.sh` after each Godot phase. When a phase is done, mark the TODO item `[x?]`, never `[x]`.

## Decisions (already made)

- **Peaks live in source-sample space.** They are computed at the file's own sample rate, before the decoder resamples to the project rate. The cache key no longer includes the project sample rate, so changing the rate keeps every cache.
- **Per-block data:** min, max, RMS, and three band energies (low, mid, high) for the spectral colour mode.
- **Band energies are per channel,** not taken from a mono sum. Stereo files can show different colours on the left and right channels.
- **Rendering uses one shader.** It does the level choice, the min/max reduction, RMS, gain, fades, colour mode and amplitude scale per pixel column. No CPU drawing and no textures baked per zoom level.
- **Display options are appearance settings,** passed to the shader as uniforms so they change instantly.

## What exists now and why it's replaced

| File | Problem |
|---|---|
| `Engine/src/audio/io/waveform_cache.rs` | `is_cache_valid` compares the key with a filename built from the same key, so it is always true. Writes aren't atomic, so a partial file is used forever. `DefaultHasher` isn't stable across Rust versions. Values are f32, 12 bytes per block per channel. |
| `Engine/src/audio/io/audio_file_service.rs` | Holds about three copies of the PCM (`all_chunks`, `interleaved_samples`, `concatenated`). Block sizes derive from `frames / 512` and are halved with truncation, so levels don't nest. Each level is rebuilt from the raw samples. Peaks are computed at the project rate. The progress value is a fixed placeholder. |
| `Godot/support/waveform/WaveformCacheReader.gd` | Reads one `get_float()` at a time. |
| `Godot/support/waveform/Waveform.gd` | Bakes 100 px textures with `set_pixel` in GDScript, on the main thread, for every level. This is the main performance problem. RMS is loaded but never drawn. |
| `Godot/support/waveform/MultiResWaveform.gd` | Chooses the level from the whole file's block count, not the visible trimmed range. |
| `Godot/arranger/timeline/clip/MidiclipRenderer.gd` | Draws the 1-texel-per-block textures with nearest filtering at about 1.5 blocks per pixel, so peaks are skipped. It also rounds start and end to whole blocks. |
| `Godot/data/WaveformPyramid.gd` | Ingests one level per OSC message. Keeps a copy of every level both as arrays and as textures. |

## Phase 1: Engine peak builder and cache format v2

### Decoder hook

The peaks need native-rate samples. The decoder resamples inside `SymphoniaDecoder::decode_to_f32_stream` (`Engine/src/audio/io/decoder.rs`).

- Add a second callback, `on_native_chunk: &mut dyn FnMut(&[Vec<f32>])`, called with each decoded planar chunk before it enters the resampler.
- Report the source sample rate and the estimated frame count (`codec_params.n_frames`, when present) in `DecodedInfo`.
- Existing callers get a no-op closure.

### `PeakBuilder` (new, `Engine/src/audio/io/peaks.rs`)

A streaming builder, fed native chunks one at a time:

- Constant `BASE_BLOCK = 64` frames. Blocks are aligned to frame 0 of the file.
- Per channel, it accumulates for the current block: min, max, the sum of squares, and the sum of squares of three band-filtered signals.
- **Band filters:** per channel, a low-pass at 200 Hz and a high-pass at 2 kHz (2nd-order biquad each), and `mid = x - low - high`. Compute the coefficients from the source sample rate. The filters are for display only and don't need to be phase-perfect.
- When a block completes, push `min, max, mean_square, low_ms, mid_ms, high_ms` to the base level as f32. The last, partial block is averaged over its real length.
- `finish()` builds levels 1..N. Each level merges two blocks of the level below: min of the mins, max of the maxes, and the average of the mean squares (weighted by frame count for the partial tail).
- **Stop condition:** stop adding levels when a level has 1 block or fewer, or its block size exceeds 2^20.
- **Conversion at write time:** RMS = sqrt(mean square), band energy = sqrt(band mean square). Convert everything to f16. Add the `half` crate unless an f16 type is already available.

Unit tests (`mod tests` in `peaks.rs`):
- a single impulse survives at every level (its max is never averaged away)
- a partial last block
- the RMS of a constant signal
- a 100 Hz sine lands mostly in the low band and a 5 kHz sine mostly in the high band
- the level sizes nest exactly (`blocks[L+1] == ceil(blocks[L] / 2)`).

### File format v2 (`waveform_cache.rs`, rewrite)

All values little-endian.

```
Header (fixed, 64 bytes)
  magic        [u8; 8] = "SONAPK02"
  version      u16 = 2
  channels     u16
  source_sr    u32            # file's own sample rate
  frames       u64            # native frames
  base_block   u32 = 64
  levels       u16
  tex_width    u16 = 4096     # texels per row, see layout below
  src_size     u64            # source file size, for validation
  src_mtime_ns u64
  complete     u8             # written last: 1 once the whole file is valid
  reserved     (pad to 64)

Level table (levels × 16 bytes)
  num_blocks   u64
  row_offset   u32            # first texture row of this level
  rows         u32

Planes: for each channel, two planes, each (total_rows × tex_width) RGBA16F texels:
  plane A: (min, max, rms, 0)
  plane B: (low, mid, high, 0)
```

- **Layout:** all levels of one channel are stacked into one texture-shaped plane. Each level starts on a new row and is padded with zero texels to a full row.
- **Why this layout:** Godot can pass each plane's bytes straight to `Image.create_from_data(tex_width, total_rows, false, Image.FORMAT_RGBAH, bytes)` with no per-value work.
- **Size:** a 10-minute 48 kHz stereo file is about 29 MB for the whole file at 64-frame base blocks.
- **Row limit:** `total_rows` must be ≤ 16384 (the GPU texture height limit). That caps a file at about 67M base blocks, roughly 12 hours at 96 kHz. If the limit is exceeded, return an error rather than a broken file.

Write a `PeakFile::write(path, &PeakBuilder)` and a `PeakFile::read_header(path)` (used by the tests and by validation). A round-trip test writes a synthetic signal and reads back the header, the level table and a few texels.

## Phase 2: Engine cache robustness and a simpler AudioFileService

**Cache key.** Use a stable 64-bit FNV-1a over `abs_path`, `src_size`, `src_mtime_ns` and the format version. Write it inline (about 10 lines, no new dependency). The file is `<key>.swp` in the existing `get_cache_dir()` (`$XDG_CACHE_HOME/sonara/waveforms/`).

**Validation.** On a cache hit, `read_header` must pass all of these checks. Otherwise treat it as a miss and rebuild:
- magic and version match
- `complete == 1`
- `src_size` and `src_mtime_ns` match the file on disk.

**Atomic write.** Write to `<key>.<pid>.<req_id>.tmp` in the same directory, fsync it, then `rename` it to `<key>.swp`. Two requests for the same file can then race safely: both files are identical and the last rename wins. On startup, delete any `*.tmp` files older than an hour.

**`process_decode_and_waveform`:**
- **Cache hit:** decode PCM for playback as today, with no peak work. Emit `DecodeReady`, then `WaveformReady`.
- **Cache miss:** decode once, feeding native chunks to `PeakBuilder` and resampled chunks to the interleaved playback buffer. Emit `DecodeReady` as soon as the PCM is complete, then write the peak file and emit `WaveformReady`.
- Delete `all_chunks`, `concatenated` and `build_waveform_pyramid`. The interleaved playback buffer is the only full copy of the audio.
- **Progress:** send the real value, `frames_decoded / n_frames`, at most every 100 ms, when `n_frames` is known.
- Remove `min_block_size` from `submit_decode_and_waveform` and from its three callers in `osc/server.rs`.

**OSC changes.** Update `osc/server.rs`, `audio/io/audio_file_service.rs` (`AfsEvent`) and `docs/subsystems/osc-protocol.md`:

| Old | New |
|---|---|
| `/audiofile/waveform/level s:req_id i:level i:block_size h:num_blocks s:file_path h:byte_offset h:byte_len` (once per level) | `/audiofile/waveform/ready s:req_id s:peak_file_path` (once) |
| `/audiofile/waveform/start … i:min_block_size` | `/audiofile/waveform/start s:req_id s:abs_path` |

`/audiofile/decode/ready` keeps its arguments. Its `sample_rate` stays the project (playback) rate. The source rate comes from the peak file header.

Update the integration test `test_decode_and_waveform_integration` so it expects `WaveformReady` and checks that a second run is a cache hit.

## Phase 3: Godot `WaveformData` loader and registry

**`Godot/support/waveform/WaveformData.gd`** (new, `RefCounted`) holds one peak file:
- `load(path) -> bool`:
  - Read the whole file with `FileAccess.get_file_as_bytes`.
  - Parse the header and the level table with `PackedByteArray.decode_u16/u32/u64`.
  - Check magic, version and `complete`.
  - Slice each plane with `slice()` and build `ImageTexture.create_from_image(Image.create_from_data(..., FORMAT_RGBAH, ...))`.
- Exposes:
  - `channels`, `source_sample_rate`, `frames`, `base_block`, `levels`
  - `level_rows: PackedInt32Array` (row offset per level) and `level_blocks: PackedInt64Array`
  - `plane_a: Array[Texture2D]` and `plane_b: Array[Texture2D]` (one per channel)
  - `is_ready()`.
- Do the file read and the `Image` creation on `WorkerThreadPool`, and create the `ImageTexture` on the main thread with `call_deferred`. Emit `loaded` when done.

**`Godot/support/waveform/WaveformRegistry.gd`** (a static cache, not an autoload): `get_or_load(peak_path) -> WaveformData`, keyed by path and reference-counted. Clips and instances that share a file (for example after `MakeClipUniqueCommand`) share the textures.

**`Godot/data/WaveformPyramid.gd` → rename to `AudioSourceInfo.gd`.** It keeps the decode metadata it already has (channels, frames, the playback sample rate, duration). It also gains:
- `peak_path`
- `data: WaveformData`
- the signal `waveform_ready`.

`apply_waveform_ready(args)` replaces `apply_decode_ready`'s cache lookup and `apply_waveform_level`. Delete `Sonara.find_waveform_cache_file`, since the engine now sends the path.

**`Godot/data/Project.gd`.** Replace the `/audiofile/waveform/level` listener with `/audiofile/waveform/ready`. `_waveform_for_req` keeps working unchanged, returning an `AudioSourceInfo`.

**Serialisation.** `Clip.gd` serialises `waveform_cache_key` today. Keep `audio_file_path` and drop the cache key and path from saved projects: the engine recomputes the key on load, and the peak file is found again as a cache hit. Add `waveform_cache_key` to the keys that are ignored when reading old project files.

Test (`Godot/tests/test_waveform_data.gd`): write a tiny v2 file from GDScript into a temp directory (header, 2 levels, 1 channel), load it, and assert the level table, the texture sizes and one texel value (via `Image.get_pixel`).

## Phase 4: `WaveformView` shader and arranger integration

**`Godot/support/waveform/waveform.gdshader`** (`canvas_item`) and **`WaveformView.gd`** (a `Control` that draws one `draw_rect` with the shader material).

`WaveformView` properties, each setting a uniform and requesting a redraw:
- `data: WaveformData`
- `start_frame: float` (source frame at the left edge)
- `frames_per_pixel: float`
- `gain: float = 1.0`
- `fade_in_frames: float = 0`, `fade_out_frames: float = 0`, `fade_curve: float` (these hooks stay at their defaults until clip gain and fades exist)
- `channel_mode` (0 = split, 1 = mono sum)
- `style` (0 = peaks, 1 = peaks + RMS)
- `color_mode` (0 = clip colour, 1 = spectral)
- `amp_scale` (0 = linear, 1 = dB)
- `color: Color`.

Shader, per fragment:
1. **Row and channel.** From `UV.y` and `channel_mode`, find the channel row, its centre line and its half-height.
2. **Pixel range.** `x = floor(FRAGCOORD-local x)`. The pixel covers source frames `[start_frame + x·fpp, start_frame + (x+1)·fpp)`. Floor or ceil both ends to whole frames. Frame positions are absolute in the file, so the waveform never shimmers when you scroll or trim.
3. **Level choice.** Take the level `L = clamp(floor(log2(fpp / base_block)), 0, levels-1)`. Its block size is at most `fpp`, so one pixel covers 1–2 blocks (3 at the edges). Loop over those blocks, with at most 4 `texelFetch` calls per plane. The texel for block `b` of level `L` is at `(b % tex_width, level_rows[L] + b / tex_width)`.
4. **Reduce.**
   - Peaks: min of the mins, max of the maxes.
   - RMS and bands: `sqrt(mean(v²))` over the blocks.
   - Mono sum mode: combine the two channels the same way. That takes 2× the fetches, which is fine.
5. **Envelope.** Multiply by `gain × fade(frame)`, then map through `amp_scale`. The dB mode maps -60..0 dB to 0..1 and keeps the sign for min and max.
6. **Colour.**
   - Clip-colour mode: `color`.
   - Spectral mode: normalise `(low, mid, high)` by their maximum and mix it towards `color`'s luminance.
7. **Coverage.** Outline alpha is 1 inside `[min, max]`, with a one-pixel soft edge using `fwidth`. In peaks+RMS style, the RMS region `[-rms, rms]` gets the full colour and the peak region gets a lighter or more transparent version.
8. **Level choice beyond `levels-1`.** Just loop over more blocks, capped at 8 fetches. This only happens for extremely zoomed-out views of short files.
9. **Below the base resolution** (`fpp < base_block`). Draw the base level, stepped. Phase 7 replaces this with raw samples.

Declare `level_rows` as `uniform int level_rows[24]`. Pass the total level count and the texture width as uniforms.

**Arranger integration:**
- `TimelineClip.tscn`: for audio clips, add a `WaveformView` child that fills the clip body. `MidiclipRenderer.gd` goes back to MIDI only. Delete `_draw_waveform`, `_draw_chunked_waveform` and the LOD tracking, and rename the file if you like.
- `TimelineClip.gd` sets the uniforms from `GridHelper` and the `ClipInstance`, on `GridHelper.changed` and when the clip changes:
  - `frames_per_tick = source_sample_rate × 60 / (recorded_bpm × ppq)`
  - `start_frame = clip_instance.clip_offset × frames_per_tick`
  - `frames_per_pixel = ticks_per_pixel × frames_per_tick`.

  This matches the engine's constant stretch ratio (`AudioClipPlayback::calculate_stretch_factor`). Warp markers can replace it later with a piecewise mapping, passed as a small texture.
- Show the loading placeholder until `data.is_ready()`, then redraw on `waveform_ready`.

Manual check (ask the user). Load a long file (10 min or more) and a short drum loop. Zoom from fully out to the base resolution:
- no hitch on load
- transients don't blink while zooming
- no shimmer while scrolling
- trimming the left edge keeps the waveform in place.

## Phase 5: Appearance settings

Register these in `Godot/settings/Settings.gd` under `CATEGORY_APPEARANCE` with `.sub("Waveforms")`. Use `Type.CHOICE` except where noted.

| Key | Options | Default |
|---|---|---|
| `appearance/waveform_style` | Peaks, Peaks + RMS | Peaks + RMS |
| `appearance/waveform_color_mode` | Clip color, Spectral (low/mid/high) | Clip color |
| `appearance/waveform_channels` | Stereo split, Mono sum | Stereo split |
| `appearance/waveform_scale` | Linear, Logarithmic (dB) | Linear |

`WaveformView` reads these on `_ready` and listens to `Settings.setting_changed`. Only the uniforms change: nothing reloads or rebuilds. Each description says what the option looks like.

## Phase 6: Sampler view, then remove the old code

- `Godot/devices/builtin/SamplerDefaultView.gd`:
  - Replace `_draw_peaks` with a `WaveformView` placed in the `$Waveform` slot. Set `start_frame = 0` and `frames_per_pixel = frames / width`.
  - The start/end region overlay stays in `_draw` and is drawn over it.
- `Godot/data/DeviceInstance.gd`: rename `sample_waveform` to `sample_source` (`AudioSourceInfo`).
- Delete:
  - `Waveform.gd`, `MultiResWaveform.gd` and `WaveformCacheReader.gd`, with their `.uid` files
  - the `audio_waveform` and `ensure_audio_waveform` and `ingest_waveform_level_from_cache` forwarding in `Clip.gd`
  - their use in `MakeClipUniqueCommand.gd`, which now shares `AudioSourceInfo.data` through the registry.
- `grep -rn "audio_waveform\|MultiResWaveform\|WaveformCacheReader\|waveform/level" Godot Engine docs` must come back empty.
- Update the docs:
  - `docs/subsystems/godot-architecture.md` and `godot-osc.md` (the clip loading section)
  - `engine-architecture.md` (the AudioFileService section)
  - `osc-protocol.md` (the "Waveform Cache Format" section describes v2).

## Phase 7 (optional): raw samples at deep zoom

At `frames_per_pixel < base_block` (≤ 64 frames per pixel), draw the actual samples.

- **New OSC request:** `/audiofile/samples s:req_id s:peak_key i:channel h:start_frame i:count`, with `count` ≤ 4096. It replies `/audiofile/samples/data s:req_id h:start_frame b:f32_blob`, which is ≤ 16 KB and fits one UDP packet.
- **Engine source of the samples:** the engine re-reads them from the source file at the native rate on an AudioFileService worker, with seek plus a short decode. It does not read the project-rate playback buffer, because the peaks and the display are in native frames. Cache the last decoded window per file.
- **Drawing:** `WaveformView` requests the visible window, debounced to 50 ms. It uploads the samples as a 1-row `FORMAT_RF` texture, and the shader draws a line (and dots below about 0.25 frames per pixel) instead of the envelope. Until the samples arrive, it keeps drawing the base level.
- This phase changes the OSC protocol, so update `osc-protocol.md`.

**As built** (differences from the above):
- The request names the file by `cache_key` (the peak file's basename), which decode jobs register with the engine. `start_frame` is `i` because Godot's OSC client only sends 32-bit ints; the engine also accepts `h`.
- The reply carries the channel: `/audiofile/samples/data s:req_id i:channel h:start_frame b:f32_blob`.
- Godot's UDP peer buffers only about 64 KB per frame, so `WaveformSampleWindow` requests 4096-frame chunks with at most two in flight, caches chunks for scrolling back, and re-requests after 500 ms. The window covers the visible range plus 25% each side, up to 8 chunks (32768 frames) per channel; wider views keep the stepped base level.
- Requests are throttled to one window update per 50 ms (rather than debounced) so the window follows a continuous scroll.
- Samples are uploaded as an R32F texture, 4096 wide, one row per channel per chunk.
- `WaveformView` now draws only its visible slice and passes positions relative to it. At deep zoom a clip can be over 10^8 px wide, where float32 `UV × size` is off by tens of pixels.
- Mono sum mode draws the mean of the two channels. Spectral colour comes from the base-level bands under the column.

## Out of scope

- Clip gain and fades as features (the shader only has the hooks).
- Warp markers.
- Cache size limits and LRU pruning of `~/.cache/sonara/waveforms/`.
- Waveforms in the browser preview (TODO: browser details panel). That can reuse `WaveformView` later.

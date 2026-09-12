# AI Assistant Implementation Plan

In-DAW chat assistant for Sonara: OpenRouter as the model gateway, Godot-side orchestration, project-scoped conversations, and tools that mutate the live `Project` through the existing history/OSC path.

Companion design note: [`docs/ai-integration.md`](ai-integration.md) (what the model is good at, MIDI DSL later). This file is the build plan.

---

## Goals

- Talk to models through a first-party **OpenRouter** client (text, image, and audio in and out).
- Store the API key in the existing Settings window / `~/.config/sonara/config.json`.
- Persist **conversations per project**, not inside the project JSON.
- Load a user-editable system prompt from `~/.config/sonara/aichat/system_prompt.md` with `{variable}` interpolation.
- Give the model an abstract tool surface, then a first set of DAW verbs: tracks, asset search, mixer routing, add device.
- MIDI composition tools come later (Phase 3), likely as a compact DSL — see the companion note.

## Non-goals (for Phases 1–2)

- Hosting or fine-tuning a local model.
- Embedding search / vector index over the sample library (plain name/path/tag search first).
- MIDI note writing, groove, or reharmonize tools.
- Putting the LLM in the Rust engine or talking to it over OSC.
- Auto-playing generated audio into the arrangement (audio I/O is for chat: listen / speak / attach a clip, not bounce-to-track).

---

## Architecture

Everything lives in Godot. Tools need `Project`, `Channel`, `AssetService`, and `HistoryUtil`; the chat UI is a dock. A Rust HTTP client would add an OSC hop for no gain.

```
Settings (api key, model)
        │
        ▼
┌───────────────────┐     HTTPS      ┌──────────────┐
│  OpenRouterClient │ ◄────────────► │  OpenRouter  │
│  (HTTP + SSE)     │                │  /v1/*       │
└─────────┬─────────┘                └──────────────┘
          │
          ▼
┌───────────────────┐     tools      ┌──────────────┐
│  Assistant        │ ◄────────────► │  AiTool[]    │
│  (turn loop)      │                │  (HistoryUtil)│
└─────────┬─────────┘                └──────────────┘
          │
    ┌─────┴──────┐
    ▼            ▼
 Conversation  PromptTemplate
 Store         ~/.config/sonara/aichat/system_prompt.md
 {project}.aichat/
```

**Layers (keep files under ~400 lines):**

| Layer | Path | Job |
|---|---|---|
| Transport | `Godot/ai/OpenRouterClient.gd` | Auth, requests, SSE, multimodal payloads |
| Types | `Godot/ai/ChatTypes.gd` | Messages, content parts, tool calls, errors |
| Orchestrator | `Godot/ai/Assistant.gd` | System prompt + history + tool loop + persist |
| Prompt | `Godot/ai/PromptTemplate.gd` | Load markdown, `{variable}` expand |
| Context | `Godot/ai/PromptContext.gd` | Variable registry (project, tempo, selection…) |
| Store | `Godot/ai/ConversationStore.gd` | Per-project conversation files |
| Tools | `Godot/ai/tools/AiTool.gd` + siblings | Schema + execute |
| UI | `Godot/ai/ui/*` | Dock, transcript, composer, conversation list |

`Assistant` is an autoload (or an `Editor`-owned node). The client is not an autoload — the assistant owns one instance.

---

## Design decisions

### Client talks Chat Completions, not Responses

Primary endpoint: `POST https://openrouter.ai/api/v1/chat/completions`.

OpenAI-compatible `messages` / `tools` / `tool_choice` / `tool_calls`. OpenRouter remaps this for providers that do not speak that schema. The newer `/api/v1/responses` API is a different event model — do not start there. Dedicated image/TTS/STT endpoints are extras on the same client, not a second stack.

### Streaming is required for audio out, and useful for text

OpenRouter delivers audio output as SSE chunks (`delta.audio.data` + `delta.audio.transcript`) and **requires** `stream: true` when `modalities` includes `audio`. Implement SSE on `HTTPClient` first; use `HTTPRequest` only for non-stream calls (model list, STT, TTS file, image generate).

Godot `HTTPRequest` does not expose a usable incremental body. `HTTPClient` + `_process` polling does.

### Conversations are a sidecar, not project JSON

Projects are a single JSON file (`Editor.save_project`). Chat transcripts would bloat saves and mark the song dirty on every token. Store them next to the project:

```
~/Documents/Sonara/MySong.json
~/Documents/Sonara/MySong.aichat/
  index.json
  conv_<id>.json
```

Unsaved / Untitled projects write to `~/.config/sonara/aichat/scratch/` and migrate into the sidecar on first Save As.

Do **not** embed chat in `Project.to_json()`.

### Re-render the system prompt every turn

Persist user / assistant / tool messages only. Rebuild the system message from `system_prompt.md` + current `{variables}` on each request so prompt edits and project changes take effect without rewriting history.

### Mutations go through HistoryUtil

Write tools call `HistoryUtil.execute(...)` (`TrackCreateCommand`, `DeviceAddCommand`, `PropertyCommand`, `MacroCommand`). The user can undo an assistant batch. Read tools never touch history.

### API key is settings-only and never logged

Key lives at `ai/openrouter/api_key` in `config.json`. Mask it in the Settings UI. Never print it, never put it on a conversation file, never send it to the engine.

`config.json` is plaintext (same as the rest of Sonara config). Document that. Do not invent a keyring in Phase 1.

---

## OpenRouter API (what the client must speak)

Base URL: `https://openrouter.ai/api/v1` (setting-overridable).

**Auth / headers (every request):**

```
Authorization: Bearer <key>
Content-Type: application/json
HTTP-Referer: https://sonara.app
X-Title: Sonara
```

`HTTP-Referer` and `X-Title` are OpenRouter’s recommended app-attribution headers.

### Chat Completions — `POST /chat/completions`

Either `messages` or `prompt` is required. We always send `messages`.

Relevant body fields:

| Field | Use |
|---|---|
| `model` | OpenRouter id, e.g. `anthropic/claude-sonnet-4.5` |
| `messages` | `system` / `user` / `assistant` / `tool` |
| `tools` | `[{type:"function", function:{name, description, parameters}}]` |
| `tool_choice` | `auto` (default), `none`, `required`, or a named function |
| `stream` | SSE; required for audio output |
| `modalities` | `["text"]`, `["text","image"]`, `["text","audio"]` |
| `audio` | `{voice, format}` when requesting audio out (`format`: `wav`) |
| `max_tokens`, `temperature` | Settings |

**Content parts (user message `content` is `string` or an array):**

```json
[
  {"type": "text", "text": "What's on this clip?"},
  {"type": "image_url", "image_url": {"url": "data:image/png;base64,...", "detail": "auto"}},
  {"type": "input_audio", "input_audio": {"data": "<base64 bytes, not a data URI>", "format": "wav"}}
]
```

- Images: HTTPS URL **or** `data:<mime>;base64,...` data URI.
- Audio: **base64 raw bytes**, not a data URI. Formats: `wav`, `mp3`. Direct file URLs are not supported for audio.
- Assistant image/audio output arrives according to `modalities` (audio as streamed base64 chunks + transcript).

**Tool result messages:**

```json
{"role": "tool", "tool_call_id": "call_...", "content": "<json string>"}
```

**SSE:** lines prefixed `data: `, terminated by `data: [DONE]`. Text in `choices[0].delta.content`. Tool-call fragments in `choices[0].delta.tool_calls` (merge by index). Audio in `choices[0].delta.audio.{data,transcript}`.

### Models — `GET /models`

```
GET /api/v1/models
GET /api/v1/models?output_modalities=all
GET /api/v1/models?output_modalities=text,image
GET /api/v1/models?output_modalities=image
```

Default listing is text-only. Use `output_modalities=all` when populating the settings picker so multimodal models appear. Each model reports `architecture.input_modalities` / `output_modalities` — the client should cache this and refuse e.g. audio-in on a text-only model with a clear error.

### Extra endpoints (same client, used when the chat model cannot do the modality)

| Method | Path | Role |
|---|---|---|
| `POST` | `/audio/transcriptions` | STT. Body: `{model, input_audio:{data, format}}`. Returns `{text}`. |
| `POST` | `/audio/speech` | TTS. Body: `{model, input, voice, response_format}`. **Raw audio bytes**, not JSON. |
| `POST` | `/images` | Dedicated image gen/edit. `{model, prompt, input_references?}`. Optional — chat `modalities:["text","image"]` covers in-chat images. |

Phase 1 implements chat completions (all three modalities) + models list. STT / TTS / `/images` can land in 1.5 if chat-native audio/image is enough for the first UI.

Not all models support tools, vision, or audio. The client reports capabilities; the assistant degrades (hide attach-image, skip `tools`, etc.).

---

## File map (create as you go)

```
Godot/ai/
  OpenRouterClient.gd
  OpenRouterSse.gd          # incremental SSE line parser
  ChatTypes.gd              # ChatMessage, ContentPart, ToolCall, ChatRequest, ChatResponse
  Assistant.gd              # autoload: turn loop
  PromptTemplate.gd
  PromptContext.gd
  Conversation.gd
  ConversationStore.gd
  system_prompt.md          # shipped default, copied to config dir on first run
  tools/
    AiTool.gd
    ToolRegistry.gd
    ListProjectTool.gd
    CreateTrackTool.gd
    RenameTrackTool.gd
    DeleteTrackTool.gd
    SetTrackColorTool.gd
    SearchAssetsTool.gd
    ListChannelsTool.gd
    SetMixerTool.gd         # volume / pan / mute / solo
    RouteChannelTool.gd
    AddSendTool.gd
    CreateBusTool.gd
    ListDevicesTool.gd
    AddDeviceTool.gd
  ui/
    AssistantPanel.gd + .tscn
    ChatTranscript.gd
    ChatComposer.gd
    ConversationList.gd
```

Wire the autoload in `Godot/project.godot` when `Assistant.gd` exists:

```
Assistant="*res://ai/Assistant.gd"
```

---

## Phase 1 — OpenRouter client + settings

Goal: from the Settings window, save a key, pick a model, and successfully complete a text (and multimodal) request. No chat dock yet. A tiny debug hook is enough to verify.

### 1.1 Secret setting type

**Files:** `Godot/settings/Settings.gd`, `Godot/settings/SettingRow.gd`

Settings today: `BOOL, INT, FLOAT, STRING, CHOICE, CHOICE_MULTI, PATH, PATH_ARRAY`. Add `SECRET` (or `secret: bool` on `STRING`).

- `LineEdit.secret = true`
- Same persist path as `STRING`
- Do not show the value in tooltips / logs

Keep `Settings.Type` and `SettingRow.Type` in sync.

### 1.2 Register an AI category

**File:** `Godot/settings/Settings.gd`

Add `CATEGORY_AI = "AI"` and include it in `get_categories()`.

| Key | Type | Default | Notes |
|---|---|---|---|
| `ai/openrouter/api_key` | SECRET | `""` | Required |
| `ai/openrouter/base_url` | STRING | `https://openrouter.ai/api/v1` | Override for proxies |
| `ai/openrouter/model` | STRING | `anthropic/claude-sonnet-4.5` | Free-typed; later a CHOICE from `/models` |
| `ai/chat/temperature` | FLOAT | `0.7` | 0–2, step 0.1 |
| `ai/chat/max_tokens` | INT | `4096` | 256–32000 |
| `ai/audio/voice` | STRING | `alloy` | Chat audio out + TTS |
| `ai/audio/format` | CHOICE | `wav` | `wav` / `mp3` |

Optional Phase 1 follow-up: after the client can `list_models()`, change `model` to a `CHOICE` (or a searchable picker) filtered by tool-calling + text.

`Settings.setting_changed` should let the client rebuild headers when the key or base URL changes.

### 1.3 Chat types

**File:** `Godot/ai/ChatTypes.gd`

`RefCounted` data classes (or inner classes) with `to_openrouter()` / `from_openrouter()`:

- `ContentPart` — `text` | `image_url` | `input_audio` | `output_audio` | `output_image`
- `ChatMessage` — `role`, `content` (String or Array), `name`, `tool_calls`, `tool_call_id`
- `ToolCall` — `id`, `name`, `arguments` (Dictionary; parse JSON when receiving)
- `ChatRequest` — model, messages, tools, stream, modalities, audio, temperature, max_tokens, tool_choice
- `ChatDelta` — incremental text, tool-call fragments, audio chunk, finish_reason
- `ChatError` — http status, OpenRouter error body (`error.message`, `error.code`)

Keep the on-wire shape isolated here so the assistant never builds raw dictionaries.

### 1.4 SSE parser

**File:** `Godot/ai/OpenRouterSse.gd`

- Feed UTF-8 bytes, emit complete `data:` payloads
- Ignore comments / empty lines
- Stop on `[DONE]`
- Tolerate split chunks (Godot will deliver partial lines)

Cover with a small GDScript test (headless) using canned SSE fixtures: split mid-line, multiple events per chunk, `[DONE]`.

### 1.5 OpenRouterClient

**File:** `Godot/ai/OpenRouterClient.gd`

Must be a `Node` (owns `HTTPClient` / `HTTPRequest` children).

**Public API:**

```
signal request_started()
signal text_delta(text: String)
signal audio_delta(b64_chunk: String, transcript: String)
signal image_delta(part: ContentPart)
signal tool_calls_ready(calls: Array)   # merged ToolCall list
signal message_finished(message: ChatMessage)
signal request_failed(error: ChatError)
signal request_cancelled()
```

Methods:

- `configure_from_settings()` — read key / base URL / model / temperature
- `has_api_key() -> bool`
- `list_models(output_modalities: String = "all") -> Array` (HTTPRequest, non-stream)
- `chat(request: ChatRequest)` — stream or not; default stream on
- `cancel()` — disconnect HTTPClient
- `transcribe(bytes, format, model)` — `/audio/transcriptions` (Phase 1.5)
- `speak(text, voice, format, model)` — `/audio/speech` (Phase 1.5)
- `generate_image(prompt, model, references)` — `/images` (Phase 1.5)

**HTTPClient chat flow:**

1. Parse base URL (`https` → TLS port 443).
2. `connect_to_host(host, port, tls_options)`.
3. Poll until `STATUS_CONNECTED`.
4. `request(METHOD_POST, path, headers, body)`.
5. Poll; on `STATUS_BODY`, read chunks into the SSE parser.
6. Merge tool-call deltas by `index` (OpenAI streaming convention).
7. Concatenate audio `data` chunks; decode base64 only after `[DONE]` (or incrementally if you play them).
8. One in-flight request. A second `chat()` cancels the first.

**Errors to surface as `ChatError`:**

- Missing API key
- TLS / DNS / connect failure
- HTTP 401 / 402 / 429 / 5xx with OpenRouter `error.message`
- Truncated SSE / invalid JSON chunk
- Model does not accept the requested modality

**Never log:** `Authorization` header, raw API key, full request body if it contains `input_audio` / image data URIs (log sizes and MIME types only).

### 1.6 Multimodal encode helpers

**File:** `Godot/ai/MediaEncode.gd` (keep it small)

- Image `Texture2D` / file path → PNG or JPEG bytes → `data:image/png;base64,...`
- Audio file / `PackedByteArray` → base64 (no data-URI prefix) + format hint
- Incoming audio chunks → `PackedByteArray` → optional temp wav under `~/.config/sonara/aichat/tmp/`
- Incoming image (URL or data URI) → `ImageTexture` for the transcript

Godot can play WAV via `AudioStreamWAV`. MP3 needs `AudioStreamMP3`. Prefer `wav` as the default chat-audio format.

### 1.7 Smoke test (no UI)

Temporary, gated by a debug flag or editor menu **AI → Test Connection**:

1. Send a one-shot `messages: [{role:user, content:"Reply with the word pong"}]`.
2. Print the assistant text to the Godot log (not the key).
3. Optional: attach a tiny PNG and ask “what color?”; attach a short wav and ask for a transcript.

Remove or hide the menu item once Phase 2 chat exists.

### 1.8 Phase 1 done when

- [ ] Settings → AI shows key (masked), base URL, model, temperature, max tokens
- [ ] Saving the dialog writes `ai/openrouter/*` via `Settings.set_value` + `Settings.save()`
- [ ] Test Connection returns model text with a valid key
- [ ] Invalid key shows a readable 401, not a silent fail
- [ ] Client can build a user message with text + image_url + input_audio
- [ ] Client can request `modalities: ["text","audio"]` and reassemble streamed wav + transcript
- [ ] Client can request `modalities: ["text","image"]` and parse image parts
- [ ] Cancel stops an in-flight stream
- [ ] SSE parser unit test passes

---

## Phase 2 — Chat, prompt, tools, persistence

Goal: a docked assistant that remembers conversations per project, expands a user-editable system prompt, and can create tracks, search assets, route the mixer, and add devices — all undoable.

### 2.1 Prompt template + variables

**Files:** `Godot/ai/PromptTemplate.gd`, `Godot/ai/PromptContext.gd`, `Godot/ai/system_prompt.md`

**On-disk user prompt:** `~/.config/sonara/aichat/system_prompt.md`

On first run, copy the shipped default from `res://ai/system_prompt.md` if the user file does not exist. Never overwrite an existing user file.

**Interpolation:** `{name}` → markdown string from `PromptContext`. Unknown `{names}` stay as-is (or become a visible `?name` — pick one and stick to it; prefer leaving unknown tokens unchanged so users can write `{example}` in docs inside the prompt). Escape hatch: `{{` / `}}` → literal `{` / `}`.

Only expand variables that actually appear in the prompt.

**Built-in variables (all markdown):**

| Token | Source | Example |
|---|---|---|
| `{project_name}` | `Project.project_name` | `My Song` |
| `{tempo}` `{bpm}` | `Project.tempo` | `128` |
| `{time_signature}` | numerator/denominator | `4/4` |
| `{ppq}` | `Project.ppq` | `960` |
| `{sample_rate}` | `Project.sample_rate` | `48000` |
| `{playhead}` | ticks + bar:beat:tick | `1:1:000 (0)` |
| `{tracks}` | compact track table | id, name, type, channel, clip count |
| `{channels}` `{mixer}` | compact mixer table | id, name, type, vol dB, pan, mute/solo, route, sends |
| `{selection}` | focused track / channel / clips | current UI focus |
| `{devices}` | devices on focused channel | name, id, position |
| `{date}` | local date | `2026-09-12` |

`PromptContext` is a registry: `register(name, Callable)` so later MIDI tools can add `{key}`, `{markers}`, `{active_clip}`.

Keep tables short (cap rows, summarize the rest). The companion note is explicit: the read path matters as much as the write path, and it must stay token-cheap.

**Shipped default prompt** should state:

- You are Sonara’s in-project assistant.
- Middle C = C3 = MIDI 60; timing is 960 PPQ.
- Prefer tools over guessing IDs; call `list_project` when unsure.
- Mutating tools are undoable; say what you changed.
- Do not dump raw MIDI bytes. Do not invent file paths.

### 2.2 Conversation model + store

**Files:** `Godot/ai/Conversation.gd`, `Godot/ai/ConversationStore.gd`

`Conversation`:

```
id: String              # "conv_" + hex
title: String           # first user line, or user-renamed
created_unix: int
updated_unix: int
model: String
messages: Array[ChatMessage]   # no system message
```

`index.json` (sidecar):

```json
{
  "active_id": "conv_ab12",
  "conversations": [
    {"id": "conv_ab12", "title": "Drum bus", "updated_unix": 1710000000}
  ]
}
```

Each `conv_<id>.json` is the full message list. Write atomically (temp file + rename). Debounce disk writes to ~300 ms after the last message change.

**Store API:**

- `bind_project(project_path: String)` — empty path → scratch dir
- `list() -> Array` (index entries)
- `load(id) -> Conversation`
- `save(conversation)`
- `create() -> Conversation`
- `delete(id)`
- `migrate_scratch_to(project_path)` — on Save As
- `autosave_current()`

Listen to `Editor.project_opened` / `project_closed` / `project_saved`. Closing a project flushes and unbinds.

Cap stored messages if needed later (not Phase 2). For now persist the full thread.

### 2.3 Abstract tool + registry

**Files:** `Godot/ai/tools/AiTool.gd`, `Godot/ai/tools/ToolRegistry.gd`

```
class_name AiTool extends RefCounted

func get_name() -> String
func get_description() -> String
func get_parameters() -> Dictionary   # JSON Schema object
func is_read_only() -> bool
func execute(args: Dictionary) -> Dictionary
  # { "ok": true, "data": {...} } or { "ok": false, "error": "..." }
```

`to_openrouter()` wraps the schema as `{type:"function", function:{name, description, parameters}}`.

Rules:

- Names: `snake_case`, unique, stable (they land in saved transcripts).
- Parameters: JSON Schema draft-07 subset (`type`, `properties`, `required`, `enum`, `description`). Describe units (`volume_db`, ticks, channel id).
- `execute` never throws to the model — catch and return `{ok:false, error}`.
- Resolve tracks/channels by **id** (int). Accept name as a convenience and disambiguate via a read tool if needed.
- Write tools go through `HistoryUtil`. Batch related writes in one `MacroCommand` when the model calls several mutators in the same turn (Assistant can wrap the whole tool-round in a macro).
- Return compact JSON. No waveform dumps, no full clip note lists (Phase 3).
- Read tools are safe with no project; write tools fail with `"No project open"`.

`ToolRegistry`:

- `register(tool: AiTool)`
- `get_openrouter_tools() -> Array`
- `execute(name, args) -> Dictionary`
- Unknown name → `{ok:false, error:"Unknown tool"}`

### 2.4 Tool loop (Assistant autoload)

**File:** `Godot/ai/Assistant.gd`

```
signal conversation_changed()
signal turn_started()
signal text_delta(text)
signal tool_started(name, args)
signal tool_finished(name, result)
signal turn_finished()
signal turn_failed(error)
```

Turn algorithm:

1. Refuse if no API key / no active conversation.
2. Append the user message (text and/or attached image/audio parts).
3. Build `messages = [system_from_prompt] + conversation.messages`.
4. `chat()` with `tools = registry.get_openrouter_tools()`, `tool_choice = auto`, `stream = true`.
5. Stream text to the UI. Persist the assistant message when the stream ends.
6. If `finish_reason == tool_calls` (or merged tool calls exist):
   - Execute each call (sequence; later: parallel reads).
   - Append `role:tool` messages.
   - Emit `tool_*` signals for the transcript.
   - Loop from step 3.
7. Stop when `finish_reason == stop`, on error, on cancel, or after **max 8** tool rounds.
8. Autosave conversation. If title is empty, set it from the first user line (trimmed, ~40 chars).

Cancel: `client.cancel()`, mark the partial assistant message, do not execute leftover tools.

### 2.5 Asset search API (needed by the tool)

**File:** `Godot/browser/AssetService.gd`

There is no text search today (`get_all_assets`, `find_asset(path)`, type getters). Add:

```
search_assets(query: String, type_filter: String = "", limit: int = 25) -> Array[Asset]
```

Match case-insensitive against `name`, `path`, `tags`. Optional `type_filter`: `audio`, `midi`, `device`, `sfz`, `soundfont`, or empty. Sort: favorites first, then `last_used`, then name. Return at most `limit`.

Do **not** build embeddings in Phase 2.

### 2.6 Basic tools

Implement these. Each is one file. Reuse existing commands / setters; do not send OSC from tools.

#### Read

| Tool | Args | Returns |
|---|---|---|
| `list_project` | — | name, tempo, time signature, PPQ, track list, channel list (compact) |
| `list_tracks` | — | id, name, type, channel_id, clip_count, color |
| `list_channels` | — | id, name, type, volume_db, pan, mute, solo, output_channel_id, sends, device names |
| `list_devices` | `channel_id` | position, name, device_id, category, bypass |
| `search_assets` | `query`, `type?`, `limit?` | path, name, type, tags, favorite |

#### Tracks

| Tool | Args | Implementation |
|---|---|---|
| `create_track` | `name`, `kind` (`instrument`/`audio`/`folder`/`group`) | `TrackCreateCommand` via `HistoryUtil.execute` |
| `rename_track` | `track_id`, `name` | `HistoryUtil.execute_property` on `Track.set_name` (or the name setter) |
| `set_track_color` | `track_id`, `hex` | property command on color |
| `delete_track` | `track_id` | `TrackDeleteCommand` |

`kind` maps 1:1 to `TrackCreateCommand`.

#### Mixer / routing

| Tool | Args | Implementation |
|---|---|---|
| `set_mixer` | `channel_id`, optional `volume_db`, `pan`, `mute`, `solo` | `Channel.set_volume` / pan / mute / solo + `PropertyCommand` / `MacroCommand` |
| `route_channel` | `channel_id`, `output_channel_id` | existing route setter (`Channel` `output_channel_id` / route method) |
| `add_send` | `channel_id`, `target_channel_id`, `amount_db?`, `pre_fader?` | `Channel.add_send` |
| `create_bus` | `name` | `Project.create_bus_channel` wrapped in a new `BusCreateCommand` if none exists — **add that command** rather than creating without undo |

Master (id 1) is not deletable. Routing to `0` is “no output” (existing ID scheme). Hardware outs are `1000+`. Document this in the tool descriptions so the model does not invent ids.

#### Devices

| Tool | Args | Implementation |
|---|---|---|
| `add_device` | `channel_id`, `asset_path` or `device_id`, `position?` | Resolve via `AssetService.get_device` / `find_asset`, then `DeviceAddCommand` (same path as `DeviceDropUtil.drop_asset`). Honor `DeviceDropUtil.can_drop_asset_on_channel` (instruments only on instrument channels, no FX on master, etc.). |

SFZ: if the asset is `TYPE.SFZ`, follow `DeviceDropUtil`’s sfizz+load path (async). The tool `execute` may `await`; Assistant must `await` tool results.

### 2.7 Chat UI

**Files:** `Godot/ai/ui/*.gd` + scenes (create scenes via Godot MCP, do not hand-edit `.tscn`).

**Placement:** new toggleable dock on the right, stacked with (or instead of) the Browser in `Editor.tscn`’s `LeftRightSplit/BoxContainer`. Do not steal the inspector. Mirror `toggle_device_lane`:

- Input action `toggle_assistant`
- View menu item
- Shortcut (suggest `Ctrl+Shift+A`) registered in the InputMap + Settings shortcuts list

`AssistantPanel`:

- Header: conversation dropdown, New, Delete, model label, Cancel
- `ConversationList` (compact)
- `ChatTranscript` (`RichTextLabel` or a VBox of bubbles): user / assistant markdown, collapsible tool-call rows (`name` + short result), inline image, audio play button
- `ChatComposer`: multiline text, attach image, attach audio file, optional hold-to-talk later, Send

While streaming, append text deltas to the last assistant bubble. Disable Send, enable Cancel.

Empty state: “Set an OpenRouter API key in Settings → AI” if `has_api_key()` is false.

Phase 2 UI does **not** need polished markdown rendering, voice hold-to-talk, or image generation buttons. File-picker attach + streamed text is enough. Play back audio parts with `AudioStreamPlayer` when present.

### 2.8 Editor / lifecycle hooks

**Files:** `Godot/editor/Editor.gd`, `Godot/editor/MainMenu.gd`, `Godot/project.godot`

- Autoload `Assistant`
- On `project_opened` / `project_saved` / `project_closed`, bind/migrate/unbind the store
- Do not clear conversations on `history.clear()` (undo != new song)
- Add **AI** menu: Toggle Assistant, New Conversation, Test Connection (optional)

### 2.9 Default system prompt file

**File:** `Godot/ai/system_prompt.md`

Keep it short. Include the variable tokens you want on every turn (`{project_name}`, `{tempo}`, `{time_signature}`, `{tracks}`, `{mixer}`, `{selection}`). Users who want a smaller prompt can delete tokens.

### 2.10 Phase 2 done when

- [x] Opening a saved project restores its conversation list and the last active thread
- [x] Untitled projects chat into scratch; Save As moves the folder to `MySong.aichat/`
- [x] Editing `~/.config/sonara/aichat/system_prompt.md` changes the next turn’s system message
- [x] `{tempo}` and `{tracks}` expand to current project values
- [x] “Add an instrument track named Lead and put PolySynth on it” creates a track + device, undo reverts both
- [x] “Search assets for kick” returns name/path hits from `AssetService`
- [x] “Make a reverb bus and send Drums to it at -12 dB” creates a bus + send
- [x] Routing / mixer tools update the engine (existing Channel OSC setters)
- [x] Missing API key is a UI error, not a crash
- [x] Tool errors come back as tool results; the model can retry
- [x] Cancel stops streaming and does not apply half-finished tool rounds

---

## Phase 3 — MIDI tools (later)

Not in scope to implement now. When it is, follow [`docs/ai-integration.md`](ai-integration.md):

- Symbolic only. No raw `.mid` bytes, no MusicXML.
- Prefer a **compact DSL** (or JSON note lists) scoped to **one clip per call**.
- Musical time: `bar:beat:ticks` at project PPQ (960). Middle C = C3 = 60.
- Split intent from realization: `set_progression`, `generate_pattern`, `apply_groove` as parameterized tools; deterministic code expands them.
- Read tools for the active clip (compact note dump, density, pitch histogram) so the model writes into context.
- New `{active_clip}` / `{markers}` prompt variables.
- Same `AiTool` + `HistoryUtil` path (`ClipNotesStateCommand` already exists).

Do not start Phase 3 until Phase 2 tools are boringly reliable.

---

## Testing checklist (cross-phase)

**Client**

- Headless SSE fixtures.
- Manual: text-only model, vision model + PNG, audio model + short wav, audio-out stream → playable wav.
- 401 / 429 / network down.

**Assistant**

- Tool-round cap (force a loop, confirm stop at 8).
- Undo after a multi-tool turn.
- Conversation survives editor restart.
- Scratch → sidecar migration.

**Tools**

- Create instrument / audio / folder / group.
- `add_device` rejected on master / wrong channel type (same rules as drag-drop).
- `search_assets` empty query / unknown type / limit.

**UI**

- Toggle dock, type, send, stream, cancel.
- Attach image + audio file, confirm they appear in the user bubble and go out on the wire.

---

## Implementation order (when we start coding)

1. `SECRET` setting + AI category keys (1.1–1.2)
2. `ChatTypes` + SSE parser + tests (1.3–1.4)
3. `OpenRouterClient` text stream + Test Connection (1.5, 1.7)
4. Image + audio parts and `modalities` (1.6)
5. `PromptTemplate` / `PromptContext` / default prompt (2.1)
6. `Conversation` + `ConversationStore` + Editor bind (2.2, 2.8)
7. `AiTool` + `ToolRegistry` + `list_project` only (2.3)
8. `Assistant` turn loop with no UI (log deltas) (2.4)
9. Remaining tools + `AssetService.search_assets` (2.5–2.6)
10. Assistant dock UI (2.7)
11. Polish: model picker from `/models`, STT/TTS helpers if chat-native audio is insufficient (1.5 extras)

---

## Open questions

Leave these until implementation if they stay true; otherwise decide in the PR.

1. **Model picker:** free-typed string first, then a cached `/models` list. Fine.
2. **Hold-to-talk:** Phase 2 file-attach only; mic capture is a later composer feature.
3. **Confirm destructive tools:** `delete_track` is undoable, so no modal in Phase 2. Revisit if users delete too eagerly.
4. **Cost / usage display:** OpenRouter returns usage on the final chunk. Optional footer later; not required to ship.
5. **Multiple projects:** Editor is single-project today. Store bind follows `project_path`. No work here.

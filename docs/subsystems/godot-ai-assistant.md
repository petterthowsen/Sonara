# Godot AI Assistant

In-project chat lives under `Godot/ai/`. Do **not** confuse it with `Godot/addons/godot_ai` (editor MCP). The `Assistant` autoload (`res://ai/Assistant.gd`) owns the tool loop; UI only listens to its signals.

```
Composer → Assistant.send_user() → OpenRouterClient (SSE)
                ↓ tool_calls
         ToolRegistry.execute() → AiTool (data layer + HistoryUtil)
                ↓ JSON tool results
         next chat round (capped by Settings `ai/chat/max_tool_rounds`)
```

## Orchestration
- `Assistant` binds chats to the open project, streams one turn at a time, cancels leftover tools, and wraps each tool-call batch in `HistoryUtil.history().begin_macro("Assistant")` / `end_macro()`.
- Wire OpenRouter through `ChatTypes` (`ORChatRequest`, `ORChatMessage`, `ORToolCall`, `ORContentPart`, `ORChatError`). Never assemble raw request dicts.
- Config: Settings keys `ai/openrouter/*` (api_key, base_url, model) and `ai/chat/*` (temperature, max_tokens, max_tool_rounds, reasoning). Client reads them on each request.

## Persistence & prompt
- `ConversationStore`: sidecar `project.aichat/` next to the project file, or `~/.config/sonara/aichat/scratch` when untitled. The dropdown lists only the bound folder's conversations; opening a project reopens its `index.json` `active_id`. Scratch is wiped when a new untitled project opens and emptied when its chats move to a saved project; Save As from a saved project copies the sidecar. Debounced JSON writes.
- `ExchangeLog`: every OpenRouter call is saved as `<aichat dir>/exchanges/<conv id>/<ex id>.json` (request body with media redacted, assembled response, `usage`, errors; never headers). The resulting assistant message stores `exchange_id` + `usage`; the transcript shows a `{ }` link per round that opens `ExchangeViewer`. Retention: Settings `ai/debug/keep_exchanges` (0 = off).
- Failed requests are appended as assistant notices with `finish_reason = "error"` so they survive transcript rebuilds; `Assistant._chat_once` skips them when building the request.
- Token meter: `Conversation.usage_summary()` (last reported prompt+completion, `TokenEstimate` for unsent messages) + `OpenRouterClient.get_context_length()` from a once-per-session `/models` fetch.
- `PromptTemplate` copies shipped `@Godot/ai/prompt/system_prompt.md` once to `~/.config/sonara/aichat/system_prompt.md`, then expands `{variables}` from `PromptContext` (project tables, playhead, selection). Edit the shipped file for default copy; do not hardcode the prompt in GDScript.

## Tools
- Subclass `AiTool`: stable snake_case `get_name()`, one-line `get_description()`, JSON Schema `get_parameters()`, `is_read_only()`, `execute()` → `{ok:true, data:{}}` or `{ok:false, error:"..."}`. Never throw to the model.
- Tempo / meter: `set_tempo` goes through `Editor.set_tempo` / `set_time_signature` (they record history). Markers: `list_markers` / `create_marker` use `MarkerActions` (new ranges carve overlapping markers; names unique).
- Clip arranging: `move_clips` / `delete_clips` / `overwrite` on `place_clip` and `create_clip` go through `history/ClipRangeActions.gd` (clear, move or copy a tick span on tracks; clips crossing an edge are split with `clip_offset` shifted). Span and track args: `AiTool.resolve_time_span` / `resolve_track_filter`.
- Register new tools in `ToolRegistry.create_default()`. Reuse `AiTool.require_project()`, `resolve_track` / `resolve_channel` / `resolve_clip` / `resolve_device`, and compact helpers. Device paths use `DeviceNaming` (`Channel/Device/Child`; sibling names unique, `Delay 2`).
- Mutating tools go through data-object APIs + `HistoryUtil.execute` / `record` (same as the rest of the editor). Device param paging lives in `DeviceToolUtil`. Asset lookup is `SearchAssetsTool` → `AssetService`.

## Clip text
- MIDI in/out for the model is `ClipText` (`ClipTextGrid`, `ClipTextEvents`, `ClipTextTime`, `ClipTextKey`). Audio clips have no text format.
- Grids: hits `1`–`9` or `x`, rests `.`; cell-diff preserves velocity/microtiming. Event writes are ops only (`add` / `del` / `move` / `vel` / `len`). Clip-local time; refer to clips by **name**. Tests: `Godot/ai/tests/test_clip_text.gd`.

## UI
- Selection context: `SelectionContext.collect(editor)` snapshots the selection for the current view (Arranger/Clip Editor: tracks, time range, clips; Mixer: channels + device paths). `ChatComposer` shows each item as a glowing `Badge` (`components/Badge.gd`, reusable pill with icon/label/glow/muted) that the user can click to exclude, and passes the active items to `Assistant.send_user(text, parts, context)`. They are stored on `ORChatMessage.context` and sent as a `<selection_context>` block before the user text (`get_context_text()`); `get_text()` never includes it. The transcript shows them as small badges on the user bubble.
- Right dock `AssistantPanel` → `ConversationList` / `ChatTranscript` / `ChatComposer`. Bind only to Assistant signals (`conversation_changed`, `text_delta`, `tool_started` / `tool_finished`, `turn_*`). Do not call OpenRouter from the panel.

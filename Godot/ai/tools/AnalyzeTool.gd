# AnalyzeTool.gd
# Renders a range offline and returns a per-bar text grid of loudness and band energy, so the
# assistant can "hear" the mix (docs/analyze-plan.md). The engine writes numbers to a JSON file;
# AnalysisFormat owns the text layout.
class_name AnalyzeTool extends AiTool

const MAX_BEAT_BARS := 16
const MAX_BARS := 128

## Overridable for tests; defaults to the editor's service.
var render_service: RenderService = null
## Where the engine writes results; overridable for tests.
var result_dir := ""


func get_name() -> String:
	return "analyze"


func get_description() -> String:
	return "Render a range of the project offline and report loudness, six frequency bands (sub, bass, lowmid, mid, himid, air), peaks and the root note per bar as a 0–9 text grid, with a masking summary when channels are listed. Use it to hear the mix before giving mixing advice or after changing levels, EQ or arrangement. Takes a few seconds and stops playback while it runs."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"start": {"type": "string", "description": "bar.beat.tick or a bar number, e.g. \"17\" or \"17.1.000\""},
			"end": {"type": "string", "description": "Exclusive end: start 17 end 21 analyzes bars 17–20"},
			"channels": {"type": "array", "items": {"type": "string"}, "description": "Channel names to analyze besides the master, or [\"all\"]. Default: master only"},
			"resolution": {"type": "string", "enum": ["bar", "beat"], "description": "Column size (default bar). beat is limited to %d bars" % MAX_BEAT_BARS},
		},
		"required": ["start", "end"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project_v = require_project()
	if project_v is Dictionary:
		return project_v
	var project: Project = project_v
	var plan := plan_request(project, args)
	if plan.has("error"):
		return fail(plan.error)
	var service := render_service if render_service else (Sonara.editor.render_service if Sonara and Sonara.editor else null)
	if service == null:
		return fail("Rendering isn't available")
	if service.is_running:
		return fail("A render is already running; try again when it finishes")
	var dir := result_dir if result_dir != "" else OS.get_user_data_dir().path_join("analysis")
	var path := dir.path_join("analysis_%d.json" % Time.get_ticks_usec())
	var options: Dictionary = plan.options
	options["result_path"] = path
	var outcome: Dictionary = await service.analyze(options)
	if not outcome.ok:
		return fail("Analysis failed: %s" % outcome.error)
	var parsed = _read_json(str(outcome.path))
	DirAccess.remove_absolute(str(outcome.path))
	if parsed == null:
		return fail("The engine's analysis result couldn't be read")
	var text := render_text(project, parsed, plan.names)
	return ok_text(text, {"bars": parsed.get("bars", []).size()})


## Validate the arguments and build RenderService options. Returns
## `{options, names}` (names: channel id -> name for the tapped channels) or fail(...).
static func plan_request(project: Project, args: Dictionary) -> Dictionary:
	if not args.has("start") or not args.has("end"):
		return fail("start and end are required")
	var start := parse_position(project, args.start)
	var end := parse_position(project, args.end)
	if start < 0:
		return fail("start must be bar.beat.tick or a bar number, got '%s'" % str(args.start))
	if end < 0:
		return fail("end must be bar.beat.tick or a bar number, got '%s'" % str(args.end))
	if end <= start:
		return fail("end must be after start")
	var resolution := str(args.get("resolution", "bar")).strip_edges().to_lower()
	if resolution not in ["bar", "beat"]:
		return fail("resolution must be bar or beat")
	var tsm := project.time_signature_map
	var bars := tsm.bar_at_tick(end - 1, project.time_numerator, project.time_denominator, project.ppq) \
			- tsm.bar_at_tick(start, project.time_numerator, project.time_denominator, project.ppq) + 1
	if resolution == "beat" and bars > MAX_BEAT_BARS:
		return fail("Beat resolution is limited to %d bars (asked for %d); use bar resolution or a shorter range" % [MAX_BEAT_BARS, bars])
	if bars > MAX_BARS:
		return fail("The range is %d bars; analyze at most %d at a time" % [bars, MAX_BARS])

	var options := {"start_tick": start, "end_tick": end, "resolution": resolution, "pre_roll_ticks": -1}
	var names := {1: "Master"}
	var raw = args.get("channels", [])
	var wanted: Array = []
	if raw is Array:
		wanted = raw
	elif raw is String:
		wanted = Array(raw.split(",", false))
	var ids: Array = []
	for n in wanted:
		var name := str(n).strip_edges()
		if name.to_lower() == "all":
			options["all_channels"] = true
			for c in project.channels:
				names[c.id] = c.name
			continue
		var channel = resolve_channel(project, {"channel": name})
		if channel is Dictionary:
			return channel
		if channel.id != 1 and not ids.has(channel.id):
			ids.append(channel.id)
			names[channel.id] = channel.name
	options["channel_ids"] = ids
	return {"options": options, "names": names}


## `17`, `17.1`, `17.2.480` -> song ticks, counting bars through time-signature changes. -1 if invalid.
static func parse_position(project: Project, value: Variant) -> int:
	var s := str(value).strip_edges().replace(":", ".")
	if value is float and is_equal_approx(value, roundf(value)):
		s = str(int(value))
	var parts := s.split(".", false)
	if parts.is_empty() or parts.size() > 3:
		return -1
	for p in parts:
		if not p.is_valid_int():
			return -1
	var bar := parts[0].to_int()
	if bar < 1:
		return -1
	var beat := parts[1].to_int() if parts.size() > 1 else 1
	var tick := parts[2].to_int() if parts.size() > 2 else 0
	if beat < 1 or tick < 0:
		return -1
	var tsm := project.time_signature_map
	var bar_tick := tsm.tick_of_bar(bar, project.time_numerator, project.time_denominator, project.ppq)
	var sig := tsm.signature_at_tick(bar_tick, project.time_numerator, project.time_denominator, project.ppq)
	return bar_tick + (beat - 1) * GridHelper.beat_ticks(project.ppq, sig.y) + tick


## Format a parsed engine result with the project's names, markers and MIDI roots.
static func render_text(project: Project, result: Dictionary, names: Dictionary) -> String:
	var markers: Array = []
	for m in ListMarkersTool.sorted_markers(project):
		markers.append({"name": m.name, "start_ticks": m.start_ticks, "end_ticks": m.get_end_ticks()})
	var spans: Array[Vector2i] = []
	for b in result.get("bars", []):
		spans.append(Vector2i(int(round(float(b.start_tick))), int(round(float(b.end_tick)))))
	for tap in result.get("header", {}).get("taps", []):
		var c := project.get_channel_by_id(int(tap))
		if c and not names.has(int(tap)):
			names[int(tap)] = c.name
	return AnalysisFormat.format(result, {
		"names": names,
		"markers": markers,
		"roots": AnalysisRoots.compute(project, spans),
	})


static func _read_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else null

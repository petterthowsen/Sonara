# SelectionContext.gd
# Snapshot of the editor selection that gets attached to the next user message. Which parts count
# depends on the current view: Arranger (and Clip Editor) sends selected tracks, the time range and
# selected clips; Mixer sends the selected channels with their device chains.
# Items are plain dictionaries `{key, kind, label, icon, color, text}` — `text` is the model-facing
# line, `key` changes whenever the selected thing does (used to reset a user's exclusion).
class_name SelectionContext extends RefCounted


const MAX_ITEMS_LISTED := 8
const ICON_DIR := "res://assets/icons/"
const RANGE_COLOR := Color(0.95, 0.72, 0.3)
const CLIP_COLOR := Color(0.36, 0.6, 0.95)
const CHANNEL_COLOR := Color(0.45, 0.8, 0.6)

const ICONS := {
	"track": "list-music.svg",
	"range": "timeline.svg",
	"clips": "file-music.svg",
	"channel": "volume-2.svg",
}


## Current selection items from the live editor, for its current view.
static func collect(editor: Editor) -> Array:
	if editor == null or editor.project == null:
		return []
	var sel := {}
	if editor.current_view == Editor.View.MIXER:
		var channels: Array = []
		if editor.mixer and not editor.mixer.selection.is_empty():
			channels.assign(editor.mixer.selection)
		elif editor.focused_channel:
			channels.append(editor.focused_channel)
		sel["channels"] = channels
	else:
		sel["tracks"] = editor.selected_tracks.duplicate()
		sel["active_track"] = editor.focused_track
		sel["range"] = editor.get_time_range()
		if editor.arranger and editor.arranger.timeline:
			sel["clips"] = editor.arranger.timeline.get_selected_clip_instances()
	return build(editor.project, sel)


## Items from an explicit selection: `{tracks, active_track, range, clips, channels}` (all optional).
static func build(project: Project, sel: Dictionary) -> Array:
	var items: Array = []
	if project == null:
		return items
	var track_item := _track_item(sel.get("tracks", []), sel.get("active_track"))
	if not track_item.is_empty():
		items.append(track_item)
	var range_item := _range_item(project, sel.get("range", {}))
	if not range_item.is_empty():
		items.append(range_item)
	var clips_item := _clips_item(project, sel.get("clips", []))
	if not clips_item.is_empty():
		items.append(clips_item)
	var channel_item := _channel_item(project, sel.get("channels", []))
	if not channel_item.is_empty():
		items.append(channel_item)
	return items


## Icon texture for an item, or null.
static func icon_for(item: Dictionary) -> Texture2D:
	var path := str(item.get("icon", ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return load(path)


## Item color whether it holds a Color or a stored html string.
static func color_for(item: Dictionary) -> Color:
	var c = item.get("color", CLIP_COLOR)
	if c is Color:
		return c
	return Color.from_string(str(c), CLIP_COLOR)


## Storage form (color as html) for conversation files.
static func to_storage(items: Array) -> Array:
	var out: Array = []
	for item in items:
		if not item is Dictionary:
			continue
		var d: Dictionary = item.duplicate()
		d["color"] = color_for(item).to_html(false)
		out.append(d)
	return out


static func _item(kind: String, key: String, label: String, color: Color, text: String) -> Dictionary:
	return {
		"kind": kind,
		"key": "%s:%s" % [kind, key],
		"label": label,
		"icon": ICON_DIR + str(ICONS.get(kind, "")),
		"color": color,
		"text": text,
	}


static func _track_item(tracks: Array, active: Track) -> Dictionary:
	var list: Array = []
	for t in tracks:
		if t is Track and not list.has(t):
			list.append(t)
	if active and not list.has(active):
		list.append(active)
	if list.is_empty():
		return {}
	var names: PackedStringArray = []
	for t in list:
		names.append(t.name)
	var color: Color = (active if active else list[0]).get_color()
	if list.size() == 1:
		var t: Track = list[0]
		return _item("track", t.name, t.name, color, "Track: \"%s\" (%s)" % [t.name, AiTool.track_kind(t)])
	var quoted := _quoted(names)
	var text := "Tracks: %s" % quoted
	if active:
		text += " (active: \"%s\")" % active.name
	return _item("track", ",".join(names), "%d tracks" % list.size(), color, text)


static func _range_item(project: Project, r: Dictionary) -> Dictionary:
	if not r.get("has", false):
		return {}
	var start := int(r.get("start", 0))
	var start_s := _bbt(project, start)
	if r.get("has_end", false) and int(r.get("end", 0)) > start:
		var end := int(r.end)
		var tpb := ClipTextTime.ticks_per_bar(project.ppq, project.time_numerator, project.time_denominator)
		var bars := float(end - start) / tpb
		var bars_s := str(int(bars)) if is_equal_approx(bars, roundf(bars)) else "%.2f" % bars
		return _item("range", "%d-%d" % [start, end], "%s–%s" % [_short_bbt(project, start), _short_bbt(project, end)], RANGE_COLOR,
			"Time range: %s–%s (%s bars, end exclusive)" % [start_s, _bbt(project, end), bars_s])
	return _item("range", str(start), "@ %s" % _short_bbt(project, start), RANGE_COLOR, "Time range start: %s (no end)" % start_s)


static func _clips_item(project: Project, clips: Array) -> Dictionary:
	var insts: Array = []
	for inst in clips:
		if inst is ClipInstance:
			insts.append(inst)
	if insts.is_empty():
		return {}
	insts.sort_custom(func(a, b): return a.start_ticks < b.start_ticks)
	var descs: PackedStringArray = []
	var keys: PackedStringArray = []
	for inst in insts:
		keys.append("%s@%d" % [inst.clip_id, inst.start_ticks])
		if descs.size() >= MAX_ITEMS_LISTED:
			continue
		var clip: Clip = inst.clip
		var clip_name: String = clip.name if clip else inst.clip_id
		var kind := "audio" if clip and clip.type == Clip.ClipType.AUDIO else "midi"
		var detail := kind
		if clip and clip.type != Clip.ClipType.AUDIO:
			detail += ", %d notes" % clip.midi_notes.size()
		descs.append("\"%s\" on \"%s\" at %s–%s (%s)" % [
			clip_name,
			inst.track.name if inst.track else "?",
			_bbt(project, inst.start_ticks),
			_bbt(project, inst.start_ticks + inst.duration_ticks),
			detail,
		])
	var first: ClipInstance = insts[0]
	var color: Color = CLIP_COLOR
	if first.track:
		color = first.track.get_color()
	elif first.clip:
		color = first.clip.color
	var text := ("Clip: " if insts.size() == 1 else "Clips: ") + "; ".join(descs)
	if insts.size() > descs.size():
		text += "; +%d more" % (insts.size() - descs.size())
	var label: String = (first.clip.name if first.clip else "Clip") if insts.size() == 1 else "%d clips" % insts.size()
	return _item("clips", ",".join(keys), label, color, text)


static func _channel_item(project: Project, channels: Array) -> Dictionary:
	var list: Array = []
	for c in channels:
		if c is Channel and not list.has(c):
			list.append(c)
	if list.is_empty():
		return {}
	var descs: PackedStringArray = []
	var names: PackedStringArray = []
	for c in list:
		names.append(c.name)
		if descs.size() >= MAX_ITEMS_LISTED:
			continue
		var devices: PackedStringArray = []
		for d in c.devices:
			if d is DeviceInstance and d.device:
				devices.append(d.address_path(project))
		descs.append("\"%s\" (%s, %.1f dB, pan %.2f, output %s; devices: %s)" % [
			c.name, AiTool.channel_kind(c), c.volume, c.pan,
			AiTool.describe_route_target(project, c.output_channel_id),
			", ".join(devices) if not devices.is_empty() else "none",
		])
	var first: Channel = list[0]
	var color: Color = first.color if first.color != Color.WHITE else CHANNEL_COLOR
	var text := ("Mixer channel: " if list.size() == 1 else "Mixer channels: ") + "; ".join(descs)
	if list.size() > descs.size():
		text += "; +%d more" % (list.size() - descs.size())
	var label: String = first.name if list.size() == 1 else "%d channels" % list.size()
	return _item("channel", ",".join(names), label, color, text)


static func _quoted(names: PackedStringArray) -> String:
	var out: PackedStringArray = []
	for i in range(mini(names.size(), MAX_ITEMS_LISTED)):
		out.append("\"%s\"" % names[i])
	var s := ", ".join(out)
	if names.size() > MAX_ITEMS_LISTED:
		s += " +%d more" % (names.size() - MAX_ITEMS_LISTED)
	return s


static func _bbt(project: Project, ticks: int) -> String:
	return ClipTextTime.format_bbt(ticks, project.ppq, project.time_numerator, project.time_denominator)


## `5.1` (bar.beat) for compact badge labels.
static func _short_bbt(project: Project, ticks: int) -> String:
	var bbt: Dictionary = ClipTextTime.ticks_to_bbt(ticks, project.ppq, project.time_numerator, project.time_denominator)
	return "%d.%d" % [bbt.bar, bbt.beat]

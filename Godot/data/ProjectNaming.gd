# ProjectNaming.gd
# One shared, case-insensitive namespace for track and channel names.
# A track and its paired mixer channel (default_channel_id, never Master) count as one entry,
# so "Drums" always names one thing. Project exposes these through thin wrappers.
class_name ProjectNaming extends RefCounted

## `Hardware Out` and `Hardware Out N` (route target names, see Phase 5 of the AI names plan).
static var _hardware_out_re := RegEx.create_from_string("^hardware out( \\d+)?$")


## True when `candidate` is reserved: `Master` (except for channel 1), `None`, `Hardware Out [N]`.
static func is_reserved(candidate: String, for_channel: Channel = null) -> bool:
	var key := NameStyle.key(candidate)
	if key == "master":
		return for_channel == null or not for_channel.is_master
	if key == "none":
		return true
	return _hardware_out_re.search(key) != null


## Channel paired with `track` for naming, or null (folders without a bus, tracks routed to Master).
static func partner_channel(project: Project, track: Track) -> Channel:
	if project == null or track == null or track.default_channel_id <= 1:
		return null
	return project.get_channel_by_id(track.default_channel_id)


## Tracks in the project paired with `channel` for naming (none for Master).
static func partner_tracks(project: Project, channel: Channel) -> Array[Track]:
	var out: Array[Track] = []
	if project == null or channel == null or channel.is_master:
		return out
	for t in project.tracks:
		if t.default_channel_id == channel.id:
			out.append(t)
	return out


## Every track and channel name except `exclude_track`, `exclude_channel` and their partners
## (a track's channel, and every track routed to that channel).
static func names_in_use(project: Project, exclude_track: Track = null, exclude_channel: Channel = null) -> PackedStringArray:
	var skip_tracks: Array[Track] = partner_tracks(project, exclude_channel)
	var skip_channels: Array[Channel] = []
	if exclude_track:
		skip_tracks.append(exclude_track)
		var partner := partner_channel(project, exclude_track)
		if partner:
			skip_channels.append(partner)
			# Tracks sharing one channel show its name, so they belong to the same entry.
			skip_tracks.append_array(partner_tracks(project, partner))
	if exclude_channel:
		skip_channels.append(exclude_channel)
	var names: PackedStringArray = []
	for t in project.tracks:
		if not skip_tracks.has(t):
			names.append(t.name)
	for ch in project.channels:
		if not skip_channels.has(ch):
			names.append(ch.name)
	return names


## `desired` (sanitized), or `desired N` if taken or reserved. Hardware-out names get `(N)`,
## since every `Hardware Out N` is itself reserved.
static func unique_name(
	project: Project,
	desired: String,
	exclude_track: Track = null,
	exclude_channel: Channel = null,
	fallback: String = "Track"
) -> String:
	var existing := names_in_use(project, exclude_track, exclude_channel)
	var base := DeviceNaming.sanitize(desired, fallback)
	if not _taken(existing, base, exclude_channel):
		return base
	var fmt := "%s (%d)" if _hardware_out_re.search(base.to_lower()) else "%s %d"
	var n := 2
	while _taken(existing, fmt % [base, n], exclude_channel):
		n += 1
	return fmt % [base, n]


## True when `candidate` is used by another entry or reserved.
static func _taken(existing: PackedStringArray, candidate: String, for_channel: Channel) -> bool:
	return DeviceNaming.is_taken(existing, candidate) or is_reserved(candidate, for_channel)


## The track and/or channel called `name` (case-insensitive), as {track, channel}.
## A match on one side fills in its partner when the partner has the same name.
static func find_by_name(project: Project, name: String) -> Dictionary:
	var result := {"track": null, "channel": null}
	if project == null or name.strip_edges().is_empty():
		return result
	for t in project.tracks:
		if DeviceNaming.names_equal(t.name, name):
			result.track = t
			break
	for ch in project.channels:
		if DeviceNaming.names_equal(ch.name, name):
			result.channel = ch
			break
	if result.track and result.channel == null:
		var partner := partner_channel(project, result.track)
		if partner and DeviceNaming.names_equal(partner.name, name):
			result.channel = partner
	if result.channel and result.track == null:
		for t in partner_tracks(project, result.channel):
			if DeviceNaming.names_equal(t.name, name):
				result.track = t
				break
	return result


## Rename duplicate and reserved names after load: channels in id order, then tracks in tree order.
## The first occurrence keeps its name; renames go through the setters so linked pairs stay in sync.
static func dedupe_names(project: Project) -> void:
	if project == null:
		return
	var seen_tracks: Array[Track] = []
	var seen_channels: Array[Channel] = []

	var by_id: Array[Channel] = project.channels.duplicate()
	by_id.sort_custom(func(a: Channel, b: Channel) -> bool: return a.id < b.id)
	for ch in by_id:
		var partners := partner_tracks(project, ch)
		if _collides(ch.name, seen_tracks, seen_channels, partners, ch):
			var old_name := ch.name
			ch.set_name(unique_name(project, old_name, null, ch, "Channel"))
			Project.logger.info("[Project] Renamed duplicate channel %d \"%s\" → \"%s\"" % [ch.id, old_name, ch.name])
		seen_channels.append(ch)
		for t in partners:
			if DeviceNaming.names_equal(t.name, ch.name):
				seen_tracks.append(t)

	var ordered := project.get_visual_track_list()
	for t in project.tracks:
		if not ordered.has(t):
			ordered.append(t)
	for t in ordered:
		if seen_tracks.has(t):
			continue
		var partner := partner_channel(project, t)
		var partners: Array[Track] = partner_tracks(project, partner)
		partners.append(t)
		if _collides(t.name, seen_tracks, seen_channels, partners, partner, false):
			var old_name := t.name
			t.name = unique_name(project, old_name, t)
			Project.logger.info("[Project] Renamed duplicate track %d \"%s\" → \"%s\"" % [t.id, old_name, t.name])
		seen_tracks.append(t)


## True when `candidate` is reserved or used by a seen entry other than the given partners.
static func _collides(
	candidate: String,
	seen_tracks: Array[Track],
	seen_channels: Array[Channel],
	own_tracks: Array[Track],
	own_channel: Channel,
	own_is_channel: bool = true
) -> bool:
	if is_reserved(candidate, own_channel if own_is_channel else null):
		return true
	for t in seen_tracks:
		if not own_tracks.has(t) and DeviceNaming.names_equal(t.name, candidate):
			return true
	for ch in seen_channels:
		if ch != own_channel and DeviceNaming.names_equal(ch.name, candidate):
			return true
	return false

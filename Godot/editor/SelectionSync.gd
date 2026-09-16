# SelectionSync.gd
# Maps arranger track selection to mixer channel selection and back. Editor applies the result
# with the silent setters on TrackList and Mixer, so neither side re-emits and loops.
class_name SelectionSync extends RefCounted


## Channels for `tracks` in selection order, and the active track's channel (tracks without a
## channel are skipped; a shared strip appears once).
static func channels_for_tracks(project: Project, tracks: Array[Track], active: Track) -> Dictionary:
	var channels: Array[Channel] = []
	if project:
		for t in tracks:
			var ch := project.get_track_mixer_channel(t)
			if ch and not channels.has(ch):
				channels.append(ch)
	var focused := project.get_track_mixer_channel(active) if project and active else null
	if focused and not channels.has(focused):
		focused = null
	return {"channels": channels, "focused": focused}


## Tracks routed to `channels` in selection order, and the track paired with `active` (a strip with
## no track, like a bus, selects nothing in the arranger).
static func tracks_for_channels(project: Project, channels: Array[Channel], active: Channel) -> Dictionary:
	var tracks: Array[Track] = []
	if project:
		for ch in channels:
			for t in project.tracks:
				if t.default_channel_id == ch.id and not tracks.has(t):
					tracks.append(t)
	var active_track := project.get_channel_paired_track(active) if project and active else null
	if active_track == null and not tracks.is_empty():
		active_track = tracks.back()
	return {"tracks": tracks, "active": active_track}

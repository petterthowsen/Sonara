# ItemVisibility.gd
# Issue 70: the two per-item states on tracks and channels, and how a view decides whether to list
# one.
#
# Hidden is visual only. Disabled (`enabled == false`) also deactivates the channel's devices in the
# engine. Both cascade: a hidden or disabled Group/Folder track takes its child tracks with it, and a
# channel inherits from its mixer parent. A channel whose routed tracks are all hidden/disabled
# through an ancestor follows them, so a Folder's children vanish from the mixer too.
#
# A view (`Project.arranger_view` / `Project.mixer_view`) carries `show_hidden` and `show_disabled`
# flags that bring the filtered items back.
class_name ItemVisibility extends RefCounted


## True when `track` or any of its ancestors is hidden.
static func track_hidden(project: Object, track: Object) -> bool:
	return _track_chain_any(project, track, func(t: Object) -> bool: return t.hidden)


## True when `track` or any of its ancestors is disabled.
static func track_disabled(project: Object, track: Object) -> bool:
	return _track_chain_any(project, track, func(t: Object) -> bool: return not t.enabled)


## True when `channel`, its mixer parents, or all the tracks playing through it are hidden.
static func channel_hidden(project: Object, channel: Object) -> bool:
	return _channel_flag(project, channel, func(c: Object) -> bool: return c.hidden, track_hidden)


## True when `channel`, its mixer parents, or all the tracks playing through it are disabled.
## This is what the engine receives.
static func channel_disabled(project: Object, channel: Object) -> bool:
	return _channel_flag(project, channel, func(c: Object) -> bool: return not c.enabled, track_disabled)


## Whether the arranger/mixer view `view` lists an item with these effective states.
static func is_listed(view: Dictionary, hidden: bool, disabled: bool) -> bool:
	if hidden and not bool(view.get("show_hidden", false)):
		return false
	if disabled and not bool(view.get("show_disabled", false)):
		return false
	return true


## Row/strip opacity for an item that is listed while hidden or disabled (shown by a toggle).
static func dim_alpha(hidden: bool, disabled: bool) -> float:
	if disabled:
		return 0.45
	return 0.65 if hidden else 1.0


static func track_listed(project: Object, track: Object) -> bool:
	return is_listed(project.arranger_view, track_hidden(project, track), track_disabled(project, track))


## The master strip is always listed.
static func channel_listed(project: Object, channel: Object) -> bool:
	if channel.is_master:
		return true
	return is_listed(project.mixer_view, channel_hidden(project, channel), channel_disabled(project, channel))


static func _track_chain_any(project: Object, track: Object, pred: Callable) -> bool:
	var seen := 0
	var t: Object = track
	while t != null and seen < 64:
		if pred.call(t):
			return true
		t = project.get_track_by_id(t.parent_track_id) if t.parent_track_id >= 0 else null
		seen += 1
	return false


static func _channel_flag(project: Object, channel: Object, own: Callable, track_pred: Callable) -> bool:
	if channel.is_master:
		return false
	var seen := 0
	var c: Object = channel
	while c != null and seen < 64:
		if own.call(c):
			return true
		c = project.get_channel_by_id(c.parent_channel_id) if c.parent_channel_id >= 0 else null
		seen += 1
	if channel.routed_tracks.is_empty():
		return false
	for t in channel.routed_tracks:
		if not track_pred.call(project, t):
			return false
	return true

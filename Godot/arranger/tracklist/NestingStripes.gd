## Left-edge folder/group insets for tracklist rows (TrackItem, AutomationLaneHeader).
##
## A nested row shows one WIDTH-px stripe per ancestor, outermost first, each in that ancestor's
## color, so every enclosing folder's header visibly continues down the left of all its
## descendants, automation lanes included. A single StyleBoxFlat border can only carry one
## color, so rows reserve the space with border_width_left and paint the stripes in _draw.
class_name NestingStripes extends RefCounted

const WIDTH := 12


## Ancestors of `track`, outermost first. Empty for top-level tracks or without a project.
static func ancestors_of(track: Track, project: Project) -> Array[Track]:
	var chain: Array[Track] = []
	if track == null or project == null:
		return chain
	var visited := {track.id: true}
	var parent_id := track.parent_track_id
	while parent_id >= 0 and not visited.has(parent_id):
		visited[parent_id] = true
		var parent := project.get_track_by_id(parent_id)
		if parent == null:
			break
		chain.push_front(parent)
		parent_id = parent.parent_track_id
	return chain


## Connect `on_change` to color/parent changes of `new_chain`, dropping those of `old_chain`.
## Watching ancestors' parent_changed keeps the stripes right when an enclosing folder moves.
static func rebind(old_chain: Array[Track], new_chain: Array[Track], on_change: Callable) -> void:
	for t in old_chain:
		if t.color_changed.is_connected(on_change):
			t.color_changed.disconnect(on_change)
		if t.parent_changed.is_connected(on_change):
			t.parent_changed.disconnect(on_change)
	for t in new_chain:
		if not t.color_changed.is_connected(on_change):
			t.color_changed.connect(on_change)
		if not t.parent_changed.is_connected(on_change):
			t.parent_changed.connect(on_change)


## Paint one stripe per ancestor down the full height of `item`.
static func draw(item: CanvasItem, chain: Array[Track], height: float) -> void:
	for i in chain.size():
		item.draw_rect(Rect2(i * WIDTH, 0.0, WIDTH, height), Utils.display_color(chain[i].color))

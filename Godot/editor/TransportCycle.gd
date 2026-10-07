# TransportCycle.gd
# Pure logic for the "Stop (cycle)" transport action while the transport is not playing.
# Each press does the first step that still changes something:
#   1. playhead -> start position
#   2. start position (and playhead) -> the start of the Marker nearest to it
#   3. start position (and playhead) -> tick 0
# From tick 0 (when no Marker starts there) the next press starts over at step 2.
class_name TransportCycle


## Next positions for a press of the stop cycle while not playing.
## `marker_starts` are the Markers' start ticks. Returns {"start": int, "playhead": int}.
static func next_step(playhead: int, start: int, marker_starts: Array) -> Dictionary:
	if playhead != start:
		return {"start": start, "playhead": start}
	if not marker_starts.is_empty() and not marker_starts.has(start):
		var nearest := nearest_marker_start(start, marker_starts)
		return {"start": nearest, "playhead": nearest}
	if start != 0:
		return {"start": 0, "playhead": 0}
	return {"start": start, "playhead": playhead}


## The marker start closest to `tick`; an earlier start wins a tie.
static func nearest_marker_start(tick: int, marker_starts: Array) -> int:
	var best: int = marker_starts[0]
	for m: int in marker_starts:
		var d := absi(m - tick)
		var best_d := absi(best - tick)
		if d < best_d or (d == best_d and m < best):
			best = m
	return best

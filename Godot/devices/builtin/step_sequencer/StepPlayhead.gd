## StepPlayhead
## Pure model behind the Step Sequencer view's playhead and fired flashes (spec 039 REQ-016,
## REQ-017). It turns the sparse `note_state` blobs (about 20 Hz) into the step to show at any
## moment, advancing by the engine's step timing between blobs. Every method takes `now_ms`, so
## tests drive a fake clock; it never reads a real one.
class_name StepPlayhead extends RefCounted

## No blob for this long clears the playhead.
const TIMEOUT_MS := 500.0
## A fired step that the playhead doesn't reach within this long flashes anyway.
const FLASH_WAIT_MS := 100.0

## Active schedule and the one it replaced. `_prev` stays in force until `_cur` starts.
var _cur: Dictionary = {}
var _prev: Dictionary = {}
var _last_feed_ms: float = -INF
## step -> time (ms) at which its flash is due.
var _pending: Dictionary = {}


## Feed one decoded blob (`NoteStrip.decode`). `latency_ms` delays everything so the playhead
## lines up with what is heard; `length` is the sequencer's Length (steps wrap at it).
func feed(state: Dictionary, now_ms: float, latency_ms: float, length: int) -> void:
	if state.is_empty() or int(state.get("step", -1)) < 0 or length < 1:
		clear()
		return
	var step: int = state["step"]
	var elapsed: int = state.get("elapsed_ms", -1)
	var next_in: int = state.get("next_in_ms", -1)
	var gap_a: int = state.get("gap_a_ms", -1)
	var gap_b: int = state.get("gap_b_ms", -1)
	var display_at := now_ms + latency_ms
	var start := display_at - maxf(float(elapsed), 0.0)
	var schedule := {
		"start": start,
		"step": step,
		"length": length,
		"next_at": display_at + next_in if next_in >= 0 else INF,
		"a": gap_a,
		"b": gap_b if gap_b >= 0 else gap_a,
	}
	if not _cur.is_empty():
		_prev = _cur
	_cur = schedule
	_last_feed_ms = now_ms

	var fired: int = state.get("fired", 0)
	for k in 16:
		if fired & (1 << k):
			_pending[k] = _flash_due(k, step, length, schedule, now_ms)


## The step to show at `now_ms`, or -1 when cleared or stale (no blob for 500 ms).
func step_at(now_ms: float) -> int:
	if _cur.is_empty() or now_ms - _last_feed_ms > TIMEOUT_MS:
		return -1
	if now_ms < _cur["start"] and not _prev.is_empty():
		var old := _eval(_prev, now_ms)
		if old >= 0:
			return old
	if now_ms < _cur["start"]:
		return -1
	return _eval(_cur, now_ms)


## Steps whose flash starts now; each is returned once.
func take_flashes(now_ms: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	if now_ms - _last_feed_ms > TIMEOUT_MS:
		_pending.clear()
		return out
	for k in _pending.keys():
		if now_ms >= _pending[k]:
			out.append(k)
			_pending.erase(k)
	out.sort()
	return out


## True while a blob is recent enough for the playhead to show.
func is_active(now_ms: float) -> bool:
	return step_at(now_ms) >= 0


func clear() -> void:
	_cur = {}
	_prev = {}
	_pending.clear()
	_last_feed_ms = -INF


## When the flash for fired step `k` is due. The engine reports `step` as current; a fired step
## behind it started earlier, estimated from the average gap. A step already reached (or passed)
## is due at once; one still ahead of the delayed display waits for the playhead, at most 100 ms.
func _flash_due(k: int, step: int, length: int, sched: Dictionary, now_ms: float) -> float:
	var back := posmod(step - k, length)
	var due: float = sched["start"]
	if back > 0:
		if sched["a"] < 0:
			return now_ms
		due -= float(back) * (float(sched["a"]) + float(sched["b"])) * 0.5
	return minf(due, now_ms + FLASH_WAIT_MS)


## Step shown by `sched` at `t`. Unknown timing holds the current step; a missing second gap
## repeats the first.
static func _eval(sched: Dictionary, t: float) -> int:
	var step: int = sched["step"]
	var length: int = sched["length"]
	var next_at: float = sched["next_at"]
	if t < next_at:
		return step
	var a: int = sched["a"]
	var b: int = sched["b"]
	if a < 0 or a + b <= 0:
		return (step + 1) % length
	var advanced := 1
	var remaining: float = t - next_at
	var period := float(a + b)
	var cycles := int(floor(remaining / period))
	advanced += cycles * 2
	remaining -= float(cycles) * period
	if remaining >= float(a):
		advanced += 1
		remaining -= float(a)
		if remaining >= float(b):
			advanced += 1
	return posmod(step + advanced, length)

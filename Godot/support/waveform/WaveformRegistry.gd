## WaveformRegistry.gd
## Shares one WaveformData per peak file, so clips and instances that use the same audio file
## (for example after Make Unique) share the textures. Entries are weak: a WaveformData is
## freed once nothing references it, and the next request loads it again.
class_name WaveformRegistry extends RefCounted

static var _entries: Dictionary = {}  # peak_path -> WeakRef(WaveformData)


## The WaveformData for `peak_path`, loading it asynchronously on first use.
static func get_or_load(peak_path: String) -> WaveformData:
	if peak_path.is_empty():
		return null
	var ref: WeakRef = _entries.get(peak_path)
	var data: WaveformData = ref.get_ref() if ref else null
	if data != null and (data.is_ready() or data.is_loading()):
		return data
	data = WaveformData.new()
	_entries[peak_path] = weakref(data)
	data.load_async(peak_path)
	return data


## Number of live entries (for tests).
static func live_count() -> int:
	var n := 0
	for ref: WeakRef in _entries.values():
		if ref.get_ref() != null:
			n += 1
	return n

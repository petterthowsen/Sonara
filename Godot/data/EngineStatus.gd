# EngineStatus.gd
# Engine-wide status stream (not tied to a project): audio callback load.
class_name EngineStatus extends RefCounted

## Emitted for each /status/engine_load report; `load_ratio` is 0.0-1.0 of the callback budget.
signal engine_load_received(load_ratio: float)

var _listening: bool = false


## Start listening for engine status messages.
func start() -> void:
	if _listening:
		return
	AudioEngineOSC.listen("/status/engine_load", _on_engine_load)
	_listening = true


## Stop listening. Call before dropping the last reference (the listener holds one).
func stop() -> void:
	if not _listening:
		return
	AudioEngineOSC.unlisten("/status/engine_load", _on_engine_load)
	_listening = false


func _on_engine_load(values: Array) -> void:
	if values.is_empty():
		return
	engine_load_received.emit(float(values[0]))

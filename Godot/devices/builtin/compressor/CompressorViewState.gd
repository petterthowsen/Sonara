## The compressor view's own settings (Curve / Scope, Peak / RMS metering), kept in the app config
## under `CompressorDefaultView.CONFIG_KEY`. Not device parameters.
class_name CompressorViewState extends RefCounted

var display := 0
var metering := 0


static func from_dict(data: Variant) -> CompressorViewState:
	var state := CompressorViewState.new()
	if data is Dictionary:
		state.display = clampi(int(data.get("display", 0)), 0, 1)
		state.metering = clampi(int(data.get("metering", 0)), 0, 1)
	return state


func to_dict() -> Dictionary:
	return {"display": display, "metering": metering}

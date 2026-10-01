## View state of the EQ panel that isn't a device parameter: which analyser to show, the dB
## range of the curve, and the analyser's resolution, speed and display tilt. Kept in the app config (`devices/eq/view`), so it is the same for every EQ
## and survives a restart. Pure data: no autoload access, so tests can round-trip it.
class_name EqViewState extends RefCounted

## Analyser: POST shows the post-EQ spectrum solid with the pre-EQ one faint behind it, PRE shows
## only the pre-EQ spectrum, OFF shows neither (and the view unsubscribes).
enum Analyser { POST, PRE, OFF }
## FFT size and smoothing width, sent to the engine as the `"resolution"` option (same order).
enum Resolution { LOW, MEDIUM, HIGH, MAX }
## Attack/release of the analyser, sent to the engine as the `"speed"` option (same order).
enum Speed { FAST, MEDIUM, SLOW }

const CONFIG_KEY := "devices/eq/view"
const ANALYSER_NAMES: Array[String] = ["post", "pre", "off"]
const DEFAULT_RANGE_DB := 12.0
const RESOLUTION_NAMES: Array[String] = ["low", "medium", "high", "max"]
const SPEED_NAMES: Array[String] = ["fast", "medium", "slow"]
## Display tilt choices in dB per octave, pivoting at 1 kHz. Positive tilts lift the highs, so a
## typical mix (falling about 4.5 dB/oct) reads roughly flat.
const TILTS: Array[float] = [0.0, 3.0, 4.5, 6.0]

var analyser: int = Analyser.POST
var range_db: float = DEFAULT_RANGE_DB
var resolution: int = Resolution.MEDIUM
var speed: int = Speed.MEDIUM
var tilt_db: float = 0.0


func to_dict() -> Dictionary:
	return {
		"analyser": ANALYSER_NAMES[analyser],
		"range_db": range_db,
		"resolution": RESOLUTION_NAMES[resolution],
		"speed": SPEED_NAMES[speed],
		"tilt_db": tilt_db,
	}


static func from_dict(data: Variant) -> EqViewState:
	var state := EqViewState.new()
	if data is Dictionary:
		var index := ANALYSER_NAMES.find(str(data.get("analyser", "post")))
		state.analyser = index if index >= 0 else Analyser.POST
		var range_value := float(data.get("range_db", DEFAULT_RANGE_DB))
		state.range_db = range_value if range_value in DbGrid.EQ_RANGES else DEFAULT_RANGE_DB
		var resolution_index := RESOLUTION_NAMES.find(str(data.get("resolution", "medium")))
		state.resolution = resolution_index if resolution_index >= 0 else Resolution.MEDIUM
		var speed_index := SPEED_NAMES.find(str(data.get("speed", "medium")))
		state.speed = speed_index if speed_index >= 0 else Speed.MEDIUM
		var tilt := float(data.get("tilt_db", 0.0))
		state.tilt_db = tilt if tilt in TILTS else 0.0
	return state


func duplicate_state() -> EqViewState:
	return EqViewState.from_dict(to_dict())


func equals(other: EqViewState) -> bool:
	return (
		analyser == other.analyser
		and is_equal_approx(range_db, other.range_db)
		and resolution == other.resolution
		and speed == other.speed
		and is_equal_approx(tilt_db, other.tilt_db)
	)

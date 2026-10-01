## View state of the EQ panel that isn't a device parameter: which analyser to show and the dB
## range of the curve. Kept in the app config (`devices/eq/view`), so it is the same for every EQ
## and survives a restart. Pure data: no autoload access, so tests can round-trip it.
class_name EqViewState extends RefCounted

## Analyser: POST shows the post-EQ spectrum solid with the pre-EQ one faint behind it, PRE shows
## only the pre-EQ spectrum, OFF shows neither (and the view unsubscribes).
enum Analyser { POST, PRE, OFF }

const CONFIG_KEY := "devices/eq/view"
const ANALYSER_NAMES: Array[String] = ["post", "pre", "off"]
const DEFAULT_RANGE_DB := 12.0

var analyser: int = Analyser.POST
var range_db: float = DEFAULT_RANGE_DB


func to_dict() -> Dictionary:
	return {"analyser": ANALYSER_NAMES[analyser], "range_db": range_db}


static func from_dict(data: Variant) -> EqViewState:
	var state := EqViewState.new()
	if data is Dictionary:
		var index := ANALYSER_NAMES.find(str(data.get("analyser", "post")))
		state.analyser = index if index >= 0 else Analyser.POST
		var range_value := float(data.get("range_db", DEFAULT_RANGE_DB))
		state.range_db = range_value if range_value in DbGrid.EQ_RANGES else DEFAULT_RANGE_DB
	return state


func duplicate_state() -> EqViewState:
	return EqViewState.from_dict(to_dict())


func equals(other: EqViewState) -> bool:
	return analyser == other.analyser and is_equal_approx(range_db, other.range_db)

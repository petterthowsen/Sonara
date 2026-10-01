## DelayStrategy.gd
## Delay rules: time and feedback first, then mix, tone, stereo and modulation.

class_name DelayStrategy extends GenericStrategy


func role_keywords() -> Dictionary:
	return {
		"mix": ["mix", "dry", "wet", "level", "blend", "balance", "volume", "gain", "output"],
		"feedback": ["feedback", "fb", "repeat*", "regen*"],
		"time": ["time", "delay", "sync", "division", "length", "bpm", "note", "beat*", "link"],
		"tone": ["low", "high", "cut", "filter", "damp*", "tone", "freq*", "lpf", "hpf", "lowcut", "highcut"],
		"stereo": ["pan", "width", "ping", "pong", "pingpong", "stereo", "spread", "cross", "rout*"],
		"character": ["mode", "drive", "tape", "clean"],
		"dynamics": ["duck*"],
		"modulation": ["mod*", "rate", "depth", "wow", "flutter"],
	}


func role_weights() -> Dictionary:
	return {
		"time": 1.0,
		"feedback": 0.95,
		"mix": 0.9,
		"character": 0.7,
		"dynamics": 0.65,
		"tone": 0.5,
		"stereo": 0.45,
		"modulation": 0.35,
		OTHER_ROLE: 0.3,
	}


func groups() -> Array[Dictionary]:
	return [
		{"id": "delay", "title": "Delay", "roles": ["time", "feedback"]},
		{"id": "character", "title": "Character", "roles": ["character"]},
		{"id": "dynamics", "title": "Dynamics", "roles": ["dynamics"]},
		{"id": "mix", "title": "Mix", "roles": ["mix"]},
		{"id": "tone", "title": "Tone", "roles": ["tone"]},
		{"id": "stereo", "title": "Stereo", "roles": ["stereo"]},
		{"id": "modulation", "title": "Modulation", "roles": ["modulation"]},
	]


const TIME_PREFIX := "Time "
const SYNC_PREFIX := "Sync "


## Mark a "Time L"/"Time R" knob with its "Sync L"/"Sync R" sibling, so the knob shows the
## division while Sync is on and its ms value is greyed rather than hidden (research: Timeless
## 3's delay-time knob hid the division behind a tab). Resolved at bind time, so a saved layout
## needs no extra keys.
func decorate_control(control: Dictionary, params: Array) -> Dictionary:
	var ids: Array = control.get("params", [])
	if ids.size() != 1 or String(control.get("kind", "")) not in [SimpleControlKinds.KNOB, SimpleControlKinds.SLIDER]:
		return control
	var time := _by_id(params, int(ids[0]))
	if time == null or not time.name.begins_with(TIME_PREFIX):
		return control
	var sync := _by_name(params, SYNC_PREFIX + time.name.substr(TIME_PREFIX.length()))
	if sync == null:
		return control
	var marked := control.duplicate()
	marked["sync"] = sync.id
	return marked


static func _by_id(params: Array, id: int) -> DeviceParameter:
	for param in params:
		if param != null and param.id == id:
			return param
	return null


static func _by_name(params: Array, name: String) -> DeviceParameter:
	for param in params:
		if param != null and param.name == name:
			return param
	return null

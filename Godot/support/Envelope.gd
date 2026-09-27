# Envelope.gd
# ADSR envelope data for EnvelopeControl: attack, decay and release times in seconds,
# sustain as a level (0–1), each clamped to its own range. `stages` says which parts the
# device actually has ("adsr", "ads", "ad", "asr", ...), so an envelope can be any subset.
#
# Setting a stage property emits its `*_changed` signal (with the clamped value) when the
# value changes, which is how edits reach the device. `set_adsr()` is for syncing from the
# device: it only emits `changed`, so it never echoes back.

@tool
class_name Envelope extends Resource

enum Stage { ATTACK, DECAY, SUSTAIN, RELEASE }

## Stage letters in `stages`, indexed by Stage.
const STAGE_LETTERS := "adsr"
const TIME_STAGES: Array[Stage] = [Stage.ATTACK, Stage.DECAY, Stage.RELEASE]

signal attack_changed(value: float)
signal decay_changed(value: float)
signal sustain_changed(value: float)
signal release_changed(value: float)

## Which stages exist, as letters in ADSR order. Unknown letters are dropped.
@export var stages := "adsr":
	set(v):
		var cleaned := ""
		for letter in STAGE_LETTERS:
			if letter in v.to_lower():
				cleaned += letter
		if cleaned != stages:
			stages = cleaned
			emit_changed()

# Ranges. Times in seconds, sustain as a level.
@export var min_attack := 0.001:
	set(v):
		min_attack = maxf(v, 0.0)
		_reclamp()
@export var max_attack := 2.0:
	set(v):
		max_attack = maxf(v, 0.001)
		_reclamp()
@export var min_decay := 0.001:
	set(v):
		min_decay = maxf(v, 0.0)
		_reclamp()
@export var max_decay := 2.0:
	set(v):
		max_decay = maxf(v, 0.001)
		_reclamp()
@export var min_sustain := 0.0:
	set(v):
		min_sustain = clampf(v, 0.0, 1.0)
		_reclamp()
@export var max_sustain := 1.0:
	set(v):
		max_sustain = clampf(v, 0.0, 1.0)
		_reclamp()
@export var min_release := 0.001:
	set(v):
		min_release = maxf(v, 0.0)
		_reclamp()
@export var max_release := 2.0:
	set(v):
		max_release = maxf(v, 0.001)
		_reclamp()

var _values: Array[float] = [0.01, 0.1, 0.7, 0.3]

@export var attack: float:
	set(v):
		set_stage_value(Stage.ATTACK, v)
	get:
		return _values[Stage.ATTACK]

@export var decay: float:
	set(v):
		set_stage_value(Stage.DECAY, v)
	get:
		return _values[Stage.DECAY]

@export var sustain: float:
	set(v):
		set_stage_value(Stage.SUSTAIN, v)
	get:
		return _values[Stage.SUSTAIN]

@export var release: float:
	set(v):
		set_stage_value(Stage.RELEASE, v)
	get:
		return _values[Stage.RELEASE]


func has_stage(stage: Stage) -> bool:
	return STAGE_LETTERS[stage] in stages


func get_stage_value(stage: Stage) -> float:
	return _values[stage]


func get_stage_min(stage: Stage) -> float:
	match stage:
		Stage.ATTACK: return min_attack
		Stage.DECAY: return min_decay
		Stage.SUSTAIN: return min_sustain
		_: return min_release


func get_stage_max(stage: Stage) -> float:
	match stage:
		Stage.ATTACK: return maxf(max_attack, min_attack)
		Stage.DECAY: return maxf(max_decay, min_decay)
		Stage.SUSTAIN: return maxf(max_sustain, min_sustain)
		_: return maxf(max_release, min_release)


## Set the range of `stage` in one go.
func set_stage_range(stage: Stage, lo: float, hi: float) -> void:
	match stage:
		Stage.ATTACK:
			min_attack = lo
			max_attack = hi
		Stage.DECAY:
			min_decay = lo
			max_decay = hi
		Stage.SUSTAIN:
			min_sustain = lo
			max_sustain = hi
		Stage.RELEASE:
			min_release = lo
			max_release = hi


## Clamp and store `value`; emits the stage's signal and `changed` when it actually changes.
func set_stage_value(stage: Stage, value: float) -> void:
	var clamped := clampf(value, get_stage_min(stage), get_stage_max(stage))
	if is_equal_approx(clamped, _values[stage]):
		return
	_values[stage] = clamped
	_stage_signal(stage).emit(clamped)
	emit_changed()


## Set all four values from the device without emitting the stage signals.
func set_adsr(p_attack: float, p_decay: float, p_sustain: float, p_release: float) -> void:
	var incoming := [p_attack, p_decay, p_sustain, p_release]
	for stage in 4:
		_values[stage] = clampf(incoming[stage], get_stage_min(stage), get_stage_max(stage))
	emit_changed()


func _stage_signal(stage: Stage) -> Signal:
	match stage:
		Stage.ATTACK: return attack_changed
		Stage.DECAY: return decay_changed
		Stage.SUSTAIN: return sustain_changed
		_: return release_changed


## Keep values inside changed ranges, without emitting stage signals.
func _reclamp() -> void:
	for stage in 4:
		_values[stage] = clampf(_values[stage], get_stage_min(stage), get_stage_max(stage))
	emit_changed()


## Serialize to a JSON dictionary.
func to_json() -> Dictionary:
	return {
		"stages": stages,
		"attack": attack,
		"decay": decay,
		"sustain": sustain,
		"release": release,
		"min_attack": min_attack,
		"max_attack": max_attack,
		"min_decay": min_decay,
		"max_decay": max_decay,
		"min_sustain": min_sustain,
		"max_sustain": max_sustain,
		"min_release": min_release,
		"max_release": max_release,
	}


## Deserialize from a JSON dictionary.
static func from_json(data: Dictionary) -> Envelope:
	var envelope := Envelope.new()
	envelope.stages = str(data.get("stages", "adsr"))
	envelope.min_attack = data.get("min_attack", 0.001)
	envelope.max_attack = data.get("max_attack", 2.0)
	envelope.min_decay = data.get("min_decay", 0.001)
	envelope.max_decay = data.get("max_decay", 2.0)
	envelope.min_sustain = data.get("min_sustain", 0.0)
	envelope.max_sustain = data.get("max_sustain", 1.0)
	envelope.min_release = data.get("min_release", 0.001)
	envelope.max_release = data.get("max_release", 2.0)
	envelope.set_adsr(data.get("attack", 0.01), data.get("decay", 0.1), data.get("sustain", 0.7), data.get("release", 0.3))
	return envelope

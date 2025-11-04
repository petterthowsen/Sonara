# Envelope.gd
# Represents an ADSR envelope for audio synthesis.
# Attack, decay, sustain, and release times are in seconds.
# Values are clamped to 0.001-2.0 seconds.

@tool
class_name Envelope extends Resource

var _attack: float = 0.01
var _decay: float = 0.1
var _sustain: float = 0.7
var _release: float = 0.3

var min_attack: float = 0.001:
	set(value):
		min_attack = clamp(value, 0.0, 9.9)
		limits_changed.emit()
		emit_changed()
	get:
		return min_attack

var max_attack: float = 2.0:
	set(value):
		max_attack = clamp(value, 0.01, 10)
		limits_changed.emit()
		emit_changed()
	get:
		return max_attack
var min_decay: float = 0.001:
	set(value):
		min_decay = clamp(value, 0.0, 9.9)
		limits_changed.emit()
		emit_changed()
	get:
		return min_decay

var max_decay: float = 2.0:
	set(value):
		max_decay = clamp(value, 0.1, 10.0)
		limits_changed.emit()
		emit_changed()
	get:
		return max_decay

var min_sustain: float = 0.0:
	set(value):
		min_sustain = clamp(value, 0.0, 1.0)
		limits_changed.emit()
		emit_changed()
	get:
		return min_sustain

var max_sustain: float = 1.0:
	set(value):
		max_sustain = clamp(value, 0.0, 1.0)
		limits_changed.emit()
		emit_changed()
	get:
		return max_sustain

var min_release: float = 0.001:
	set(value):
		min_release = clamp(value, 0.0, 9.9)
		limits_changed.emit()
		emit_changed()
	get:
		return min_release

var max_release: float = 2.0:
	set(value):
		max_release = clamp(value, 0.01, 10.0)
		limits_changed.emit()
		emit_changed()
	get:
		return max_release

@export var attack: float:
	set(value):
		_attack = clamp(value, min_attack, max_attack)
		attack_changed.emit(value)
		emit_changed()
	get:
		return _attack

@export var decay: float:
	set(value):
		_decay = clamp(value, min_decay, max_decay)
		decay_changed.emit(value)
		emit_changed()
	get:
		return _decay

@export var sustain: float:
	set(value):
		_sustain = clamp(value, min_sustain, max_sustain)
		sustain_changed.emit(value)
		emit_changed()
	get:
		return _sustain

@export var release: float:
	set(value):
		_release = clamp(value, min_release, max_release)
		release_changed.emit(value)
		emit_changed()
	get:
		return _release

var attack_normalized: float:
	set(value):
		attack = remap(value, 0, 1, min_attack, max_attack)
	get:
		return attack / max_attack

var decay_normalized: float:
	set(value):
		decay = remap(value, 0, 1, min_decay, max_decay)
	get:
		return decay / max_decay

var sustain_normalized: float:
	set(value):
		sustain = remap(value, 0, 1, min_sustain, max_sustain)
	get:
		return sustain / max_sustain

var release_normalized: float:
	set(value):
		release = remap(value, 0, 1, min_release, max_release)
	get:
		return release / max_release

signal attack_changed(value: float)
signal decay_changed(value: float)
signal sustain_changed(value: float)
signal release_changed(value: float)
signal limits_changed()

var adr_max_length: float:
	get:
		return max_attack + max_decay + max_release


func reset() -> void:
	_attack = 0.01
	_decay = 0.1
	_sustain = 0.7
	_release = 0.3
	
	attack_changed.emit(_attack)
	decay_changed.emit(_decay)
	sustain_changed.emit(_sustain)
	release_changed.emit(_release)
	emit_changed()


func set_adsr(attack: float, decay: float, sustain: float, release: float) -> void:
	_attack = attack
	_decay = decay
	_sustain = sustain
	_release = release
	attack_changed.emit(_attack)
	decay_changed.emit(_decay)
	sustain_changed.emit(_sustain)
	release_changed.emit(_release)
	emit_changed()


## Serialize envelope to JSON dictionary
func to_json() -> Dictionary:
	return {
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
		"max_release": max_release
	}


## Deserialize envelope from JSON dictionary
static func from_json(data: Dictionary) -> Envelope:
	var envelope = Envelope.new()
	envelope.min_attack = data.get("min_attack", 0.001)
	envelope.max_attack = data.get("max_attack", 2.0)
	envelope.min_decay = data.get("min_decay", 0.001)
	envelope.max_decay = data.get("max_decay", 2.0)
	envelope.min_sustain = data.get("min_sustain", 0.0)
	envelope.max_sustain = data.get("max_sustain", 1.0)
	envelope.min_release = data.get("min_release", 0.001)
	envelope.max_release = data.get("max_release", 2.0)
	envelope.attack = data.get("attack", 0.01)
	envelope.decay = data.get("decay", 0.1)
	envelope.sustain = data.get("sustain", 0.7)
	envelope.release = data.get("release", 0.3)
	return envelope

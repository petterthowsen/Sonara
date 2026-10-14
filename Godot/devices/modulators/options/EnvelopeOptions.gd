## ADSR and AD options: the `EnvelopeControl` editor above the stage knobs. The knobs write the
## same parameters as the editor but, unlike it, are modulator targets. AD hides its Sustain and
## Release slots (the modulator has no such parameters).
class_name EnvelopeOptions extends ModulatorOptions

## Modulator parameter IDs by envelope stage (the engine's blocks-of-ten convention).
const STAGE_PARAM := {
	Envelope.Stage.ATTACK: 0,
	Envelope.Stage.DECAY: 10,
	Envelope.Stage.SUSTAIN: 20,
	Envelope.Stage.RELEASE: 30,
}
const STAGES := [Envelope.Stage.ATTACK, Envelope.Stage.DECAY, Envelope.Stage.SUSTAIN, Envelope.Stage.RELEASE]

@onready var envelope_control: EnvelopeControl = %EnvelopeControl

var envelope: Envelope = null


func setup(mod: Modulator) -> void:
	envelope = Envelope.new()
	envelope.stages = "adsr" if mod.kind == "adsr" else "ad"
	for stage in STAGES:
		var param := mod.get_parameter(STAGE_PARAM[stage])
		if param == null or stage == Envelope.Stage.SUSTAIN:
			continue
		var lo := maxf(0.0, param.min_value)
		envelope.set_stage_range(stage, lo, maxf(lo + 0.001, param.max_value))
		if param.is_logarithmic or not is_equal_approx(param.skew, 1.0):
			envelope.set_stage_curve(stage, param.skew, param.is_logarithmic)
	envelope_control.envelope = envelope
	envelope.attack_changed.connect(func(value: float): _commit(mod, Envelope.Stage.ATTACK, value))
	envelope.decay_changed.connect(func(value: float): _commit(mod, Envelope.Stage.DECAY, value))
	envelope.sustain_changed.connect(func(value: float): _commit(mod, Envelope.Stage.SUSTAIN, value))
	envelope.release_changed.connect(func(value: float): _commit(mod, Envelope.Stage.RELEASE, value))
	super.setup(mod)


func sync() -> void:
	super.sync()
	if envelope == null or modulator == null:
		return
	var values: Array[float] = []
	for stage in STAGES:
		var param := modulator.get_parameter(STAGE_PARAM[stage])
		if param == null:
			values.append(envelope.get_stage_value(stage))
		elif stage == Envelope.Stage.SUSTAIN:
			values.append(modulator.get_param(param.id))
		else:
			values.append(param.normalized_to_value(modulator.get_param(param.id)))
	envelope.set_adsr(values[0], values[1], values[2], values[3])


func _commit(mod: Modulator, stage: int, value: float) -> void:
	var param := mod.get_parameter(STAGE_PARAM[stage])
	if param == null:
		return
	if stage == Envelope.Stage.SUSTAIN:
		mod.set_param(param.id, value)
	else:
		mod.set_param(param.id, param.value_to_normalized(value))

class_name Utils extends RefCounted

## Convert linear amplitude (0.0 to 1.0+) to decibels
## Returns db_floor for values <= 0.000001 (default: -60.0 dB)
static func lin_to_db(linear: float, db_floor: float = -60.0) -> float:
	if linear <= 0.000001:
		return db_floor
	return 20.0 * log(linear) / log(10.0)


## Convert decibels to linear amplitude
## -inf dB = 0.0 linear, 0 dB = 1.0 linear, +6 dB ≈ 2.0 linear
static func db_to_lin(db: float) -> float:
	return pow(10.0, db / 20.0)


## Intelligently shorten text for compact displays
## Uses multiple strategies: common abbreviations, first-word shortening, and word selection
static func shorten_text(text: String, max_length: int = 15) -> String:
	if text.length() <= max_length:
		return text
	
	# Common audio/music term abbreviations
	var abbreviations = {
		"Reverb": "Rev",
		"Compressor": "Comp",
		"Equalizer": "EQ",
		"Synthesizer": "Synth",
		"Oscillator": "Osc",
		"Filter": "Flt",
		"Modulator": "Mod",
		"Generator": "Gen",
		"Analyzer": "Anlz",
		"Limiter": "Lim",
		"Distortion": "Dist",
		"Amplifier": "Amp",
		"Envelope": "Env",
		"Frequency": "Freq",
		"Instrument": "Inst",
		"Controller": "Ctrl",
		"Sampler": "Smplr",
		"Sequencer": "Seq"
	}
	
	# First, apply common abbreviations
	var result = text
	for full in abbreviations:
		result = result.replace(full, abbreviations[full])
	
	# If it fits now, we're done
	if result.length() <= max_length:
		return result
	
	# Split into words
	var words = result.split(" ", false)
	if words.size() == 1:
		# Single word - just truncate
		return result.substr(0, max_length - 1) + "."
	
	# Multiple words: abbreviate first word if it's long and we have other words
	if words[0].length() > 7 and words.size() > 1:
		words[0] = words[0][0] + "."
	
	# Try to fit words with spaces
	result = ""
	for i in range(words.size()):
		var test = result
		if i > 0:
			test += " "
		test += words[i]
		
		if test.length() <= max_length:
			result = test
		else:
			# Can't fit this word - try abbreviating it
			if i > 0:
				var abbreviated = words[i].substr(0, min(3, words[i].length()))
				test = result + " " + abbreviated
				if test.length() <= max_length:
					result = test
			break
	
	# Final fallback: just truncate
	if result.is_empty():
		result = text.substr(0, max_length - 1) + "."
	
	return result

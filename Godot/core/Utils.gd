class_name Utils extends RefCounted

## Whether the app was launched with `--test` (see `tests/run_all.sh`).
## Autoloads check this to skip side effects that break headless test runs:
## real MIDI device enumeration, config file I/O, and asset scans.
static func is_test_mode() -> bool:
	return "--test" in OS.get_cmdline_user_args()


## Clamp color components to 0–1 for drawing. Does not mutate the source.
static func display_color(color: Color) -> Color:
	return color.clamp()


## Black or white depending on background luminance, for readable labels.
static func contrasting_text_color(bg: Color) -> Color:
	var drawn := display_color(bg)
	return Color.BLACK if drawn.get_luminance() > 0.179 else Color.WHITE


## Dark halo for light text; fully transparent when the text is black.
static func contrasting_shadow_color(text_color: Color) -> Color:
	if text_color.get_luminance() > 0.5:
		return Color(0, 0, 0, 0.55)
	return Color(0, 0, 0, 0)


## Apply a font color to a Label, including those that use LabelSettings.
static func apply_label_font_color(label: Label, color: Color) -> void:
	if label == null:
		return
	if label.label_settings:
		if not label.label_settings.resource_local_to_scene:
			label.label_settings = label.label_settings.duplicate()
			label.label_settings.resource_local_to_scene = true
		label.label_settings.font_color = color
		label.label_settings.shadow_color = contrasting_shadow_color(color)
	else:
		label.add_theme_color_override("font_color", color)
		label.add_theme_color_override("font_shadow_color", contrasting_shadow_color(color))


## Serialize a Color without clamping HDR components (unlike Color.to_html).
static func color_to_json(color: Color) -> Array:
	return [color.r, color.g, color.b, color.a]


## Load a Color from float RGBA arrays or legacy HTML hex strings.
static func color_from_json(data: Variant, fallback: Color = Color.WHITE) -> Color:
	if data is Array and data.size() >= 3:
		var a: float = data[3] if data.size() > 3 else 1.0
		return Color(float(data[0]), float(data[1]), float(data[2]), a)
	if data is String:
		return Color.from_string(data, fallback)
	return fallback


## Convert linear amplitude (0.0 to 1.0+) to decibels
## Returns db_floor for values <= 0.000001 (default: -60.0 dB)
static func lin_to_db(linear: float, db_floor: float = -60.0) -> float:
	if linear <= 0.000001:
		return db_floor
	return 20.0 * log(linear) / log(10.0)


## Expand a leading `~/` or `$HOME/` to the user's home directory.
static func expand_path(path: String) -> String:
	var home := OS.get_environment("HOME")
	if home.is_empty():
		return path
	if path.begins_with("~/"):
		return home + path.substr(1)
	if path.begins_with("$HOME/"):
		return home + path.substr(5)
	return path


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


## Fuzzy search matching with scoring
## Returns a score from 0.0 (no match) to 1.0 (perfect match)
## Higher scores indicate better matches
static func fuzzy_match(query: String, target: String) -> float:
	if query.is_empty():
		return 1.0  # Empty query matches everything perfectly
	if target.is_empty():
		return 0.0

	var query_lower = query.to_lower()
	var target_lower = target.to_lower()

	# Exact match gets highest score
	if query_lower == target_lower:
		return 1.0

	# Simple substring match
	if target_lower.contains(query_lower):
		var substring_score = 0.8
		# Bonus for matches at word boundaries or start of string
		if target_lower.begins_with(query_lower):
			substring_score += 0.15
		elif target_lower.find(" " + query_lower) >= 0:
			substring_score += 0.1
		return substring_score

	# Multi-word query handling - split by spaces and match each word
	var query_words = query_lower.split(" ", false)
	if query_words.size() > 1:
		var matched_words = 0

		# Match each query word and collect scores
		for i in range(query_words.size()):
			var word = query_words[i]
			if word.is_empty():
				continue

			var word_score = _match_single_word(word, target_lower)
			if word_score > 0.0:
				matched_words += 1

		# Require at least one word to match
		if matched_words == 0:
			return 0.0

		# Calculate base score - weight first word more heavily
		var base_score = 0.0
		var other_word_scores = []

		for i in range(query_words.size()):
			var word = query_words[i]
			if word.is_empty():
				continue

			var word_score = _match_single_word(word, target_lower)
			if word_score > 0.0:
				if i == 0:  # First word gets special treatment
					base_score += word_score * 0.6  # First word is 60% of the score
				else:  # Other words share the remaining 40%
					other_word_scores.append(word_score)

		# Add other word scores
		if other_word_scores.size() > 0:
			var other_weight = 0.4 / other_word_scores.size()
			for score in other_word_scores:
				base_score += score * other_weight

		# Coverage bonus: reward matching more words
		var coverage_ratio = float(matched_words) / float(query_words.size())
		var coverage_bonus = coverage_ratio * 0.2

		# Full coverage bonus: extra points for matching ALL words
		var full_coverage_bonus = 0.0
		if matched_words == query_words.size():
			full_coverage_bonus = 0.15

		# Length penalty: MASSIVELY penalize long strings (shorter is MUCH better)
		var target_length = target.length()
		var length_penalty = 0.0
		if target_length > 15:
			length_penalty = (target_length - 15) * 0.05  # 5% penalty per character over 15
		elif target_length < 8:
			length_penalty = -0.05  # Small bonus for very short names

		# First character bonus: significant bonus if target starts with first query word
		var first_char_bonus = 0.0
		if not target.is_empty() and not query_words[0].is_empty():
			if target_lower.begins_with(query_words[0]):
				first_char_bonus = 0.25  # Strong bonus for starting with first query word

		var final_score = base_score + coverage_bonus + full_coverage_bonus + first_char_bonus - length_penalty
		return clamp(final_score, 0.0, 0.98)

	# Single word fuzzy matching
	return _match_single_word(query_lower, target_lower)


static func _match_single_word(query: String, target: String) -> float:
	# Check for exact substring match with word boundaries
	var substring_score = 0.0
	if target.contains(query):
		# Only give high score if it's a proper word match
		if target.begins_with(query):
			# Check if it's followed by a separator (word boundary)
			var query_len = query.length()
			if target.length() == query_len or target[query_len] in " -_":
				substring_score = 0.9  # Starts with query as a complete word/part
			else:
				substring_score = 0.5  # Starts with query but continues (like "basson" starting with "bass")
		elif target.find(" " + query) >= 0 or target.find("-" + query) >= 0 or target.find("_" + query) >= 0:
			substring_score = 0.8  # Word boundary match
		else:
			# Loose substring match - much lower score
			substring_score = 0.3
		return substring_score

	# Split target into words for better matching
	var target_words = target.split(" ", false)
	for i in range(target_words.size()):
		target_words[i] = target_words[i].strip_edges()

	# Also check hyphen and underscore separated parts
	var hyphen_parts = target.split("-", false)
	var underscore_parts = target.split("_", false)

	# Check each word/part for substring matches
	for word in target_words + hyphen_parts + underscore_parts:
		if word.contains(query):
			var word_score = 0.6
			if word.begins_with(query):
				word_score += 0.2
			return word_score

	# Fuzzy character matching - strict approach
	var query_chars = query.split("")
	var target_chars = target.split("")

	if query_chars.size() > target_chars.size() + 2:  # Allow small length differences
		return 0.0

	var matches = 0
	var query_idx = 0
	var consecutive_matches = 0
	var max_consecutive = 0

	# Greedy matching with consecutive bonus - find each query char in target (in order)
	for target_idx in range(target_chars.size()):
		if query_idx < query_chars.size() and target_chars[target_idx] == query_chars[query_idx]:
			matches += 1
			consecutive_matches += 1
			max_consecutive = max(max_consecutive, consecutive_matches)
			query_idx += 1
		else:
			consecutive_matches = 0

	# Require at least 70% of characters to match in order for fuzzy matching
	var match_ratio = float(matches) / float(query_chars.size())
	if match_ratio < 0.7:
		return 0.0

	# Bonus for consecutive matches (prefer "bass" over scattered b,a,s,s)
	var consecutive_bonus = float(max_consecutive) / float(query_chars.size()) * 0.2

	# Starting character bonus
	var start_bonus = 0.0
	if not target.is_empty() and not query.is_empty() and target[0] == query[0]:
		start_bonus = 0.1

	# Length penalty: MASSIVELY penalize long strings (shorter is MUCH better)
	var target_length = target.length()
	var length_penalty = 0.0
	if target_length > 15:
		length_penalty = (target_length - 15) * 0.05  # 5% penalty per character over 15
	elif target_length < 8:
		length_penalty = -0.05  # Small bonus for very short names

	var final_score = match_ratio + consecutive_bonus + start_bonus - length_penalty
	return clamp(final_score, 0.0, 0.85)

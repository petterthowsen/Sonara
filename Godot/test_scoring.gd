#!/usr/bin/env -S godot --headless -s
# Comprehensive test script for fuzzy search scoring

extends SceneTree

func _init():
	print("Testing comprehensive fuzzy search scoring...")

	# Test cases for different scenarios
	var test_scenarios = [
		{
			"query": "bass sec",
			"targets": [
				{"name": "bass-SEC-KS-C6", "rank": 1, "reason": "short, starts with bass, contains SEC"},
				{"name": "bass-SEC-staccato", "rank": 2, "reason": "medium length, starts with bass, contains SEC"},
				{"name": "bass-clarinet-SOLO-PERF-KS-C6", "rank": 3, "reason": "very long, starts with bass, no SEC"},
				{"name": "bass-SOLO-accent", "rank": 4, "reason": "starts with bass, no SEC"},
				{"name": "basson-SOLO-PERF-KS-C6", "rank": 7, "reason": "similar to bass but doesn't start with it, no SEC"},
				{"name": "all-strings-SEC-pizzicato", "rank": 5, "reason": "long, contains SEC, no bass"},
				{"name": "bassoon-SEC-normal-mod-wheel", "rank": 6, "reason": "long, contains SEC, doesn't start with bass"},
			]
		},
		{
			"query": "piano",
			"targets": [
				{"name": "piano", "rank": 1, "reason": "exact short match"},
				{"name": "electric-piano", "rank": 2, "reason": "starts with piano"},
				{"name": "piano-roll", "rank": 3, "reason": "starts with piano"},
				{"name": "grand-piano-concert", "rank": 5, "reason": "long, contains piano"},
				{"name": "pianissimo", "rank": 4, "reason": "contains piano but different word"},
			]
		},
		{
			"query": "drum kit",
			"targets": [
				{"name": "drum-kit", "rank": 1, "reason": "short, exact match"},
				{"name": "drum-kit-acoustic", "rank": 2, "reason": "starts with drum-kit"},
				{"name": "electronic-drum-kit", "rank": 4, "reason": "longer, contains drum kit"},
				{"name": "drum-machine", "rank": 3, "reason": "contains drum, no kit"},
			]
		}
	]

	var all_passed = true

	for scenario in test_scenarios:
		var query = scenario.query
		var targets = scenario.targets

		print("\n=== Testing query: '%s' ===" % query)

		# Calculate scores for all targets
		var scored_results = []
		for target in targets:
			var score = Utils.fuzzy_match(query, target.name)
			# Debug output for bass sec query
			if query == "bass sec":
				print("      DEBUG %s: score=%.3f" % [target.name, score])
			scored_results.append({
				"name": target.name,
				"score": score,
				"expected_rank": target.rank,
				"reason": target.reason
			})

		# Sort by score (best first)
		scored_results.sort_custom(func(a, b): return a.score > b.score)

		# Print results
		print("Results (sorted by score):")
		for i in range(scored_results.size()):
			var result = scored_results[i]
			var rank_indicator = ""
			if i + 1 == result.expected_rank:
				rank_indicator = "✅"
			else:
				rank_indicator = "❌ (expected rank %d)" % result.expected_rank

			print("  %d. %.3f - %s %s" % [i + 1, result.score, result.name, rank_indicator])
			print("      %s" % result.reason)

		# Check if ranking is correct
		var ranking_correct = true
		for i in range(scored_results.size()):
			if i + 1 != scored_results[i].expected_rank:
				ranking_correct = false
				break

		if ranking_correct:
			print("✅ Ranking is correct for '%s'" % query)
		else:
			print("❌ Ranking needs improvement for '%s'" % query)
			all_passed = false

	if all_passed:
		print("\n🎉 All scoring tests passed!")
		quit(0)
	else:
		print("\n❌ Some scoring tests failed")
		quit(1)

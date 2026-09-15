# test_asset_paths.gd
# Headless tests for AssetPaths (library-relative asset path conversion).
# Run: godot --headless --path Godot -s tests/test_asset_paths.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Asset path tests"


func run_tests() -> void:
	_test_round_trip()
	_test_longest_root_wins()
	_test_duplicate_labels_numbered()
	_test_slash_boundary_required()
	_test_device_ids_pass_through()
	_test_absolute_input_passes_through()
	_test_build_listing_folders_and_files()
	_test_build_listing_recursive_subfolder_counts()
	_test_build_listing_pagination()
	_test_build_listing_unknown_folder()
	_test_build_listing_page_out_of_range()
	_test_build_listing_roots()


func _test_round_trip() -> void:
	var roots := AssetPaths.build_roots(["/home/peter/Music/libs/SFZ"])
	var abs_path := "/home/peter/Music/libs/SFZ/VPO3/Strings/harp-KS-B7.sfz"
	var rel := AssetPaths.to_relative(abs_path, roots)
	_assert(rel == "SFZ/VPO3/Strings/harp-KS-B7.sfz", "abs -> rel: got %s" % rel)
	var back := AssetPaths.to_absolute(rel, roots)
	_assert(back == abs_path, "rel -> abs round trip: got %s" % back)


func _test_longest_root_wins() -> void:
	var roots := AssetPaths.build_roots(["/home/peter/Music/libs", "/home/peter/Music/libs/SFZ"])
	var abs_path := "/home/peter/Music/libs/SFZ/VPO3/x.sfz"
	var rel := AssetPaths.to_relative(abs_path, roots)
	_assert(rel == "SFZ/VPO3/x.sfz", "nested root wins: got %s" % rel)


func _test_duplicate_labels_numbered() -> void:
	var roots := AssetPaths.build_roots(["/a/SFZ", "/b/SFZ", "/c/SFZ"])
	var labels: Array = []
	for root in roots:
		labels.append(root.label)
	_assert(labels == ["SFZ", "SFZ 2", "SFZ 3"], "duplicate labels numbered: got %s" % [labels])


func _test_slash_boundary_required() -> void:
	var roots := AssetPaths.build_roots(["/a/SFZ"])
	var rel := AssetPaths.to_relative("/a/SFZ2/x.sfz", roots)
	_assert(rel == "/a/SFZ2/x.sfz", "no false-positive match on prefix without slash: got %s" % rel)


func _test_device_ids_pass_through() -> void:
	var roots := AssetPaths.build_roots(["/a/SFZ"])
	var device_id := "sonara.builtin.delay"
	_assert(AssetPaths.to_relative(device_id, roots) == device_id, "device path unaffected by to_relative")
	_assert(AssetPaths.to_absolute(device_id, roots) == "", "bare device id has no root, resolved separately by AssetService")


func _test_absolute_input_passes_through() -> void:
	var roots := AssetPaths.build_roots(["/a/SFZ"])
	var abs_path := "/some/other/place/x.wav"
	_assert(AssetPaths.to_absolute(abs_path, roots) == abs_path, "absolute input to_absolute passes through unchanged")


func _vpo_rel_paths() -> Array:
	return [
		"SFZ/VPO3/Strings/1st-violin-SEC-PERF.sfz",
		"SFZ/VPO3/Strings/2nd-violin-SEC-PERF.sfz",
		"SFZ/VPO3/Strings/harp-KS-B7.sfz",
		"SFZ/VPO3/Brass/trumpet-SEC-PERF.sfz",
		"Samples/Drums/kick_01.wav",
	]


func _test_build_listing_folders_and_files() -> void:
	var listing := AssetPaths.build_listing(_vpo_rel_paths(), "SFZ/VPO3", 1, 30)
	var folder_names: Array = []
	for f in listing.folders:
		folder_names.append(f.name)
	_assert(folder_names == ["Brass", "Strings"], "subfolders listed alphabetically: got %s" % [folder_names])
	_assert(listing.files.is_empty(), "no files directly in SFZ/VPO3")
	_assert(listing.total_files == 0, "total_files counts only direct files, got %d" % listing.total_files)


func _test_build_listing_recursive_subfolder_counts() -> void:
	var listing := AssetPaths.build_listing(_vpo_rel_paths(), "SFZ/VPO3", 1, 30)
	var counts := {}
	for f in listing.folders:
		counts[f.name] = f.count
	_assert(counts.get("Strings") == 3, "Strings subfolder counts every file under it, got %s" % counts.get("Strings"))
	_assert(counts.get("Brass") == 1, "Brass subfolder counts its one file, got %s" % counts.get("Brass"))


func _test_build_listing_pagination() -> void:
	var paths: Array = []
	for i in range(35):
		paths.append("SFZ/Strings/file_%02d.sfz" % i)
	var page1 := AssetPaths.build_listing(paths, "SFZ/Strings", 1, 30)
	_assert(page1.files.size() == 30, "page 1 has 30 files, got %d" % page1.files.size())
	_assert(page1.total_pages == 2, "35 files at 30/page is 2 pages, got %d" % page1.total_pages)
	var page2 := AssetPaths.build_listing(paths, "SFZ/Strings", 2, 30)
	_assert(page2.files.size() == 5, "page 2 has the remaining 5 files, got %d" % page2.files.size())


func _test_build_listing_unknown_folder() -> void:
	var listing := AssetPaths.build_listing(_vpo_rel_paths(), "SFZ/DoesNotExist", 1, 30)
	_assert(listing.get("error") == "not_found", "unknown folder returns not_found")


func _test_build_listing_page_out_of_range() -> void:
	var listing := AssetPaths.build_listing(_vpo_rel_paths(), "SFZ/VPO3/Strings", 5, 30)
	_assert(listing.get("error") == "page_out_of_range", "page past the end returns page_out_of_range")
	_assert(listing.get("total_pages") == 1, "reports the actual page count, got %s" % listing.get("total_pages"))


func _test_build_listing_roots() -> void:
	var listing := AssetPaths.build_listing(_vpo_rel_paths(), "", 1, 30)
	var folder_names: Array = []
	for f in listing.folders:
		folder_names.append(f.name)
	_assert(folder_names == ["Samples", "SFZ"], "empty folder lists roots as top-level segments, sorted case-insensitively: got %s" % [folder_names])

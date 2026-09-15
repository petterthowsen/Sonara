# AssetPaths.gd
# Pure helpers for converting between absolute asset paths and library-relative
# paths shown to the AI assistant. Roots are passed in so this stays testable
# headless, without touching AssetService or the filesystem.
class_name AssetPaths


## Root dirs as `[{abs: String, label: String}]`. Label = last folder name, with " 2", " 3"... for duplicates.
static func build_roots(abs_dirs: Array) -> Array[Dictionary]:
	var seen: Dictionary = {}
	var roots: Array[Dictionary] = []
	var label_counts: Dictionary = {}
	for raw in abs_dirs:
		var dir := str(raw)
		dir = Utils.expand_path(dir)
		while dir.ends_with("/") and dir.length() > 1:
			dir = dir.substr(0, dir.length() - 1)
		if dir.is_empty() or seen.has(dir):
			continue
		seen[dir] = true
		var base_label := dir.get_file()
		if base_label.is_empty():
			base_label = dir
		var count: int = label_counts.get(base_label, 0) + 1
		label_counts[base_label] = count
		var label := base_label if count == 1 else "%s %d" % [base_label, count]
		roots.append({"abs": dir, "label": label})
	return roots


## "/home/peter/Music/libs/SFZ/VPO3/Strings/x.sfz" → "SFZ/VPO3/Strings/x.sfz". Longest matching root wins. Returns abs path if no root matches.
static func to_relative(abs_path: String, roots: Array) -> String:
	var best: Dictionary = {}
	var best_len := -1
	for root in roots:
		var root_abs: String = root.get("abs", "")
		if root_abs.is_empty():
			continue
		if abs_path == root_abs or abs_path.begins_with(root_abs + "/"):
			if root_abs.length() > best_len:
				best_len = root_abs.length()
				best = root
	if best.is_empty():
		return abs_path
	var rest: String = abs_path.substr(best.abs.length())
	if rest.begins_with("/"):
		rest = rest.substr(1)
	return best.label + "/" + rest


## Inverse. Accepts an absolute path unchanged. Returns "" if the label is unknown.
static func to_absolute(path: String, roots: Array) -> String:
	if path.begins_with("/"):
		return path
	var slash := path.find("/")
	var label := path if slash < 0 else path.substr(0, slash)
	var rest := "" if slash < 0 else path.substr(slash + 1)
	for root in roots:
		if root.get("label", "") == label:
			if rest.is_empty():
				return root.abs
			return root.abs + "/" + rest
	return ""


## Folder listing for `list_assets`. `folder` is library-relative with no trailing slash
## ("" lists top-level roots). Direct children of `folder` are split into subfolders
## (`{name, count}`, count = every asset anywhere under that subfolder) and files (paginated,
## `per_page` per page, sorted case-insensitively). Returns `{"error": "not_found"}` when nothing
## in `rel_paths` falls under `folder`, or `{"error": "page_out_of_range", "total_pages": N}`.
static func build_listing(rel_paths: Array, folder: String, page: int, per_page: int) -> Dictionary:
	var prefix := "" if folder.is_empty() else folder + "/"
	var folder_counts: Dictionary = {}
	var files: Array[String] = []
	for raw in rel_paths:
		var p := str(raw)
		if not p.begins_with(prefix):
			continue
		var rest := p.substr(prefix.length())
		if rest.is_empty():
			continue
		var slash := rest.find("/")
		if slash >= 0:
			var sub := rest.substr(0, slash)
			folder_counts[sub] = int(folder_counts.get(sub, 0)) + 1
		else:
			files.append(rest)
	if folder_counts.is_empty() and files.is_empty():
		return {"error": "not_found"}
	var folder_names := folder_counts.keys()
	folder_names.sort_custom(func(a, b): return str(a).to_lower() < str(b).to_lower())
	var folders: Array = []
	for name in folder_names:
		folders.append({"name": name, "count": folder_counts[name]})
	files.sort_custom(func(a: String, b: String) -> bool: return a.to_lower() < b.to_lower())
	var total_files := files.size()
	var total_pages := maxi(1, ceili(float(total_files) / per_page))
	if page < 1 or page > total_pages:
		return {"error": "page_out_of_range", "total_pages": total_pages}
	var start := (page - 1) * per_page
	var page_files := files.slice(start, mini(start + per_page, total_files))
	return {
		"folders": folders,
		"files": page_files,
		"total_files": total_files,
		"total_pages": total_pages,
		"page": page,
	}

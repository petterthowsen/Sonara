## SimpleLayoutStore.gd
## Loads, saves and caches Simple View layouts, one JSON file per device id under
## `~/.config/sonara/device_layouts/`. A layout is shared by every instance of a device.

class_name SimpleLayoutStore extends RefCounted

const DIR_NAME := "device_layouts"

enum LoadStatus { OK, MISSING, INVALID }

static var logger := Log.make("SimpleLayoutStore")

## Tests point this at a temp dir; empty means the config dir.
static var base_dir_override: String = ""

static var _cache: Dictionary[String, SimpleLayout] = {}
static var _unsafe_chars := RegEx.create_from_string("[^A-Za-z0-9._-]")


## Directory the layout files live in.
static func base_dir() -> String:
	if not base_dir_override.is_empty():
		return base_dir_override
	# Looked up at runtime so headless tests, which compile before autoloads exist, can load this.
	var tree := Engine.get_main_loop() as SceneTree
	var sonara := tree.root.get_node_or_null("Sonara") if tree != null else null
	var config_dir: String = sonara.get_config_dir() if sonara != null \
		else OS.get_environment("HOME").path_join(".config/sonara")
	return config_dir.path_join(DIR_NAME)


## File path for `device_id`: unsafe chars become `_`, plus a short hash of the raw id so
## ids that sanitize alike still get different files.
static func path_for(device_id: String) -> String:
	var safe := _unsafe_chars.sub(device_id, "_", true)
	return base_dir().path_join("%s-%s.json" % [safe, device_id.md5_text().left(8)])


## Read the layout file for `device_id`. Returns `{status: LoadStatus, layout: SimpleLayout|null}`.
## An unparseable file or an unknown version is INVALID.
static func load_layout(device_id: String) -> Dictionary:
	var path := path_for(device_id)
	if not FileAccess.file_exists(path):
		return {"status": LoadStatus.MISSING, "layout": null}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		logger.warning("Layout file %s is not valid JSON (line %d: %s)" % [path, json.get_error_line(), json.get_error_message()])
		return {"status": LoadStatus.INVALID, "layout": null}
	var layout := SimpleLayout.from_dict(json.data)
	if layout == null:
		logger.warning("Layout file %s has an unknown version or shape" % path)
		return {"status": LoadStatus.INVALID, "layout": null}
	layout.device_id = device_id
	for problem in layout.validate():
		logger.warning("Layout file %s: %s" % [path, problem])
	return {"status": LoadStatus.OK, "layout": layout}


## Write `layout` to its file (via a temp file and rename) and cache it. Returns true on success.
static func save(layout: SimpleLayout) -> bool:
	var path := path_for(layout.device_id)
	var err := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if err != OK and err != ERR_ALREADY_EXISTS:
		logger.error("Can't create %s: %s" % [path.get_base_dir(), error_string(err)])
		return false
	var tmp_path := path + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		logger.error("Can't write %s: %s" % [tmp_path, error_string(FileAccess.get_open_error())])
		return false
	file.store_string(JSON.stringify(layout.to_dict(), "\t", false) + "\n")
	file.close()
	err = DirAccess.rename_absolute(tmp_path, path)
	if err != OK:
		logger.error("Can't replace %s: %s" % [path, error_string(err)])
		return false
	_cache[layout.device_id] = layout
	return true


## The layout for `device`: from the cache, else its file, else newly generated and saved.
## A broken file is left untouched and a generated layout is used instead (REQ-017).
## Loaded layouts are reconciled with `params` (REQ-016) unless `params` is empty.
static func load_or_generate(device: Device, params: Array) -> SimpleLayout:
	var device_id := device.device_id
	var layout: SimpleLayout = _cache.get(device_id)
	if layout == null:
		var result := load_layout(device_id)
		match result.status:
			LoadStatus.OK:
				layout = result.layout
				logger.info("loaded layout for %s from %s" % [device_id, path_for(device_id)])
			LoadStatus.INVALID:
				layout = SimpleLayoutGenerator.generate(device, params)
				logger.warning("Using a generated layout for %s; the broken file was not overwritten" % device_id)
			_:
				layout = SimpleLayoutGenerator.generate(device, params)
				if save(layout):
					logger.info("generated layout for %s at %s" % [device_id, path_for(device_id)])
		_cache[device_id] = layout
	if not params.is_empty():
		layout.reconcile(params)
	return layout


## Replace the layout for `device` with a newly generated one and overwrite its file (REQ-015).
static func regenerate(device: Device, params: Array) -> SimpleLayout:
	var layout := SimpleLayoutGenerator.generate(device, params)
	save(layout)
	_cache[device.device_id] = layout
	return layout


## Forget cached layouts so the next load reads the files again.
static func clear_cache() -> void:
	_cache.clear()

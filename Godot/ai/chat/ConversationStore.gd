# ConversationStore.gd
# Per-project sidecar (`*.aichat/`) or untitled scratch folder.
class_name ConversationStore extends RefCounted


const INDEX_NAME := "index.json"
const SCRATCH_REL := "aichat/scratch"
const SAVE_DEBOUNCE_SEC := 0.3

var _dir: String = ""
var _index: Dictionary = {"active_id": "", "conversations": []}
var _current: Conversation = null
var _bound_path: String = ""
var _save_due: bool = false
var _save_at_msec: int = 0


## Empty path → scratch under ~/.config/sonara/aichat/scratch.
func bind_project(project_path: String) -> void:
	autosave_current()
	_bound_path = project_path
	if project_path.is_empty():
		_dir = _scratch_dir()
	else:
		_dir = _sidecar_dir(project_path)
	DirAccess.make_dir_recursive_absolute(_dir)
	_index = _read_index()
	_current = null
	var active_id := str(_index.get("active_id", ""))
	if not active_id.is_empty() and FileAccess.file_exists(_conv_path(active_id)):
		_current = load_conversation(active_id)
	if _current == null:
		_current = create()


## Flush and forget the bound folder.
func unbind() -> void:
	autosave_current()
	_dir = ""
	_bound_path = ""
	_current = null
	_index = {"active_id": "", "conversations": []}


## Index entries (id / title / updated_unix).
func list_conversations() -> Array:
	var entries = _index.get("conversations", [])
	return entries if entries is Array else []


## Load one conversation file. Null if missing.
func load_conversation(id: String) -> Conversation:
	var path := _conv_path(id)
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		push_warning("[ConversationStore] Invalid conversation file")
		return null
	return Conversation.from_storage(parsed)


## Write one conversation and refresh the index entry.
func save(conversation: Conversation) -> void:
	if _dir.is_empty() or conversation == null or conversation.id.is_empty():
		return
	conversation.touch()
	DirAccess.make_dir_recursive_absolute(_dir)
	_atomic_write(_conv_path(conversation.id), JSON.stringify(conversation.to_storage(), "\t"))
	_upsert_index(conversation)
	_atomic_write(_index_path(), JSON.stringify(_index, "\t"))


## Create, persist, and activate a new conversation.
func create() -> Conversation:
	var c := Conversation.create_new()
	c.title = "New chat"
	_current = c
	_index["active_id"] = c.id
	save(c)
	return c


## Delete a conversation file. Creates a replacement if the last one is removed.
func delete_conversation(id: String) -> void:
	if _dir.is_empty() or id.is_empty():
		return
	var path := _conv_path(id)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var kept: Array = []
	for entry in list_conversations():
		if entry is Dictionary and str(entry.get("id", "")) != id:
			kept.append(entry)
	_index["conversations"] = kept
	if str(_index.get("active_id", "")) == id:
		_index["active_id"] = str(kept[0].id) if not kept.is_empty() else ""
		_current = null
	_atomic_write(_index_path(), JSON.stringify(_index, "\t"))
	if _current == null:
		if not kept.is_empty():
			_current = load_conversation(str(kept[0].id))
		if _current == null:
			_current = create()


## Move scratch files next to a newly saved project.
func migrate_scratch_to(project_path: String) -> void:
	if project_path.is_empty():
		return
	var dest := _sidecar_dir(project_path)
	if dest == _dir:
		_bound_path = project_path
		return
	autosave_current()
	DirAccess.make_dir_recursive_absolute(dest)
	var src := _dir
	if src.is_empty() or not DirAccess.dir_exists_absolute(src):
		bind_project(project_path)
		return
	var da := DirAccess.open(src)
	if da:
		da.list_dir_begin()
		var name := da.get_next()
		while name != "":
			if name != "." and name != "..":
				var from_path := src.path_join(name)
				var to_path := dest.path_join(name)
				if FileAccess.file_exists(to_path):
					DirAccess.remove_absolute(to_path)
				DirAccess.copy_absolute(from_path, to_path)
			name = da.get_next()
		da.list_dir_end()
	_dir = dest
	_bound_path = project_path
	_index = _read_index()
	if _current:
		save(_current)
	print("[ConversationStore] Migrated scratch → %s" % dest)


## Write the active conversation immediately.
func autosave_current() -> void:
	_save_due = false
	if _current:
		save(_current)


## Mark the current conversation dirty; flush after a short debounce.
func schedule_save() -> void:
	if _current == null:
		return
	_current.touch()
	_save_due = true
	_save_at_msec = Time.get_ticks_msec() + int(SAVE_DEBOUNCE_SEC * 1000.0)


## Flush if the debounce window has elapsed. Call from `_process`.
func poll_autosave() -> void:
	if _save_due and Time.get_ticks_msec() >= _save_at_msec:
		autosave_current()


func get_current() -> Conversation:
	return _current


func set_current(conversation: Conversation) -> void:
	autosave_current()
	_current = conversation
	if conversation:
		_index["active_id"] = conversation.id
		_upsert_index(conversation)
		_atomic_write(_index_path(), JSON.stringify(_index, "\t"))


func get_active_id() -> String:
	return str(_index.get("active_id", ""))


func is_scratch() -> bool:
	return _bound_path.is_empty() and not _dir.is_empty()


func _scratch_dir() -> String:
	var tree := Engine.get_main_loop() as SceneTree
	if tree and tree.root:
		var sonara := tree.root.get_node_or_null("Sonara")
		if sonara:
			return str(sonara.call("get_config_dir")).path_join(SCRATCH_REL)
	return OS.get_environment("HOME").path_join(".config/sonara").path_join(SCRATCH_REL)


func _sidecar_dir(project_path: String) -> String:
	var base := project_path.get_basename()
	if base.is_empty():
		return _scratch_dir()
	return base + ".aichat"


func _index_path() -> String:
	return _dir.path_join(INDEX_NAME)


func _conv_path(id: String) -> String:
	if _dir.is_empty() or id.is_empty():
		return ""
	return _dir.path_join("%s.json" % id)


func _read_index() -> Dictionary:
	var path := _index_path()
	if not FileAccess.file_exists(path):
		return {"active_id": "", "conversations": []}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		if not parsed.has("conversations"):
			parsed["conversations"] = []
		if not parsed.has("active_id"):
			parsed["active_id"] = ""
		return parsed
	return {"active_id": "", "conversations": []}


func _upsert_index(conversation: Conversation) -> void:
	var entries: Array = list_conversations()
	var found := false
	for i in range(entries.size()):
		if entries[i] is Dictionary and str(entries[i].get("id", "")) == conversation.id:
			entries[i] = conversation.to_index_entry()
			found = true
			break
	if not found:
		entries.append(conversation.to_index_entry())
	_index["conversations"] = entries
	_index["active_id"] = conversation.id


func _atomic_write(path: String, text: String) -> void:
	if path.is_empty():
		return
	var tmp := path + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		push_warning("[ConversationStore] Could not write %s" % tmp)
		return
	file.store_string(text)
	file.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		DirAccess.copy_absolute(tmp, path)
		DirAccess.remove_absolute(tmp)

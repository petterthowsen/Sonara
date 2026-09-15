# test_conversation_scope.gd
# Headless tests for per-project conversation scoping in ConversationStore.
# Run: godot --headless --path Godot -s ai/tests/test_conversation_scope.gd -- --test
extends TestBase


var _root: String = ""


func suite_name() -> String:
	return "Conversation scope tests"


func run_tests() -> void:
	_root = OS.get_user_data_dir().path_join("test_conversation_scope_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_root)
	_test_projects_are_isolated()
	_test_reopen_restores_active()
	_test_fresh_scratch()
	_test_scratch_migrates_and_empties()
	_test_save_as_copies()
	_test_save_over_keeps_dest_chats()
	_test_title_from_first_message()
	_test_repair_titles_and_prune_empty()
	ConversationStore._remove_dir_recursive(_root)


func _store() -> ConversationStore:
	var s := ConversationStore.new()
	s.scratch_dir_override = _root.path_join("scratch")
	return s


func _ids(store: ConversationStore) -> Array:
	var out: Array = []
	for e in store.list_conversations():
		out.append(str(e.id))
	return out


func _test_projects_are_isolated() -> void:
	var s := _store()
	s.bind_project(_root.path_join("a.sonara"))
	var a_id := s.get_current().id
	s.bind_project(_root.path_join("b.sonara"))
	var b_id := s.get_current().id
	_assert(not _ids(s).has(a_id), "project B does not list project A's chats")
	_assert(_ids(s) == [b_id], "project B lists only its own chat")
	s.bind_project(_root.path_join("a.sonara"))
	_assert(_ids(s) == [a_id], "project A lists only its own chat")


func _test_reopen_restores_active() -> void:
	var s := _store()
	var path := _root.path_join("reopen.sonara")
	s.bind_project(path)
	var first := s.get_current().id
	var second := s.create()
	second.messages.append(ChatTypes.ORChatMessage.user_text("Second"))
	s.save(second)
	s.set_current(s.load_conversation(first))
	s.unbind()
	var s2 := _store()
	s2.bind_project(path)
	_assert(s2.get_current().id == first, "reopening a project restores its last active conversation")
	_assert(_ids(s2).size() == 2, "reopened project lists both chats")


func _test_fresh_scratch() -> void:
	var s := _store()
	s.bind_project("", true)
	var old_id := s.get_current().id
	s.unbind()
	s.bind_project("", true)
	_assert(not _ids(s).has(old_id), "a new untitled project starts with empty scratch")
	_assert(s.is_scratch(), "store is bound to scratch")


func _test_scratch_migrates_and_empties() -> void:
	var s := _store()
	s.bind_project("", true)
	var id := s.get_current().id
	var path := _root.path_join("saved.sonara")
	s.migrate_to(path)
	_assert(s.get_bound_path() == path, "store rebinds to the saved project")
	_assert(_ids(s).has(id), "scratch chat moved into the project")
	_assert(not FileAccess.file_exists(_root.path_join("scratch").path_join("%s.json" % id)), "scratch emptied after migration")


func _test_save_as_copies() -> void:
	var s := _store()
	var src := _root.path_join("orig.sonara")
	s.bind_project(src)
	var id := s.get_current().id
	var dest := _root.path_join("copy.sonara")
	s.migrate_to(dest)
	_assert(_ids(s).has(id), "Save As carries chats to the new project")
	_assert(FileAccess.file_exists(_root.path_join("orig.aichat").path_join("%s.json" % id)), "original project keeps its chats")


func _test_title_from_first_message() -> void:
	var s := _store()
	s.bind_project(_root.path_join("titles.sonara"))
	var conv := s.get_current()
	conv.messages.append(ChatTypes.ORChatMessage.user_text("Make a bassline\nin C minor"))
	conv.ensure_title_from_first_user()
	_assert(conv.title == "Make a bassline", "new chat takes its title from the first user line: %s" % conv.title)


func _test_repair_titles_and_prune_empty() -> void:
	var s := _store()
	var path := _root.path_join("repair.sonara")
	s.bind_project(path)
	var filled := s.get_current()
	filled.messages.append(ChatTypes.ORChatMessage.user_text("Add drums"))
	s.save(filled)
	var empty := s.create()
	var active := s.create()
	active.messages.append(ChatTypes.ORChatMessage.user_text("Mix it"))
	s.save(active)
	s.unbind()
	var s2 := _store()
	s2.bind_project(path)
	var titles := {}
	for e in s2.list_conversations():
		titles[str(e.id)] = str(e.title)
	_assert(not titles.has(empty.id), "empty non-active chat is pruned")
	_assert(titles.get(filled.id, "") == "Add drums", "placeholder title repaired from first message")
	_assert(titles.get(active.id, "") == "Mix it", "active chat title repaired")
	_assert(s2.get_current().id == active.id, "active chat still reopened")


func _test_save_over_keeps_dest_chats() -> void:
	var s := _store()
	var dest := _root.path_join("existing.sonara")
	s.bind_project(dest)
	var dest_id := s.get_current().id
	s.get_current().messages.append(ChatTypes.ORChatMessage.user_text("Existing"))
	s.save(s.get_current())
	s.bind_project(_root.path_join("other.sonara"))
	var src_id := s.get_current().id
	s.migrate_to(dest)
	_assert(_ids(s).has(dest_id), "saving over a project keeps its existing chats")
	_assert(_ids(s).has(src_id), "saving over a project adds the current chats")
	_assert(s.get_active_id() == src_id, "current chat stays active after saving over")

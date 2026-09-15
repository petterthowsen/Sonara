# ToolRegistry.gd
# Named AiTool lookup and OpenRouter schema export.
class_name ToolRegistry extends RefCounted


var _tools: Dictionary = {}


## Register a tool (last one wins on name clash).
func register(tool: AiTool) -> void:
	if tool == null:
		return
	var n := tool.get_name()
	if n.is_empty():
		push_warning("[ToolRegistry] Tool with empty name ignored")
		return
	_tools[n] = tool


## All tools as OpenRouter `tools[]` items.
func get_openrouter_tools() -> Array:
	var out: Array = []
	for tool in _tools.values():
		if tool is AiTool:
			out.append(tool.to_openrouter())
	return out


## Look up a tool by name.
func get_tool(name: String) -> AiTool:
	return _tools.get(name)


## Execute by name. Unknown → `{ok:false}`. Always awaited so async tools are legal.
func execute(name: String, args: Dictionary) -> Dictionary:
	var tool: AiTool = _tools.get(name)
	if tool == null:
		return AiTool.fail("Unknown tool: %s" % name)
	if args == null:
		args = {}
	var result = await tool.execute(args)
	if result is Dictionary:
		return result
	return AiTool.fail("Tool %s returned a non-dict result" % name)


## Default Phase 2 DAW tools.
static func create_default() -> ToolRegistry:
	var reg := ToolRegistry.new()
	reg.register(ListProjectTool.new())
	reg.register(ListTracksTool.new())
	reg.register(ListChannelsTool.new())
	reg.register(ListDevicesTool.new())
	reg.register(SearchAssetsTool.new())
	reg.register(ListAssetsTool.new())
	reg.register(CreateTrackTool.new())
	reg.register(RenameTrackTool.new())
	reg.register(SetTrackColorTool.new())
	reg.register(DeleteTrackTool.new())
	reg.register(SetMixerTool.new())
	reg.register(RouteChannelTool.new())
	reg.register(AddSendTool.new())
	reg.register(CreateBusTool.new())
	reg.register(AddDeviceTool.new())
	reg.register(RemoveDeviceTool.new())
	reg.register(SetDeviceTool.new())
	reg.register(GetDeviceTool.new())
	reg.register(SetDeviceParamsTool.new())
	reg.register(LoadDeviceFileTool.new())
	reg.register(MoveDeviceTool.new())
	reg.register(ListClipsTool.new())
	reg.register(ReadClipTool.new())
	reg.register(WriteClipTool.new())
	reg.register(CreateClipTool.new())
	reg.register(PlaceClipTool.new())
	reg.register(RenameClipTool.new())
	return reg

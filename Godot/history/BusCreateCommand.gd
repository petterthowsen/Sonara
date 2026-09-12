# BusCreateCommand.gd
# Undoable mixer bus creation (keeps Channel identity).
class_name BusCreateCommand extends Command


var project: Project = null
var channel: Channel = null
var bus_name: String = "Bus"


## Create a bus-create command. If channel already exists, use record().
func _init(p_project: Project = null, p_name: String = "Bus", p_channel: Channel = null) -> void:
	name = "Create Bus"
	project = p_project
	bus_name = p_name
	channel = p_channel


## Create (or re-add) the bus channel.
func do() -> void:
	if project == null:
		return
	if channel != null:
		if project.get_channel_by_id(channel.id) == null:
			project.add_channel(channel)
		return
	channel = project.create_bus_channel(bus_name)


## Remove the bus channel.
func undo() -> void:
	if project == null or channel == null:
		return
	project.remove_channel(channel.id)

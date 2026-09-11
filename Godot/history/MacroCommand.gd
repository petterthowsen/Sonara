# MacroCommand.gd
# Ordered list of child commands treated as one undo/redo step.
# do() runs children forward; undo() runs them in reverse.
class_name MacroCommand extends Command

## Child commands executed in order.
var commands: Array[Command] = []


## Create a named macro optionally seeded with child commands.
func _init(p_name: String = "Macro", p_commands: Array = []) -> void:
	name = p_name
	for cmd in p_commands:
		if cmd is Command:
			commands.append(cmd)


## Append a child command.
func add(cmd: Command) -> void:
	commands.append(cmd)


## Run every child do() in order.
func do() -> void:
	for cmd in commands:
		cmd.do()


## Run every child undo() in reverse order.
func undo() -> void:
	for i in range(commands.size() - 1, -1, -1):
		commands[i].undo()

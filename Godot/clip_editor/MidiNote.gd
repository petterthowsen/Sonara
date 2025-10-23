# MidiNote.gd

class_name MidiNote extends PanelContainer

@onready var label: Label = $Label

signal request_remove()
signal request_select()
signal request_move()

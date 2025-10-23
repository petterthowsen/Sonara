extends Control

@onready var volume_slider: HSlider = $PanelContainer/VBoxContainer/Vol/VolumeSlider
@onready var vol_spin_box: SpinBox = $PanelContainer/VBoxContainer/Freq/VolSpinBox
@onready var start: Button = $PanelContainer/VBoxContainer/HBoxContainer/Start
@onready var stop: Button = $PanelContainer/VBoxContainer/HBoxContainer/Stop

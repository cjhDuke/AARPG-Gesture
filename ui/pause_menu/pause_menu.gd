extends CanvasLayer
## 暂停菜单（autoload: PauseMenu）：RESUME / TITLE / QUIT

const TITLE_SCENE : String = "res://ui/title/title_scene.tscn"

signal shown
signal hidden

@onready var button_resume: Button = %Button_Resume
@onready var button_title: Button = %Button_Title
@onready var button_quit: Button = %Button_Quit

var is_paused : bool = false


func _ready() -> void:
	hide_pause_menu()
	button_resume.pressed.connect( hide_pause_menu )
	button_title.pressed.connect( _on_title_pressed )
	button_quit.pressed.connect( _on_quit_pressed )


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if LevelManager.is_loading_level:
			return
		if is_paused == false:
			show_pause_menu()
		else:
			hide_pause_menu()
		get_viewport().set_input_as_handled()


func show_pause_menu() -> void:
	get_tree().paused = true
	visible = true
	is_paused = true
	button_resume.grab_focus()
	shown.emit()


func hide_pause_menu() -> void:
	get_tree().paused = false
	visible = false
	is_paused = false
	hidden.emit()


func _on_title_pressed() -> void:
	hide_pause_menu()
	LevelManager.load_new_level( TITLE_SCENE )


func _on_quit_pressed() -> void:
	get_tree().quit()

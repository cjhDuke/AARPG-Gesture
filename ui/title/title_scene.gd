extends Node2D

const START_LEVEL: String = "res://levels/guard/guard_arena.tscn"
## 标题背景的镜头位置（主角被隐藏，只借用它身上的 Camera2D）
const CAMERA_POS := Vector2(230, 132)

@export var music: AudioStream
@export var button_focus_audio: AudioStream
@export var button_press_audio: AudioStream

@onready var title_ui: Control = $CanvasLayer/Control
@onready var button_start: Button = $CanvasLayer/Control/Button_start
@onready var button_quit: Button = $CanvasLayer/Control/Button_quit
@onready var audio_stream_player: AudioStreamPlayer = $AudioStreamPlayer
@onready var splash_screen: Control = $CanvasLayer/SplashScreen


func _ready() -> void:
	get_tree().paused = true
	# 从游戏里返回标题时，加载流程结束会取消暂停，这里重新暂停
	LevelManager.level_loaded.connect( _pause_tree )
	PlayerManager.player.visible = false
	PlayerManager.player.global_position = CAMERA_POS
	
	PlayerHud.visible = false
	PauseMenu.process_mode = Node.PROCESS_MODE_DISABLED

	title_ui.visible = false
	
	splash_screen.finished.connect(setup_title_screen)
	
	LevelManager.level_load_started.connect(exit_title_screen)


func setup_title_screen() -> void:
	if is_instance_valid(splash_screen):
		splash_screen.queue_free()

	title_ui.visible = true

	AudioManager.play_music(music)
	button_start.pressed.connect(start_game)
	button_quit.pressed.connect(quit_game)
	button_start.grab_focus()
	
	button_start.focus_entered.connect(play_audio.bind(button_focus_audio))
	button_quit.focus_entered.connect(play_audio.bind(button_focus_audio))


func start_game() -> void:
	play_audio(button_press_audio)
	LevelManager.load_new_level(START_LEVEL)


func quit_game() -> void:
	get_tree().quit()


func exit_title_screen() -> void:
	PlayerManager.player.visible = true
	
	PlayerHud.visible = true
	PauseMenu.process_mode = Node.PROCESS_MODE_ALWAYS
	
	self.queue_free()


func _pause_tree() -> void:
	get_tree().paused = true


func play_audio(_a: AudioStream) -> void:
	audio_stream_player.stream = _a
	audio_stream_player.play()

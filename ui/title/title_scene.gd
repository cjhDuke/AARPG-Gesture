extends Node2D

const START_LEVEL: String = "res://levels/survival/survival_arena.tscn"
## 标题背景的镜头位置（主角被隐藏，只借用它身上的 Camera2D）。
## x 取房间中心，y 比中心靠上，让顶部露出一截墙，看得出是个房间
const CAMERA_POS := Vector2(256, 112)
## 选择标记相对按钮左边缘的 x 偏移，以及 START 确认后飞出的距离、时长
const MARKER_OFFSET_X := -22.0
const MARKER_FLY_DISTANCE := 360.0
const MARKER_FLY_TIME := 0.25
## 按钮从下方滑入的距离、时长
const MENU_SLIDE_DISTANCE := 28.0
const MENU_SLIDE_TIME := 0.4

@export var music: AudioStream
@export var button_focus_audio: AudioStream
@export var button_press_audio: AudioStream

@onready var title_ui: Control = $CanvasLayer/Control
@onready var logo: TitleLogo = $CanvasLayer/Control/Logo
@onready var subtitle: Label = $CanvasLayer/Control/Subtitle
@onready var orbit_boomerang: TitleBoomerang = $CanvasLayer/Control/OrbitBoomerang
@onready var menu: VBoxContainer = $CanvasLayer/Control/Menu
@onready var button_start: Button = $CanvasLayer/Control/Menu/Button_start
@onready var button_quit: Button = $CanvasLayer/Control/Menu/Button_quit
@onready var marker: TitleBoomerang = $CanvasLayer/Control/Menu/Marker
@onready var audio_stream_player: AudioStreamPlayer = $AudioStreamPlayer
@onready var splash_screen: Control = $CanvasLayer/SplashScreen

var _marker_tween: Tween
var _starting: bool = false
var _marker_placed: bool = false


func _ready() -> void:
	get_tree().paused = true
	# 从游戏里返回标题时，加载流程结束会取消暂停，这里重新暂停
	LevelManager.level_loaded.connect( _pause_tree )
	PlayerManager.player.visible = false
	PlayerManager.player.global_position = CAMERA_POS

	PlayerHud.visible = false
	PauseMenu.process_mode = Node.PROCESS_MODE_DISABLED

	title_ui.visible = false
	menu.visible = false
	marker.visible = false

	splash_screen.finished.connect(setup_title_screen)


func setup_title_screen() -> void:
	var returning := LevelManager.title_seen
	LevelManager.title_seen = true
	if is_instance_valid(splash_screen):
		splash_screen.queue_free()

	title_ui.visible = true

	AudioManager.play_music(music)
	button_start.pressed.connect(start_game)
	button_quit.pressed.connect(quit_game)

	# 竖排菜单：上下循环，左右也能在按钮间切换
	var buttons: Array[Button] = [button_start, button_quit]
	for i in buttons.size():
		var button := buttons[i]
		var prev_path := buttons[(i + buttons.size() - 1) % buttons.size()].get_path()
		var next_path := buttons[(i + 1) % buttons.size()].get_path()
		button.focus_neighbor_top = prev_path
		button.focus_neighbor_left = prev_path
		button.focus_neighbor_bottom = next_path
		button.focus_neighbor_right = next_path
		button.focus_entered.connect(play_audio.bind(button_focus_audio))
		button.focus_entered.connect(_move_marker.bind(button))

	# 标题入场：字母逐个落下，每落一个响一声；全部落定后淡入副标题和回旋镖，按钮滑入
	logo.letter_landed.connect(func(_i: int) -> void: play_audio(button_focus_audio))
	logo.intro_finished.connect(_on_logo_finished)
	# 从游戏里返回标题：字母直接就位，不再播下落动画
	if returning:
		logo.show_instantly()
	else:
		logo.play_intro()


func _on_logo_finished() -> void:
	orbit_boomerang.visible = true
	var tw := title_ui.create_tween()
	tw.tween_property(subtitle, "modulate:a", 1.0, 0.4)
	_show_menu()


func _show_menu() -> void:
	menu.visible = true
	# 等一帧让容器排好版，再记下按钮的最终位置
	await get_tree().process_frame
	if not is_inside_tree():
		return
	var final_y := menu.position.y
	menu.position.y = final_y + MENU_SLIDE_DISTANCE
	menu.modulate.a = 0.0
	var tw := title_ui.create_tween()
	tw.set_parallel(true)
	tw.tween_property(menu, "position:y", final_y, MENU_SLIDE_TIME) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(menu, "modulate:a", 1.0, MENU_SLIDE_TIME)
	tw.chain().tween_callback(button_start.grab_focus)


## 选择标记滑到获得焦点的按钮左侧
func _move_marker(button: Button) -> void:
	if _starting:
		return
	var target := Vector2(MARKER_OFFSET_X, button.position.y + button.size.y * 0.5)
	marker.visible = true
	if _marker_tween:
		_marker_tween.kill()
	if not _marker_placed:
		_marker_placed = true
		marker.position = target
		return
	_marker_tween = title_ui.create_tween()
	_marker_tween.tween_property(marker, "position", target, 0.15) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func start_game() -> void:
	if _starting:
		return
	_starting = true
	play_audio(button_press_audio)
	# 回旋镖横向飞出屏幕，然后再开始加载关卡
	if _marker_tween:
		_marker_tween.kill()
	_marker_tween = title_ui.create_tween()
	_marker_tween.tween_property(marker, "position:x", marker.position.x + MARKER_FLY_DISTANCE, MARKER_FLY_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await _marker_tween.finished
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

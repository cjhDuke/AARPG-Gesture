class_name SurvivalHud extends CanvasLayer
## 生存模式的界面：底部状态行、WAVE 提示、胜负结算面板（念力条在主角头顶，见 psi_bar.gd）

signal retry_pressed
signal title_pressed

@onready var status_label : Label = %StatusLabel
@onready var banner_label : Label = %BannerLabel
@onready var result_panel : Control = %ResultPanel
@onready var result_title : Label = %ResultTitle
@onready var result_stats : Label = %ResultStats
@onready var trophy : Sprite2D = %Trophy
@onready var retry_button : Button = %RetryButton
@onready var title_button : Button = %TitleButton
@onready var congrats_music : AudioStreamPlayer = %CongratsMusic

var _banner_tween : Tween


func _ready() -> void:
	banner_label.modulate.a = 0.0
	result_panel.visible = false
	retry_button.pressed.connect( retry_pressed.emit )
	title_button.pressed.connect( title_pressed.emit )


func _process( _delta : float ) -> void:
	if trophy.visible:
		trophy.frame = int( Time.get_ticks_msec() / 150 ) % 8


func set_status( wave : int, total_waves : int, kills : int, best : int ) -> void:
	status_label.text = "WAVE %d/%d  KILLS %d  BEST %d" % [ wave, total_waves, kills, best ]


func show_banner( text : String ) -> void:
	banner_label.text = text
	if _banner_tween:
		_banner_tween.kill()
	_banner_tween = create_tween()
	_banner_tween.tween_property( banner_label, "modulate:a", 1.0, 0.15 )
	_banner_tween.tween_interval( 0.9 )
	_banner_tween.tween_property( banner_label, "modulate:a", 0.0, 0.4 )


## 显示结算面板并暂停游戏；RETRY 获得焦点，回车 / 握拳都能确认
func show_result( victory : bool, kills : int, best : int ) -> void:
	result_title.text = "VICTORY" if victory else "GAME OVER"
	result_stats.text = "KILLS %d   BEST %d" % [ kills, best ]
	trophy.visible = victory
	if victory:
		AudioManager.stop_music()
		congrats_music.play()
	result_panel.visible = true
	get_tree().paused = true
	retry_button.grab_focus.call_deferred()


func hide_result() -> void:
	congrats_music.stop()
	result_panel.visible = false

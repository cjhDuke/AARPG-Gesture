class_name SurvivalArena extends Level
## 手引生存关卡：5 波敌人，清完胜利，血量归零失败

const TITLE_SCENE : String = "res://ui/title/title_scene.tscn"
## 开局到第 1 波、以及每波清完到下一波之间的停顿（秒）
const START_DELAY : float = 1.0
const WAVE_DELAY : float = 2.0

@onready var spawner : WaveSpawner = $WaveSpawner
@onready var controller : HandController = $HandController
@onready var hud : SurvivalHud = $SurvivalHud
@onready var wave_timer : Timer = $WaveTimer

var wave : int = 0
var kills : int = 0
var _ended : bool = false
var _player : Player
var _death_fx : DeathFx


func _ready() -> void:
	super._ready()
	_player = PlayerManager.player
	_player.can_move = true
	_player.died.connect( _on_player_died )
	# 镜头固定在房间中心，不跟着被击退的主角晃
	var camera : Camera2D = _player.get_node( "Camera2D" )
	camera.top_level = true
	camera.global_position = HandController.CENTER

	spawner.enemy_killed.connect( _on_enemy_killed )
	spawner.wave_cleared.connect( _on_wave_cleared )
	wave_timer.timeout.connect( _begin_wave )
	hud.retry_pressed.connect( _on_retry_pressed )
	hud.title_pressed.connect( _on_title_pressed )
	_start_run()


func _free_level() -> void:
	_clear_death_fx()
	controller.release_player()
	var camera : Camera2D = _player.get_node( "Camera2D" )
	camera.top_level = false
	camera.position = Vector2.ZERO
	super._free_level()


## 开始（或重新开始）一局
func _start_run() -> void:
	_clear_death_fx()
	spawner.set_process( true )
	wave_timer.stop()
	spawner.clear()
	for c in get_children():
		if c is Boomerang:
			c.queue_free()
	wave = 0
	kills = 0
	_ended = false
	PlayerManager.reset_player()
	_player.global_position = HandController.CENTER
	controller.enabled = true
	controller.reset()
	_update_status()
	wave_timer.start( START_DELAY )


func _begin_wave() -> void:
	wave += 1
	hud.show_banner( "WAVE %d" % wave )
	spawner.start_wave( wave - 1 )
	_update_status()


func _on_enemy_killed() -> void:
	kills += 1
	RunStats.best_kills = maxi( RunStats.best_kills, kills )
	_update_status()


func _on_wave_cleared() -> void:
	if _ended:
		return
	if wave >= WaveSpawner.WAVES.size():
		_end_run( true )
	else:
		_player.update_hp( 1 )
		wave_timer.start( WAVE_DELAY )


## 主角死亡：先放死亡动效（慢动作 + 闪白 + 倒下 + 冒烟，见 death_fx.gd），播完再弹 GAME OVER 面板。
## 期间停止刷怪、关掉手势 / 键盘操控（回旋镖随之收回）、禁用暂停菜单；
## 主角 is_dead 且受击框已关，敌人不会再造成伤害
func _on_player_died() -> void:
	if _ended:
		return
	_ended = true
	wave_timer.stop()
	spawner.set_process( false )
	controller.enabled = false
	PauseMenu.process_mode = Node.PROCESS_MODE_DISABLED
	_death_fx = DeathFx.new()
	add_child( _death_fx )
	_death_fx.finished.connect( _on_death_fx_finished )
	_death_fx.start( _player )


func _on_death_fx_finished() -> void:
	_end_run( false )


## 结束死亡动效并恢复时间流速（重开、回标题、关卡释放时都会调用，可重复调用）
func _clear_death_fx() -> void:
	if is_instance_valid( _death_fx ):
		_death_fx.cleanup()
		_death_fx.queue_free()
	_death_fx = null
	Engine.time_scale = 1.0


func _end_run( victory : bool ) -> void:
	_ended = true
	wave_timer.stop()
	controller.enabled = false
	# 结算期间不允许 Esc 打开暂停菜单
	PauseMenu.process_mode = Node.PROCESS_MODE_DISABLED
	hud.show_result( victory, kills, RunStats.best_kills )


func _on_retry_pressed() -> void:
	hud.hide_result()
	get_tree().paused = false
	PauseMenu.process_mode = Node.PROCESS_MODE_ALWAYS
	AudioManager.play_music( music )
	_start_run()


func _on_title_pressed() -> void:
	LevelManager.load_new_level( TITLE_SCENE )


func _update_status() -> void:
	hud.set_status( maxi( wave, 1 ), WaveSpawner.WAVES.size(), kills, RunStats.best_kills )

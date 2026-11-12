class_name SurvivalArena extends Level
## 手引生存关卡：5 波敌人，清完胜利，血量归零失败

const TITLE_SCENE : String = "res://ui/title/title_scene.tscn"
## 开局到第 1 波、以及每波清完到下一波之间的停顿（秒）
const START_DELAY : float = 1.0
const WAVE_DELAY : float = 2.0
## 清波宝箱的位置：房间中心偏下，避开屏幕正中的 WAVE CLEAR 横幅
const CHEST_POS := HandController.CENTER + Vector2( 0, 36 )

@onready var spawner : WaveSpawner = $WaveSpawner
@onready var controller : HandController = $HandController
@onready var hud : SurvivalHud = $SurvivalHud
@onready var wave_timer : Timer = $WaveTimer

var wave : int = 0
var kills : int = 0
var _ended : bool = false
var _player : Player
var _death_fx : DeathFx
var loot : LootDropper
var _chest : RewardChest
## 这一波主角是否受过伤（决定宝箱里有没有药水）
var _wave_hurt : bool = false


func _ready() -> void:
	super._ready()
	_player = PlayerManager.player
	_player.can_move = true
	_player.died.connect( _on_player_died )
	_player.player_damaged.connect( _on_player_damaged )
	# 镜头固定在房间中心，不跟着被击退的主角晃
	var camera : Camera2D = _player.get_node( "Camera2D" )
	camera.top_level = true
	camera.global_position = HandController.CENTER

	loot = LootDropper.new()
	loot.name = "LootDropper"
	loot.controller = controller
	add_child( loot )
	loot.bag_changed.connect( hud.set_bag )
	hud.set_bag( 0, LootDropper.BAG_CAPACITY )
	spawner.enemy_destroyed_at.connect( loot.handle_enemy_destroyed )
	spawner.enemy_killed.connect( _on_enemy_killed )
	spawner.wave_cleared.connect( _on_wave_cleared )
	wave_timer.timeout.connect( _begin_wave )
	hud.retry_pressed.connect( _on_retry_pressed )
	hud.title_pressed.connect( _on_title_pressed )
	_start_run()


func _free_level() -> void:
	_clear_death_fx()
	_clear_rewards()
	controller.release_player()
	var camera : Camera2D = _player.get_node( "Camera2D" )
	camera.top_level = false
	camera.position = Vector2.ZERO
	super._free_level()


## 开始（或重新开始）一局
func _start_run() -> void:
	_clear_death_fx()
	_clear_rewards()
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
	_wave_hurt = false
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
		_spawn_chest()


func _on_player_damaged( _hit_box : HitBox ) -> void:
	_wave_hurt = true


## 清波奖励：房间中心淡入宝箱，主角走近开箱，箱子消失后才开始下一波
func _spawn_chest() -> void:
	hud.show_banner( "WAVE CLEAR" )
	_chest = RewardChest.new()
	_chest.loot = loot
	_chest.flawless = not _wave_hurt
	_chest.finished.connect( _on_chest_finished )
	add_child( _chest )
	_chest.global_position = CHEST_POS


func _on_chest_finished() -> void:
	_chest = null
	if _ended:
		return
	wave_timer.start( WAVE_DELAY )


## 清掉宝箱、掉落物和飘字
func _clear_rewards() -> void:
	if is_instance_valid( _chest ):
		_chest.queue_free()
	_chest = null
	if loot != null:
		loot.clear()


## 主角死亡：先放死亡动效（慢动作 + 闪白 + 倒下 + 冒烟，见 death_fx.gd），播完再弹 GAME OVER 面板。
## 期间停止刷怪、关掉手势 / 键盘操控（回旋镖随之收回）、禁用暂停菜单；
## 主角 is_dead 且受击框已关，敌人不会再造成伤害
func _on_player_died() -> void:
	if _ended:
		return
	_ended = true
	wave_timer.stop()
	_clear_rewards()
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
	_clear_rewards()
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

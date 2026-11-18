class_name DeathFx extends Node
## 主角死亡动效（生存关卡用）：整体慢动作约 1.2 秒（真实时间），
## 定在受击帧 -> 闪白几下 -> 倒下（旋转约 90 度）并淡出 -> 原地播一次冒烟帧 -> finished。
## 开始时把 Engine.time_scale 降到 SLOW_SCALE，结束 / cleanup() / 节点离开场景树时一定恢复为 1。
## 主角没有现成的死亡动画，所以用现有资源（stun 帧 + enemies/slime/destroy_smoke.png）拼出来。
## 视觉复原由 Player.reset_visuals() 负责（PlayerManager.reset_player() 会调用）。

signal finished

const SLOW_SCALE : float = 0.35
## 各阶段结束的真实时间（秒）
const FLASH_END : float = 0.45
const FALL_END : float = 0.95
const TOTAL : float = 1.2
const FLASH_INTERVAL : float = 0.075
const SMOKE_TEXTURE : Texture2D = preload( "res://enemies/slime/destroy_smoke.png" )
const SMOKE_FRAMES : int = 6
## 主角精灵相对脚底原点的位置（和 player.tscn 里 Sprite2D 的 position 一致）
const SPRITE_HOME := Vector2( 0, -21 )
## 受击（stun）帧：和 player.tscn 里 stun_down / stun_up / stun_side 动画一致
const STUN_FRAMES : Dictionary = { "down": 30, "up": 31, "side": 32 }

var _player : Player
var _start_usec : int = 0
var _fall_sign : float = 1.0
var _smoke : Sprite2D
var _running : bool = false


func _ready() -> void:
	# 慢动作期间时间不能被暂停影响；树暂停时（理论上不会）也要走完
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process( false )


func start( player : Player ) -> void:
	_player = player
	_running = true
	_start_usec = Time.get_ticks_usec()
	# 向离自己朝向的反方向倒（朝左时往另一侧），精灵 scale.x 为 -1 时旋转方向不变，所以只看朝向
	_fall_sign = -1.0 if player.cardinal_direction == Vector2.LEFT else 1.0

	# 定在受击帧：停掉所有动画，关掉状态机（不再响应攻击等输入）
	player.animation_player.stop( true )
	player.effect_animation_player.stop()
	player.state_machine.process_mode = Node.PROCESS_MODE_DISABLED
	player.sprite_2d.frame = int( STUN_FRAMES[player.anim_direction()] )
	player.sprite_2d.modulate = Color.WHITE
	player.modulate = Color.WHITE

	Engine.time_scale = SLOW_SCALE
	set_process( true )


## 立即结束动效：恢复时间流速并删除冒烟精灵。可重复调用
func cleanup() -> void:
	_running = false
	set_process( false )
	Engine.time_scale = 1.0
	if is_instance_valid( _smoke ):
		_smoke.queue_free()
	_smoke = null


func _exit_tree() -> void:
	cleanup()


func _process( _delta : float ) -> void:
	if not _running or not is_instance_valid( _player ):
		return
	var t := float( Time.get_ticks_usec() - _start_usec ) / 1000000.0
	var sprite := _player.sprite_2d

	if t < FLASH_END:
		# 闪白：白 / 正常交替
		var on := int( t / FLASH_INTERVAL ) % 2 == 0
		sprite.modulate = Color( 3.0, 3.0, 3.0, 1.0 ) if on else Color.WHITE
	elif t < FALL_END:
		# 倒下：绕脚底旋转到 90 度（先快后慢），同时淡出
		var u := clampf( (t - FLASH_END) / (FALL_END - FLASH_END), 0.0, 1.0 )
		var angle := deg_to_rad( 90.0 ) * _fall_sign * ( 1.0 - (1.0 - u) * (1.0 - u) )
		sprite.rotation = angle
		sprite.position = SPRITE_HOME.rotated( angle )
		sprite.modulate = Color( 1, 1, 1, 1.0 - u )
	else:
		sprite.modulate = Color( 1, 1, 1, 0 )
		_update_smoke( t )

	if t >= TOTAL:
		var was_running := _running
		cleanup()
		if was_running:
			finished.emit()


## 冒烟：原地播一次 6 帧
func _update_smoke( t : float ) -> void:
	if _smoke == null:
		_smoke = Sprite2D.new()
		_smoke.texture = SMOKE_TEXTURE
		_smoke.hframes = SMOKE_FRAMES
		_smoke.z_index = 3
		add_child( _smoke )
		_smoke.global_position = _player.global_position + Vector2( 0, -14 )
	var u := clampf( (t - FALL_END) / (TOTAL - FALL_END), 0.0, 0.999 )
	_smoke.frame = int( u * SMOKE_FRAMES )

class_name Boomerang extends Node2D

enum State { INACTIVE, THROW, RETURN, GUIDED }

## 拖尾最多保留的点数
const TRAIL_MAX_POINTS := 12
## 精灵相对节点的偏移（场景里 Sprite2D 在 (0,-16)）
const SPRITE_OFFSET := Vector2( 0, -16 )

## 冰霜尾迹：减速时长（秒）、拖尾点离敌人多近算扫到（像素）
const FROST_TIME : float = 2.0
const FROST_TRAIL_DIST : float = 14.0
## 沉重回旋镖（穿透强化）：伤害加成和体积倍率
const HEAVY_BONUS : int = 1
const HEAVY_SCALE : float = 1.3

var player : Player
## 强化开关（由 HandController 在每次起飞 / 切换强化时设置）
var frost : bool = false
## 掉落物被吸附的距离（精灵中心到掉落物图标中心，像素）；吸附强化加大
var magnet_range : float = 18.0
var _heavy : bool = false
var direction : Vector2
var speed : float = 0
var state
## GUIDED 状态的当前速度向量
var velocity : Vector2 = Vector2.ZERO
var _target : Vector2 = Vector2.ZERO
var _trail : Line2D

@export var acceleration : float = 500.0
@export var max_speed : float = 400.0
@export var catch_audio : AudioStream
## 受控飞行：最大速度、加速度（像素/秒、像素/秒²）
@export var guided_max_speed : float = 340.0
@export var guided_accel : float = 2600.0
## 追目标的"弹簧"增益：期望速度 = min( guided_max_speed, 离目标距离 * guided_gain )，越大越跟手
@export var guided_gain : float = 10.0

@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var audio: AudioStreamPlayer2D = $AudioStreamPlayer2D

func _ready() -> void:
	visible = false
	state = State.INACTIVE
	player = PlayerManager.player
	_make_trail()


func _physics_process(delta: float) -> void:
	if state == State.THROW:
		speed -= acceleration * delta
		position += direction * speed * delta
		if speed <= 0:
			state = State.RETURN
		pass
	elif state == State.GUIDED:
		var to_target := _target - global_position
		var dist := to_target.length()
		var desired := Vector2.ZERO
		if dist > 0.01:
			desired = to_target / dist * minf( guided_max_speed, dist * guided_gain )
		velocity = velocity.move_toward( desired, guided_accel * delta )
		global_position += velocity * delta
		speed = velocity.length()
	elif state == State.RETURN:
		direction = global_position.direction_to( player.global_position )
		speed += acceleration * delta
		position += direction * speed * delta
		if global_position.distance_to( player.global_position ) <= 10:
			PlayerManager.play_audio( catch_audio )
			queue_free()
		pass

	if state == State.GUIDED or state == State.RETURN:
		_push_trail_point()
		if frost:
			_frost_sweep()

	var speed_ratio = speed / max_speed
	audio.pitch_scale = speed_ratio * 0.75 + 0.75
	animation_player.speed_scale = 1 + ( speed_ratio * 0.25 )

	pass

func throw( throw_direction : Vector2 ) -> void:
	direction = throw_direction
	speed = max_speed
	state = State.THROW
	animation_player.play("boomerang")
	PlayerManager.play_audio( catch_audio )
	visible = true
	pass


## 受控飞行：以 dir 方向起飞，之后追着 set_target 给的目标点
func launch_guided( dir : Vector2 ) -> void:
	direction = dir
	velocity = dir * guided_max_speed * 0.5
	speed = velocity.length()
	_target = global_position
	state = State.GUIDED
	animation_player.play("boomerang")
	PlayerManager.play_audio( catch_audio )
	visible = true


## 目标点（全局坐标，节点原点的目标位置）
func set_target( p : Vector2 ) -> void:
	_target = p


## 松开：转入返回状态
func release() -> void:
	if state != State.GUIDED:
		return
	speed = maxf( velocity.length(), 120.0 )
	state = State.RETURN


## 重新抓住：返回途中切回受控状态，保持当前飞行方向和速度（上限 guided_max_speed）。
## 只在 RETURN 状态有效，返回是否成功
func regrab() -> bool:
	if state != State.RETURN:
		return false
	velocity = direction * minf( speed, guided_max_speed )
	speed = velocity.length()
	_target = global_position
	state = State.GUIDED
	return true


## 沉重回旋镖开 / 关：伤害 +1、精灵和判定放大约 1.3 倍（缩放子节点自己，位置偏移不变）
func set_heavy( on : bool ) -> void:
	if on == _heavy:
		return
	_heavy = on
	var k := HEAVY_SCALE if on else 1.0
	var hb : HitBox = $HitBox
	hb.damage = 1 + ( HEAVY_BONUS if on else 0 )
	$Sprite2D.scale = Vector2( k, k )
	$HitBox/CollisionShape2D2.scale = Vector2( k, k )
	$Area2D/CollisionShape2D.scale = Vector2( k, k )


## 冰霜尾迹：拖尾点 FROST_TRAIL_DIST 以内的敌人减速
func _frost_sweep() -> void:
	var parent := get_parent()
	if parent == null:
		return
	for c in parent.get_children():
		if c is Enemy and not c.spawning and c.hp > 0 and not c.is_queued_for_deletion():
			var p : Vector2 = c.global_position + Vector2( 0, -8 )
			for i in _trail.get_point_count():
				if _trail.get_point_position( i ).distance_to( p ) <= FROST_TRAIL_DIST:
					c.apply_slow( FROST_TIME )
					break


func _make_trail() -> void:
	_trail = Line2D.new()
	_trail.top_level = true
	_trail.width = 3.0
	_trail.z_index = 3
	_trail.default_color = Color( 0.4, 0.9, 1.0, 0.9 )
	var g := Gradient.new()
	g.colors = PackedColorArray( [ Color( 0.4, 0.9, 1.0, 0.0 ), Color( 0.7, 1.0, 1.0, 0.9 ) ] )
	g.offsets = PackedFloat32Array( [ 0.0, 1.0 ] )
	_trail.gradient = g
	add_child( _trail )
	_trail.global_position = Vector2.ZERO


func _push_trail_point() -> void:
	_trail.add_point( global_position + SPRITE_OFFSET )
	while _trail.get_point_count() > TRAIL_MAX_POINTS:
		_trail.remove_point( 0 )

class_name Boomerang extends Node2D

enum State { INACTIVE, THROW, RETURN, GUIDED }

## 拖尾最多保留的点数
const TRAIL_MAX_POINTS := 12
## 精灵相对节点的偏移（场景里 Sprite2D 在 (0,-16)）
const SPRITE_OFFSET := Vector2( 0, -16 )

var player : Player
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
@export var guided_max_speed : float = 260.0
@export var guided_accel : float = 1400.0

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
			desired = to_target / dist * minf( guided_max_speed, dist * 8.0 )
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

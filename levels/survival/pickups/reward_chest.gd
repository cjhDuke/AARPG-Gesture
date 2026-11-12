class_name RewardChest extends Node2D
## 清波宝箱：淡入后等主角走近（OPEN_DIST）打开，弹出奖励（1 个苹果；这波没受伤再加 1 瓶药水），
## 约 1 秒后淡出并释放。释放前发 finished，关卡据此开始下一波。
## 箱子有实体碰撞（墙体层），从出现一直保留到完全淡出，主角和敌人都穿不过去。

const CHEST_TEXTURE : Texture2D = preload( "res://levels/survival/pickups/treasure_chest.png" )
const OPEN_SOUND : AudioStream = preload( "res://levels/survival/pickups/treasure_open.wav" )

## 主角离箱子多近就开箱（像素）。要比主角贴着碰撞体时的距离（侧面约 28）大，否则碰到也开不了
const OPEN_DIST : float = 30.0
## 碰撞体：箱子底部的占地范围（相对节点原点），在墙体层（第 5 层）上
const BODY_SIZE := Vector2( 34, 14 )
const BODY_OFFSET := Vector2( 0, -7 )
const WALL_LAYER : int = 16
## 主角离碰撞体这么远才启用碰撞，避免箱子直接出现在主角身上把人卡住
const BODY_CLEARANCE : float = 12.0
const FADE_IN_TIME : float = 0.4
## 开箱后停留多久再淡出、淡出时长
const LINGER_TIME : float = 1.0
const FADE_OUT_TIME : float = 0.4
## 宝箱奖励的存在时间（比普通掉落物长），且下一波开始后仍留在场上
const REWARD_LIFETIME : float = 15.0
## 奖励弹出的落点相对箱子的偏移
const APPLE_OFFSET := Vector2( -20, 8 )
const POTION_OFFSET := Vector2( 20, 8 )

signal opened
signal finished

var loot : LootDropper
## 这一波主角没受过伤：额外给药水
var flawless : bool = false
var is_opened : bool = false

var _sprite : Sprite2D
var _body : StaticBody2D
var _armed : bool = false
var _closing : bool = false


func _ready() -> void:
	# 主角的 z_index 是 2；取同一层才能和主角按 y 排序（主角站在箱子后面时被箱子挡住）
	z_index = 2
	_sprite = Sprite2D.new()
	_sprite.texture = CHEST_TEXTURE
	_sprite.hframes = 2
	# 帧 64x64，把箱子的底边大致对齐到节点原点
	_sprite.position = Vector2( 0, -24 )
	add_child( _sprite )
	_body = StaticBody2D.new()
	_body.collision_layer = 0
	_body.collision_mask = 0
	_body.position = BODY_OFFSET
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = BODY_SIZE
	shape.shape = rect
	_body.add_child( shape )
	# 宝箱常在敌人被打死的物理回调里生成，此时直接加入碰撞体会报 "Can't change this state while flushing queries"，
	# 所以延后到本帧末加入场景（_process 里要判断 _body 是否已入树）
	add_child.call_deferred( _body )
	modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property( self, "modulate:a", 1.0, FADE_IN_TIME )
	tween.tween_callback( func() -> void: _armed = true )


func _process( _delta : float ) -> void:
	var player := PlayerManager.player
	if player == null:
		return
	if _body.is_inside_tree() and _body.collision_layer == 0 and not _player_overlaps_body( player ):
		_body.collision_layer = WALL_LAYER
	if not _armed or is_opened or player.is_dead:
		return
	if global_position.distance_to( player.global_position ) <= OPEN_DIST:
		_open()


## 主角（按 BODY_CLEARANCE 放大）是否压在碰撞体的范围上
func _player_overlaps_body( player : Player ) -> bool:
	var half := BODY_SIZE * 0.5 + Vector2( BODY_CLEARANCE, BODY_CLEARANCE )
	var d := player.global_position - _body.global_position
	return absf( d.x ) < half.x and absf( d.y ) < half.y


func _open() -> void:
	is_opened = true
	_sprite.frame = 1
	PlayerManager.play_audio( OPEN_SOUND )
	if loot != null:
		var origin := global_position + Vector2( 0, -8 )
		loot.spawn_pickup( Pickup.Kind.APPLE, origin, global_position + APPLE_OFFSET, REWARD_LIFETIME )
		if flawless:
			loot.spawn_pickup( Pickup.Kind.POTION, origin, global_position + POTION_OFFSET, REWARD_LIFETIME )
	opened.emit()
	var tween := create_tween()
	tween.tween_interval( LINGER_TIME )
	tween.tween_property( self, "modulate:a", 0.0, FADE_OUT_TIME )
	tween.tween_callback( _finish )


func _finish() -> void:
	if _closing:
		return
	_closing = true
	finished.emit()
	queue_free()

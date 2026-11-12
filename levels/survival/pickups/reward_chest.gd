class_name RewardChest extends Node2D
## 清波宝箱：淡入后等主角走近（OPEN_DIST）打开，弹出奖励（1 个苹果；这波没受伤再加 1 瓶药水），
## 约 1 秒后淡出并释放。释放前发 finished，关卡据此开始下一波。

const CHEST_TEXTURE : Texture2D = preload( "res://levels/survival/pickups/treasure_chest.png" )
const OPEN_SOUND : AudioStream = preload( "res://levels/survival/pickups/treasure_open.wav" )

## 主角离箱子多近就开箱（像素）
const OPEN_DIST : float = 18.0
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
	modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property( self, "modulate:a", 1.0, FADE_IN_TIME )
	tween.tween_callback( func() -> void: _armed = true )


func _process( _delta : float ) -> void:
	if not _armed or is_opened:
		return
	var player := PlayerManager.player
	if player == null or player.is_dead:
		return
	if global_position.distance_to( player.global_position ) <= OPEN_DIST:
		_open()


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

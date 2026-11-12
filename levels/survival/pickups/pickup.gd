class_name Pickup extends Node2D
## 掉落物：苹果（回 1 点血）、宝石（回 25% 念力）、药水（回 2 点血并回满念力）。
## 生成时有个小弹跳，存在 lifetime 秒（最后 2 秒闪烁）后消失。
## 主角走近（PICKUP_DIST）直接拾取；场上飞行中的回旋镖碰到它时，它会飞向主角，到达后生效。
## 纯代码建节点，由 LootDropper.spawn_pickup() 创建。

enum Kind { APPLE, GEM, POTION }

const ITEMS_TEXTURE : Texture2D = preload( "res://levels/survival/pickups/items.png" )
const HP_UP_SOUND : AudioStream = preload( "res://levels/survival/pickups/hp_up.wav" )
const PICKUP_SOUND : AudioStream = preload( "res://levels/survival/pickups/item_pickup.wav" )
const FONT : Font = preload( "res://ui/fonts/abaddon_light.ttf" )

## 图集里各类型的区域（每格 32x32）
const REGIONS : Dictionary = {
	Kind.APPLE: Rect2( 192, 0, 32, 32 ),
	Kind.GEM: Rect2( 0, 0, 32, 32 ),
	Kind.POTION: Rect2( 32, 0, 32, 32 ),
}
## 精灵静止时相对节点原点的偏移（图标悬在地面上方一点）
const REST_Y : float = -12.0
## 主角离掉落物多近算拾取（像素）
const PICKUP_DIST : float = 14.0
## 回旋镖精灵中心离掉落物图标中心多近算碰到（像素）
const BOOMERANG_DIST : float = 18.0
## 生成后这么久才允许拾取，避免弹跳还没落地就被吸走
const ARM_TIME : float = 0.25
## 默认存在时间、最后多久开始闪烁（秒）
const DEFAULT_LIFETIME : float = 8.0
const BLINK_TIME : float = 2.0
## 被回旋镖碰到后飞向主角：初速、加速度、到达距离
const FLY_SPEED : float = 140.0
const FLY_ACCEL : float = 900.0
const FLY_ARRIVE_DIST : float = 6.0

## 拾取并生效时发出（kind 为 Kind 枚举值）
signal collected( kind : int )

var kind : int = Kind.APPLE
var lifetime : float = DEFAULT_LIFETIME
## 用来读 / 加念力；为空时视为念力已满
var controller : HandController

var _age : float = 0.0
var _flying : bool = false
var _fly_speed : float = 0.0
var _sprite : Sprite2D
var _hop_tween : Tween
var _move_tween : Tween


func _ready() -> void:
	add_to_group( "loot_fx" )
	# 和主角同一 z 层，按 y 排序
	z_index = 2
	var tex := AtlasTexture.new()
	tex.atlas = ITEMS_TEXTURE
	tex.region = REGIONS[kind]
	_sprite = Sprite2D.new()
	_sprite.texture = tex
	_sprite.position = Vector2( 0, REST_Y )
	add_child( _sprite )


## 从当前位置弹到 dest：落点用 tween 平移，图标本身上下弹两下
func pop_to( dest : Vector2 ) -> void:
	_move_tween = create_tween()
	_move_tween.tween_property( self, "global_position", dest, 0.35 ) \
		.set_trans( Tween.TRANS_SINE ).set_ease( Tween.EASE_OUT )
	_hop_tween = create_tween()
	_hop_tween.tween_property( _sprite, "position:y", REST_Y - 16.0, 0.17 ) \
		.set_trans( Tween.TRANS_QUAD ).set_ease( Tween.EASE_OUT )
	_hop_tween.tween_property( _sprite, "position:y", REST_Y, 0.17 ) \
		.set_trans( Tween.TRANS_QUAD ).set_ease( Tween.EASE_IN )
	_hop_tween.tween_property( _sprite, "position:y", REST_Y - 4.0, 0.07 ) \
		.set_trans( Tween.TRANS_QUAD ).set_ease( Tween.EASE_OUT )
	_hop_tween.tween_property( _sprite, "position:y", REST_Y, 0.07 ) \
		.set_trans( Tween.TRANS_QUAD ).set_ease( Tween.EASE_IN )


## 主角当前是否该拾取它（满血的苹果不拾取；药水血和念力都满才不拾取；宝石总是拾取）
func can_collect() -> bool:
	var player := PlayerManager.player
	if player == null or player.is_dead:
		return false
	match kind:
		Kind.APPLE:
			return player.hp < player.max_hp
		Kind.POTION:
			return player.hp < player.max_hp or _psi() < 1.0
	return true


func is_flying() -> bool:
	return _flying


func _process( delta : float ) -> void:
	var player := PlayerManager.player
	if player == null:
		return
	if _flying:
		_process_flying( delta, player )
		return

	_age += delta
	if _age >= lifetime:
		queue_free()
		return
	# 最后 BLINK_TIME 秒闪烁
	if lifetime - _age < BLINK_TIME:
		_sprite.visible = int( _age * 10.0 ) % 2 == 0
	else:
		_sprite.visible = true
	if _age < ARM_TIME or not can_collect():
		return

	if global_position.distance_to( player.global_position ) <= PICKUP_DIST:
		_apply( player )
	elif _touched_by_boomerang():
		_start_flying()


func _process_flying( delta : float, player : Player ) -> void:
	if player.is_dead:
		queue_free()
		return
	_fly_speed += FLY_ACCEL * delta
	# 朝主角身体中段飞，更像"吸"过去
	var goal := player.global_position + Vector2( 0, REST_Y )
	global_position = global_position.move_toward( goal, _fly_speed * delta )
	if global_position.distance_to( goal ) <= FLY_ARRIVE_DIST:
		_apply( player )


func _touched_by_boomerang() -> bool:
	var parent := get_parent()
	if parent == null:
		return false
	var my_center := global_position + Vector2( 0, REST_Y )
	for c in parent.get_children():
		if c is Boomerang and c.state != Boomerang.State.INACTIVE \
				and c.visible and not c.is_queued_for_deletion():
			if ( c.global_position + Boomerang.SPRITE_OFFSET ).distance_to( my_center ) <= BOOMERANG_DIST:
				return true
	return false


func _start_flying() -> void:
	_flying = true
	_fly_speed = FLY_SPEED
	_sprite.visible = true
	# 结束弹跳动画，免得和飞行抢位置
	if _move_tween:
		_move_tween.kill()
	if _hop_tween:
		_hop_tween.kill()
	_sprite.position.y = REST_Y


func _psi() -> float:
	return controller.psi if is_instance_valid( controller ) else 1.0


## 生效：回血 / 回念力、音效、飘字，然后消失
func _apply( player : Player ) -> void:
	var text := ""
	match kind:
		Kind.APPLE:
			player.update_hp( 1 )
			PlayerHud.flash_heal()
			PlayerManager.play_audio( HP_UP_SOUND )
			text = "+1 HP"
		Kind.GEM:
			if is_instance_valid( controller ):
				controller.add_psi( 0.25 )
			PlayerManager.play_audio( PICKUP_SOUND )
			text = "+PSI"
		Kind.POTION:
			player.update_hp( 2 )
			PlayerHud.flash_heal()
			if is_instance_valid( controller ):
				controller.add_psi( 1.0 )
			PlayerManager.play_audio( HP_UP_SOUND )
			text = "+2 HP  PSI MAX"
	show_float_text( get_parent(), player.global_position + Vector2( 0, -48 ), text )
	collected.emit( kind )
	queue_free()


## 在 pos（世界坐标，文字底边中点）飘一行小字，向上飘并淡出后自行释放
static func show_float_text( parent : Node, pos : Vector2, text : String ) -> void:
	if parent == null:
		return
	var label := Label.new()
	label.add_to_group( "loot_fx" )
	label.text = text
	label.add_theme_font_override( "font", FONT )
	label.add_theme_font_size_override( "font_size", 8 )
	label.add_theme_color_override( "font_color", Color( 0.6, 1.0, 0.7 ) )
	label.add_theme_color_override( "font_outline_color", Color.BLACK )
	label.add_theme_constant_override( "outline_size", 3 )
	label.z_index = 100
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child( label )
	label.reset_size()
	label.global_position = pos - Vector2( label.size.x * 0.5, label.size.y )
	var tween := label.create_tween()
	tween.set_parallel( true )
	tween.tween_property( label, "position:y", label.position.y - 14.0, 1.0 )
	tween.tween_property( label, "modulate:a", 0.0, 0.5 ).set_delay( 0.6 )
	tween.chain().tween_callback( label.queue_free )

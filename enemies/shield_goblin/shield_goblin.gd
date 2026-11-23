class_name ShieldGoblin extends Enemy
## 盾牌哥布林：身前有一面盾，盾始终（以有限的转向速度）朝向主角。
## 伤害来源（HitBox 的位置）落在盾朝向的 ±block_half_angle 内就被格挡：不掉血、不进硬直、
## 播格挡音、盾闪白光；近战（旋转斩）被挡时哥布林会被轻推开一小段。
## 要逼玩家把回旋镖 / 念力爆破绕到它背后。炸弹爆炸（HitBox.unblockable）不被挡。

const SHIELD_ATLAS := preload( "res://enemies/art_v2/shield_plate.png" )
const CLANG_SOUND : AudioStream = preload( "res://enemies/shield_goblin/clang.wav" )

## 盾的半个有效角度（度）：伤害来源方向和盾朝向的夹角不超过它就被挡
@export var block_half_angle : float = 70.0
## 盾的最大转向速度（度/秒）：快速绕后的镖有机会在盾转过来之前命中
@export var shield_turn_speed : float = 240.0
## 近战被挡时的推开速度（像素/秒）和衰减（像素/秒²），推开距离约 速度²/(2*衰减)
@export var push_speed : float = 180.0
@export var push_decel : float = 700.0
## 两次格挡音之间的最短间隔（秒），避免镖在盾上蹭一下连响
@export var clang_cooldown : float = 0.15

## 盾当前朝向（弧度，世界坐标）
var shield_angle : float = PI / 2.0

var _plate : Sprite2D
var _flash : float = 0.0
var _clang_timer : float = 0.0
var _push : Vector2 = Vector2.ZERO
var _initialized : bool = false


func _ready() -> void:
	super._ready()
	_plate = Sprite2D.new()
	_plate.name = "ShieldPlate"
	_plate.texture = SHIELD_ATLAS
	_plate.hframes = 3
	_plate.vframes = 3
	add_child( _plate )
	_sync_plate()


func _process( delta : float ) -> void:
	_clang_timer = maxf( _clang_timer - delta, 0.0 )
	_flash = maxf( _flash - delta, 0.0 )
	if is_instance_valid( player ):
		var target := ( player.global_position - global_position ).angle()
		if not _initialized:
			shield_angle = target
			_initialized = true
		var max_step := deg_to_rad( shield_turn_speed ) * delta
		shield_angle += clampf( angle_difference( shield_angle, target ), -max_step, max_step )
	_sync_plate()


func _physics_process( delta : float ) -> void:
	if _push != Vector2.ZERO and not _is_defeated:
		velocity += _push
		_push = _push.move_toward( Vector2.ZERO, push_decel * delta )
	super._physics_process( delta )


func can_block( hit_box : HitBox ) -> bool:
	if hit_box.unblockable or _is_defeated or spawning:
		return false
	var to_src := hit_box.global_position - global_position
	if to_src.length() < 0.5:
		return true
	return absf( angle_difference( shield_angle, to_src.angle() ) ) <= deg_to_rad( block_half_angle )


func on_blocked( hit_box : HitBox ) -> void:
	_flash = 0.12
	_sync_plate()
	if _clang_timer <= 0.0:
		_clang_timer = clang_cooldown
		var audio : AudioStreamPlayer2D = $AudioStreamPlayer2D
		audio.stream = CLANG_SOUND
		audio.play()
	# 镖和念力爆破不推；其余（旋转斩）把哥布林从伤害来源推开一点，免得自动旋转斩一直空砍贴脸的它
	var src := hit_box.get_parent()
	if not ( src is Boomerang or src is PsiBlast ):
		var away := ( global_position - hit_box.global_position ).normalized()
		if away == Vector2.ZERO:
			away = Vector2.from_angle( shield_angle + PI )
		_push = away * push_speed


## 盾面跟随世界方向，身体可以在追逐或硬直时独立转向。
func _sync_plate() -> void:
	var forward := Vector2.from_angle( shield_angle )
	var row := 1 if absf( forward.x ) > absf( forward.y ) else ( 0 if forward.y > 0.0 else 2 )
	var column := 0
	if _flash > 0.0:
		column = 2 if _flash > 0.055 else 1
	_plate.visible = not _is_defeated
	_plate.frame_coords = Vector2i( column, row )
	_plate.position = Vector2( forward.x * 12.0, -12.0 + forward.y * 5.0 ).round()
	_plate.flip_h = row == 1 and forward.x < 0.0
	_plate.show_behind_parent = row == 2
	_plate.self_modulate = sprite_2d.self_modulate

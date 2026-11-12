class_name PsiBlast extends Node2D
## 念力爆破：回旋镖受控飞行结束时在它的精灵位置炸一次。
## 伤害走现有的 HitBox / HurtBox：生成一个短暂存在的圆形 HitBox（对敌人受击层生效），
## 每个敌人只会在进入范围时结算一次。HitBox 的父节点是 PsiBlast，
## LootDropper 据此把爆破击杀按"回旋镖击杀"处理。

const SHEET : Texture2D = preload( "res://player/sprites/psi_blast.png" )
const SOUND : AudioStream = preload( "res://player/audio/psi_blast.wav" )
## 精灵表 8 帧 128x128；峰值帧里爆炸主体直径约 100 像素，据此把精灵缩放到和范围一致
const FRAMES : int = 8
const BODY_DIAMETER : float = 100.0
## 动画总时长（秒）
const ANIM_TIME : float = 0.45
## HitBox 保持开启的时长（秒）：够物理引擎做一次重叠检测即可
const HIT_TIME : float = 0.1
const ENEMY_HURT_LAYER : int = 256

## 把调色板里的紫换成念力条的青色（交换 r、g 通道），白色高光不变
const TINT_SHADER_CODE := "shader_type canvas_item;\nvoid fragment() { vec4 c = texture(TEXTURE, UV); COLOR = vec4(c.grb, c.a); }"

var _hit_box : HitBox
var _sprite : Sprite2D


## 在 world_pos 生成一次爆破，加到 parent 下
static func spawn( parent : Node, world_pos : Vector2, radius : float, damage : int ) -> PsiBlast:
	var blast := PsiBlast.new()
	blast.add_to_group( "loot_fx" )
	blast.z_index = 5
	parent.add_child( blast )
	blast.global_position = world_pos
	blast._setup( radius, damage )
	return blast


func _setup( radius : float, damage : int ) -> void:
	_hit_box = HitBox.new()
	_hit_box.damage = damage
	_hit_box.ignores_stun_invulnerability = true
	_hit_box.collision_layer = 0
	_hit_box.collision_mask = ENEMY_HURT_LAYER
	_hit_box.monitorable = false
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = radius
	shape.shape = circle
	_hit_box.add_child( shape )
	add_child( _hit_box )

	_sprite = Sprite2D.new()
	_sprite.texture = SHEET
	_sprite.hframes = FRAMES
	var s := radius * 2.0 / BODY_DIAMETER
	_sprite.scale = Vector2( s, s )
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = TINT_SHADER_CODE
	mat.shader = sh
	_sprite.material = mat
	add_child( _sprite )

	var player := AudioStreamPlayer.new()
	player.stream = SOUND
	player.bus = &"Master"
	add_child( player )
	player.play()

	# 判定只开一小会儿
	get_tree().create_timer( HIT_TIME ).timeout.connect( _stop_hit )
	var tween := create_tween()
	tween.tween_property( _sprite, "frame", FRAMES - 1, ANIM_TIME ).from( 0 )
	await tween.finished
	# 音效没播完就等它播完
	if player.playing:
		await player.finished
	queue_free()


func _stop_hit() -> void:
	if is_instance_valid( _hit_box ):
		_hit_box.set_deferred( "monitoring", false )

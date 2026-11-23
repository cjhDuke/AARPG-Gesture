class_name BossTorch extends Node2D
## Boss 关的火把：给巫师的护盾供能。点燃时有火焰动画；被受控 / 返回途中的回旋镖或念力爆破碰到就熄灭
## （由 boss.douse() 统一处理：回念力、特效、判断是否碎盾），熄灭后在护盾阶段里倒计时重燃，
## 底座上的一圈进度条和渐亮的火星显示还剩多久。节点原点在火把底座中心。

const TEXTURE : Texture2D = preload( "res://enemies/wizard_boss/torch.png" )
const ABSORB_SOUND : AudioStream = preload( "res://levels/survival/pickups/item_pickup.wav" )
## 精灵表：5 帧 32x64，火焰在上、底座在下
const FRAME_SIZE := Vector2( 32, 64 )
const FRAMES : int = 5
const FRAME_FPS : float = 8.0
## 熄灭时只画底座（帧的下半部分）
const BOWL_Y : float = 32.0
## 判定中心（相对原点，火焰所在的位置）和半径（像素，比图标宽松）
const HIT_CENTER := Vector2( 0, -24 )
const HIT_RADIUS : float = 18.0
const ENEMY_HURT_LAYER : int = 256
const WALL_LAYER : int = 16

var lit : bool = true
var relight_total : float = 8.0
var relight_left : float = 0.0
var boss : WizardBoss

var _t : float = 0.0
var _hurt : HurtBox


func _ready() -> void:
	add_to_group( "boss_fx" )
	z_index = 2
	# 只阻挡脚下的底座。火焰受击判定独立，熄灭后底座仍在。
	var base := StaticBody2D.new()
	base.collision_layer = WALL_LAYER
	base.collision_mask = 0
	var footprint := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2( 24, 8 )
	footprint.position = Vector2( 0, -5 )
	footprint.shape = rect
	base.add_child( footprint )
	add_child( base )
	# 念力爆破走 HitBox / HurtBox：放一个敌人受击层上的 HurtBox 接它（镖在 _process 里按位置检测）
	_hurt = HurtBox.new()
	_hurt.collision_layer = ENEMY_HURT_LAYER
	_hurt.collision_mask = 0
	_hurt.monitoring = false
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = HIT_RADIUS
	shape.shape = circle
	shape.position = HIT_CENTER
	_hurt.add_child( shape )
	add_child( _hurt )
	_hurt.Damaged.connect( _on_hurt )


## 判定中心（世界坐标）
func hit_center() -> Vector2:
	return global_position + HIT_CENTER


func _process( delta : float ) -> void:
	_t += delta
	if boss != null and is_instance_valid( boss ):
		if lit:
			_check_boomerang()
		elif boss.phase == WizardBoss.Phase.SHIELD and boss.active:
			relight_left -= delta
			if relight_left <= 0.0:
				relight()
	queue_redraw()


## 受控飞行 / 返回途中的回旋镖精灵中心进入判定半径就算碰到
func _check_boomerang() -> void:
	var parent := get_parent()
	if parent == null:
		return
	for c in parent.get_children():
		if c is Boomerang and ( c.state == Boomerang.State.GUIDED or c.state == Boomerang.State.RETURN ):
			if ( c.global_position + Boomerang.SPRITE_OFFSET ).distance_to( hit_center() ) <= HIT_RADIUS:
				boss.douse( self )
				return


func _on_hurt( hb : HitBox ) -> void:
	if hb.get_parent() is PsiBlast and boss != null and is_instance_valid( boss ):
		boss.douse( self )


## 熄灭并开始重燃倒计时；已经熄灭返回 false
func extinguish( seconds : float ) -> bool:
	if not lit:
		return false
	lit = false
	relight_total = maxf( seconds, 0.1 )
	relight_left = relight_total
	return true


func relight() -> void:
	lit = true
	relight_left = 0.0


## 吸收火焰的小特效：几个火星从火把飞向主角
func play_absorb( target : Node2D ) -> void:
	var fx := AbsorbFx.new()
	fx.target = target
	fx.add_to_group( "boss_fx" )
	fx.z_index = 6
	get_parent().add_child( fx )
	fx.global_position = hit_center()
	var audio := AudioStreamPlayer.new()
	audio.stream = ABSORB_SOUND
	audio.volume_db = -6.0
	audio.pitch_scale = 1.3
	audio.bus = &"SFX"
	fx.add_child( audio )
	audio.play()


func _draw() -> void:
	if lit:
		var f := int( _t * FRAME_FPS ) % FRAMES
		draw_texture_rect_region( TEXTURE, Rect2( -16, -64, 32, 64 ), Rect2( f * 32.0, 0, 32, 64 ) )
		return
	# 熄灭：只画底座（略暗），火焰口上一团暗红火星随倒计时渐亮
	draw_texture_rect_region( TEXTURE, Rect2( -16, -32, 32, 32 ), Rect2( 0, BOWL_Y, 32, 32 ), Color( 0.7, 0.7, 0.8 ) )
	var k := 1.0 - clampf( relight_left / relight_total, 0.0, 1.0 ) if relight_total > 0.0 else 0.0
	# 只有护盾阶段才在倒计时；破绽阶段火把保持熄灭，不画进度（以免被误会成快要重燃）
	if boss != null and is_instance_valid( boss ) and boss.phase != WizardBoss.Phase.SHIELD:
		draw_circle( Vector2( 0, -27 ), 2.0, Color( 0.35, 0.12, 0.1, 0.6 ) )
		return
	var flick := 0.8 + 0.2 * sin( _t * 14.0 )
	var ember := Color( 0.5, 0.15, 0.1 ).lerp( Color( 1.0, 0.7, 0.2 ), k )
	draw_circle( Vector2( 0, -27 ), 2.0 + 3.0 * k, Color( ember.r, ember.g, ember.b, ( 0.5 + 0.5 * k ) * flick ) )
	# 渐亮的小火苗
	if k > 0.35:
		var h := ( k - 0.35 ) / 0.65 * 9.0
		draw_colored_polygon( PackedVector2Array( [ Vector2( -3, -27 ), Vector2( 3, -27 ), Vector2( 0, -27 - h ) ] ), Color( 1.0, 0.6, 0.15, 0.7 * flick ) )
	# 倒计时进度圈：绕着底座上沿，从正上方顺时针填满
	var c := Vector2( 0, -27 )
	draw_arc( c, 11.0, 0.0, TAU, 32, Color( 0, 0, 0, 0.5 ), 3.0 )
	draw_arc( c, 11.0, -PI * 0.5, -PI * 0.5 + TAU * k, 32, Color( 1.0, 0.75, 0.25, 0.95 ), 2.0 )


## 火星飞向主角（约 0.45 秒），到达后消失
class AbsorbFx extends Node2D:
	const TIME : float = 0.45
	var target : Node2D
	var _from : Vector2
	var _t : float = 0.0

	func _ready() -> void:
		_from = global_position

	func _process( delta : float ) -> void:
		_t += delta
		if _t >= TIME or not is_instance_valid( target ):
			queue_free()
			return
		queue_redraw()

	func _draw() -> void:
		if not is_instance_valid( target ):
			return
		var dest := target.global_position + Vector2( 0, -14 ) - global_position
		var k := _t / TIME
		for i in 6:
			var kk := clampf( k - i * 0.05, 0.0, 1.0 )
			var side := Vector2( 0, -1 ).rotated( i * 1.05 ) * sin( kk * PI ) * 10.0
			var p := ( dest * ease( kk, 0.6 ) ) + side
			draw_circle( p, 2.2 - kk * 1.2, Color( 1.0, 0.7 - 0.2 * kk, 0.2, 1.0 - kk * 0.4 ) )

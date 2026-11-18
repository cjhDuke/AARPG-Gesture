class_name BossFireball extends EnemyProjectile
## 巫师的火球：直线飞行，命中主角 -1。
## 被回旋镖打到不会消失，而是调头飞向巫师（变蓝、速度 REFLECT_SPEED），命中后巫师踉跄，不再伤主角；
## 被念力爆破打到、或弹反强化下被旋转斩打到则直接销毁（继承 EnemyProjectile 的 destroy_by_player）。

const REFLECT_SPEED : float = 160.0
## 反弹的火球离巫师身体中心多近算命中（像素）
const HIT_BOSS_DIST : float = 20.0

var reflected : bool = false
## 反弹后的目标（发射它的巫师）
var boss : WizardBoss


func _init() -> void:
	speed = 90.0
	max_lifetime = 6.0
	hit_radius = 6.0


func _process( _delta : float ) -> void:
	queue_redraw()


func _physics_process( delta : float ) -> void:
	if reflected and not _gone:
		if is_instance_valid( boss ) and boss.is_inside_tree():
			var to_boss := boss.body_center() - global_position
			if to_boss.length() <= HIT_BOSS_DIST:
				_gone = true
				_spawn_pop()
				boss.on_fireball_hit()
				queue_free()
				return
			# 轻微追踪：保证一定打得到
			direction = to_boss.normalized()
			rotation = direction.angle()
	super._physics_process( delta )


func _on_hurt( hit_box : HitBox ) -> void:
	if reflected or _gone:
		return
	var src := hit_box.get_parent()
	if src is Boomerang:
		_reflect()
	elif src is PsiBlast or ( parry_by_spin and ( src is Player or src.get_parent() is Player ) ):
		destroy_by_player()


func _reflect() -> void:
	reflected = true
	speed = REFLECT_SPEED
	_age = 0.0
	# 不再伤主角（物理回调里改碰撞掩码，延后执行）
	set_deferred( "collision_mask", 0 )
	_spawn_pop()


func _draw() -> void:
	var core := Color( 1.0, 0.95, 0.6 )
	var mid := Color( 1.0, 0.55, 0.12 )
	var halo := Color( 1.0, 0.3, 0.1 )
	if reflected:
		core = Color( 0.85, 1.0, 1.0 )
		mid = Color( 0.35, 0.75, 1.0 )
		halo = Color( 0.2, 0.4, 1.0 )
	var flick := 1.0 + 0.15 * sin( Time.get_ticks_msec() * 0.03 )
	# 节点已按飞行方向旋转，-x 是身后：拖一条渐隐的尾巴
	for i in 4:
		var k := float( i + 1 )
		draw_circle( Vector2( -3.0 * k, 0 ), maxf( 6.0 - k * 1.2, 1.5 ), Color( mid.r, mid.g, mid.b, 0.5 - k * 0.1 ) )
	draw_circle( Vector2.ZERO, 9.0 * flick, Color( halo.r, halo.g, halo.b, 0.28 ) )
	draw_circle( Vector2.ZERO, 6.5 * flick, mid )
	draw_circle( Vector2.ZERO, 3.5, core )

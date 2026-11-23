class_name EnemyStateArcher extends EnemyStateApproach
## 弓手的行为状态（替换 Approach）：保持距离、定时预警并射箭。数值在 ArcherGoblin 上调。
## 受击硬直（Stun）结束后回到这里；硬直会打断预警，计时重来。

const RELEASE_TIME := 0.09
const RECOVER_TIME := 0.13

var _cooldown : float = 1.0
var _aim_left : float = 0.0
var _release_left := 0.0
var _anim : String = ""


func enter() -> void:
	var a := enemy as ArcherGoblin
	a.aiming = false
	_aim_left = 0.0
	_cooldown = randf_range( 0.6, a.shoot_interval )
	_release_left = 0.0
	_anim = ""
	_set_anim( "idle" )


func exit() -> void:
	( enemy as ArcherGoblin ).aiming = false
	_aim_left = 0.0


func process( delta : float ) -> EnemyState:
	var a := enemy as ArcherGoblin
	var to_player : Vector2 = a.target_point() - a.muzzle()
	var dir := to_player.normalized() if to_player.length() > 0.001 else Vector2.DOWN
	_release_left = maxf( 0.0, _release_left - delta )
	var facing := a.aim_dir if _release_left > 0.0 else dir
	if a.set_direction( facing ):
		_refresh_anim()

	if a.spawning:
		a.velocity = Vector2.ZERO
		return null

	if a.aiming:
		a.velocity = Vector2.ZERO
		a.aim_dir = dir
		_aim_left -= delta
		if _aim_left <= 0.0:
			# 方向在预警结束这一刻锁定
			a.aiming = false
			_cooldown = a.shoot_interval
			_release_left = RELEASE_TIME + RECOVER_TIME
			_set_anim( "bow_release" )
			enemy.animation_player.advance( 0.0 )
			a.shoot( dir )
		elif _aim_left <= a.telegraph_time * 0.78:
			_set_anim( "bow_aim" )
		return null

	var retreat := not a.stationary and to_player.length() < a.keep_distance
	a.velocity = -dir * a.move_speed if retreat else Vector2.ZERO
	if _release_left > 0.0:
		_set_anim( "bow_release" if _release_left > RECOVER_TIME else "bow_recover" )
	else:
		_set_anim( "chase" if retreat else "idle" )

	_cooldown -= delta
	if _cooldown <= 0.0:
		a.aiming = true
		a.aim_dir = dir
		_aim_left = a.telegraph_time
		_release_left = 0.0
		_set_anim( "bow_raise" )
	return null


## 弓手没有攻击判定区，接触伤害只靠本体 HitBox
func _sync_attack_area() -> void:
	pass


func _set_anim( n : String ) -> void:
	if n != _anim:
		_anim = n
		_refresh_anim()


func _refresh_anim() -> void:
	if _anim != "":
		enemy.update_animation( _anim )

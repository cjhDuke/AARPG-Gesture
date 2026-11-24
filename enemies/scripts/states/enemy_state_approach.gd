class_name EnemyStateApproach extends EnemyState
## 始终直线逼近主角（站桩守卫模式的敌人初始状态，Stun 结束后也回到这里）

@export var anim_name : String = "walk"
@export var speed : float = 40.0
## 逼近时才开启的攻击判定（哥布林的挥击范围），可为空
@export var attack_area : HitBox


func enter() -> void:
	enemy.update_animation( anim_name )
	_sync_attack_area()


func exit() -> void:
	if attack_area:
		attack_area.monitoring = false


func process( _delta : float ) -> EnemyState:
	var target := PlayerManager.player.global_position
	if enemy.route_to_player.is_valid():
		target = enemy.route_to_player.call( enemy.global_position, target )
	var dir := enemy.global_position.direction_to( target )
	enemy.velocity = dir * speed
	if enemy.set_direction( dir ):
		enemy.update_animation( anim_name )
	_sync_attack_area()
	return null


## 淡入生成期间不开攻击判定
func _sync_attack_area() -> void:
	if attack_area:
		attack_area.monitoring = not enemy.spawning

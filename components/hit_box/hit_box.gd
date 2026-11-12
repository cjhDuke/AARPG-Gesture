class_name HitBox extends Area2D

@export var damage : int = 1
## 为 true 时无视敌人的受击硬直无敌（淡入、死亡动画期间的无敌仍然有效），只给念力爆破用
var ignores_stun_invulnerability : bool = false

## 为 true 时无视盾牌格挡（炸弹爆炸）
var unblockable : bool = false

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	area_entered.connect( _on_area_entered )
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass

func _on_area_entered ( a : Area2D ) -> void:
	if a is HurtBox:
		a.take_damage( self )
	pass

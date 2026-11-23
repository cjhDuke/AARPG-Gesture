extends Enemy
## Passive slime that reacts only to the weapon taught in this exercise.

enum Weapon { SWORD, RANG, HEAVY_RANG }

var weapon := Weapon.SWORD


func _ready() -> void:
	fade_in_time = 0.0
	hp = 2 if weapon == Weapon.HEAVY_RANG else 1
	super._ready()
	state_machine.set_process(false)
	state_machine.set_physics_process(false)
	hit_box.monitoring = false


func _take_damage(box: HitBox) -> void:
	var rang := box.get_parent() as Boomerang
	if weapon == Weapon.SWORD:
		if rang != null or box.get_parent() is PsiBlast:
			return
	elif rang == null or rang.state != Boomerang.State.GUIDED:
		return
	super._take_damage(box)

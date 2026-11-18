class_name Arrow extends EnemyProjectile
## 弓手的箭：32x8 的精灵（箭头朝 +x），速度 120、伤害 1，直线飞行

const TEXTURE : Texture2D = preload( "res://enemies/archer_goblin/arrow.png" )


func _build_visual() -> void:
	var sprite := Sprite2D.new()
	sprite.texture = TEXTURE
	# 节点原点放在箭头上：箭头碰到主角才算命中
	sprite.position = Vector2( -13, 0 )
	add_child( sprite )

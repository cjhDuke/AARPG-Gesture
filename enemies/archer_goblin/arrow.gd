class_name Arrow extends EnemyProjectile
## 弓手的箭：32x8 的精灵（箭头朝 +x），速度 120、伤害 1，直线飞行

const TEXTURE : Texture2D = preload( "res://enemies/art_v2/archer_arrow.png" )


func _init() -> void:
	terrain_mask |= ARROW_COVER_LAYER


static func cover_endpoint( space: PhysicsDirectSpaceState2D, from: Vector2, to: Vector2 ) -> Vector2:
	var query := PhysicsRayQueryParameters2D.create( from, to, ARROW_COVER_LAYER )
	query.hit_from_inside = true
	return space.intersect_ray( query ).get( "position", to )


func _build_visual() -> void:
	var sprite := Sprite2D.new()
	sprite.texture = TEXTURE
	# 节点原点放在箭头上：箭头碰到主角才算命中
	sprite.position = Vector2( -13, 0 )
	add_child( sprite )

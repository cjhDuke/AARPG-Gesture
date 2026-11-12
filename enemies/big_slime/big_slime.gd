class_name BigSlime extends Enemy
## 大史莱姆：1.6 倍大小（场景根节点缩放，碰撞体和受击框一起放大）。
## 被消灭时分裂出 split_count 只普通史莱姆，在它左右各 split_offset 像素处。
## 分裂由 WaveSpawner 在清波判定之前调用 on_defeated() 触发，用 spawn_extra 生成，
## 所以小史莱姆没死之前这一波不算清完。

@export var split_count : int = 2
## 小史莱姆离大史莱姆中心的水平距离（像素）
@export var split_offset : float = 10.0
@export var split_type : String = "slime"


func on_defeated( spawner : Node ) -> void:
	var rect := HandController.ARENA_RECT
	for i in split_count:
		# 左右对称排开；只有 1 只时放在中间
		var side := 0.0 if split_count == 1 else ( float( i ) / float( split_count - 1 ) * 2.0 - 1.0 )
		var pos := global_position + Vector2( side * split_offset, 0 )
		pos = Vector2( clampf( pos.x, rect.position.x, rect.end.x ), clampf( pos.y, rect.position.y, rect.end.y ) )
		spawner.spawn_extra( split_type, pos )

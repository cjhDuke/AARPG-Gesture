class_name BombSlime extends Enemy
## 炸弹史莱姆：红色，头上有闪烁的引信火花。死亡时原地留下一颗引信炸弹（BombExplosion），
## 闪烁膨胀 fuse_time 秒后爆炸，给近战击杀的玩家走开的时间。
## 波次计数：一被打死就按"已消灭"计入（和其他怪一致）；之后的爆炸可能波及主角或其他怪，
## 那些怪的死亡也各自正常计数。宝箱出现后爆炸才伤到主角是可以接受的。

## 爆炸半径（像素）
@export var blast_radius : float = 40.0
## 死后到爆炸的延迟（秒）
@export var fuse_time : float = 0.5
@export var blast_player_damage : int = 1
@export var blast_enemy_damage : int = 2

static var _spark_points: PackedVector2Array

var _marks : Node2D
var _time : float = 0.0


func _ready() -> void:
	super._ready()
	enemy_destroyed.connect( _on_bomb_destroyed )
	if _spark_points.is_empty():
		_cache_spark_points()
	# 像素亮点跟随精灵里的引信。
	_marks = Node2D.new()
	_marks.draw.connect( _draw_fuse )
	add_child( _marks )


func _process( delta : float ) -> void:
	_time += delta
	_marks.visible = not _is_defeated
	_marks.queue_redraw()


## 每格引信在胶体压扁、起跳和转身时位置不同。由图集顶部的亮点定位一次。
func _cache_spark_points() -> void:
	var image := sprite_2d.texture.get_image()
	for frame_id in sprite_2d.hframes * sprite_2d.vframes:
		var cell := Vector2i( frame_id % sprite_2d.hframes, frame_id / sprite_2d.hframes )
		var frame_image := image.get_region( Rect2i( cell * 64, Vector2i( 64, 64 ) ) )
		var ink := frame_image.get_used_rect()
		var tip := Vector2( ink.get_center().x, ink.position.y )
		var brightness := 0.0
		for y in range( ink.position.y, mini( ink.position.y + 7, ink.end.y ) ):
			for x in range( ink.position.x, ink.end.x ):
				var pixel := frame_image.get_pixel( x, y )
				if pixel.a > 0.5 and pixel.r > 0.6 and pixel.g > pixel.b + 0.1 and pixel.r + pixel.g > brightness:
					tip = Vector2( x, y )
					brightness = pixel.r + pixel.g
		_spark_points.append( tip - Vector2( 32, 32 ) )


func _draw_fuse() -> void:
	if int( _time * 14.0 ) % 2 != 0:
		return
	var tip := _spark_points[sprite_2d.frame]
	tip.x *= sprite_2d.scale.x
	tip = ( tip + sprite_2d.position ).round()
	_marks.draw_rect( Rect2( tip - Vector2.ONE, Vector2( 3, 3 ) ), Color( 1.0, 0.69, 0.16, 0.55 ) )
	_marks.draw_rect( Rect2( tip, Vector2.ONE ), Color( 1.0, 0.97, 0.73 ) )


func _on_bomb_destroyed( _hit_box : HitBox ) -> void:
	BombExplosion.arm( get_parent(), global_position, blast_radius, fuse_time,
		blast_player_damage, blast_enemy_damage )

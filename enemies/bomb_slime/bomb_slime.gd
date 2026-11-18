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

var _marks : Node2D
var _time : float = 0.0


func _ready() -> void:
	super._ready()
	enemy_destroyed.connect( _on_bomb_destroyed )
	# 引信火花画在精灵之上
	_marks = Node2D.new()
	_marks.draw.connect( _draw_fuse )
	add_child( _marks )


func _process( delta : float ) -> void:
	_time += delta
	_marks.visible = not _is_defeated
	_marks.queue_redraw()


## 头顶一小段弯曲的引信，末端是闪烁的火花
func _draw_fuse() -> void:
	var base := Vector2( 0, -19 )
	var mid := Vector2( 2, -22 )
	var tip := Vector2( 5, -23 )
	_marks.draw_line( base, mid, Color( 0.25, 0.15, 0.1 ), 1.0 )
	_marks.draw_line( mid, tip, Color( 0.25, 0.15, 0.1 ), 1.0 )
	var on := int( _time * 14.0 ) % 2 == 0
	var c := Color( 1.0, 0.95, 0.4 ) if on else Color( 1.0, 0.5, 0.1 )
	var r := 2.0 if on else 1.0
	_marks.draw_line( tip + Vector2( -r - 1, 0 ), tip + Vector2( r + 1, 0 ), c, 1.0 )
	_marks.draw_line( tip + Vector2( 0, -r - 1 ), tip + Vector2( 0, r + 1 ), c, 1.0 )
	_marks.draw_rect( Rect2( tip + Vector2( -0.5, -0.5 ), Vector2( 1, 1 ) ), Color.WHITE )


func _on_bomb_destroyed( _hit_box : HitBox ) -> void:
	BombExplosion.arm( get_parent(), global_position, blast_radius, fuse_time,
		blast_player_damage, blast_enemy_damage )

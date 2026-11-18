class_name HandCursor extends Node2D
## 手的光标：世界坐标里的小圆环 + 十字。张开时白色，握拳时橙色。

const COLOR_OPEN := Color( 1, 1, 1, 0.95 )
const COLOR_FIST := Color( 1.0, 0.6, 0.15, 0.95 )
const RADIUS := 6.0

var fist : bool = false :
	set( v ):
		if fist != v:
			fist = v
			queue_redraw()


func _ready() -> void:
	z_index = 100
	visible = false


func _draw() -> void:
	var c := COLOR_FIST if fist else COLOR_OPEN
	draw_arc( Vector2.ZERO, RADIUS, 0.0, TAU, 20, Color( 0, 0, 0, 0.7 ), 3.0 )
	draw_arc( Vector2.ZERO, RADIUS, 0.0, TAU, 20, c, 1.0 )
	draw_line( Vector2( -RADIUS - 3, 0 ), Vector2( -RADIUS + 2, 0 ), c, 1.0 )
	draw_line( Vector2( RADIUS - 2, 0 ), Vector2( RADIUS + 3, 0 ), c, 1.0 )
	draw_line( Vector2( 0, -RADIUS - 3 ), Vector2( 0, -RADIUS + 2 ), c, 1.0 )
	draw_line( Vector2( 0, RADIUS - 2 ), Vector2( 0, RADIUS + 3 ), c, 1.0 )

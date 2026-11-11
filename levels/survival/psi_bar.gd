class_name PsiBar extends Node2D
## 主角头顶的念力条（世界坐标）：满值青色，低于 0.3 变红。
## 操控回旋镖和回充期间显示，回满后淡出；念力不足起飞失败时 flash() 闪烁。

## 相对主角原点（脚底）的偏移：精灵连帽子约 46 像素高，条放在头顶上方
const OFFSET := Vector2( 0, -50 )
const BAR_SIZE := Vector2( 28, 4 )
const COLOR_OK := Color( 0.25, 0.9, 1.0 )
const COLOR_LOW := Color( 1.0, 0.3, 0.25 )
const COLOR_BACK := Color( 0, 0, 0, 0.75 )
const LOW_THRESHOLD : float = 0.3
const FADE_TIME : float = 0.3
const FLASH_TIME : float = 0.4
const FLASH_BLINK_HZ : float = 12.5

var _value : float = 1.0
var _active : bool = false
var _alpha : float = 0.0
var _flash_left : float = 0.0


func _ready() -> void:
	z_index = 100
	visible = false


## value 0-1；active 为 true 时显示，false 时淡出
func update_state( value : float, active : bool ) -> void:
	_value = clampf( value, 0.0, 1.0 )
	_active = active


## 闪烁约 0.4 秒（即使当前隐藏也显示）
func flash() -> void:
	_flash_left = FLASH_TIME


## 立刻隐藏（死亡、结算、控制器禁用）
func hide_now() -> void:
	_active = false
	_alpha = 0.0
	_flash_left = 0.0
	visible = false


func _process( delta : float ) -> void:
	if _active:
		_alpha = 1.0
	else:
		_alpha = move_toward( _alpha, 0.0, delta / FADE_TIME )
	var shown := _alpha
	if _flash_left > 0.0:
		_flash_left = maxf( _flash_left - delta, 0.0 )
		# 闪烁：按固定频率明暗交替，期间至少可见
		shown = 1.0 if int( _flash_left * FLASH_BLINK_HZ ) % 2 == 0 else 0.25
	visible = shown > 0.0
	modulate.a = shown
	queue_redraw()


func _draw() -> void:
	var origin := Vector2( -BAR_SIZE.x * 0.5, 0.0 )
	draw_rect( Rect2( origin - Vector2.ONE, BAR_SIZE + Vector2.ONE * 2.0 ), COLOR_BACK )
	var c := COLOR_OK if _value >= LOW_THRESHOLD else COLOR_LOW
	draw_rect( Rect2( origin, Vector2( BAR_SIZE.x * _value, BAR_SIZE.y ) ), c )

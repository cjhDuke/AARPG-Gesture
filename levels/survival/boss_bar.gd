class_name BossBar extends Control
## Boss 血条：3 段，名字在左。画面顶部、手势提示框的正下方。
## 第 1 轮扣最右一段，往左依次扣；当前段按剩余血量比例填充。只在 Boss 关显示（SurvivalHud 创建和管理）。

const SEGMENTS : int = 3
const SEG_W : float = 56.0
const SEG_H : float = 7.0
const GAP : float = 6.0
const COL_BACK := DungeonTheme.BACKGROUND
const COL_FULL := Color( "#b568a3" )
const COL_HURT := DungeonTheme.TEXT
const COL_EDGE := DungeonTheme.GOLD

var round_idx : int = 0
var seg_hp : int = 10
var seg_max : int = 10
## 刚受伤的闪白时间
var _flash : float = 0.0
var _name : Label


func _ready() -> void:
	theme = DungeonTheme.THEME
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name = Label.new()
	_name.text = "WIZARD"
	_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name.add_theme_font_size_override( "font_size", 8 )
	_name.add_theme_color_override( "font_outline_color", Color.BLACK )
	_name.add_theme_constant_override( "outline_size", 3 )
	_name.position = Vector2( -36, -3 )
	add_child( _name )


func set_hp( round_no : int, hp : int, hp_max : int ) -> void:
	if round_no - 1 == round_idx and hp < seg_hp:
		_flash = 0.15
	round_idx = round_no - 1
	seg_hp = hp
	seg_max = maxi( hp_max, 1 )
	queue_redraw()


func _process( delta : float ) -> void:
	if _flash > 0.0:
		_flash = maxf( _flash - delta, 0.0 )
		queue_redraw()


func _draw() -> void:
	# The compact rail uses a thin copper frame; the three phase fills stay distinct.
	draw_rect( Rect2( -39, -5, 221, 17 ), DungeonTheme.BACKGROUND )
	draw_rect( Rect2( -39, -5, 221, 17 ), DungeonTheme.GOLD, false, 1.0 )
	for slot in SEGMENTS:
		# 从左到右的第 slot 格对应第 (SEGMENTS - 1 - slot) 轮
		var r := SEGMENTS - 1 - slot
		var frac := 0.0
		if r > round_idx:
			frac = 1.0
		elif r == round_idx:
			frac = clampf( float( seg_hp ) / float( seg_max ), 0.0, 1.0 )
		var x := slot * ( SEG_W + GAP )
		var rect := Rect2( x, 0, SEG_W, SEG_H )
		draw_rect( rect, COL_BACK )
		if frac > 0.0:
			var col := COL_HURT if ( r == round_idx and _flash > 0.0 ) else COL_FULL
			draw_rect( Rect2( x + 1, 1, ( SEG_W - 2.0 ) * frac, SEG_H - 2.0 ), col )
		draw_rect( rect, COL_EDGE, false, 1.0 )

class_name TitleLogo extends Control
## 像素大字标题：每个字母是独立的一组 Label（红色硬边投影垫在下面、米白字 + 深色描边在上面）。
## 入场：字母逐个从上方落下并回弹，每落一个发一次 letter_landed；
## 全部落定后整体缓慢上下浮动（约 ±2 像素，周期 2 秒）并发出 intro_finished。
## 本节点处于暂停的场景树里，所以要挂在 ALWAYS 的父节点下（CanvasLayer 已是）。

signal letter_landed( index: int )
signal intro_finished

@export var text: String = "PSI HAND"
## 字体基准是 16，用整数倍保持像素对齐
@export var font_size: int = 64
## 字母静止时的顶边 y
@export var rest_y: float = 30.0
@export var letter_gap: float = 2.0
@export var shadow_offset: Vector2 = Vector2( 4, 4 )
@export var face_color: Color = Color( 0.96, 0.92, 0.80 )
@export var outline_color: Color = Color( 0.10, 0.07, 0.12 )
@export var shadow_color: Color = Color( 0.72, 0.26, 0.25 )
@export var outline_size: int = 4

const DROP_FROM_Y := -90.0
const DROP_TIME := 0.6
const DROP_STAGGER := 0.13
## TRANS_BOUNCE 的第一次触地发生在总时长的约 36% 处
const FIRST_IMPACT := 0.36
const FLOAT_AMPLITUDE := 2.0
const FLOAT_PERIOD := 2.0

var _holder: Control
var _letters: Array[Control] = []
var _float_t: float = 0.0
var _floating: bool = false
var _skipped: bool = false
var _intro_tween: Tween


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_holder = Control.new()
	_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child( _holder )
	_build()


func _process( delta: float ) -> void:
	if not _floating:
		return
	_float_t += delta
	_holder.position.y = roundf( sin( _float_t * TAU / FLOAT_PERIOD ) * FLOAT_AMPLITUDE )


## 下落动画期间按确认键（回车 / 空格）直接跳过
func _unhandled_input( event: InputEvent ) -> void:
	if _intro_tween != null and not _floating and event.is_action_pressed( "ui_accept" ):
		skip_intro()
		get_viewport().set_input_as_handled()


## 标题总宽度（屏幕像素），给外部对齐其他元素用
func get_text_width() -> float:
	var font := get_theme_default_font()
	var total := 0.0
	for ch in text:
		total += _advance( font, ch ) + letter_gap
	return total - letter_gap


func play_intro() -> void:
	_floating = false
	_skipped = false
	_float_t = 0.0
	_holder.position.y = 0.0
	for l in _letters:
		l.position.y = DROP_FROM_Y
		l.visible = true
	var tw := create_tween()
	_intro_tween = tw
	tw.set_parallel( true )
	var k := 0
	for i in _letters.size():
		var l: Control = _letters[ i ]
		var delay := DROP_STAGGER * k
		tw.tween_property( l, "position:y", rest_y, DROP_TIME ) \
			.set_delay( delay ).set_trans( Tween.TRANS_BOUNCE ).set_ease( Tween.EASE_OUT )
		tw.tween_callback( letter_landed.emit.bind( i ) ).set_delay( delay + DROP_TIME * FIRST_IMPACT )
		k += 1
	tw.chain().tween_callback( _on_intro_done )


## 跳过下落动画：字母直接就位并发 intro_finished（按确认键跳过；动画已结束时无效）
func skip_intro() -> void:
	if _floating or _skipped:
		return
	_skipped = true
	if _intro_tween:
		_intro_tween.kill()
	_float_t = 0.0
	_holder.position.y = 0.0
	for l in _letters:
		l.position.y = rest_y
		l.visible = true
	_on_intro_done()


func _on_intro_done() -> void:
	_floating = true
	intro_finished.emit()


func _build() -> void:
	var font := get_theme_default_font()
	var vw := get_viewport_rect().size.x
	var x: float = roundf( ( vw - get_text_width() ) * 0.5 )
	for ch in text:
		var adv := _advance( font, ch )
		if ch != " ":
			var letter := Control.new()
			letter.mouse_filter = Control.MOUSE_FILTER_IGNORE
			letter.position = Vector2( x, DROP_FROM_Y )
			letter.visible = false
			# 先加投影再加字面，字面压在投影上
			letter.add_child( _make_label( ch, shadow_color, shadow_offset ) )
			letter.add_child( _make_label( ch, face_color, Vector2.ZERO ) )
			_holder.add_child( letter )
			_letters.append( letter )
		x += adv + letter_gap


func _make_label( ch: String, color: Color, offset: Vector2 ) -> Label:
	var l := Label.new()
	l.text = ch
	l.position = offset
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override( "font_size", font_size )
	l.add_theme_color_override( "font_color", color )
	l.add_theme_color_override( "font_outline_color", outline_color )
	l.add_theme_constant_override( "outline_size", outline_size )
	return l


func _advance( font: Font, ch: String ) -> float:
	if ch == " ":
		return float( font_size ) * 0.4
	return font.get_string_size( ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size ).x

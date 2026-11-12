class_name UpgradeMenu extends CanvasLayer
## 强化三选一弹窗：打开时暂停游戏、画面压暗，横排 3 张卡片（最少 1 张），必须选一个才会关闭。
## 键盘：左右 / A D 切换，回车 / 空格 / J 确认；鼠标：悬停高亮、左键点击选中。手势不参与。
## 默认焦点在中间那张；打开后前 CONFIRM_LOCK_MS 毫秒不接受确认（防止连按误选）。
## 弹窗期间 Esc 被本弹窗吞掉，暂停菜单弹不出来（两层暂停会打架）；选完 / abort() 后恢复暂停状态。
## 选定后发 chosen( id )（此时已取消暂停），由关卡给对应强化升级；弹窗随后自己释放。
## process_mode 为 ALWAYS，用真实时间计时，不受暂停和 Engine.time_scale 影响。

const FONT : Font = preload( "res://ui/fonts/abaddon_light.ttf" )
const APPEAR_SOUND : AudioStream = preload( "res://levels/survival/upgrade_appear.wav" )
const CHOOSE_SOUND : AudioStream = preload( "res://levels/survival/upgrade_choose.wav" )

const CARD_SIZE := Vector2( 132, 140 )
const CARD_GAP : float = 10.0
const CARD_TOP : float = 66.0
const SELECT_LIFT : float = 6.0
## 打开后多久之内不接受确认（毫秒）
const CONFIRM_LOCK_MS : int = 400

const COL_DIM := Color( 0.0, 0.0, 0.0, 0.62 )
const COL_TITLE := Color( 1.0, 0.9, 0.55 )
const COL_CARD := Color( 0.08, 0.09, 0.1, 0.9 )
const COL_CARD_SEL := Color( 0.16, 0.17, 0.2, 0.97 )
const COL_BORDER := Color( 0.35, 0.37, 0.42 )
const COL_BORDER_SEL := Color( 1.0, 0.85, 0.35 )

signal chosen( id : String )

var _ids : Array[String] = []
## 打开时各强化的当前等级（id -> 等级，0 = 还没有）
var _levels : Dictionary = {}
var _cards : Array[Card] = []
var _sel : int = 0
var _opened_ms : int = 0
var _done : bool = false
var _audio : AudioStreamPlayer


## 在 add_child 之前调用：要展示的强化 id 和当前各强化等级
func setup( ids : Array[String], levels : Dictionary ) -> void:
	_ids = ids
	_levels = levels


func _ready() -> void:
	layer = 8
	process_mode = Node.PROCESS_MODE_ALWAYS
	_opened_ms = Time.get_ticks_msec()

	var dim := ColorRect.new()
	dim.color = COL_DIM
	dim.set_anchors_preset( Control.PRESET_FULL_RECT )
	# 吞掉鼠标，免得点穿到下面（暂停期间下面本来也不响应）
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child( dim )

	var root := Control.new()
	root.set_anchors_preset( Control.PRESET_FULL_RECT )
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child( root )

	var title := _make_label( "CHOOSE UPGRADE", 16, COL_TITLE )
	title.set_anchors_preset( Control.PRESET_TOP_WIDE )
	title.offset_top = 28.0
	title.offset_bottom = 52.0
	root.add_child( title )

	var hint := _make_label( "LEFT / RIGHT: SELECT   ENTER: CONFIRM   OR CLICK", 8, Color( 0.75, 0.8, 0.85 ) )
	hint.set_anchors_preset( Control.PRESET_BOTTOM_WIDE )
	hint.offset_top = -40.0
	hint.offset_bottom = -26.0
	root.add_child( hint )

	var n := _ids.size()
	var total_w := n * CARD_SIZE.x + ( n - 1 ) * CARD_GAP
	var x0 := roundf( ( 480.0 - total_w ) * 0.5 )
	for i in n:
		var card := Card.new()
		card.setup( _ids[i], int( _levels.get( _ids[i], 0 ) ) )
		card.size = CARD_SIZE
		card.position = Vector2( x0 + i * ( CARD_SIZE.x + CARD_GAP ), CARD_TOP )
		card.mouse_entered.connect( _select.bind( i ) )
		card.gui_input.connect( _on_card_gui_input.bind( i ) )
		root.add_child( card )
		_cards.append( card )
	# 默认焦点在中间那张
	_select( n >> 1 )

	_audio = AudioStreamPlayer.new()
	_audio.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child( _audio )
	_play( APPEAR_SOUND )
	get_tree().paused = true


## 外部中止（重开、跳关、关卡释放）：不选，直接取消暂停并释放
func abort() -> void:
	if _done:
		return
	_done = true
	get_tree().paused = false
	queue_free()


## 当前高亮的是第几张
func selected_index() -> int:
	return _sel


func card_count() -> int:
	return _cards.size()


func _input( event : InputEvent ) -> void:
	if _done:
		return
	# 弹窗期间 Esc 不能弹出暂停菜单：在这里吞掉（PauseMenu 用 _unhandled_input）
	if event.is_action_pressed( "pause" ):
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed( "ui_left" ) or event.is_action_pressed( "left" ):
		_select( _sel - 1 )
	elif event.is_action_pressed( "ui_right" ) or event.is_action_pressed( "right" ):
		_select( _sel + 1 )
	elif event.is_action_pressed( "ui_accept" ) or _is_key( event, KEY_J ):
		_confirm()
	else:
		return
	get_viewport().set_input_as_handled()


func _is_key( event : InputEvent, key : Key ) -> bool:
	return event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == key


func _on_card_gui_input( event : InputEvent, i : int ) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_select( i )
		_confirm()


func _select( i : int ) -> void:
	if _cards.is_empty():
		return
	_sel = clampi( i, 0, _cards.size() - 1 )
	for k in _cards.size():
		_cards[k].set_selected( k == _sel )
		_cards[k].position.y = CARD_TOP - ( SELECT_LIFT if k == _sel else 0.0 )


func _confirm() -> void:
	if _done or Time.get_ticks_msec() - _opened_ms < CONFIRM_LOCK_MS:
		return
	_done = true
	_play( CHOOSE_SOUND )
	get_tree().paused = false
	for c in get_children():
		if c is CanvasItem:
			c.visible = false
	chosen.emit( _ids[_sel] )
	# 音效还在播，晚一点再释放
	await get_tree().create_timer( 0.6 ).timeout
	queue_free()


func _play( sound : AudioStream ) -> void:
	_audio.stream = sound
	_audio.play()


func _make_label( text : String, font_size : int, color : Color ) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override( "font_size", font_size )
	label.add_theme_color_override( "font_color", color )
	return label


## 一张强化卡片：图标、名称、等级变化、下一级效果。全部用 _draw 画
class Card extends Control:
	var upgrade_id : String = ""
	var from_level : int = 0
	var selected : bool = false

	func setup( id : String, lv : int ) -> void:
		upgrade_id = id
		from_level = lv
		mouse_filter = Control.MOUSE_FILTER_STOP

	func set_selected( on : bool ) -> void:
		selected = on
		# 没选中的卡片稍微压暗，高亮的那张更突出
		modulate = Color.WHITE if on else Color( 0.78, 0.78, 0.82 )
		queue_redraw()

	func _draw() -> void:
		var w := size.x
		var rect := Rect2( Vector2.ZERO, size )
		draw_rect( rect, COL_CARD_SEL if selected else COL_CARD )
		if selected:
			# 外圈柔光 + 金色粗边
			draw_rect( rect.grow( 2.0 ), Color( 1.0, 0.85, 0.35, 0.3 ), false, 2.0 )
			draw_rect( rect, COL_BORDER_SEL, false, 2.0 )
		else:
			draw_rect( rect, COL_BORDER, false, 1.0 )
		var def := Upgrades.get_def( upgrade_id )
		Upgrades.draw_icon( self, upgrade_id, Vector2( w * 0.5, 36.0 ), 32.0 )
		draw_string( FONT, Vector2( 0, 72 ), String( def.get( "name", upgrade_id ) ), HORIZONTAL_ALIGNMENT_CENTER, w, 12, Color( 1.0, 0.95, 0.7 ) )
		var lv_text := "NEW" if from_level == 0 else "LV %d > %d" % [ from_level, from_level + 1 ]
		var lv_col := Color( 0.4, 0.9, 1.0 ) if from_level == 0 else Color( 0.55, 1.0, 0.65 )
		draw_string( FONT, Vector2( 0, 90 ), lv_text, HORIZONTAL_ALIGNMENT_CENTER, w, 12, lv_col )
		# 下一级效果，最多 3 行，左右各留 8 像素
		draw_multiline_string( FONT, Vector2( 8, 110 ), Upgrades.level_desc( upgrade_id, from_level + 1 ),
			HORIZONTAL_ALIGNMENT_CENTER, w - 16.0, 8, 3, Color( 0.75, 0.9, 1.0 ) )

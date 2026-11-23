class_name UpgradeMenu extends CanvasLayer
## 强化三选一弹窗：打开时暂停游戏、画面压暗，横排 3 张卡片（最少 1 张），必须选一个才会关闭。
## 键盘：左右 / A D 切换，回车 / 空格 / J 确认；鼠标：悬停高亮、左键点击选中。手势不参与。
## 默认焦点在中间那张；打开后前 CONFIRM_LOCK_MS 毫秒不接受确认（防止连按误选）。
## 弹窗期间 Esc 被本弹窗吞掉，暂停菜单弹不出来（两层暂停会打架）；选完 / abort() 后恢复暂停状态。
## 选定后发 chosen( id )（此时已取消暂停），由关卡给对应强化升级；弹窗随后自己释放。
## process_mode 为 ALWAYS，用真实时间计时，不受暂停和 Engine.time_scale 影响。

const APPEAR_SOUND : AudioStream = preload( "res://levels/survival/upgrade_appear.wav" )
const CHOOSE_SOUND : AudioStream = preload( "res://levels/survival/upgrade_choose.wav" )

const CARD_SIZE := Vector2( 132, 158 )
const CARD_GAP : float = 10.0
const CARD_TOP : float = 62.0
const SELECT_LIFT : float = 4.0
const DESC_TOP : float = 104.0
const DESC_HEIGHT : float = 46.0
## 打开后多久之内不接受确认（毫秒）
const CONFIRM_LOCK_MS : int = 400

const COL_DIM := Color( 0.129, 0.102, 0.125, 0.64 )

signal chosen( id : String )
## 供关卡接管 Esc，未连接时仍只吞掉按键。
signal dismiss_requested

## 关卡附加确认框打开时暂停卡片交互，保留当前选项和游戏暂停。
var selection_enabled := true

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
	# 高于摄像头和手势提示（10），避免完整调试面板遮住卡片。
	layer = 11
	process_mode = Node.PROCESS_MODE_ALWAYS
	_opened_ms = Time.get_ticks_msec()

	var dim := ColorRect.new()
	dim.theme = DungeonTheme.THEME
	dim.color = COL_DIM
	dim.set_anchors_preset( Control.PRESET_FULL_RECT )
	# 吞掉鼠标，免得点穿到下面（暂停期间下面本来也不响应）
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child( dim )

	var root := Control.new()
	root.theme = DungeonTheme.THEME
	root.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	root.set_anchors_preset( Control.PRESET_FULL_RECT )
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child( root )

	var title := _make_label( "CHOOSE UPGRADE", 24, DungeonTheme.TEXT )
	title.set_anchors_preset( Control.PRESET_TOP_WIDE )
	title.offset_top = 26.0
	title.offset_bottom = 54.0
	root.add_child( title )

	var hint := _make_label( "ARROWS / A D: SELECT   ENTER / CLICK: CONFIRM", 10, DungeonTheme.TEXT )
	hint.set_anchors_preset( Control.PRESET_TOP_WIDE )
	hint.offset_top = 232.0
	hint.offset_bottom = 248.0
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
	_audio.bus = &"SFX"
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
	if _done or not selection_enabled:
		return
	# 弹窗期间 Esc 不能弹出暂停菜单：在这里吞掉（PauseMenu 用 _unhandled_input）
	if event.is_action_pressed( "pause" ):
		get_viewport().set_input_as_handled()
		dismiss_requested.emit()
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
	if not selection_enabled or _cards.is_empty():
		return
	_sel = clampi( i, 0, _cards.size() - 1 )
	for k in _cards.size():
		_cards[k].set_selected( k == _sel )
		_cards[k].position.y = CARD_TOP - ( SELECT_LIFT if k == _sel else 0.0 )


func _confirm() -> void:
	if _done or not selection_enabled or Time.get_ticks_msec() - _opened_ms < CONFIRM_LOCK_MS:
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
	label.theme = DungeonTheme.THEME
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_override( "font", DungeonTheme.BODY_FONT )
	label.add_theme_font_size_override( "font_size", font_size )
	label.add_theme_color_override( "font_color", color )
	return label


## 一张强化卡片：面板与纹理用 _draw，正文由 Label 自动换行。
class Card extends Control:
	var upgrade_id : String = ""
	var from_level : int = 0
	var selected : bool = false

	func setup( id : String, lv : int ) -> void:
		upgrade_id = id
		from_level = lv
		theme = DungeonTheme.THEME
		mouse_filter = Control.MOUSE_FILTER_STOP
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	func _ready() -> void:
		_add_text( Upgrades.display_name( upgrade_id ), 66.0, 20.0, 14, DungeonTheme.TEXT )
		var lv_text := "NEW" if from_level == 0 else "LV %d > %d" % [ from_level, from_level + 1 ]
		_add_text( lv_text, 88.0, 16.0, 12, DungeonTheme.PSI )
		_add_text( Upgrades.level_desc( upgrade_id, from_level + 1 ), DESC_TOP, DESC_HEIGHT, 12, DungeonTheme.TEXT )

	func _add_text( text : String, top : float, height : float, font_size : int, color : Color ) -> void:
		var label := Label.new()
		label.theme = DungeonTheme.THEME
		# 先启用换行并锁住卡片内宽，再写 text；否则未换行的整句最小宽度会撑大 Label。
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var text_size := Vector2( CARD_SIZE.x - 20.0, height )
		label.custom_minimum_size = text_size
		label.size = text_size
		label.position = Vector2( 10, top )
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_font_override( "font", DungeonTheme.BODY_FONT )
		label.add_theme_font_size_override( "font_size", font_size )
		label.add_theme_constant_override( "line_spacing", 0 )
		label.add_theme_color_override( "font_color", color )
		label.text = text
		add_child( label )

	func set_selected( on : bool ) -> void:
		selected = on
		queue_redraw()

	func _draw() -> void:
		DungeonTheme.draw_panel( self, Rect2( Vector2.ZERO, size ), selected )
		Upgrades.draw_icon( self, upgrade_id, Vector2( size.x * 0.5, 36.0 ), 48.0 )

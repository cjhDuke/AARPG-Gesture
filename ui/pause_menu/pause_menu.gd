extends CanvasLayer
## 暂停菜单（autoload: PauseMenu）：RESUME / RESTART / TITLE / QUIT，左侧可显示背包面板。
## 背包内容和重开由当前关卡提供：关卡在 _ready 里设 bag_provider / restart_handler，释放时调 clear_level_hooks()。
## 没有提供时（练习场、标题）不显示背包面板和 RESTART，按钮居中。

const TITLE_SCENE : String = "res://ui/title/title_scene.tscn"
const ITEMS_TEXTURE : Texture2D = preload( "res://levels/survival/pickups/items.png" )
## 有背包面板时，面板和按钮列各自的左边缘（相对屏幕中心的 x 偏移）及面板尺寸
const BAG_PANEL_X : float = -150.0
const BAG_PANEL_SIZE := Vector2( 156, 172 )
const BUTTONS_X_WITH_BAG : float = 30.0
const BUTTONS_X_CENTERED : float = -60.0
const BUTTONS_WIDTH : float = 120.0
const PANEL_TOP : float = 78.0

signal shown
signal hidden

@onready var root : Control = $Control
@onready var button_box : VBoxContainer = $Control/VBoxContainer
@onready var button_resume: Button = %Button_Resume
@onready var button_restart: Button = %Button_Restart
@onready var button_title: Button = %Button_Title
@onready var button_quit: Button = %Button_Quit

var is_paused : bool = false
## 返回背包内容：{ "upgrades": Array[String]（可选，已拥有强化的显示名）, "status": String, "rows": Array[{ "region": Rect2, "name": String, "value": String, "note": String }] }
var bag_provider : Callable
## 重开当前关卡（菜单已收起、游戏已取消暂停后调用）
var restart_handler : Callable

var _bag_panel : Control
var _bag_rows : VBoxContainer
var _bag_status : Label
var _bag_upgrades : Label


func _ready() -> void:
	_build_bag_panel()
	hide_pause_menu()
	button_resume.pressed.connect( hide_pause_menu )
	button_restart.pressed.connect( _on_restart_pressed )
	button_title.pressed.connect( _on_title_pressed )
	button_quit.pressed.connect( _on_quit_pressed )


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if LevelManager.is_loading_level:
			return
		if is_paused == false:
			show_pause_menu()
		else:
			hide_pause_menu()
		get_viewport().set_input_as_handled()


## 关卡释放时调用：不再显示背包和 RESTART
func clear_level_hooks() -> void:
	bag_provider = Callable()
	restart_handler = Callable()


func show_pause_menu() -> void:
	get_tree().paused = true
	_refresh()
	visible = true
	is_paused = true
	button_resume.grab_focus()
	shown.emit()


func hide_pause_menu() -> void:
	get_tree().paused = false
	visible = false
	is_paused = false
	hidden.emit()


## 按当前关卡提供的内容刷新背包面板、按钮显隐和焦点顺序
func _refresh() -> void:
	var has_bag := bag_provider.is_valid()
	_bag_panel.visible = has_bag
	if has_bag:
		_fill_bag( bag_provider.call() )
	button_restart.visible = restart_handler.is_valid()
	var x := BUTTONS_X_WITH_BAG if has_bag else BUTTONS_X_CENTERED
	button_box.offset_left = x
	button_box.offset_right = x + BUTTONS_WIDTH
	# 可见按钮上下循环
	var buttons : Array[Button] = []
	for b : Button in [ button_resume, button_restart, button_title, button_quit ]:
		if b.visible:
			buttons.append( b )
	for i in buttons.size():
		var prev := buttons[ ( i + buttons.size() - 1 ) % buttons.size() ].get_path()
		var next := buttons[ ( i + 1 ) % buttons.size() ].get_path()
		buttons[i].focus_neighbor_top = prev
		buttons[i].focus_neighbor_bottom = next
		buttons[i].focus_neighbor_left = buttons[i].get_path()
		buttons[i].focus_neighbor_right = buttons[i].get_path()


func _build_bag_panel() -> void:
	_bag_panel = Control.new()
	_bag_panel.name = "BagPanel"
	_bag_panel.anchor_left = 0.5
	_bag_panel.anchor_right = 0.5
	_bag_panel.offset_left = BAG_PANEL_X
	_bag_panel.offset_right = BAG_PANEL_X + BAG_PANEL_SIZE.x
	_bag_panel.offset_top = PANEL_TOP
	_bag_panel.offset_bottom = PANEL_TOP + BAG_PANEL_SIZE.y
	root.add_child( _bag_panel )

	var bg := ColorRect.new()
	bg.color = Color( 0.08, 0.09, 0.1, 0.75 )
	bg.set_anchors_preset( Control.PRESET_FULL_RECT )
	_bag_panel.add_child( bg )

	var box := VBoxContainer.new()
	box.set_anchors_preset( Control.PRESET_FULL_RECT )
	box.offset_left = 8.0
	box.offset_top = 4.0
	box.offset_right = -8.0
	box.offset_bottom = -4.0
	box.add_theme_constant_override( "separation", 2 )
	_bag_panel.add_child( box )

	var title := _make_label( "BAG", 16, Color( 1.0, 0.9, 0.55 ) )
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child( title )
	_bag_rows = VBoxContainer.new()
	_bag_rows.add_theme_constant_override( "separation", 3 )
	_bag_rows.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child( _bag_rows )
	# 已拥有的强化：一段自动换行的小字，没有强化时隐藏
	_bag_upgrades = _make_label( "", 8, Color( 0.6, 1.0, 0.7 ) )
	_bag_upgrades.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bag_upgrades.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child( _bag_upgrades )
	_bag_status = _make_label( "", 8, Color( 0.75, 0.8, 0.85 ) )
	_bag_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child( _bag_status )


func _fill_bag( info : Dictionary ) -> void:
	for c in _bag_rows.get_children():
		c.queue_free()
	for row : Dictionary in info.get( "rows", [] ):
		var line := HBoxContainer.new()
		line.add_theme_constant_override( "separation", 6 )
		var tex := AtlasTexture.new()
		tex.atlas = ITEMS_TEXTURE
		tex.region = row["region"]
		var icon := TextureRect.new()
		icon.texture = tex
		icon.custom_minimum_size = Vector2( 26, 26 )
		icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		line.add_child( icon )
		var text := VBoxContainer.new()
		text.add_theme_constant_override( "separation", -2 )
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.alignment = BoxContainer.ALIGNMENT_CENTER
		var head := HBoxContainer.new()
		var name_label := _make_label( str( row["name"] ), 12, Color.WHITE )
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child( name_label )
		head.add_child( _make_label( str( row["value"] ), 12, Color( 0.6, 1.0, 0.7 ) ) )
		text.add_child( head )
		text.add_child( _make_label( str( row["note"] ), 8, Color( 0.65, 0.68, 0.72 ) ) )
		line.add_child( text )
		_bag_rows.add_child( line )
	var ups : Array = info.get( "upgrades", [] )
	_bag_upgrades.visible = not ups.is_empty()
	_bag_upgrades.text = "UPGRADES: " + ", ".join( PackedStringArray( ups ) ) if not ups.is_empty() else ""
	_bag_status.text = str( info.get( "status", "" ) )


func _make_label( text : String, font_size : int, color : Color ) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override( "font_size", font_size )
	label.add_theme_color_override( "font_color", color )
	return label


func _on_restart_pressed() -> void:
	var handler := restart_handler
	hide_pause_menu()
	if handler.is_valid():
		handler.call()


func _on_title_pressed() -> void:
	hide_pause_menu()
	LevelManager.load_new_level( TITLE_SCENE )


func _on_quit_pressed() -> void:
	get_tree().quit()

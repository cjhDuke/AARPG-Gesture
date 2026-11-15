class_name SurvivalHud extends CanvasLayer
## 生存模式的界面：底部状态行、WAVE 提示、胜负结算面板（念力条在主角头顶，见 psi_bar.gd）

signal retry_pressed
signal title_pressed

@onready var status_label : Label = %StatusLabel
@onready var banner_label : Label = %BannerLabel
@onready var result_panel : Control = %ResultPanel
@onready var result_title : Label = %ResultTitle
@onready var result_stats : Label = %ResultStats
@onready var trophy : Sprite2D = %Trophy
@onready var retry_button : Button = %RetryButton
@onready var title_button : Button = %TitleButton
@onready var congrats_music : AudioStreamPlayer = %CongratsMusic

## 背包格子（右上角心形下面）：左上角位置、格子间距、苹果图标在图集里的区域
const BAG_POS := Vector2( 376, 32 )
const BAG_STEP : float = 18.0
const BAG_ICON_REGION := Rect2( 200, 8, 16, 16 )

## 已拥有强化的图标行：状态行上方，最多九枚原生 24px 图标。
const UPGRADE_POS := Vector2( 8, 218 )
const UPGRADE_ICON : float = 24.0
const UPGRADE_STEP : float = 27.0

var _upgrade_frame : Panel
var _banner_tween : Tween
var _upgrade_icons : Array[Control] = []
var _bag_icons : Array[TextureRect] = []
## Boss 血条（只在 Boss 关存在）：左上角位置在手势提示框正下方，居中偏右给左边的名字留位置
var _boss_bar : BossBar
const BOSS_BAR_POS := Vector2( 168, 27 )


func _ready() -> void:
	$Root.theme = DungeonTheme.THEME
	_build_settings_button()
	banner_label.add_theme_font_override( "font", DungeonTheme.TITLE_FONT )
	result_title.add_theme_font_override( "font", DungeonTheme.TITLE_FONT )
	# Slim framing leaves native pixels and level marks unobstructed.
	_upgrade_frame = _make_frame( Rect2( 4, 216, 248, 33 ) )
	_upgrade_frame.visible = false
	$Root.add_child( _upgrade_frame )
	$Root.move_child( _upgrade_frame, 0 )
	var status_frame := _make_frame( Rect2( 0, 250, 480, 20 ) )
	status_label.add_sibling( status_frame )
	$Root.move_child( status_frame, status_label.get_index() )
	var result_frame := Panel.new()
	result_frame.position = Vector2( 90, 24 )
	result_frame.size = Vector2( 300, 216 )
	result_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	result_frame.add_theme_stylebox_override( "panel", DungeonTheme.panel() )
	result_panel.add_child( result_frame )
	result_panel.move_child( result_frame, 1 )
	banner_label.modulate.a = 0.0
	result_panel.visible = false
	retry_button.pressed.connect( retry_pressed.emit )
	title_button.pressed.connect( title_pressed.emit )


func _build_settings_button() -> void:
	var button := Button.new()
	button.name = "SettingsButton"
	button.theme = preload("res://ui/settings/settings_theme.gd").make_theme()
	button.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var icon := AtlasTexture.new()
	icon.atlas = preload("res://ui/theme/ui_icons.png")
	icon.region = Rect2(64, 128, 32, 32)
	button.icon = icon
	button.expand_icon = true
	button.tooltip_text = "Settings (Esc)"
	button.position = Vector2(450, 6)
	button.size = Vector2(24, 28)
	button.pressed.connect(PauseMenu.show_pause_menu)
	$Root.add_child(button)


func _make_frame( rect : Rect2 ) -> Panel:
	var frame := Panel.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.position = rect.position
	frame.size = rect.size
	var style := StyleBoxFlat.new()
	style.bg_color = DungeonTheme.BACKGROUND
	style.border_color = DungeonTheme.GOLD
	style.set_border_width_all( 1 )
	frame.add_theme_stylebox_override( "panel", style )
	return frame


## total_waves 为 0 表示 Boss 关（没有波次），显示 BOSS
func set_status( stage : int, wave : int, total_waves : int, kills : int, best : int ) -> void:
	if total_waves <= 0:
		status_label.text = "STAGE %d  BOSS  KILLS %d  BEST %d" % [ stage, kills, best ]
	else:
		status_label.text = "STAGE %d  WAVE %d/%d  KILLS %d  BEST %d" % [ stage, wave, total_waves, kills, best ]


## 显示 Boss 血条（名字固定 WIZARD）
func show_boss_bar() -> void:
	if _boss_bar == null:
		_boss_bar = BossBar.new()
		_boss_bar.position = BOSS_BAR_POS
		$Root.add_child( _boss_bar )
		$Root.move_child( _boss_bar, result_panel.get_index() )
	_boss_bar.visible = true


func set_boss_hp( round_no : int, hp : int, hp_max : int ) -> void:
	if _boss_bar != null:
		_boss_bar.set_hp( round_no, hp, hp_max )


func hide_boss_bar() -> void:
	if _boss_bar != null:
		_boss_bar.queue_free()
		_boss_bar = null


func is_boss_bar_visible() -> bool:
	return _boss_bar != null and _boss_bar.visible


## 背包显示：capacity 个苹果格子，前 count 个点亮，其余是暗色剪影
func set_bag( count : int, capacity : int ) -> void:
	while _bag_icons.size() < capacity:
		var tex := AtlasTexture.new()
		tex.atlas = Pickup.ITEMS_TEXTURE
		tex.region = BAG_ICON_REGION
		var icon := TextureRect.new()
		icon.texture = tex
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.position = BAG_POS + Vector2( BAG_STEP * _bag_icons.size(), 0 )
		$Root.add_child( icon )
		$Root.move_child( icon, 0 )
		_bag_icons.append( icon )
	for i in _bag_icons.size():
		_bag_icons[i].visible = i < capacity
		_bag_icons[i].modulate = Color.WHITE if i < count else Color( 0.35, 0.28, 0.24, 0.65 )


## 已拥有的强化用小图标排成一行，图标底部用小点标出等级（levels 是 { id: 等级 }）
func set_upgrades( levels : Dictionary ) -> void:
	for c in _upgrade_icons:
		c.queue_free()
	_upgrade_icons.clear()
	_upgrade_frame.visible = not levels.is_empty()
	_upgrade_frame.size.x = 8.0 + maxf( 0.0, levels.size() - 1 ) * UPGRADE_STEP + UPGRADE_ICON
	var i := 0
	for id in levels:
		var icon := Upgrades.Icon.new( id, UPGRADE_ICON, int( levels[id] ) )
		icon.position = UPGRADE_POS + Vector2( UPGRADE_STEP * i, 0 )
		$Root.add_child( icon )
		$Root.move_child( icon, result_panel.get_index() )
		_upgrade_icons.append( icon )
		i += 1


func show_banner( text : String ) -> void:
	banner_label.text = text
	if _banner_tween:
		_banner_tween.kill()
	_banner_tween = create_tween()
	_banner_tween.tween_property( banner_label, "modulate:a", 1.0, 0.15 )
	_banner_tween.tween_interval( 0.9 )
	_banner_tween.tween_property( banner_label, "modulate:a", 0.0, 0.4 )


## 显示结算面板并暂停游戏；RETRY 获得焦点，回车确认（手势不参与菜单操作）
func show_result( victory : bool, kills : int, best : int ) -> void:
	result_title.text = "VICTORY" if victory else "GAME OVER"
	result_title.add_theme_color_override( "font_color", DungeonTheme.GOLD_BRIGHT if victory else Color( "#d98775" ) )
	result_stats.text = "KILLS %d   BEST %d" % [ kills, best ]
	trophy.visible = victory
	if victory:
		AudioManager.stop_music()
		congrats_music.play()
	result_panel.visible = true
	get_tree().paused = true
	retry_button.grab_focus.call_deferred()


func hide_result() -> void:
	congrats_music.stop()
	result_panel.visible = false

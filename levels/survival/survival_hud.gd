class_name SurvivalHud extends CanvasLayer
## 生存模式的界面：底部状态行、WAVE 提示、胜负结算面板（念力条在主角头顶，见 psi_bar.gd）

signal retry_pressed
signal title_pressed
signal item_used( kind : int )
var bag_provider : Callable

@onready var status_label : Label = %StatusLabel
@onready var gameplay : Control = $Root/Gameplay
@onready var banner_label : Label = %BannerLabel
@onready var result_panel : Control = %ResultPanel
@onready var result_title : Label = %ResultTitle
@onready var result_stats : Label = %ResultStats
@onready var trophy : Sprite2D = %Trophy
@onready var retry_button : Button = %RetryButton
@onready var title_button : Button = %TitleButton
@onready var leaderboard_button : Button = %LeaderboardButton
@onready var ranking_label : Label = %RankingLabel
@onready var result_extra : Label = %ResultExtra
@onready var congrats_music : AudioStreamPlayer = %CongratsMusic

## 已拥有强化的图标行：状态行上方，最多九枚原生 24px 图标。
const UPGRADE_POS := Vector2( 8, 218 )
const UPGRADE_ICON : float = 24.0
const UPGRADE_STEP : float = 27.0

var _upgrade_frame : Panel
var _banner_tween : Tween
var _save_notice_label : Label
var _save_notice_tween : Tween
var _upgrade_icons : Array[Control] = []
var _item_buttons : Dictionary = {}
var _leaderboard: LeaderboardPanel
var _ranking_badge: Label
var _result_snapshot: Dictionary = {}
## Boss 血条（只在 Boss 关存在）：左上角位置在手势提示框正下方，居中偏右给左边的名字留位置
var _boss_bar : BossBar
const BOSS_BAR_POS := Vector2( 168, 27 )


func _ready() -> void:
	$Root.theme = DungeonTheme.THEME
	result_panel.theme = DungeonTheme.THEME
	_build_save_notice()
	_build_settings_button()
	banner_label.add_theme_font_override( "font", DungeonTheme.TITLE_FONT )
	result_title.add_theme_font_override( "font", DungeonTheme.TITLE_FONT )
	# Slim framing leaves native pixels and level marks unobstructed.
	_upgrade_frame = _make_frame( Rect2( 4, 216, 248, 33 ) )
	_upgrade_frame.visible = false
	gameplay.add_child( _upgrade_frame )
	gameplay.move_child( _upgrade_frame, 0 )
	var status_frame := _make_frame( Rect2( 0, 250, 480, 20 ) )
	status_label.add_sibling( status_frame )
	gameplay.move_child( status_frame, status_label.get_index() )
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
	leaderboard_button.pressed.connect(_open_leaderboard)
	leaderboard_button.focus_neighbor_left = retry_button.get_path()
	leaderboard_button.focus_neighbor_right = title_button.get_path()
	retry_button.focus_neighbor_right = leaderboard_button.get_path()
	title_button.focus_neighbor_left = leaderboard_button.get_path()
	_leaderboard = LeaderboardPanel.new()
	_leaderboard.name = "LeaderboardPanel"
	add_child(_leaderboard)
	_leaderboard.closed.connect(_on_leaderboard_closed)
	_build_ranking_badge()
	RunStats.stats_changed.connect(_refresh_ranking_badge)
	LeaderboardManager.run_status_changed.connect(_refresh_ranking_badge)


func _build_save_notice() -> void:
	_save_notice_label = Label.new()
	_save_notice_label.name = "SaveNotice"
	_save_notice_label.position = Vector2( 24, 181 )
	_save_notice_label.size = Vector2( 432, 32 )
	_save_notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_save_notice_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_save_notice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_save_notice_label.add_theme_font_size_override( "font_size", 9 )
	_save_notice_label.add_theme_color_override( "font_color", DungeonTheme.GOLD_BRIGHT )
	_save_notice_label.add_theme_color_override( "font_outline_color", Color( 0, 0, 0, 1 ) )
	_save_notice_label.add_theme_constant_override( "outline_size", 3 )
	_save_notice_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_save_notice_label.modulate.a = 0.0
	gameplay.add_child( _save_notice_label )


## 非模态存档提示；错误消息保留更长时间并可自动换行。
func show_save_notice( message : String, is_error : bool = false ) -> void:
	if _save_notice_tween and _save_notice_tween.is_running():
		_save_notice_tween.kill()
	_save_notice_label.text = message
	_save_notice_label.add_theme_color_override( "font_color", Color( "#ff8078" ) if is_error else DungeonTheme.GOLD_BRIGHT )
	_save_notice_label.position.y = 181 if is_error else 190
	_save_notice_label.size.y = 32 if is_error else 20
	_save_notice_label.modulate.a = 1.0
	_save_notice_tween = create_tween()
	_save_notice_tween.set_pause_mode( Tween.TWEEN_PAUSE_PROCESS )
	_save_notice_tween.tween_interval( 5.0 if is_error else 1.5 )
	_save_notice_tween.tween_property( _save_notice_label, "modulate:a", 0.0, 0.5 )


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
	gameplay.add_child(button)


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
		status_label.text = "STAGE %d  BOSS  KILLS %d  BEST KILLS %d" % [ stage, kills, best ]
	else:
		status_label.text = "STAGE %d  WAVE %d/%d  KILLS %d  BEST KILLS %d" % [ stage, wave, total_waves, kills, best ]


## 显示 Boss 血条（名字固定 WIZARD）
func show_boss_bar() -> void:
	if _boss_bar == null:
		_boss_bar = BossBar.new()
		_boss_bar.position = BOSS_BAR_POS
		gameplay.add_child( _boss_bar )
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


## 心形下方的两种库存，点击或按 Q / E 使用
func set_bag( count : int, capacity : int ) -> void:
	if _item_buttons.is_empty():
		for kind : int in [ Pickup.Kind.APPLE, Pickup.Kind.POTION ]:
			var button := Button.new()
			# 先设置紧凑样式再放图标，避免默认按钮边距提前撑高且不自动缩回。
			button.add_theme_font_size_override( "font_size", 8 )
			for state in [ "normal", "hover", "pressed", "hover_pressed", "disabled", "focus" ]:
				button.add_theme_stylebox_override( state, StyleBoxEmpty.new() )
			var tex := AtlasTexture.new()
			tex.atlas = Pickup.ITEMS_TEXTURE
			tex.region = Pickup.REGIONS[kind].grow( -8 )
			button.icon = tex
			button.position = Vector2( 356 + ( 46 if kind == Pickup.Kind.POTION else 0 ), 30 )
			button.focus_mode = Control.FOCUS_NONE
			button.tooltip_text = "Apple (Q): +1 HP" if kind == Pickup.Kind.APPLE else "Potion (E): +2 HP, PSI MAX"
			button.pressed.connect( item_used.emit.bind( kind ) )
			gameplay.add_child( button )
			button.size = Vector2( 42, 16 )
			_item_buttons[kind] = button
	var potions : int = int( bag_provider.call() ) if bag_provider.is_valid() else 0
	_item_buttons[Pickup.Kind.APPLE].text = "Q %d/%d" % [ count, capacity ]
	_item_buttons[Pickup.Kind.POTION].text = "E %d/%d" % [ potions, capacity ]
	_item_buttons[Pickup.Kind.APPLE].disabled = count <= 0
	_item_buttons[Pickup.Kind.POTION].disabled = potions <= 0


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
		gameplay.add_child( icon )
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
	# 战斗控件统一隐藏，避免运行时新增节点盖住结算或接收点击。
	gameplay.hide()
	result_title.text = "VICTORY" if victory else "GAME OVER"
	result_title.add_theme_color_override( "font_color", DungeonTheme.GOLD_BRIGHT if victory else Color( "#d98775" ) )
	var result := RunStats.get_last_result()
	_result_snapshot = result
	var progress := int(result.get("progress", 0))
	var elapsed_ms := int(result.get("elapsed_ms", 0))
	var continued := bool(result.get("continued", false))
	var new_best := bool(result.get("new_best_kills", false))
	var best_for_run := int(result.get("best_kills", best))
	result_stats.text = "PROGRESS %d/9   %s %s" % [progress, "SESSION TIME" if continued else "TIME", RunStats.format_time(elapsed_ms)]
	result_extra.text = "KILLS %d   BEST KILLS %d\n%s" % [kills, best_for_run, "NEW BEST KILLS!" if new_best else ""]
	_update_result_ranking_label(result)
	trophy.visible = victory
	_layout_result(victory)
	if victory:
		AudioManager.stop_music()
		congrats_music.play()
	result_panel.visible = true
	leaderboard_button.visible = not LevelManager.practice_mode
	ranking_label.visible = not LevelManager.practice_mode
	for button in [retry_button, title_button]:
		button.disabled = false
	retry_button.focus_neighbor_right = leaderboard_button.get_path() if leaderboard_button.visible else title_button.get_path()
	title_button.focus_neighbor_left = leaderboard_button.get_path() if leaderboard_button.visible else retry_button.get_path()
	get_tree().paused = true
	retry_button.grab_focus.call_deferred()


## 失败页没有奖杯；将整组内容上移，保持上下留白相等。胜利页保留奖杯位置。
func _layout_result(victory: bool) -> void:
	var shift := 0.0 if victory else -34.0
	result_title.position.y = 112.0 + shift
	result_stats.position.y = 145.0 + shift
	result_extra.position.y = 161.0 + shift
	ranking_label.position.y = 184.0 + shift
	result_panel.get_node("Buttons").position.y = 194.0 + shift


func hide_result() -> void:
	if _leaderboard.is_open:
		_leaderboard.close()
	congrats_music.stop()
	result_panel.visible = false
	gameplay.show()
	retry_button.disabled = false
	title_button.disabled = false

func _open_leaderboard() -> void:
	if LevelManager.practice_mode or _leaderboard == null or not result_panel.visible:
		return
	_leaderboard.open()
	for button in [retry_button, title_button, leaderboard_button]:
		button.disabled = true

func _on_leaderboard_closed() -> void:
	if result_panel.visible and leaderboard_button.visible:
		for button in [retry_button, title_button, leaderboard_button]:
			button.disabled = false
		leaderboard_button.grab_focus.call_deferred()

func _build_ranking_badge() -> void:
	_ranking_badge = Label.new()
	_ranking_badge.name = "RankingStatus"
	_ranking_badge.text = "NOT RANKED"
	_ranking_badge.position = Vector2(8, 202)
	_ranking_badge.size = Vector2(240, 12)
	_ranking_badge.add_theme_font_size_override("font_size", 8)
	_ranking_badge.add_theme_color_override("font_color", DungeonTheme.GOLD_BRIGHT)
	_ranking_badge.tooltip_text = "ONLINE RANKING NOT AVAILABLE"
	_ranking_badge.mouse_filter = Control.MOUSE_FILTER_STOP
	gameplay.add_child(_ranking_badge)
	_refresh_ranking_badge()


func _refresh_ranking_badge(_changed: Variant = null) -> void:
	if not is_instance_valid(_ranking_badge):
		return
	var snapshot := RunStats.get_run_snapshot()
	if snapshot.is_empty() and result_panel.visible:
		snapshot = _result_snapshot
	if result_panel.visible and not _result_snapshot.is_empty():
		_update_result_ranking_label(_result_snapshot)
	if bool(snapshot.get("practice", false)):
		_ranking_badge.text = "PRACTICE MODE - NOT RANKED"
		_ranking_badge.tooltip_text = "PRACTICE MODE"
	elif bool(snapshot.get("continued", false)):
		_ranking_badge.text = "CONTINUED RUN - NOT RANKED"
		_ranking_badge.tooltip_text = "CONTINUED RUN"
	else:
		var run_status := LeaderboardManager.get_run_status()
		var status := str(run_status.get("status", "NOT RANKED"))
		_ranking_badge.text = _ranking_status_text(status)
		var reason := str(run_status.get("reason", ""))
		_ranking_badge.tooltip_text = reason if not reason.is_empty() else status


func _update_result_ranking_label(result: Dictionary) -> void:
	if bool(result.get("practice", false)):
		ranking_label.text = "PRACTICE MODE - NOT RANKED"
		return
	if bool(result.get("continued", false)):
		ranking_label.text = "CONTINUED RUN - NOT RANKED"
		return
	var run_status := LeaderboardManager.get_run_status()
	var status := str(run_status.get("status", "NOT RANKED"))
	var status_text := _ranking_status_text(status)
	var rank := int(run_status.get("rank", 0))
	if rank > 0 and status in ["RANKED", "UPLOADED"]:
		status_text += "  #%d" % rank
	ranking_label.text = status_text


func _ranking_status_text(status: String) -> String:
	match status:
		"PREPARING": return "PREPARING"
		"RANKED": return "RANKED"
		"UPLOADING": return "UPLOADING"
		"UPLOADED": return "UPLOADED"
		"PENDING": return "PENDING"
		_: return "NOT RANKED"

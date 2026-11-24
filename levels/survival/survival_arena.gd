class_name SurvivalArena extends Level
## 手引生存关卡：按 StageData 的关卡表依次打各关的各波，同一场景内切关；全部清完胜利，血量归零失败

const TITLE_SCENE : String = "res://ui/title/title_scene.tscn"
## 开局到第 1 波、以及每波清完到下一波之间的停顿（秒）
const START_DELAY : float = 1.0
const WAVE_DELAY : float = 2.0
## 清波宝箱的位置：房间中心偏下，避开屏幕正中的 WAVE CLEAR 横幅
const CHEST_POS := HandController.CENTER + Vector2( 0, 36 )
## 切关后横幅显示的时间（秒），之后才开始第一波
const STAGE_BANNER_TIME : float = 1.5

## 每局开始（含重开）时发出，练习场面板用它把强化开关重新施加
signal run_started

@onready var spawner : WaveSpawner = $WaveSpawner
@onready var controller : HandController = $HandController
@onready var hud : SurvivalHud = $SurvivalHud
@onready var wave_timer : Timer = $WaveTimer

## 当前是第几关（StageData 里启用的关卡中的序号，从 0 开始）
var stage : int = 0
## 当前关的第几波（从 1 开始，0 表示还没开始）
var wave : int = 0
var kills : int = 0
var _ended : bool = false
var _player : Player
var _death_fx : DeathFx
var loot : LootDropper
var _chest : RewardChest
## Boss 关的巫师（只在 Boss 关存在）
var _boss : WizardBoss
## 强化三选一弹窗（选择期间存在，游戏处于暂停）
var _upgrade_menu : UpgradeMenu
## 这一波主角是否受过伤（决定宝箱里有没有药水）
var _wave_hurt : bool = false
## 当前关的数据（StageData.get_stage）和图块地图节点
var _stage_data : Dictionary
var _map : Node
var _map_path : String = ""
## 每次重开 +1；关卡切换的协程醒来后用它判断这一局是否已被重开作废
var _run_id : int = 0
## _advance_stage 协程正在跑（淡出 / 换关 / 淡入）；重开和练习场跳关会递增 _run_id 作废它，并把本标记清掉
var _stage_changing : bool = false
var _checkpoint: Dictionary = {}
var _practice_layout: Node2D
var practice_encounter_name := ""
var campaign_version := StageData.LEGACY_VERSION
var campaign_preview := LevelManager.practice_mode and OS.get_cmdline_user_args().has( "--campaign-preview" )
## 只在玩家可操作的正式流程累计时间；开场与强制切关横幅不计。
var _run_clock_started := false
var _stage_clock_held := false


func _ready() -> void:
	super._ready()
	_player = PlayerManager.player
	_player.can_move = true
	_player.died.connect( _on_player_died )
	_player.player_damaged.connect( _on_player_damaged )
	# 镜头固定在房间中心，不跟着被击退的主角晃
	var camera : Camera2D = _player.get_node( "Camera2D" )
	camera.top_level = true
	camera.global_position = HandController.CENTER

	loot = LootDropper.new()
	loot.name = "LootDropper"
	loot.controller = controller
	add_child( loot )
	loot.bag_changed.connect( hud.set_bag )
	hud.item_used.connect( use_bag_item )
	hud.bag_provider = func() -> int: return loot.bag_potions
	controller.upgrades_changed.connect( hud.set_upgrades )
	hud.set_bag( 0, LootDropper.BAG_CAPACITY )
	PauseMenu.bag_provider = _bag_info
	PauseMenu.item_user = use_bag_item
	PauseMenu.restart_handler = _start_run
	PauseMenu.shown.connect(_pause_run_clock)
	PauseMenu.hidden.connect(_sync_run_clock)
	spawner.enemy_destroyed_at.connect( loot.handle_enemy_destroyed )
	spawner.enemy_killed.connect( _on_enemy_killed )
	spawner.wave_cleared.connect( _on_wave_cleared )
	wave_timer.timeout.connect( _begin_wave )
	hud.retry_pressed.connect( _on_retry_pressed )
	hud.title_pressed.connect( _on_title_pressed )
	var checkpoint := SaveManager.take_pending_checkpoint()
	if checkpoint.is_empty():
		_start_run()
	else:
		_restore_checkpoint(checkpoint)


func _free_level() -> void:
	LeaderboardManager.abandon_run()
	RunStats.abandon_run()
	PauseMenu.clear_level_hooks()
	_clear_death_fx()
	_clear_rewards()
	_clear_boss()
	controller.release_player()
	var camera : Camera2D = _player.get_node( "Camera2D" )
	camera.top_level = false
	camera.position = Vector2.ZERO
	super._free_level()


## 开始（或重新开始）一局
func _start_run() -> void:
	PlayerHud.show()
	var legacy_check := OS.is_debug_build() and OS.get_cmdline_user_args().has("--legacy-campaign")
	campaign_version = StageData.CURRENT_VERSION if campaign_preview or (not LevelManager.practice_mode and not legacy_check) else StageData.LEGACY_VERSION
	var ruleset := StageData.ruleset(campaign_version)
	RunStats.begin_run( false, 0, _milestones_before( stage_count() - 1 ) + 3, ruleset )
	LeaderboardManager.begin_run(false, ruleset)
	_run_clock_started = false
	_stage_clock_held = false
	_checkpoint = {}
	_clear_death_fx()
	_clear_rewards()
	_clear_boss()
	spawner.set_process( true )
	wave_timer.stop()
	spawner.clear()
	for c in get_children():
		if c is Boomerang:
			c.queue_free()
	_run_id += 1
	# 只有打断了自己的切关转场时才复位遮罩；关卡刚加载的第一局不能动转场，
	# 否则会打断 LevelManager.load_new_level 的淡入
	if _stage_changing:
		SceneTransition.reset()
	_stage_changing = false
	_load_stage( 0 )
	wave = 0
	kills = 0
	_ended = false
	PlayerManager.reset_player()
	_player.global_position = HandController.CENTER
	controller.enabled = true
	controller.reset()
	_update_status()
	wave_timer.start( START_DELAY )
	run_started.emit()


func _process(_delta: float) -> void:
	_sync_run_clock()


func _pause_run_clock() -> void:
	RunStats.set_timing_active(false)


func _sync_run_clock() -> void:
	var active := _run_clock_started and not _ended and not _stage_changing and not _stage_clock_held
	active = active and not LevelManager.is_loading_level and not get_tree().paused
	if is_instance_valid(_boss) and _boss.phase == WizardBoss.Phase.ENTER:
		active = false
	RunStats.set_timing_active(active)


func _begin_wave() -> void:
	LeaderboardManager.seal_run()
	_run_clock_started = true
	_stage_clock_held = false
	if _is_boss_stage():
		_begin_boss()
		return
	wave += 1
	_wave_hurt = false
	_capture_checkpoint()
	hud.show_banner( "WAVE %d" % wave )
	var wave_data: Dictionary = _stage_data["waves"][wave - 1]
	if wave_data.has("batches"):
		var route := Callable( _map, "route_target" ) if _map.has_method( "route_target" ) else Callable()
		spawner.start_scheduled_wave( wave_data["batches"], CampaignPreviewData.ZONES, route, _stage_data.get( "archer_anchors", {} ) )
	else:
		spawner.start_wave( wave_data )
	_update_status()
	_autosave_wave.call_deferred(_run_id)
	_sync_run_clock()


## 切到第 n 关（只换数据、图块地图和音乐，不碰主角和背包）
func _load_stage( n : int ) -> void:
	if is_instance_valid( _practice_layout ):
		_practice_layout.free()
		_practice_layout = null
	practice_encounter_name = ""
	stage = n
	_stage_data = StageData.get_stage( n, campaign_version )
	var path : String = _stage_data["tilemap"]
	if path != _map_path or not is_instance_valid( _map ):
		# 释放旧地图节点，实例化新场景放在同一位置（最底层）
		if is_instance_valid( _map ):
			_map.free()
		_map = load( path ).instantiate()
		_map_path = path
		add_child( _map )
		move_child( _map, 0 )
	# 高台和弓手站位跟着当前关的图块地图走（地牢没有高台）
	spawner.blocked_rects = _map.get_ledge_rects() if _map.has_method( "get_ledge_rects" ) else ( [] as Array[Rect2] )
	spawner.sort_enemies_with_player = _map.has_method( "attach_wall_depth" ) and _map.attach_wall_depth( self, _player.z_index )
	spawner.archer_spots.assign( _stage_data.get( "archer_spots", [] ) )
	if _stage_data.has( "archer_anchors" ):
		spawner.archer_spots.assign( _stage_data["archer_anchors"].values() )
	AudioManager.play_music( load( _stage_data["music"] ) )


## 当前关是 Boss 关（没有波次）
func _is_boss_stage() -> bool:
	return _stage_data.get( "type", "waves" ) == "boss"


## Boss 关开场：巫师淡入登场（登场期间不攻击），血条显示
func _begin_boss() -> void:
	_clear_boss()
	_wave_hurt = false
	_capture_checkpoint()
	_boss = WizardBoss.spawn( self, spawner, controller )
	_boss.hp_changed.connect( hud.set_boss_hp )
	_boss.defeated.connect( _on_boss_defeated )
	_boss.segment_cleared.connect(_on_boss_segment_cleared)
	hud.show_boss_bar( _boss )
	hud.set_boss_hp( 1, _boss.seg_hp, _boss.segment_hp )
	_update_status()
	_autosave_wave.call_deferred(_run_id)
	_sync_run_clock()


func _autosave_wave(run_id: int) -> void:
	if LevelManager.practice_mode:
		return
	if LevelManager.is_loading_level:
		await LevelManager.level_loaded
	if not is_inside_tree() or get_tree().current_scene != self or run_id != _run_id or not can_save_checkpoint():
		return
	if SaveManager.save_autosave(get_checkpoint()):
		hud.show_save_notice("AUTOSAVED")
	else:
		hud.show_save_notice("AUTOSAVE FAILED\n" + SaveManager.autosave_error, true)


func can_save_checkpoint() -> bool:
	if LevelManager.practice_mode or _checkpoint.is_empty() or _ended or _stage_changing or is_instance_valid(_chest) or is_instance_valid(_upgrade_menu) or not wave_timer.is_stopped():
		return false
	return is_instance_valid(_boss) if _is_boss_stage() else spawner.is_running()


func get_checkpoint() -> Dictionary:
	return _checkpoint.duplicate(true) if can_save_checkpoint() else {}


func _capture_checkpoint() -> void:
	if LevelManager.practice_mode:
		return
	_checkpoint = {
		"stage": stage, "stage_name": _stage_data["name"],
		"kind": _stage_data.get("type", "waves"), "wave": 1 if _is_boss_stage() else wave,
		"hp": _player.hp, "psi": controller.psi, "upgrades": controller.owned_levels(),
		"kills": kills, "loot": loot.get_checkpoint_state(),
	}
	if campaign_version != StageData.LEGACY_VERSION:
		_checkpoint["campaign_version"] = campaign_version


func _restore_checkpoint(data: Dictionary) -> void:
	campaign_version = StageData.checkpoint_version(data)
	var completed := _milestones_before(int(data["stage"]))
	if data.get("kind", "waves") != "boss":
		completed += int(data["wave"]) - 1
	var ruleset := StageData.ruleset(campaign_version)
	RunStats.begin_run(true, completed, StageData.milestones_for_ruleset(ruleset), ruleset)
	LeaderboardManager.begin_run(true, ruleset)
	_run_clock_started = false
	_stage_clock_held = false
	_run_id += 1
	wave_timer.stop()
	_load_stage(int(data["stage"]))
	_ended = false
	PlayerManager.reset_player()
	controller.reset()
	for id in data["upgrades"]:
		controller.set_upgrade_level(id, int(data["upgrades"][id]))
	_player.hp = int(data["hp"])
	_player.update_hp(0)
	_player.global_position = HandController.CENTER
	controller.psi = float(data["psi"])
	controller.add_psi(0.0)
	controller.enabled = true
	loot.restore_checkpoint_state(data["loot"])
	kills = int(data["kills"])
	RunStats.update_best_kills(kills)
	_report_stats_error()
	wave = int(data["wave"]) - 1 if not _is_boss_stage() else 0
	_begin_wave()
	run_started.emit()


func _on_boss_defeated() -> void:
	if _ended:
		return
	_clear_boss()
	_end_run( true )


func _on_boss_segment_cleared(segment: int) -> void:
	if _ended:
		return
	RunStats.record_milestone( _milestones_before( stage ) + segment )
	if segment == WizardBoss.ROUNDS:
		RunStats.set_timing_active(false)


## 清掉 Boss 和它创建的一切（巫师、火把、光束、特效、血条；小怪和投射物由 spawner.clear() 清）。可重复调用
func _clear_boss() -> void:
	if is_instance_valid( _boss ):
		_boss.cleanup()
	_boss = null
	# 兜底：不管引用在不在，节点组里的 Boss 相关节点都清掉
	for n in get_tree().get_nodes_in_group( "wizard_boss" ):
		n.queue_free()
	for n in get_tree().get_nodes_in_group( "boss_fx" ):
		n.queue_free()
	hud.hide_boss_bar()


## 当前关的波数
func _wave_total() -> int:
	return _stage_data["waves"].size()


func _is_last_stage() -> bool:
	return stage >= stage_count() - 1


func stage_count() -> int:
	return StageData.stage_count(campaign_version)


func stage_name() -> String:
	return _stage_data.get( "name", "" )


func _milestones_before( index: int ) -> int:
	return StageData.milestones_before(index, campaign_version)


func _on_enemy_killed() -> void:
	kills += 1
	RunStats.update_best_kills(kills)
	_report_stats_error()
	_update_status()


func _report_stats_error() -> void:
	if not RunStats.last_error.is_empty():
		hud.show_save_notice("BEST KILLS NOT SAVED\n" + RunStats.last_error, true)


func _on_wave_cleared() -> void:
	if _ended:
		return
	if not practice_encounter_name.is_empty():
		_spawn_chest()
		return
	RunStats.record_milestone( _milestones_before( stage ) + wave )
	if wave >= _wave_total() and _is_last_stage():
		_end_run( true )
	else:
		_spawn_chest()


func _on_player_damaged( _hit_box : HitBox ) -> void:
	_wave_hurt = true


## 清波奖励：房间中心淡入宝箱，主角走近开箱，箱子消失后才开始下一波
func _spawn_chest() -> void:
	hud.show_banner( "WAVE CLEAR" )
	_chest = RewardChest.new()
	_chest.loot = loot
	_chest.flawless = not _wave_hurt
	_chest.finished.connect( _on_chest_finished )
	add_child( _chest )
	_chest.global_position = CHEST_POS


func _on_chest_finished() -> void:
	_chest = null
	if _ended:
		return
	if not practice_encounter_name.is_empty():
		hud.show_banner( "ENCOUNTER COMPLETE" )
		return
	if wave >= _wave_total():
		_advance_stage()
	elif _wave_wants_upgrade():
		_upgrade_then_next_wave()
	else:
		wave_timer.start( WAVE_DELAY )


## 关卡之间的钩子：在淡出之前调用。这一波标了 "upgrade" 就先弹出强化三选一（游戏暂停，选完才继续）。
func _between_stages() -> void:
	if _wave_wants_upgrade():
		await _choose_upgrade()


## 这一波清完后是否要出强化选择（波次表的 "upgrade" 字段；全局最后一波不会走到这里，直接 VICTORY）
func _wave_wants_upgrade() -> bool:
	if wave < 1 or wave > _wave_total():
		return false
	return bool( _stage_data["waves"][wave - 1].get( "upgrade", false ) )


## 强化选择完（或没有可选的）之后开下一波
func _upgrade_then_next_wave() -> void:
	var id := _run_id
	await _choose_upgrade()
	if id != _run_id or _ended or not is_inside_tree():
		return
	wave_timer.start( WAVE_DELAY )


## 强化三选一：从没满级的强化池里随机抽最多 3 个不同的，弹出暂停弹窗（UpgradeMenu），选中的那项 +1 级。
## 没有可选的（全部满级）就直接返回，不弹窗。重开 / 死亡 / 跳关时弹窗被 abort 掉并取消暂停，
## 这个协程不会再醒来（弹窗释放后 chosen 不再发出；醒来的情况用 _run_id 判断）
func _choose_upgrade() -> void:
	if _ended:
		return
	var id := _run_id
	var candidates : Array[String] = []
	for u in Upgrades.pool_ids():
		if controller.upgrade_level( u ) < Upgrades.max_level( u ):
			candidates.append( u )
	if candidates.is_empty():
		return
	candidates.shuffle()
	var picks : Array[String] = []
	for i in mini( 3, candidates.size() ):
		picks.append( candidates[i] )
	_clear_upgrade_menu()
	RunStats.set_timing_active(false)
	_upgrade_menu = UpgradeMenu.new()
	_upgrade_menu.setup( picks, controller.owned_levels() )
	add_child( _upgrade_menu )
	var menu := _upgrade_menu
	var picked : String = await menu.chosen
	if id != _run_id or _ended or not is_inside_tree():
		return
	_upgrade_menu = null
	var lv := controller.add_upgrade( picked )
	_sync_run_clock()
	Pickup.show_float_text( self, _player.global_position + Vector2( 0, -48 ), "%s LV %d" % [ Upgrades.display_name( picked ), lv ] )


## 关掉还开着的强化弹窗并取消它造成的暂停（可重复调用）
func _clear_upgrade_menu() -> void:
	if is_instance_valid( _upgrade_menu ):
		_upgrade_menu.abort()
	_upgrade_menu = null


## 当前关清完且宝箱收走后：钩子 -> 淡出 -> 换关卡 -> 淡入 -> 横幅 -> 第一波。
## 主角血量、背包、掉落统计都留在原节点上，不重置。
func _advance_stage() -> void:
	_stage_changing = true
	_stage_clock_held = true
	RunStats.set_timing_active(false)
	var id := _run_id
	await _advance_stage_flow()
	# 流程被重开 / 跳关作废时，标志已由那边清掉，不要覆盖
	if id == _run_id:
		_stage_changing = false


func _advance_stage_flow() -> void:
	var id := _run_id
	await _between_stages()
	if id != _run_id or _ended or not is_inside_tree():
		return
	controller.enabled = false
	await SceneTransition.fade_out()
	if id != _run_id or _ended or not is_inside_tree():
		return
	loot.clear_world_drops()
	spawner.clear()
	for c in get_children():
		if c is Boomerang:
			c.queue_free()
	_clear_boss()
	_load_stage( stage + 1 )
	wave = 0
	_player.velocity = Vector2.ZERO
	_player.global_position = HandController.CENTER
	_update_status()
	await SceneTransition.fade_in()
	if id != _run_id or _ended or not is_inside_tree():
		return
	controller.enabled = true
	hud.show_banner( "STAGE %d - %s" % [ stage + 1, _stage_data["name"] ] )
	wave_timer.start( STAGE_BANNER_TIME )


## 练习场调试：立刻切到第 n 关（清敌人、掉落物、宝箱，主角回中心，从第 1 波开始，不淡入淡出）。
## 递增 _run_id 让还没醒来的旧协程作废；正在淡出 / 淡入换关时也可以跳（会把画面恢复显示）；这一局已结束时忽略
func debug_goto_stage( n : int ) -> void:
	if _ended:
		return
	# 调试入口永远不能保留正常局的统计资格。
	RunStats.abandon_run()
	RunStats.begin_run( true, _milestones_before( n ), _milestones_before( stage_count() - 1 ) + 3, StageData.ruleset(campaign_version) )
	LeaderboardManager.begin_run(true)
	_run_id += 1
	if _stage_changing:
		SceneTransition.reset()
	_stage_changing = false
	controller.enabled = true
	wave_timer.stop()
	_clear_rewards()
	_clear_boss()
	spawner.clear()
	for c in get_children():
		if c is Boomerang:
			c.queue_free()
	_load_stage( n )
	wave = 0
	_wave_hurt = false
	_player.velocity = Vector2.ZERO
	_player.global_position = HandController.CENTER
	controller.enabled = true
	_update_status()
	hud.show_banner( "STAGE %d - %s" % [ stage + 1, _stage_data["name"] ] )
	wave_timer.start( STAGE_BANNER_TIME )


## 练习场单波对照。每次重置到相同的角色资源和出生位置。
func debug_start_encounter( layout: Node2D, label: String, batches: Array, zones: Dictionary ) -> void:
	if not LevelManager.practice_mode or campaign_preview:
		layout.free()
		return
	hud.hide_result()
	PauseMenu.process_mode = Node.PROCESS_MODE_ALWAYS
	_start_run()
	wave_timer.stop()
	_practice_layout = layout
	practice_encounter_name = label
	add_child( layout )
	move_child( layout, _map.get_index() + 1 )
	spawner.blocked_rects.assign( layout.get_ledge_rects() )
	spawner.sort_enemies_with_player = layout.attach_wall_depth( self, _player.z_index )
	wave = 2
	_wave_hurt = false
	hud.show_banner( label )
	spawner.start_scheduled_wave( batches, zones, Callable( layout, "route_target" ) )
	_update_status()


## 练习场调试：立刻清掉这一波的所有敌人，走正常的清波流程（宝箱 / 切关 / 胜利）
func debug_clear_wave() -> void:
	if _ended:
		return
	RunStats.abandon_run()
	RunStats.begin_run( true, _milestones_before( stage ) + maxi( wave - 1, 0 ), _milestones_before( stage_count() - 1 ) + 3, StageData.ruleset(campaign_version) )
	LeaderboardManager.begin_run(true)
	if is_instance_valid( _boss ):
		# Boss 关：K = 立即碎盾进入破绽阶段
		_boss.debug_break_shield()
		return
	spawner.debug_clear_wave()


func _unhandled_input( event : InputEvent ) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		if key == KEY_Q or key == KEY_E:
			use_bag_item( Pickup.Kind.APPLE if key == KEY_Q else Pickup.Kind.POTION )
			get_viewport().set_input_as_handled()


func use_bag_item( kind : int ) -> bool:
	if _ended or _stage_changing or LevelManager.is_loading_level or is_instance_valid( _upgrade_menu ):
		return false
	return is_instance_valid( loot ) and loot.use_item( kind )


## 暂停菜单背包面板的内容
func _bag_info() -> Dictionary:
	var owned : Array[String] = []
	var levels := controller.owned_levels()
	for u in levels:
		owned.append( "%s LV %d" % [ Upgrades.display_name( u ), levels[u] ] )
	return {
		"upgrades": owned,
		"status": ( "STAGE %d  BOSS   KILLS %d" % [ stage + 1, kills ] ) if _is_boss_stage() else ( "STAGE %d  WAVE %d/%d   KILLS %d" % [ stage + 1, maxi( wave, 1 ), _wave_total(), kills ] ),
		"rows": [
			{ "region": Pickup.REGIONS[Pickup.Kind.APPLE], "name": "APPLE",
				"value": "%d/%d" % [ loot.bag_apples, LootDropper.BAG_CAPACITY ], "note": "+1 HP",
				"kind": Pickup.Kind.APPLE, "can_use": loot.can_use_item( Pickup.Kind.APPLE ) },
			{ "region": Pickup.REGIONS[Pickup.Kind.POTION], "name": "POTION",
				"value": "%d/%d" % [ loot.bag_potions, LootDropper.BAG_CAPACITY ], "note": "+2 HP, PSI MAX",
				"kind": Pickup.Kind.POTION, "can_use": loot.can_use_item( Pickup.Kind.POTION ) },
			{ "region": Pickup.REGIONS[Pickup.Kind.GEM], "name": "GEM",
				"value": "x%d" % loot.picked[Pickup.Kind.GEM], "note": "PICKED - PSI +25%" },
		],
	}


## 清掉宝箱、掉落物和飘字
func _clear_rewards() -> void:
	if is_instance_valid( _chest ):
		_chest.queue_free()
	_chest = null
	_clear_upgrade_menu()
	if loot != null:
		loot.clear()


## 主角死亡：先放死亡动效（慢动作 + 闪白 + 倒下 + 冒烟，见 death_fx.gd），播完再弹 GAME OVER 面板。
## 期间停止刷怪、关掉手势 / 键盘操控（回旋镖随之收回）、禁用暂停菜单；
## 主角 is_dead 且受击框已关，敌人不会再造成伤害
func _on_player_died() -> void:
	if _ended:
		return
	_ended = true
	RunStats.set_timing_active(false)
	wave_timer.stop()
	_clear_rewards()
	if is_instance_valid( _boss ):
		_boss.freeze()
	spawner.set_process( false )
	if campaign_version == StageData.CURRENT_VERSION or not practice_encounter_name.is_empty():
		spawner.clear()
	controller.enabled = false
	PauseMenu.process_mode = Node.PROCESS_MODE_DISABLED
	_death_fx = DeathFx.new()
	add_child( _death_fx )
	_death_fx.finished.connect( _on_death_fx_finished )
	_death_fx.start( _player )


func _on_death_fx_finished() -> void:
	_end_run( false )


## 结束死亡动效并恢复时间流速（重开、回标题、关卡释放时都会调用，可重复调用）
func _clear_death_fx() -> void:
	if is_instance_valid( _death_fx ):
		_death_fx.cleanup()
		_death_fx.queue_free()
	_death_fx = null
	Engine.time_scale = 1.0


func _end_run( victory : bool ) -> void:
	_ended = true
	RunStats.finish_run(victory, kills)
	LeaderboardManager.finish_run(RunStats.get_last_result())
	_report_stats_error()
	wave_timer.stop()
	_clear_rewards()
	controller.enabled = false
	# 结算期间不允许 Esc 打开暂停菜单
	PauseMenu.process_mode = Node.PROCESS_MODE_DISABLED
	PlayerHud.hide()
	hud.show_result( victory, kills, RunStats.best_kills )


func _on_retry_pressed() -> void:
	hud.hide_result()
	get_tree().paused = false
	PauseMenu.process_mode = Node.PROCESS_MODE_ALWAYS
	_start_run()


func _on_title_pressed() -> void:
	LevelManager.load_new_level( TITLE_SCENE )


func _update_status() -> void:
	if not practice_encounter_name.is_empty():
		hud.status_label.text = "%s  KILLS %d" % [ practice_encounter_name, kills ]
		return
	hud.set_status( stage + 1, maxi( wave, 1 ), _wave_total(), kills, RunStats.best_kills )

extends Node
## 由隔离 APPDATA 的 Godot 运行，真实标题/转场/关卡与存读档整合回归。

var _checks := 0
var _failures := 0


func _ready() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("RANKING INTEGRATION: " + message)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, false, true).timeout


func _until(predicate: Callable, seconds: float = 6.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await _wait(0.02)
	_check(false, "Timeout waiting for scene state")
	return false


func _elapsed() -> int:
	return int(RunStats.get_run_snapshot()["elapsed_ms"])


func _capture(name: String) -> void:
	if not OS.get_cmdline_user_args().has("--capture-previews") or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var folder := "res://build/previews/leaderboard"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	_check(get_viewport().get_texture().get_image().save_png(folder.path_join(name + ".png")) == OK, "Save actual scene preview")


func _run() -> void:
	if not OS.get_user_data_dir().replace("\\", "/").contains(".stage1_checks/"):
		push_error("Run this test with an isolated APPDATA under .stage1_checks.")
		get_tree().quit(2)
		return
	AuthManager.set_process(false)
	AuthManager.startup_prompt_handled = true
	GestureInput.set_process(false)
	AudioServer.set_bus_mute(0, true)
	get_tree().current_scene = null
	get_tree().change_scene_to_file("res://ui/title/title_scene.tscn")
	if not await _until(func() -> bool: return get_tree().current_scene != null):
		get_tree().quit(1)
		return
	var title := get_tree().current_scene
	title.logo.skip_intro()
	if not await _until(func() -> bool: return title._menu_ready):
		get_tree().quit(1)
		return
	_check(get_tree().paused, "Title owns pause state")
	title.start_game()
	if not await _until(func() -> bool:
		return get_tree().current_scene is SurvivalArena and not LevelManager.is_loading_level and get_tree().current_scene.wave == 1):
		get_tree().quit(1)
		return
	var arena := get_tree().current_scene as SurvivalArena
	PlayerManager.player.god_mode = true
	_check(not RunStats.get_run_snapshot()["continued"], "START begins fresh statistics")
	await _wait(0.12)
	_check(_elapsed() >= 70, "First playable wave starts monotonic clock")
	var checkpoint := arena.get_checkpoint()
	_check(not checkpoint.is_empty(), "Wave checkpoint still available")
	var save_id := SaveManager.create_save(checkpoint, "Ranking regression")
	_check(not save_id.is_empty(), "Rank clock does not prevent manual saving")
	_check(not RunStats.get_run_snapshot()["continued"], "Saving does not mark the current run continued")
	_check(not SaveManager.list_saves().is_empty(), "Autosave/manual saves still exist")
	PauseMenu.show_pause_menu()
	_check(PauseMenu.is_paused, "Actual settings opens")
	var before := _elapsed()
	await _wait(0.2)
	_check(abs(_elapsed() - before) <= 25, "Pause settings duration excluded")
	PauseMenu.hide_pause_menu()
	await _wait(0.12)
	_check(_elapsed() > before + 65, "Clock resumes after settings")

	# 快速产生清波信号；不是 debug_clear_wave，不改变正式入口的统计状态。
	arena.spawner.clear()
	arena._on_wave_cleared()
	_check(RunStats.get_run_snapshot()["progress"] == 1, "Clearing wave records milestone one")
	var rank_time := int(RunStats.get_run_snapshot()["rank_time_ms"])
	before = _elapsed()
	await _wait(0.12)
	_check(_elapsed() > before + 65, "Time walking toward reward chest counts")
	_check(RunStats.get_run_snapshot()["rank_time_ms"] == rank_time, "Incomplete progress does not change ranking time")
	arena._clear_rewards()
	arena._choose_upgrade()
	_check(get_tree().paused and is_instance_valid(arena._upgrade_menu), "Actual upgrade menu pauses")
	before = _elapsed()
	await _wait(0.48)
	_check(abs(_elapsed() - before) <= 25, "Upgrade choice duration excluded")
	arena._upgrade_menu._confirm()
	await _wait(0.12)
	_check(not get_tree().paused and _elapsed() > before + 65, "Clock resumes after upgrade selection")

	# 连续补足两波，走真实跨关淡出/淡入/横幅流程。
	RunStats.record_milestone(2)
	RunStats.record_milestone(3)
	arena.wave = 3
	for id in Upgrades.pool_ids():
		arena.controller.set_upgrade_level(id, Upgrades.max_level(id))
	arena._advance_stage()
	before = _elapsed()
	if not await _until(func() -> bool: return arena.stage == 1 and not arena._stage_changing):
		get_tree().quit(1)
		return
	_check(abs(_elapsed() - before) <= 25, "Forced stage transition excluded")
	_check(arena.wave == 0, "Stage banner precedes first grassland wave")
	await _wait(0.2)
	_check(abs(_elapsed() - before) <= 25, "Forced stage banner excluded")
	if not await _until(func() -> bool: return arena.wave == 1):
		get_tree().quit(1)
		return
	await _wait(0.1)
	_check(_elapsed() > before + 50, "Next stage resumes clock")

	# Boss 的最后一击停止计时，死亡演出仍走原来的 defeated -> 结算。
	arena.wave_timer.stop()
	arena.spawner.clear()
	for milestone in range(4, 7):
		RunStats.record_milestone(milestone)
	arena._load_stage(2)
	arena._begin_boss()
	before = _elapsed()
	await _wait(0.15)
	_check(abs(_elapsed() - before) <= 25, "Boss forced entrance excluded")
	if not await _until(func() -> bool: return arena._boss.phase == WizardBoss.Phase.SHIELD):
		get_tree().quit(1)
		return
	await _wait(0.1)
	_check(_elapsed() > before + 50, "Boss battle clock resumes")
	var boss := arena._boss
	var hit := HitBox.new()
	hit.damage = boss.segment_hp
	for segment in range(1, 4):
		boss.debug_break_shield()
		boss._on_damaged(hit)
		_check(RunStats.get_run_snapshot()["progress"] == 6 + segment, "Boss segment milestone %d" % segment)
	hit.free()
	before = _elapsed()
	_check(boss.phase == WizardBoss.Phase.DYING, "Boss death presentation remains")
	await _wait(0.25)
	_check(_elapsed() == before, "Final hit freezes clock before death presentation")
	if not await _until(func() -> bool: return arena.hud.result_panel.visible):
		get_tree().quit(1)
		return
	_check(RunStats.get_last_result()["victory"], "Victory result recorded")
	_check(RunStats.get_last_result()["elapsed_ms"] == before, "Victory result does not count death animation")
	_check(RunStats.get_last_result()["ranking_status"] == "NOT RANKED", "Candidate never claims online upload")
	await _capture("actual-victory")
	arena._on_retry_pressed()
	_check(not get_tree().paused and RunStats.get_run_snapshot()["progress"] == 0, "Retry resets progress and pause")
	await _wait(1.2)
	before = _elapsed()
	arena._on_player_died()
	await _wait(0.25)
	_check(abs(_elapsed() - before) <= 25, "Player death slow motion excluded")
	if not await _until(func() -> bool: return arena.hud.result_panel.visible):
		get_tree().quit(1)
		return
	_check(not RunStats.get_last_result()["victory"], "Game over result recorded")
	_check(is_equal_approx(Engine.time_scale, 1.0), "Death resets game time scale")
	await _capture("actual-game-over")
	arena._on_title_pressed()
	if not await _until(func() -> bool:
		return get_tree().current_scene != null and not get_tree().current_scene is SurvivalArena and not LevelManager.is_loading_level):
		get_tree().quit(1)
		return
	_check(get_tree().paused, "Returning title preserves its pause")
	_check(SaveManager.load_game(save_id), "Load real saved checkpoint")
	if not await _until(func() -> bool: return get_tree().current_scene is SurvivalArena and not LevelManager.is_loading_level):
		get_tree().quit(1)
		return
	arena = get_tree().current_scene as SurvivalArena
	_check(RunStats.get_run_snapshot()["continued"], "Manual load becomes continued run")
	_check(RunStats.get_run_snapshot()["ranking_reason"] == "CONTINUED RUN", "Continued run clearly ineligible")
	_check(arena.kills == int(checkpoint["kills"]), "Checkpoint kills preserved")
	_check(RunStats.get_run_snapshot()["progress"] == 0, "First-wave checkpoint not credited as cleared")
	arena._on_title_pressed()
	await _until(func() -> bool: return not LevelManager.is_loading_level)
	print("SURVIVAL_RANKING_TEST checks=%d failures=%d" % [_checks, _failures])
	get_tree().quit(0 if _failures == 0 else 1)

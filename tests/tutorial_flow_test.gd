extends Node
## Run with isolated APPDATA and -- --no-gesture-autostart.

const TITLE := "res://ui/title/title_scene.tscn"
const TrainingRoom = preload("res://levels/tutorial/tutorial_room.gd")
const Step = TrainingRoom.Step
const FIXTURE_ACCOUNT := "10101010-1010-4010-8010-101010101010"

var _failure := false


func _ready() -> void:
	call_deferred("_run")


func _check(passed: bool, message: String) -> bool:
	if not passed:
		_failure = true
		push_error("TUTORIAL FLOW: " + message)
	return passed


func _until(predicate: Callable, message: String) -> bool:
	var deadline := Time.get_ticks_msec() + 5500
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	return _check(predicate.call(), message)


func _key(code: Key, down: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = down
	Input.parse_input_event(event)


func _step(room: TrainingRoom, value: int) -> bool:
	return await _until(func() -> bool: return is_instance_valid(room) and room.step == value, "Reach lesson %d" % value)


func _walk_to(pos: Vector2) -> void:
	var player := PlayerManager.player
	var deadline := Time.get_ticks_msec() + 2900
	while player.global_position.distance_to(pos) > 7.0 and Time.get_ticks_msec() < deadline:
		var delta := pos - player.global_position
		for pair in [[&"left", -delta.x], [&"right", delta.x], [&"up", -delta.y], [&"down", delta.y]]:
			if pair[1] > 4.0:
				Input.action_press(pair[0])
			else:
				Input.action_release(pair[0])
		await get_tree().physics_frame
	for action in [&"left", &"right", &"up", &"down"]:
		Input.action_release(action)


func _start() -> bool:
	if not await _until(func() -> bool: return get_tree().current_scene != null and get_tree().current_scene.scene_file_path == TITLE and not LevelManager.is_loading_level, "Title loads"):
		return false
	var title := get_tree().current_scene
	title.logo.skip_intro()
	if not await _until(func() -> bool: return title._menu_ready, "START becomes available"):
		return false
	title.button_start.pressed.emit()
	return true


func _run() -> void:
	if not OS.get_environment("APPDATA").replace("\\", "/").contains("/.stage4_checks/"):
		push_error("Use an isolated APPDATA under .stage4_checks.")
		get_tree().quit(2)
		return
	AudioServer.set_bus_mute(0, true)
	GestureInput.set_process(false)
	AuthManager.set_process(false)
	AuthManager.startup_prompt_handled = true
	get_tree().current_scene = null
	if not LevelManager.practice_mode:
		# Give the real title router the same state it receives from account sign-in.
		AuthManager.authenticated = true
		AuthManager.user_id = FIXTURE_ACCOUNT
		AuthManager._tutorial_state = "pending"
		_check(SaveManager.set_profile(FIXTURE_ACCOUNT), "Bind fixture save profile")
	get_tree().change_scene_to_file(TITLE)
	if not await _start():
		get_tree().quit(1)
		return
	if LevelManager.practice_mode:
		await _wait_for_wave()
		get_tree().quit(int(_failure))
		return
	if not await _until(func() -> bool: return get_tree().current_scene is TrainingRoom and not LevelManager.is_loading_level, "Pending account enters pre-stage room"):
		get_tree().quit(1)
		return
	var room := get_tree().current_scene as TrainingRoom
	_check(RunStats.get_run_snapshot().is_empty(), "Training has no active ranked statistics")
	_check(SaveManager.list_saves().is_empty(), "Training has no autosave")
	if "--test-skip" in OS.get_cmdline_user_args():
		room.actions.get_node("Controls/TitleButton").pressed.emit()
		room.actions._accept.pressed.emit()
		_check(AuthManager.should_start_tutorial(), "Returning to title leaves tutorial pending")
		if not await _start() or not await _until(func() -> bool: return get_tree().current_scene is TrainingRoom and not LevelManager.is_loading_level, "Pending account can return to training"):
			get_tree().quit(1)
			return
		room = get_tree().current_scene as TrainingRoom
		_key(KEY_ESCAPE, true)
		_key(KEY_ESCAPE, false)
		await get_tree().process_frame
		_check(get_tree().paused and room.actions._action == "skipped", "Escape opens the skip confirmation and freezes the room")
		room.actions._cancel.pressed.emit()
		_check(not get_tree().paused and room.step == Step.MOVE, "Cancel restores current lesson")
		room.actions.get_node("Controls/SkipButton").pressed.emit()
		room.actions._accept.pressed.emit()
	else:
		await _play_lessons(room)
	if await _wait_for_wave():
		var arena := get_tree().current_scene as SurvivalArena
		_check(arena.kills == 0 and arena.loot.bag_apples == 0 and arena.loot.bag_potions == 0, "First wave starts with empty inventory and zero kills")
		_check(arena.controller.owned_levels().is_empty() and PlayerManager.player.hp == PlayerManager.player.max_hp, "Training upgrades and damage are reset")
		_check(not AuthManager.should_start_tutorial() or LevelManager.tutorial_preview, "Terminal tutorial result prevents repeating the normal route")
	print("TUTORIAL FLOW ", "FAIL" if _failure else "PASS")
	get_tree().quit(int(_failure))


func _wait_for_wave() -> bool:
	return await _until(func() -> bool: return get_tree().current_scene is SurvivalArena and get_tree().current_scene.wave == 1 and not LevelManager.is_loading_level, "First survival wave starts")


func _play_lessons(room: TrainingRoom) -> void:
	await _capture("01-move")
	await _walk_to(TrainingRoom.MOVE_GOAL)
	if not await _step(room, Step.MELEE):
		return
	await _walk_to(TrainingRoom.MELEE_POS - Vector2(24, 0))
	_key(KEY_J, true)
	await get_tree().process_frame
	_key(KEY_J, false)
	if not await _step(room, Step.RANG):
		return
	await get_tree().create_timer(0.35).timeout
	await _capture("02-boomerang")
	_key(KEY_RIGHT, true)
	await get_tree().physics_frame
	_key(KEY_L, true)
	var hit := await _step(room, Step.RECALL)
	_key(KEY_RIGHT, false)
	_key(KEY_L, false)
	if not hit or not await _step(room, Step.GEM):
		return
	await _walk_to(TrainingRoom.RANG_POS)
	if not await _step(room, Step.CHEST):
		return
	await _walk_to(TrainingRoom.CHEST_POS + Vector2(34, 10))
	await _walk_to(TrainingRoom.CHEST_POS + Vector2(24, 9))
	if not await _step(room, Step.PICKUPS):
		return
	await get_tree().create_timer(1.5).timeout
	await _walk_to(TrainingRoom.CHEST_POS + RewardChest.POTION_OFFSET)
	await _walk_to(TrainingRoom.CHEST_POS + RewardChest.APPLE_OFFSET)
	if not await _step(room, Step.APPLE):
		return
	_check(PlayerManager.player.hp == PlayerManager.player.max_hp - 3, "Healing starts with controlled damage")
	await _capture("03-healing")
	_key(KEY_Q, true)
	_key(KEY_Q, false)
	if not await _step(room, Step.POTION):
		return
	_check(room.loot.bag_apples == 0 and PlayerManager.player.hp == PlayerManager.player.max_hp - 2, "Apple is consumed for one HP")
	_key(KEY_E, true)
	_key(KEY_E, false)
	if not await _step(room, Step.CHOOSE):
		return
	_check(room.loot.bag_potions == 0 and PlayerManager.player.hp == PlayerManager.player.max_hp, "Potion is consumed for two HP")
	await _capture("04-upgrade")
	_key(KEY_ESCAPE, true)
	_key(KEY_ESCAPE, false)
	await get_tree().process_frame
	_check(room.actions._modal.visible and room.actions._action == "skipped", "Escape also opens skip during upgrade selection")
	room.actions._cancel.pressed.emit()
	_check(get_tree().paused and is_instance_valid(room._menu) and room._menu.selection_enabled, "Cancel during upgrade restores the selectable cards")
	await get_tree().create_timer(0.45).timeout
	var upgrade := "pool"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--test-upgrade="):
			upgrade = arg.trim_prefix("--test-upgrade=")
	if upgrade in ["pierce", "blast"]:
		var arrow := KEY_LEFT if upgrade == "pierce" else KEY_RIGHT
		_key(arrow, true)
		_key(arrow, false)
	_key(KEY_ENTER, true)
	_key(KEY_ENTER, false)
	if not await _step(room, Step.TRY_UPGRADE):
		return
	_check(room.controller.upgrade_level(upgrade) == 1, "Real upgrade menu applies " + upgrade)
	match upgrade:
		"pool":
			_key(KEY_L, true)
			await _until(func() -> bool: return room._pooled_hold, "PSI POOL sustains a longer cast")
			_key(KEY_L, false)
		"blast":
			_key(KEY_L, true)
			await get_tree().create_timer(0.63).timeout
			_key(KEY_L, false)
		"pierce":
			await _walk_to(TrainingRoom.RANG_POS - Vector2(85, 0))
			_key(KEY_RIGHT, true)
			await get_tree().create_timer(0.1).timeout
			_key(KEY_L, true)
			await _until(func() -> bool: return LevelManager.is_loading_level, "HEAVY RANG defeats the practice target")
			_key(KEY_RIGHT, false)
			_key(KEY_L, false)


func _capture(name: String) -> void:
	if DisplayServer.get_name() == "headless" or "--capture-previews" not in OS.get_cmdline_user_args():
		return
	await RenderingServer.frame_post_draw
	var folder := ProjectSettings.globalize_path("res://build/previews/tutorial")
	DirAccess.make_dir_recursive_absolute(folder)
	_check(get_viewport().get_texture().get_image().save_png(folder.path_join(name + ".png")) == OK, "Save actual game preview")

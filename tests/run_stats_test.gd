extends Node

const GUEST_PATH := "user://stats/guest.json"
const UUID_A := "11111111-1111-4111-8111-" + "111111111111"
const UUID_B := "22222222-2222-4222-8222-" + "222222222222"

var _failures: Array[String] = []
var _check_count := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred("_start")


func _start() -> void:
	var appdata := OS.get_environment("APPDATA").to_lower().replace("\\", "/")
	if not appdata.contains("/.stage1_checks"):
		push_error("RunStats tests require APPDATA to be isolated under .stage1_checks")
		get_tree().quit(2)
		return
	var args := OS.get_cmdline_user_args()
	if not args.has("--practice"):
		push_error("RunStats tests must start with -- --practice to suppress account startup activity")
		get_tree().quit(2)
		return
	AuthManager.set_process(false)
	GestureInput.set_process(false)
	var master_bus := AudioServer.get_bus_index("Master")
	if master_bus >= 0:
		AudioServer.set_bus_mute(master_bus, true)
	LevelManager.practice_mode = false
	await get_tree().process_frame
	if args.has("--run-stats-seed"):
		_seed_identity("guest", 37)
		_seed_identity(UUID_A, 41)
		_seed_identity(UUID_B, 17)
		_set_account(UUID_A)
		RunStats.begin_run()
		_set_account(UUID_B)
		RunStats.abandon_run()
		_check(RunStats.best_kills == 17, "abandon after identity change leaves account B intact")
		_quit_with_report()
		return
	if args.has("--run-stats-verify"):
		_set_guest()
		_check(RunStats.best_kills == 37, "guest BEST survives a new process")
		_set_account(UUID_A)
		_check(RunStats.best_kills == 41, "account A BEST survives a new process")
		_set_account(UUID_B)
		_check(RunStats.best_kills == 17, "account B BEST survives a new process")
		_quit_with_report()
		return
	await _exercise_stats()
	_quit_with_report()


func _exercise_stats() -> void:
	_set_guest()
	var parsed_integer_record: Variant = JSON.parse_string("{\"version\":1,\"best_kills\":37}")
	_check(RunStats._valid_record(parsed_integer_record), "JSON integer-valued numbers are accepted")
	_check(not RunStats._valid_record({"version": true, "best_kills": 37}), "boolean version is rejected")
	_check(not RunStats._valid_record({"version": 1, "best_kills": 2.5}), "fractional BEST is rejected")
	RunStats.begin_run(true, 4)
	var snap := RunStats.get_run_snapshot()
	_check(snap.progress == 4 and snap.continued, "continued starting progress is displayed")
	_check(snap.milestone_ms.is_empty() and snap.rank_time_ms == 0, "continued milestones have no fabricated times")
	RunStats.record_milestone(6)
	_check(RunStats.get_run_snapshot().progress == 4, "milestone jumps are rejected")
	RunStats.record_milestone(5)
	var first_time: int = RunStats.get_run_snapshot().milestone_ms[0]
	RunStats.record_milestone(5)
	_check(RunStats.get_run_snapshot().milestone_ms.size() == 1, "duplicate milestone is rejected")
	_check(RunStats.get_run_snapshot().rank_time_ms == first_time, "rank time is latest reached milestone time")
	RunStats.abandon_run()

	# Identity is captured once at begin_run; a session change cannot redirect writes.
	_set_account(UUID_A)
	RunStats.begin_run()
	_set_account(UUID_B)
	RunStats.update_best_kills(41)
	var result := RunStats.finish_run(false, 41)
	_check(result.best_kills == 41 and result.new_best_kills, "mid-run identity change keeps result bound to account A")
	_check(RunStats.best_kills == 0, "account B has an independent BEST")
	_set_account(UUID_A)
	_check(RunStats.best_kills == 41, "account A BEST is retained after switching back")

	# Continued runs update BEST, while practice mode neither reads nor writes it.
	RunStats.begin_run(true, 2)
	RunStats.update_best_kills(44)
	RunStats.finish_run(false, 44)
	_check(RunStats.best_kills == 44, "continued run can update local BEST")
	LevelManager.practice_mode = true
	RunStats.begin_run()
	RunStats.update_best_kills(999)
	var practice_result := RunStats.finish_run(false, 999)
	_check(practice_result.practice and practice_result.best_kills == 0, "practice result does not expose normal BEST")
	LevelManager.practice_mode = false
	_check(RunStats.best_kills == 44, "practice does not contaminate normal BEST")

	# Monotonic timing ignores time_scale and explicit pause/disabled intervals.
	RunStats.begin_run()
	RunStats.set_timing_active(true)
	Engine.time_scale = 0.2
	var timer_started_usec := Time.get_ticks_usec()
	var elapsed_before_timer: int = RunStats.get_run_snapshot().elapsed_ms
	await get_tree().create_timer(0.12, true, false, true).timeout
	var scene_timer_wall_ms := int((Time.get_ticks_usec() - timer_started_usec) / 1000)
	var scene_timer_stats_ms: int = RunStats.get_run_snapshot().elapsed_ms - elapsed_before_timer
	_check(absi(scene_timer_stats_ms - scene_timer_wall_ms) <= 50, "stats follows real ticks while SceneTreeTimer waits")
	var clock_before_wait_usec := Time.get_ticks_usec()
	var timer_wait_ms: int = await _wait_real(0.12)
	var wall_delta_ms := int((Time.get_ticks_usec() - clock_before_wait_usec) / 1000)
	var polled_elapsed: int = RunStats.get_run_snapshot().elapsed_ms
	var polled_stats_delta_ms := polled_elapsed - elapsed_before_timer - scene_timer_stats_ms
	_check(absi(polled_stats_delta_ms - wall_delta_ms) <= 50 and timer_wait_ms >= 120, "stats tracks monotonic wall time during slow motion")
	_check(polled_stats_delta_ms >= 80, "elapsed time is independent of Engine.time_scale")
	RunStats.set_timing_active(false)
	await _wait_real(0.12)
	var stopped_elapsed: int = RunStats.get_run_snapshot().elapsed_ms
	_check(stopped_elapsed - polled_elapsed < 50, "disabled timing does not accumulate")
	RunStats.set_timing_active(true)
	get_tree().paused = true
	await _wait_real(0.12)
	var paused_elapsed: int = RunStats.get_run_snapshot().elapsed_ms
	RunStats.set_timing_active(false)
	_check(RunStats.get_run_snapshot().elapsed_ms - paused_elapsed < 20, "disabling timing while paused excludes the whole paused gap")
	get_tree().paused = false
	RunStats.set_timing_active(true)
	await _wait_real(0.04)
	RunStats.set_timing_active(false)
	Engine.time_scale = 1.0
	_check(RunStats.get_run_snapshot().elapsed_ms - stopped_elapsed < 80, "paused duration is excluded")
	RunStats.set_timing_active(true)
	await _wait_real(0.03)
	get_tree().paused = true
	await _wait_real(0.12)
	get_tree().paused = false
	await _wait_real(0.03)
	RunStats.set_timing_active(false)
	_check(RunStats.get_run_snapshot().elapsed_ms < stopped_elapsed + 160, "active clock samples pause state throughout the pause")

	# Milestone 9 freezes immediately, regardless of later enabled requests.
	RunStats.begin_run()
	for milestone in range(1, 10):
		RunStats.record_milestone(milestone)
	var final_milestone_time: int = RunStats.get_run_snapshot().elapsed_ms
	RunStats.set_timing_active(true)
	await _wait_real(0.05)
	_check(RunStats.get_run_snapshot().elapsed_ms == final_milestone_time, "milestone 9 freezes timing")
	var won := RunStats.finish_run(true, 44)
	_check(won.victory and won.progress == 9 and won.rank_time_ms == won.milestone_ms[-1], "victory snapshot fields are coherent")
	_check(won.ranking_status == "NOT RANKED" and won.ranking_reason == "ONLINE RANKING NOT AVAILABLE", "offline status is explicit")
	_check(RunStats.finish_run(false, 0) == won, "finish is idempotent")
	_check(RunStats.format_time(75432) == "01:15.432", "time formatting")

	# Invalid JSON must not crash; a failed temporary write must preserve the old record.
	_set_guest()
	var base := RunStats.best_kills
	var file := FileAccess.open(GUEST_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string("{invalid")
		file.close()
	RunStats._best_by_identity.erase("guest")
	_check(RunStats.best_kills == 0, "malformed stats file is safely rejected")
	RunStats.begin_run()
	var temp_absolute := ProjectSettings.globalize_path(GUEST_PATH + ".tmp")
	if FileAccess.file_exists(GUEST_PATH + ".tmp"):
		DirAccess.remove_absolute(temp_absolute)
	var mkdir_error := DirAccess.make_dir_absolute(temp_absolute)
	_check(mkdir_error == OK, "test can block temporary file creation")
	RunStats.update_best_kills(base + 10)
	_check(RunStats.last_error != "", "write failure is exposed")
	RunStats.abandon_run()
	DirAccess.remove_absolute(temp_absolute)

	# Recreate a valid source record and ensure a failed temp write leaves it intact.
	file = FileAccess.open(GUEST_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"version": 1, "best_kills": base}))
		file.close()
	RunStats._best_by_identity.erase("guest")
	var temp_dir := ProjectSettings.globalize_path(GUEST_PATH + ".tmp")
	DirAccess.make_dir_absolute(temp_dir)
	RunStats.begin_run()
	RunStats.update_best_kills(base + 1)
	RunStats.abandon_run()
	DirAccess.remove_absolute(temp_dir)
	RunStats._best_by_identity.erase("guest")
	_check(RunStats.best_kills == base, "failed write leaves previous JSON value intact")

	# Restore guest identity and pause state for clean process exit.
	_set_guest()
	get_tree().paused = false
	Engine.time_scale = 1.0


func _set_guest() -> void:
	AuthManager.authenticated = false
	AuthManager.user_id = ""
	AuthManager.session_changed.emit()


func _seed_identity(identity: String, kills: int) -> void:
	var path := RunStats._path_for_identity(identity)
	var absolute := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(absolute)
	if FileAccess.file_exists(path + ".tmp"):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ".tmp"))
	RunStats._best_by_identity.erase(identity)
	if identity == "guest":
		_set_guest()
	else:
		_set_account(identity)
	RunStats.begin_run()
	RunStats.update_best_kills(kills)
	var result := RunStats.finish_run(false, kills)
	_check(result.best_kills == kills, "seed writes expected BEST for " + identity)


func _set_account(identity: String) -> void:
	AuthManager.authenticated = true
	AuthManager.user_id = identity
	AuthManager.session_changed.emit()


func _wait_real(seconds: float) -> int:
	var started_usec := Time.get_ticks_usec()
	var duration_usec := int(seconds * 1000000.0)
	while Time.get_ticks_usec() - started_usec < duration_usec:
		await get_tree().process_frame
	return int((Time.get_ticks_usec() - started_usec) / 1000)


func _check(condition: bool, description: String) -> void:
	_check_count += 1
	if not condition:
		_failures.append(description)
		push_error("RunStats test failed: " + description)


func _quit_with_report() -> void:
	if _failures.is_empty():
		print("PASS: RunStats checks (%d)" % _check_count)
		get_tree().quit(0)
	else:
		push_error("RunStats failures: " + "; ".join(_failures))
		get_tree().quit(1)

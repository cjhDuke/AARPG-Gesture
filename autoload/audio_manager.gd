extends Node

signal volume_changed(bus: StringName, value: float)
signal storage_error(operation: StringName, error: int)

const SETTINGS_PATH := "user://settings.cfg"
const VOLUME_BUSES: Array[StringName] = [&"Master", &"Music", &"SFX"]
const SAVE_DELAY := 0.4

## UI can query this after connecting: startup load errors happen before UI exists.
var last_settings_error: int = OK
var _bus_volumes: Dictionary = {&"Master": 1.0, &"Music": 1.0, &"SFX": 1.0}
var _base_db: Dictionary = {}
var _save_timer: Timer
var _settings_initialized := false
var _settings_dirty := false

var music_audio_player_count : int = 2
var current_music_player : int = 0
var music_players : Array[ AudioStreamPlayer ] = []
var music_bus : String = "Music"

var music_fade_duration : float = 0.5


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = SAVE_DELAY
	_save_timer.ignore_time_scale = true
	_save_timer.timeout.connect(flush_settings)
	add_child(_save_timer)
	for bus in VOLUME_BUSES:
		_base_db[bus] = AudioServer.get_bus_volume_db(AudioServer.get_bus_index(bus))
	_load_settings()
	for bus in VOLUME_BUSES:
		_apply_bus_volume(bus)
	_settings_initialized = true
	for i in music_audio_player_count:
		var player = AudioStreamPlayer.new()
		add_child(player)
		player.bus = music_bus
		music_players.append(player)
		player.volume_db = -40
		

func get_bus_volume(bus: StringName) -> float:
	return float(_bus_volumes.get(bus, 1.0))


func set_bus_volume(bus: StringName, value: float) -> void:
	if not _settings_initialized or not _bus_volumes.has(bus) or not is_finite(value):
		return
	value = clampf(value, 0.0, 1.0)
	if get_bus_volume(bus) == value:
		return
	_bus_volumes[bus] = value
	_apply_bus_volume(bus)
	_settings_dirty = true
	_save_timer.start()
	volume_changed.emit(bus, value)


func _apply_bus_volume(bus: StringName) -> void:
	var index := AudioServer.get_bus_index(bus)
	var value := get_bus_volume(bus)
	AudioServer.set_bus_mute(index, value == 0.0)
	AudioServer.set_bus_volume_db(index, float(_base_db[bus]) + linear_to_db(value) if value > 0.0 else float(_base_db[bus]))


func _load_settings() -> void:
	var config := ConfigFile.new()
	var error := config.load(SETTINGS_PATH)
	if error == ERR_FILE_NOT_FOUND:
		return
	if error != OK:
		_report_storage_error(&"load", error)
		return
	for bus in VOLUME_BUSES:
		var value: Variant = config.get_value("audio", String(bus), 1.0)
		if (value is float or value is int) and is_finite(float(value)) and float(value) >= 0.0 and float(value) <= 1.0:
			_bus_volumes[bus] = float(value)


## Safe to call before quitting from UI; unchanged/uninitialized settings never write.
func flush_settings() -> void:
	if not _settings_initialized or not _settings_dirty:
		return
	_save_timer.stop()
	var config := ConfigFile.new()
	# Reload so other settings sections are retained. Do not overwrite unreadable files.
	var error := config.load(SETTINGS_PATH)
	if error != OK and error != ERR_FILE_NOT_FOUND:
		_report_storage_error(&"save", error)
		return
	for bus in VOLUME_BUSES:
		config.set_value("audio", String(bus), get_bus_volume(bus))
	error = config.save(SETTINGS_PATH)
	last_settings_error = error
	if error != OK:
		_report_storage_error(&"save", error)
		return
	_settings_dirty = false


func _report_storage_error(operation: StringName, error: int) -> void:
	last_settings_error = error
	storage_error.emit(operation, error)
	push_warning("Audio settings %s failed: %s" % [operation, error_string(error)])


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		flush_settings()


func _exit_tree() -> void:
	flush_settings()


func play_music( _audio : AudioStream ) -> void:
	if _audio == null:
		return
	_set_music_looping(_audio)
	if _audio == music_players[ current_music_player ].stream and music_players[ current_music_player ].playing:
		return
		
	current_music_player += 1
	if current_music_player > 1:
		current_music_player = 0
	
	var current_player : AudioStreamPlayer = music_players[ current_music_player ]
	current_player.stream = _audio
	play_and_fade_in( current_player )
	
	var old_player = music_players[1]
	if current_music_player == 1:
		old_player = music_players[0]
		
	fade_out_and_stop( old_player )


func play_and_fade_in( player : AudioStreamPlayer ) -> void:
	player.play(0)
	var tween : Tween = create_tween()
	tween.tween_property( player, 'volume_db', 0, music_fade_duration )
	pass


func stop_music() -> void:
	for player in music_players:
		if player.playing:
			fade_out_and_stop(player)
	
	
func fade_out_and_stop( player : AudioStreamPlayer ) -> void:
	var tween : Tween = create_tween()
	tween.tween_property( player, 'volume_db', -40, music_fade_duration )
	await tween.finished
	player.stop()
	pass


func _set_music_looping(_audio: AudioStream) -> void:
	for property in _audio.get_property_list():
		if property.name == "loop":
			_audio.set("loop", true)
			return

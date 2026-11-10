extends Node
## 手势输入接收端（autoload: GestureInput）
## 通过本机 UDP 接收 Python 识别端的状态包和画面包，
## 按 docs/ai/gesture-protocol.md 的边沿规则注入 InputEventAction。

signal direction_triggered(dir: Vector2)
signal state_updated(state: Dictionary)
signal frame_updated(texture: ImageTexture)
signal connection_changed(connected: bool)

const RECV_PORT := 47800
const SEND_PORT := 47801
const HOST := "127.0.0.1"
const TIMEOUT_MSEC := 1000
const PING_INTERVAL_MSEC := 1000
const PANEL_SCENE := preload("res://ui/gesture_panel/gesture_panel.tscn")

const DIR_ACTION := {
	"up": "ui_up", "down": "ui_down", "left": "ui_left", "right": "ui_right"
}
const DIR_VECTOR := {
	"up": Vector2.UP, "down": Vector2.DOWN, "left": Vector2.LEFT, "right": Vector2.RIGHT
}

## 是否在游戏启动时自动拉起识别进程
@export var autostart: bool = true

var connected: bool = false
var last_state: Dictionary = {}
## 只反映状态包里的 proc_ms（识别端单帧处理耗时），不是端到端延迟
var latency_ms: float = 0.0
## Godot 侧统计的状态包到达间隔（毫秒，指数平滑）
var packet_interval_ms: float = 0.0
var last_stage: int = 0

var _udp := PacketPeerUDP.new()
var _bound := false
var _last_seq: int = -1
var _last_rx_msec: int = 0
var _last_ping_msec: int = 0
var _prev_zone: String = "center"
var _prev_gesture: String = "none"
## 当前由手势按下的动作 -> true
var _pressed: Dictionary = {}
## 下一帧要松开的动作
var _pending_release: Array[String] = []
var _texture: ImageTexture
var _pid: int = -1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_last_ping_msec = Time.get_ticks_msec()
	var err := _udp.bind(RECV_PORT, HOST)
	if err != OK:
		push_warning("GestureInput: 无法绑定 UDP %d（错误码 %d），手势输入禁用" % [RECV_PORT, err])
	else:
		_bound = true
		_udp.set_dest_address(HOST, SEND_PORT)
	add_child(PANEL_SCENE.instantiate())
	if autostart and _bound:
		_start_recognizer()


func _process(_delta: float) -> void:
	if not _bound:
		return
	# 先松开上一帧排队的动作
	for a in _pending_release:
		_release(a)
	_pending_release.clear()

	# 读完缓冲区：状态包只留 seq 最新的，画面包只留最后一个
	var newest_state: Dictionary = {}
	var newest_seq := _last_seq
	var last_frame := PackedByteArray()
	while _udp.get_available_packet_count() > 0:
		var pkt := _udp.get_packet()
		if pkt.size() < 2:
			continue
		if pkt[0] == 83: # 'S'
			var parsed = JSON.parse_string(pkt.slice(1).get_string_from_utf8())
			if parsed is Dictionary and parsed.has("seq"):
				var s := int(parsed["seq"])
				if s > newest_seq:
					newest_seq = s
					newest_state = parsed
		elif pkt[0] == 70 and pkt.size() > 2: # 'F'
			last_frame = pkt
	if not newest_state.is_empty():
		_last_seq = newest_seq
		_on_state(newest_state)
	if last_frame.size() > 2:
		_on_frame(last_frame)

	var now := Time.get_ticks_msec()
	if connected and now - _last_rx_msec > TIMEOUT_MSEC:
		_set_connected(false)
	if now - _last_ping_msec >= PING_INTERVAL_MSEC:
		_last_ping_msec = now
		_send_cmd({"cmd": "ping"})


func _on_state(st: Dictionary) -> void:
	var now := Time.get_ticks_msec()
	if _last_rx_msec > 0 and connected:
		var dt := float(now - _last_rx_msec)
		packet_interval_ms = dt if packet_interval_ms == 0.0 else lerpf(packet_interval_ms, dt, 0.1)
	_last_rx_msec = now
	latency_ms = float(st.get("proc_ms", 0.0))
	if not connected:
		# 重新连上时从干净的状态开始比较边沿
		_prev_zone = "center"
		_prev_gesture = "none"
		_set_connected(true)

	var gesture := str(st.get("gesture", "none"))
	var zone := str(st.get("zone", "center"))
	var paused := get_tree().paused

	# 区域边沿
	if zone != _prev_zone and DIR_VECTOR.has(zone):
		direction_triggered.emit(DIR_VECTOR[zone])
		if paused:
			_pulse(DIR_ACTION[zone])
		elif gesture != "fist" and gesture != "two":
			_pulse("attack")
	# 手势边沿
	if gesture != _prev_gesture:
		if gesture == "fist":
			if paused:
				_pulse("ui_accept")
			else:
				_press("attack")
		elif _prev_gesture == "fist":
			_release("attack")
		if gesture == "two" and not paused:
			_pulse("ability")
	_prev_zone = zone
	_prev_gesture = gesture
	last_state = st
	state_updated.emit(st)


func _on_frame(pkt: PackedByteArray) -> void:
	var img := Image.new()
	if img.load_jpg_from_buffer(pkt.slice(2)) != OK:
		return
	if _texture == null:
		_texture = ImageTexture.create_from_image(img)
	else:
		_texture.set_image(img)
	frame_updated.emit(_texture)


func _set_connected(v: bool) -> void:
	if connected == v:
		return
	connected = v
	if not v:
		_release_all()
		last_state = {}
		_prev_zone = "center"
		_prev_gesture = "none"
		packet_interval_ms = 0.0
	connection_changed.emit(v)


# ---------- 输入注入 ----------

func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	_pressed[action] = true


func _release(action: String) -> void:
	if not _pressed.has(action):
		return
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = false
	Input.parse_input_event(ev)
	_pressed.erase(action)


## 按下，下一帧松开
func _pulse(action: String) -> void:
	_press(action)
	_pending_release.append(action)


func _release_all() -> void:
	for a in _pressed.keys():
		_release(a)
	_pending_release.clear()


# ---------- 命令 ----------

func _send_cmd(d: Dictionary) -> void:
	if _bound:
		_udp.put_packet(JSON.stringify(d).to_utf8_buffer())


func request_calibrate() -> void:
	_send_cmd({"cmd": "calibrate"})


## 把操作框换到下一个预设位置（脸或杂物在框里时用）
func cycle_roi() -> void:
	_send_cmd({"cmd": "roi"})


func set_stage(n: int) -> void:
	last_stage = n
	_send_cmd({"cmd": "stage", "value": n})


# ---------- 识别进程 ----------

func _gesture_dir() -> String:
	if OS.has_feature("template"):
		return OS.get_executable_path().get_base_dir().path_join("gesture")
	return ProjectSettings.globalize_path("res://gesture")


func _start_recognizer() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var dir := _gesture_dir()
	var main_py := dir.path_join("main.py")
	if not FileAccess.file_exists(main_py):
		print("GestureInput: 未找到 %s，跳过启动识别进程" % main_py)
		return
	var python := "python"
	var cfg_path := dir.path_join("config.json")
	if FileAccess.file_exists(cfg_path):
		var cfg = JSON.parse_string(FileAccess.get_file_as_string(cfg_path))
		if cfg is Dictionary and cfg.has("python") and str(cfg["python"]) != "":
			python = str(cfg["python"])
		# 配置的是绝对路径但文件不存在（换了机器）时，退回 PATH 里的 python
		if python.is_absolute_path() and not FileAccess.file_exists(python):
			python = "python"
	_pid = OS.create_process(python, ["-u", main_py, "--managed"])
	if _pid <= 0:
		push_warning("GestureInput: 启动识别进程失败（%s）" % python)
		_pid = -1


func _stop_recognizer() -> void:
	_release_all()
	if _pid > 0:
		_send_cmd({"cmd": "quit"})
		OS.kill(_pid)
		_pid = -1


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_stop_recognizer()


func _exit_tree() -> void:
	_stop_recognizer()
	if _bound:
		_udp.close()
		_bound = false

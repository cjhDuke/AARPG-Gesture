"""手势状态、预览帧和控制命令的本机 UDP 收发。"""
import json
import socket

FRAME_MAX_BYTES = 60000


class Net:
    def __init__(self, cfg):
        n = cfg["net"]
        self.addr = (n["host"], n["state_port"])
        self.send_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.recv_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.recv_sock.bind((n["host"], n["command_port"]))
        self.recv_sock.setblocking(False)

    def send_state(self, state):
        """状态包：b'S' + UTF-8 JSON。"""
        data = b"S" + json.dumps(state, separators=(",", ":")).encode("utf-8")
        self.send_sock.sendto(data, self.addr)

    def send_frame(self, stage, jpeg_bytes):
        """画面包：b'F' + 阶段号 + JPEG；超过 60000 字节则丢弃。"""
        data = b"F" + bytes([stage & 0xFF]) + bytes(jpeg_bytes)
        if len(data) >= FRAME_MAX_BYTES:
            return False
        self.send_sock.sendto(data, self.addr)
        return True

    def poll_commands(self):
        """非阻塞读出所有待处理命令（dict 列表），忽略格式错误的包。"""
        cmds = []
        while True:
            try:
                data, _ = self.recv_sock.recvfrom(4096)
            except (BlockingIOError, ConnectionResetError):
                break
            except OSError:
                break
            try:
                obj = json.loads(data.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                continue
            if isinstance(obj, dict):
                cmds.append(obj)
        return cmds

    def close(self):
        self.send_sock.close()
        self.recv_sock.close()

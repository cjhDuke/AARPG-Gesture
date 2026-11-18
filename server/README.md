# PSI HAND 服务端

提供账号、云存档和排行榜，API 前缀为 `/api/v1`。

使用 Python 3.12，在项目根目录运行：

```powershell
python -m pip install -r server/requirements.txt
$env:AUTH_SECRET = (python -c "import secrets; print(secrets.token_hex(32))")
python -m uvicorn app:from_environment --app-dir server --factory --host 127.0.0.1 --port 18123 --workers 1
```

访问 `http://127.0.0.1:18123/api/v1/health` 检查服务。Godot 调试客户端可用 `-- --auth-api=http://127.0.0.1:18123/api/v1` 连接本机实例。

SQLite 默认保存在启动目录的 `accounts.sqlite3`，可用 `AUTH_DATABASE` 指定路径。重复使用同一数据库时请复用原 `AUTH_SECRET`。如需发送验证码，配置 `RESEND_API_KEY_FILE` 或 `RESEND_API_KEY`，并将 `MAIL_FROM` 设为已验证的发件地址。

在项目根目录运行 `python -m unittest discover -s tests -p "test_leaderboard_*.py"` 可执行隔离的服务端回归。手势识别回归使用 `python -m unittest discover -s gesture/tests`。

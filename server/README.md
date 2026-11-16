# PSI HAND 账号服务

服务提供邮箱验证码注册、邮箱密码登录、密码重置、会话续期、退出账号、自定义显示名和云存档。API 前缀为 `/api/v1`。云存档 schema 3 与 Nginx 80k 请求限制已部署至 `game.dukechen.top`；部署备份、健康检查和公网接口验证记录见 [cloud-saves.md](../docs/ai/cloud-saves.md)。客户端双设备完整 E2E 仍待最终验收，不能据此宣称跨设备闭环已完成。账号接入与验收见 [accounts.md](../docs/ai/accounts.md)。

注册可携带 `username`（2～24 字，支持 Unicode 字母、数字、空格、下划线和连字符，允许重名）；`PATCH /api/v1/me` 使用 Bearer 会话修改当前账号显示名，登录仍用邮箱。schema 1 自动迁移到 2，保留原密码哈希和会话，旧账号/旧客户端会获得默认显示名。密码原样处理、区分大小写，支持数字与大小写字母；注册和密码重置长度为 8～128 字符，登录继续接受 1～128 字符以兼容旧账号。

云档服务将 schema 1/2 升级到 3。发布包含 `cloud_saves.py / save_payload.py / request_limits.py`；旧账号版不能直接读取 schema 3，回滚须同步考虑数据库兼容性。云档接口仅接受当前账号会话，使用 revision 条件写入和 operation_id 幂等；账号请求仍限制 8 KiB，云档 PUT 请求封装限制 80 KiB、规范载荷限制 64 KiB。生产 Nginx 已加载 80k 限制。

请求字段校验错误（HTTP 422）返回不包含提交字段值的固定错误码：`invalid_password_length`（密码长度不符，固定提示 8-128 字符）、`invalid_email`（邮箱格式无效）、`invalid_code_input`（验证码或挑战 ID 格式无效）、`invalid_username`（显示名不符合规则）；其他字段错误使用 `invalid_input`。验证码内容错误或过期仍返回 `invalid_code`。

## 运行

Python 3.12，先在独立虚拟环境安装 `requirements.txt`。生产入口：

```text
python -m uvicorn app:from_environment --factory --host 127.0.0.1 --port 18123 --workers 1
```

配置项：

| 环境变量 | 内容 |
|---|---|
| `AUTH_SECRET` | 至少 32 字符的安全随机服务端密钥，用于验证码 HMAC 和待发邮件加密；必须固定保留。 |
| `AUTH_DATABASE` | SQLite 文件路径，默认 `/var/lib/psi-hand-api/accounts.sqlite3`。 |
| `RESEND_API_KEY_FILE` | 权限受限的 Key 文件路径；生产使用此项。 |
| `RESEND_API_KEY` | 仅未指定 Key 文件时使用的环境变量备选，不放在启动命令参数里。 |
| `MAIL_FROM` | 默认 `PSI HAND <noreply@mail.game.dukechen.top>`，必须使用已验证发信域。 |
| `MAIL_DAILY_LIMIT` | 项目每日邮件申请上限，默认 90；按 UTC 日重置。 |

不提供内置测试密码、万能验证码或公开调试收件箱。没有发信渠道时验证码申请返回 503，不能伪造发送成功。`GET /api/v1/health` 不暴露配置。

`deploy/` 是当前 DMIT 的实际布局：原公网入口已转发普通 HTTPS 到 Nginx 的回环 8001 端口，因此 HTTPS 站点不直接监听公网 443。不要把该端口布局当成任意服务器的通用安装方式。

## 当前运维

```text
systemctl status psi-hand-api
systemctl restart psi-hand-api
journalctl -u psi-hand-api --since today
systemctl list-timers psi-hand-certificate.timer
nginx -t
```

Key 位于 `/etc/psi-hand-api/resend.key`（root:psi-hand-api，0640）；其他运行配置位于 `/etc/psi-hand-api/service.env`（root，0600）。调整 Key 后重启独立账号服务即可，不需要重启已有转发服务。

SQLite 启用 WAL，必须用 SQLite backup API 做一致性备份；不能只复制正在写入的主文件。异机备份与恢复演练属于后续收尾阶段。生产仅运行一个 worker，邮件 outbox 由同进程后台工作器处理。

所有业务写入使用参数化 SQL、事务和唯一约束。验证码错误次数必须在返回失败前提交；重发成功才作废旧码；密码校验与创建会话之间须重新核对密码哈希，避免并发重置产生旧密码新会话。

当前 443 前置转发未保留源 IP，IP 桶可能被用户共享；扩大规模前应处理可信源地址传递。不要接受客户端任意传入的 X-Forwarded-For 来绕过这一限制。

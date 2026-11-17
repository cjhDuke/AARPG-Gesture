# 云存档回归

测试数据与凭据仅放在被忽略的 `.stage1_checks/`，不得使用玩家的 APPDATA 或把凭据提交到 Git。测试脚本不发送邮件，不内置账号或绕过正式鉴权；生产测试仅使用明确创建的临时账号，结束后精确清理这些账号。

`storage_safety.gd` 是无需服务器的 21 项回归。将 `APPDATA` 指向项目 `.stage1_checks/storage-safety-profile`，用 Godot 4.6.3 执行：

```text
Godot --headless --audio-driver Dummy --path <project> --script <project>/tests/cloud/storage_safety.gd -- --no-gesture-autostart
```

`run_e2e.py` 启动两个独立 APPDATA 的图形客户端，测试游客复制导入、后台上传、另一客户端下载并实际读档、离线队列重启、修改冲突保留两份、删除冲突、墓碑、账号隔离与练习场禁写。默认静音、禁止自动启动摄像头；`--headless` 可跳过截图。

先在 `.stage1_checks/cloud-test-config.json` 填入两个专用临时账号的 `email/password/owner` 与 `other_email/other_password/other_owner`（owner 为服务端用户 UUID），以及 `base_url` 和项目内 `.stage1_checks/cloud-e2e` 的绝对路径 `state_dir`。应在空云档账号上按顺序执行；`--fresh` 只清本测试的本机 A/B 目录，不清服务器。

runner 将 `base_url` 作为调试客户端的 `--auth-api` 参数，隔离本机联调应填写回环测试服务地址。不要省略地址后误用默认生产服务。

```text
python tests/cloud/run_e2e.py --godot <Godot.exe> --fresh
```

失败时保留服务端及本机状态用于诊断；修复后可用 `--from <phase>` 或 `--only <phase>` 继续。不要在已执行后续阶段的状态上盲目重跑前序阶段。密码会在输出中遮盖，配置和用户目录仍属于敏感临时文件，验收后应删除。

runner 保留详细引擎日志以识别 Dummy 图形测试的旧音频退出告警；仅当资源路径和类型明确为标题 `waves.mp3` / `menu_focus.wav`，且与末尾清理错误的数量一致时豁免该清理错误。脚本错误、功能断言及其他资源/同步错误仍阻止通过。`ui_probe` 是不写云档的额外弹窗摘要探针，可在主流程完成后单独运行。

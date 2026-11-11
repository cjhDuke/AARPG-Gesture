# AARPG-Gesture

手势控制的 2D 像素"手引生存"小游戏（Godot 4.6 + Python/OpenCV）。开始任何工作前先读下面两份文档，不必重新扫描整个项目：

- @docs/ai/INDEX.md —— 项目结构、输入系统、运行环境
- @docs/ai/survival-mode-plan.md —— 当前方案和进度：手引生存模式，手的位置控制走位，握拳操控回旋镖
- docs/ai/guard-mode-plan.md —— 已被取代的站桩守卫方案，仅作历史记录
- docs/ai/gesture-plan.md —— 已被取代的旧方案（MediaPipe），仅作历史记录

约定：
- 本项目是数字图像处理课程项目：输入必须是图像 / 视频，识别用传统图像处理（可调用 OpenCV）。
- 修改代码后，同步更新 `docs/ai/` 下对应文档。
- 功能大改或重要 bug 修复完成后可直接本地 git commit 并写好说明，不必询问；push 和删除原 Demo 仍需用户确认。
- 每当游戏处于可导出、可玩的状态，直接导出 Windows exe 到 `build/`，并删除旧版只留最新一份（`gesture/` 要复制到 exe 旁边）。
- 具体编码任务可交给 Sonnet / Haiku 子代理执行，以节省额度。

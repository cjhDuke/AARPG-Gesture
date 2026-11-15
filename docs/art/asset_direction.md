# UI／图标／字体：阶段 2 实现与验收

## 已批准方向与阶段边界

用户已批准中世纪像素地牢风格：深棕黑 `#211a20`、木棕 `#47312a`、旧铜金 `#bf8b45`、象牙 `#f3dfae` 与念力青 `#68d5dc`。实际界面以 480×270 逻辑分辨率排版，使用硬边、窄铜框、铆钉及最近邻纹理；旧静态提案已清理，以下真实游戏截图为当前审核依据。

阶段 1 视觉方案已批准；阶段 2 的其它 UI／图标／字体已有验收记录，待用户审核。三选一技能说明已完成独立布局矩阵验收：Godot 4.6.3 导入解析 exit 0，`headless.log` 与 `visual.log` 均记录 `LAYOUT_CHECK_PASS CASES=75 CARDS=225 FAILURES=0`。阶段 3 攻击特效待审核，本阶段不改攻击动画或特效资源，保留候选图与下文候选记录。最新正式 exe 已重新导出并完成独立图形启动验证，本轮不做真实摄像头测试。

维护入口见 [UI 模块记忆](../ai/ui-art.md)；主题及许可细节见 [主题资源说明](../../ui/theme/asset_sources.md)，强化映射见 [技能图标来源](../../ui/skill_icons/asset_sources.md)。

## 实际主题与字体

- `ui/theme/dungeon_theme.gd`（DungeonTheme）提供统一字体、颜色、THEME 和 `panel(selected)`／`draw_panel()`；`dungeon_theme.tres` 统一 Button 状态、PanelContainer、Label，并由 `project.godot` 的 `gui/theme/custom` 全局接入。
- `panel/selected/hover/pressed/disabled.png` 是程序绘制的 16×16 原生像素九宫格，不是素材包宣传图；共享 StyleBox 作为只读资源使用。
- 标题字体 `ui/fonts/dungeon_font.ttf` 原样复制自 `D:\文件\AARPG Resource\Assets\DungeonFont.ttf`；PSI HAND 使用 48px，按逐字宽度与阴影居中。其导入关闭抗锯齿、hinting 和 subpixel，oversampling=1。正文继续使用 `ui/fonts/abaddon_light.ttf`，主题默认 12px。两款字体均无中文字形，游戏文案保持英文。
- 标题显式接入 Theme，保留原地牢小剧场、ALWAYS 动画父节点、落字／跳过、回旋镖选择标记、START → load_new_level、QUIT 和练习标记。

## 已接入素材映射

技能图标源目录：`D:\文件\AARPG Resource\Assets\skill\skill_icons_by_quintino_pixels\24x24\`。以下 PNG 原样复制到 `ui/skill_icons/`，保留自带边框；`Upgrades.ICON_TEXTURES` 维护语义映射，弹窗使用 48×48（2 倍最近邻），HUD 使用原生 24×24，等级点列位于下方。

| 语义 / id | 项目文件 | 源文件 |
|---|---|---|
| PSI BLAST / blast | `blast.png` | `skill_icons24.png` |
| HEAVY RANG / pierce | `pierce.png` | `skill_icons14.png` |
| MAGNET / magnet | `magnet.png` | `skill_icons25.png` |
| FROST TRAIL / frost | `frost.png` | `skill_icons19.png` |
| PSI POOL / pool | `pool.png` | `skill_icons53.png` |
| WIDE SPIN / wide_spin | `wide_spin.png` | `skill_icons6.png` |
| PARRY / parry | `parry.png` | `skill_icons22.png` |
| HEART / heart | `heart.png` | `skill_icons16.png` |
| SHOCKWAVE / shockwave（仅练习场实验项） | `shockwave.png` | `skill_icons5.png` |

三选一卡片当前为 132×158、间距 10；名称、NEW／等级和效果说明使用实际等级表，说明用显式换行给每个独立效果分行，最多三行，未修改强化数值。说明区为卡片内 `(10, 104)` 的 112×46 区域，底边为 y=150、距卡片底边保留 8px，12px 文字配 0 行距；名称、等级和说明均先启用自动换行并锁定 112px 内宽，配置字体与行距后再设置文本，避免整句最小宽度撑出卡片。仍支持左右／A D 切换、回车／空格／J 或鼠标确认；400ms 确认锁、不可取消与暂停流程保留，手势不参与菜单。布局矩阵已通过，最新正式 exe 已重新导出并验证。

UI 图集 `ui/theme/ui_icons.png` 原样复制自 `D:\文件\AARPG Resource\Assets\Free_Medieval_Fantasy_UI_Pack\icons3.png`（256×256），只导入这一张实际图集。暂停菜单（PauseMenu）的背包图标通过 AtlasTexture 从该图集取 `Rect2(224, 0, 32, 32)`；HUD 苹果格使用原 `levels/survival/pickups/items.png` 的 `Rect2(200, 8, 16, 16)`，血量及拾取物继续使用原游戏资源。Kibyra 的包允许个人及商业使用、署名可选，禁止原文件直接再分发／转售或冒充原创重传；不将此许可推定覆盖 DungeonFont 或技能图标包。

## 验收与预览

主审已逐个核对 9 张技巧图标的 SHA-256，均与源文件一致。强化 `LIST` 中除 `desc` 外的 id、名称、池标记和全部玩法字段与 HEAD 完全一致，主审已验证；本次只更新说明文本与布局。

2026-11-15 三选一说明布局矩阵验收通过。主审在沙箱外用 Godot 4.6.3 完成导入解析，exit 0、无 `ERROR`；`_ui_layout_check/headless.log` 与 `visual.log` 均有 `LAYOUT_CHECK_PASS CASES=75 CARDS=225 FAILURES=0`，覆盖 25 个等级 × 1280×720／1440×810／1920×1080，每 case 三张同技能卡片含选中与未选中。全部 Label 实际 rect 在左右 10px、底部 8px 内，`TextParagraph` 实际宽高不超过 Label，Label 与排版 line count 一致，desc 与数据一致、无 clip／省略且不超过 3 行。负向控制按旧顺序实际宽度 130px > 112px，复现旧 bug。图形日志无 `ERROR`，headless 仅有系统证书存储的沙箱警告。

六张真实窗口截图已由主审查看并确认视觉通过，待用户审核：[标题](ui_title.png)、[强化三选一](ui_upgrade.png)、[LV3 爆破／弹反／大回旋](ui_upgrade_details.png)、[暂停背包](ui_pause.png)、[HUD](ui_hud.png)、[结算](ui_result.png)。上述完整交互回归属于源码测试，未使用真实摄像头；源码窗口日志存在 shader cache 无法创建提示，无界面日志存在 UDP 47800 绑定失败提示。13 个识别端文件及练习场启动脚本均已与源文件逐个核对 SHA-256；补齐 `eval_recording.py`，删除构建目录中的 `__pycache__`，未复制 tests、fake_sender、recordings 或 cache。

最新正式成品 `build/AARPG-Gesture.exe` 已重新导出并验证：2026-11-15 14:17:38，116281592 bytes，导出 exit 0，导出日志无 `ERROR`、无 `_ui_layout_check`。新 exe 在沙箱外以 `--resolution 1920x1080 --position -2200,-2200 --quit-after 180 -- --no-gesture-autostart` 独立图形启动，exit 0，日志仅含 Godot 4.6.3 与 D3D12／RTX 4060 信息，无 `ERROR`。正式 exe 仅验证图形启动，未进行完整交互或真实摄像头测试；根目录导出与构建日志已复核后清理。

`docs/art/` 保留上述六张截图、本说明、`attack_candidates.png` 和空 `.gdignore`；新增的 `ui_upgrade_details.png` 是本轮必要验收交付。旧静态提案、UI／技能候选图及本目录内 `.import` 已删除。临时 `_ui_verify/`、`_ui_layout_check/` 及根目录 `_ui_engine.log`、`_ui_export.log`、`_ui_build.log`、`_ui_import.log` 已在证据留档后安全清理。阶段 3 候选联系表见 [attack_candidates.png](attack_candidates.png)，尚未接入，待审核。

## 阶段 3：保留的攻击特效候选（未接入、待审核）

| 语义 | 候选源文件 / 区域 | 待核实事项 |
|---|---|---|
| WIDE SPIN（旋转斩范围、击退） | `D:\文件\AARPG Resource\Assets\attck_effect\Part 4\184.png`；白色调色行第 6 行，64×64 网格，帧 1–3 | 大范围旋转环候选；联系表按 2 倍最近邻展示，与现有 `spin_effect.png` 是否重复／相似尚未核实。 |
| PSI BLAST（回旋镖结束时范围爆破） | `D:\文件\AARPG Resource\Assets\attck_effect\Part 9\436.png`；白色调色行第 6 行，64×64 网格，帧 1–3 | 螺旋爆发候选；与现有 `psi_blast.png` 是否重复／相似尚未核实。 |

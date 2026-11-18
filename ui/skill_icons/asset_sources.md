# 技巧图标来源与接入

图标来自 [Quintino Pixels 的 Free Pixel Art Skill Icons Pack](https://quintino-pixels.itch.io/free-pixel-art-skill-icons-pack) 中的 `24x24/` 目录。PNG 原样复制，保留 24×24 像素与图内自带边框；使用时最近邻缩放。

| 项目文件 | 来源文件 | 原图辨识 |
|---|---|---|
| `blast.png` | `skill_icons24.png` | 蓝色旋涡 |
| `pierce.png` | `skill_icons14.png` | 红色投射武器 |
| `magnet.png` | `skill_icons25.png` | 粉色弯钩状吸引符号（按批准映射） |
| `frost.png` | `skill_icons19.png` | 蓝色冰晶 |
| `pool.png` | `skill_icons53.png` | 紫色能量槽 |
| `wide_spin.png` | `skill_icons6.png` | 橙白环形扫击 |
| `parry.png` | `skill_icons22.png` | 蓝色盾牌 |
| `heart.png` | `skill_icons16.png` | 红心 |
| `shockwave.png` | `skill_icons5.png` | 金色能量环 |

`levels/survival/upgrades.gd` 的 `ICON_TEXTURES` 维护语义映射，`draw_icon()` API 保留；`Icon` 默认 24px，等级点位于图标下方额外 5px 区域，不遮主体。HUD 调用方仍须使用 24px 尺寸及足够间距。

三选一卡片在 `levels/survival/upgrade_menu.gd`：132×158、间距 10、图标 48×48，统一调用 `DungeonTheme` 的面板、正文与颜色。描述直接读取原等级表，由 Label 自动换行，不截断效果或改数值。交互、暂停与 400ms 确认锁沿用原逻辑。

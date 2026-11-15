class_name DungeonTheme extends RefCounted
## Shared palette, typography and native-pixel nine-patch panels.
const BODY_FONT: Font = preload("res://ui/fonts/abaddon_light.ttf")
const TITLE_FONT: Font = preload("res://ui/fonts/dungeon_font.ttf")
const THEME: Theme = preload("res://ui/theme/dungeon_theme.tres")
const BACKGROUND: Color = Color("#211a20")
const PANEL: Color = Color("#47312a")
const GOLD: Color = Color("#bf8b45")
const GOLD_BRIGHT: Color = Color("#f3dfae")
const TEXT: Color = Color("#f3dfae")
const MUTED: Color = Color("#b7a895")
const PSI: Color = Color("#68d5dc")


static func panel(selected: bool = false) -> StyleBox:
	return THEME.get_stylebox("selected" if selected else "panel", "Dungeon")


static func draw_panel(canvas: CanvasItem, rect: Rect2, selected: bool = false) -> void:
	canvas.draw_style_box(panel(selected), rect)

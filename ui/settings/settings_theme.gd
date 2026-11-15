extends RefCounted
## Small, shared skin for the settings panel and its HUD entrance.

const GOLD := DungeonTheme.GOLD
const INK := DungeonTheme.TEXT

static func flat(color: Color, border: Color, width := 1) -> StyleBoxFlat:
	var skin := StyleBoxFlat.new()
	skin.bg_color = color
	skin.border_color = border
	skin.set_border_width_all(width)
	return skin

static func make_theme() -> Theme:
	var theme := DungeonTheme.THEME.duplicate() as Theme
	theme.set_font_size("font_size", "Button", 12)
	for state in ["normal", "hover", "pressed", "disabled"]:
		var style := theme.get_stylebox(state, "Button").duplicate() as StyleBox
		style.set_content_margin(SIDE_LEFT, 6)
		style.set_content_margin(SIDE_RIGHT, 6)
		style.set_content_margin(SIDE_TOP, 4)
		style.set_content_margin(SIDE_BOTTOM, 4)
		theme.set_stylebox(state, "Button", style)
	theme.set_stylebox("hover_pressed", "Button", theme.get_stylebox("pressed", "Button"))
	theme.set_stylebox("slider", "HSlider", flat(DungeonTheme.BACKGROUND, DungeonTheme.MUTED))
	theme.set_stylebox("grabber_area", "HSlider", flat(DungeonTheme.PANEL, GOLD))
	theme.set_stylebox("grabber_area_highlight", "HSlider", flat(GOLD, INK))
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([GOLD, INK])
	var grabber := GradientTexture2D.new()
	grabber.gradient = gradient
	grabber.width = 8
	grabber.height = 12
	theme.set_icon("grabber", "HSlider", grabber)
	theme.set_icon("grabber_highlight", "HSlider", grabber)
	theme.set_icon("grabber_disabled", "HSlider", grabber)
	theme.set_stylebox("focus", "HSlider", flat(Color.TRANSPARENT, GOLD))
	return theme

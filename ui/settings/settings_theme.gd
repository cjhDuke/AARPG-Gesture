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
	# Category tabs use a flat strip, separate from framed action buttons.
	theme.set_type_variation("SettingsTab", "Button")
	theme.set_font_size("font_size", "SettingsTab", 14)
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var selected := state in ["pressed", "hover_pressed"]
		var hovered := state in ["hover", "hover_pressed"]
		var background := GOLD if selected else DungeonTheme.BACKGROUND
		if hovered:
			background = DungeonTheme.GOLD_BRIGHT if selected else DungeonTheme.PANEL
		var style := flat(background, DungeonTheme.GOLD_BRIGHT if selected else DungeonTheme.PANEL, 0)
		style.border_width_bottom = 3 if selected else 1
		style.set_content_margin(SIDE_LEFT, 8)
		style.set_content_margin(SIDE_RIGHT, 8)
		style.set_content_margin(SIDE_TOP, 3)
		style.set_content_margin(SIDE_BOTTOM, 5)
		theme.set_stylebox(state, "SettingsTab", style)
	for state: String in ["font_color", "font_hover_color", "font_disabled_color"]:
		theme.set_color(state, "SettingsTab", DungeonTheme.TEXT if state == "font_hover_color" else DungeonTheme.MUTED)
	theme.set_color("font_pressed_color", "SettingsTab", DungeonTheme.BACKGROUND)
	theme.set_color("font_hover_pressed_color", "SettingsTab", DungeonTheme.BACKGROUND)
	var tab_focus := flat(Color.TRANSPARENT, DungeonTheme.GOLD_BRIGHT)
	tab_focus.expand_margin_left = -2
	tab_focus.expand_margin_right = -2
	tab_focus.expand_margin_top = -2
	tab_focus.expand_margin_bottom = -4
	theme.set_stylebox("focus", "SettingsTab", tab_focus)
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

class_name GameSettings
extends RefCounted
## Persistent player settings. No Autoload is required.
## Audio and UI palette are stored in user://settings.cfg.

const PATH := "user://settings.cfg"
const BUS_MUSIC := "Music"
const BUS_SFX := "SFX"
const VOICE_PTT_ACTION := "voice_push_to_talk"

const DISPLAY_MODE_WINDOWED := "windowed"
const DISPLAY_MODE_BORDERLESS := "borderless"
const DISPLAY_MODE_FULLSCREEN := "fullscreen"
const DISPLAY_MODES: Array[String] = [
	DISPLAY_MODE_WINDOWED,
	DISPLAY_MODE_BORDERLESS,
	DISPLAY_MODE_FULLSCREEN,
]

const PALETTE_ORDER: Array[String] = ["classic", "ocean", "royal", "forest"]
const PALETTES := {
	"classic": {
		"title": "Classic",
		"description": "Тёплая золотисто-коричневая тема",
		"background": Color("#1D120C"),
		"panel": Color("#281B12"),
		"panel_alt": Color("#24170F"),
		"button": Color("#2B1A12"),
		"border": Color("#8A6A3A"),
		"border_soft": Color("#725532"),
		"border_dim": Color("#51412D"),
		"text": Color("#F3E6C8"),
		"muted": Color("#A8957A"),
		"gold": Color("#E8C36A"),
		"accent": Color("#C98A2B"),
		"accent_hover": Color("#49301C"),
		"accent_text": Color("#241505"),
		"focus": Color("#FFE9A8"),
		"button_pressed": Color("#17100B"),
		"button_disabled": Color("#211A14")
	},
	"ocean": {
		"title": "Ocean",
		"description": "Холодная сине-бирюзовая тема",
		"background": Color("#101D25"),
		"panel": Color("#172A35"),
		"panel_alt": Color("#1C3440"),
		"button": Color("#1B3541"),
		"border": Color("#3F8291"),
		"border_soft": Color("#356D7D"),
		"border_dim": Color("#294C59"),
		"text": Color("#DFEFF4"),
		"muted": Color("#8CAEB8"),
		"gold": Color("#75C7D8"),
		"accent": Color("#267F93"),
		"accent_hover": Color("#315A68"),
		"accent_text": Color("#071C22"),
		"focus": Color("#B5F0FA"),
		"button_pressed": Color("#102630"),
		"button_disabled": Color("#1A2930")
	},
	"royal": {
		"title": "Royal",
		"description": "Сдержанная фиолетовая тема",
		"background": Color("#171923"),
		"panel": Color("#23263A"),
		"panel_alt": Color("#2E304A"),
		"button": Color("#292B43"),
		"border": Color("#756AA0"),
		"border_soft": Color("#625782"),
		"border_dim": Color("#45445F"),
		"text": Color("#EFEAFF"),
		"muted": Color("#ACA5C5"),
		"gold": Color("#A89CEB"),
		"accent": Color("#7565B5"),
		"accent_hover": Color("#493F70"),
		"accent_text": Color("#151027"),
		"focus": Color("#D3C9FF"),
		"button_pressed": Color("#1A1B2B"),
		"button_disabled": Color("#242537")
	},
	"forest": {
		"title": "Forest",
		"description": "Тёмно-зелёная природная тема",
		"background": Color("#171C17"),
		"panel": Color("#222D20"),
		"panel_alt": Color("#2C3928"),
		"button": Color("#263322"),
		"border": Color("#718A58"),
		"border_soft": Color("#61784D"),
		"border_dim": Color("#46553A"),
		"text": Color("#E6EEDB"),
		"muted": Color("#A4B196"),
		"gold": Color("#A6C47A"),
		"accent": Color("#6E8B4C"),
		"accent_hover": Color("#40543B"),
		"accent_text": Color("#15200F"),
		"focus": Color("#D4E9B4"),
		"button_pressed": Color("#182317"),
		"button_disabled": Color("#20291E")
	}
}

static var music_volume := 0.7
static var sfx_volume := 0.8
static var mouse_look := true
## Дублирующие кнопки подсказки/сброса поверх игрового изображения.
## На телефонах включены по умолчанию, на ПК — выключены.
static var show_camera_action_buttons := OS.has_feature("mobile")
static var music_track := ""
static var palette_id := "classic"
static var display_mode := DISPLAY_MODE_WINDOWED
static var voice_volume := 0.8
## input_volume_threshold: меньшее значение делает микрофон чувствительнее.
static var voice_input_threshold := 0.01
## GD-Sync: 0 = очень высокое качество, 3 = низкое.
static var voice_quality := 2
static var voice_ptt_keycode: int = KEY_V
static var _loaded := false
static var _windowed_rect_saved := false
static var _saved_window_size := Vector2i.ZERO
static var _saved_window_position := Vector2i.ZERO
static var _saved_window_mode: int = DisplayServer.WINDOW_MODE_WINDOWED


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var cfg := ConfigFile.new()
	var has_saved_display_mode := false
	if cfg.load(PATH) == OK:
		music_volume = clampf(float(cfg.get_value("audio", "music", music_volume)), 0.0, 1.0)
		sfx_volume = clampf(float(cfg.get_value("audio", "sfx", sfx_volume)), 0.0, 1.0)
		mouse_look = bool(cfg.get_value("camera", "mouse_look", mouse_look))
		show_camera_action_buttons = bool(cfg.get_value("game_ui", "camera_action_buttons", show_camera_action_buttons))
		music_track = str(cfg.get_value("audio", "track", music_track))
		palette_id = str(cfg.get_value("visual", "palette", palette_id))
		voice_volume = clampf(float(cfg.get_value("voice", "volume", voice_volume)), 0.0, 1.0)
		voice_input_threshold = clampf(float(cfg.get_value("voice", "input_threshold", voice_input_threshold)), 0.001, 0.1)
		voice_quality = clampi(int(cfg.get_value("voice", "quality", voice_quality)), 0, 3)
		voice_ptt_keycode = int(cfg.get_value("voice", "ptt_keycode", voice_ptt_keycode))
		if cfg.has_section_key("display", "mode"):
			display_mode = _normalize_display_mode(str(cfg.get_value("display", "mode", DISPLAY_MODE_WINDOWED)))
			has_saved_display_mode = true
		else:
			display_mode = _detect_display_mode()
	else:
		display_mode = _detect_display_mode()
	if not PALETTES.has(palette_id):
		palette_id = "classic"
	_ensure_bus(BUS_MUSIC)
	_ensure_bus(BUS_SFX)
	apply_audio()
	apply_voice_input()
	if has_saved_display_mode and is_display_mode_supported():
		_apply_display_mode(display_mode)


static func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "music", music_volume)
	cfg.set_value("audio", "sfx", sfx_volume)
	cfg.set_value("camera", "mouse_look", mouse_look)
	cfg.set_value("game_ui", "camera_action_buttons", show_camera_action_buttons)
	cfg.set_value("audio", "track", music_track)
	cfg.set_value("visual", "palette", palette_id)
	cfg.set_value("display", "mode", display_mode)
	cfg.set_value("voice", "volume", voice_volume)
	cfg.set_value("voice", "input_threshold", voice_input_threshold)
	cfg.set_value("voice", "quality", voice_quality)
	cfg.set_value("voice", "ptt_keycode", voice_ptt_keycode)
	var err := cfg.save(PATH)
	if err != OK:
		push_warning("GameSettings: не удалось сохранить настройки (%d)." % err)


## Desktop display modes are hidden on mobile devices and web exports.
static func is_display_mode_supported() -> bool:
	return not OS.has_feature("mobile") and not OS.has_feature("web")


static func _normalize_display_mode(value: String) -> String:
	return value if DISPLAY_MODES.has(value) else DISPLAY_MODE_WINDOWED


static func _detect_display_mode() -> String:
	if not is_display_mode_supported():
		return DISPLAY_MODE_WINDOWED
	var current_mode := DisplayServer.window_get_mode()
	if current_mode == DisplayServer.WINDOW_MODE_FULLSCREEN or current_mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
		return DISPLAY_MODE_FULLSCREEN
	if DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_BORDERLESS):
		return DISPLAY_MODE_BORDERLESS
	return DISPLAY_MODE_WINDOWED


static func set_display_mode(value: String) -> void:
	ensure_loaded()
	if not is_display_mode_supported():
		return
	var next_mode := _normalize_display_mode(value)
	if next_mode == display_mode:
		return
	display_mode = next_mode
	_apply_display_mode(display_mode)
	save()


static func _capture_windowed_rect() -> void:
	if _windowed_rect_saved:
		return
	var current_mode := DisplayServer.window_get_mode()
	if current_mode != DisplayServer.WINDOW_MODE_WINDOWED and current_mode != DisplayServer.WINDOW_MODE_MAXIMIZED:
		return
	if DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_BORDERLESS):
		return
	_saved_window_mode = current_mode
	_saved_window_size = DisplayServer.window_get_size()
	_saved_window_position = DisplayServer.window_get_position()
	_windowed_rect_saved = true


static func _apply_display_mode(value: String) -> void:
	if not is_display_mode_supported():
		return
	var mode := _normalize_display_mode(value)
	if mode != DISPLAY_MODE_WINDOWED:
		_capture_windowed_rect()

	match mode:
		DISPLAY_MODE_WINDOWED:
			# Fullscreen forces borderless=true, so clear the flag before restoring a normal window.
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			if _windowed_rect_saved:
				DisplayServer.window_set_size(_saved_window_size)
				DisplayServer.window_set_position(_saved_window_position)
				if _saved_window_mode == DisplayServer.WINDOW_MODE_MAXIMIZED:
					DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
				_windowed_rect_saved = false
		DISPLAY_MODE_BORDERLESS:
			# Borderless covers the current monitor but remains a desktop window.
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
			var screen := DisplayServer.window_get_current_screen()
			if screen < 0:
				screen = DisplayServer.get_primary_screen()
			var screen_size := DisplayServer.screen_get_size(screen)
			if screen_size != Vector2i.ZERO:
				DisplayServer.window_set_size(screen_size)
				DisplayServer.window_set_position(DisplayServer.screen_get_position(screen))
		DISPLAY_MODE_FULLSCREEN:
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


static func get_palette(id: String = "") -> Dictionary:
	ensure_loaded()
	var key := id if PALETTES.has(id) else palette_id
	return PALETTES[key]


static func get_color(role: String) -> Color:
	var palette := get_palette()
	if palette.has(role) and typeof(palette[role]) == TYPE_COLOR:
		return palette[role]
	var fallback: Variant = PALETTES["classic"].get(role, Color.WHITE)
	return fallback if typeof(fallback) == TYPE_COLOR else Color.WHITE


static func set_palette(id: String) -> void:
	ensure_loaded()
	if not PALETTES.has(id):
		return
	palette_id = id
	save()
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		apply_palette_tree((main_loop as SceneTree).root)


static func apply_palette_tree(root: Node) -> void:
	ensure_loaded()
	if root == null or not is_instance_valid(root):
		return
	_apply_palette_recursive(root)


static func _apply_palette_recursive(node: Node) -> void:
	# PopupMenu is a Window-like node, so it needs its own explicit theme.
	if node is PopupMenu:
		_apply_popup_menu_palette(node as PopupMenu)

	if node is Control and not node.has_meta("skip_palette_recolor"):
		var control := node as Control
		for color_name in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_disabled_color"]:
			if control.has_theme_color_override(color_name):
				var old_color := control.get_theme_color(color_name)
				var new_color := _map_palette_color(old_color)
				if not new_color.is_equal_approx(old_color):
					control.add_theme_color_override(color_name, new_color)

		for style_name in ["normal", "hover", "pressed", "focus", "disabled", "panel", "slider", "grabber_area", "grabber_area_highlight", "tab_selected", "tab_unselected", "tab_hovered", "tab_disabled"]:
			if not control.has_theme_stylebox_override(style_name):
				continue
			var source := control.get_theme_stylebox(style_name)
			if source is StyleBoxFlat:
				var style := (source as StyleBoxFlat).duplicate() as StyleBoxFlat
				style.bg_color = _map_palette_color(style.bg_color)
				style.border_color = _map_palette_color(style.border_color)
				control.add_theme_stylebox_override(style_name, style)

		if control is OptionButton:
			apply_option_button_palette(control as OptionButton)
		elif control is MenuButton:
			_apply_popup_menu_palette((control as MenuButton).get_popup())

	for child in node.get_children():
		_apply_palette_recursive(child)


static func apply_option_button_palette(button: OptionButton) -> void:
	if button == null or not is_instance_valid(button):
		return
	button.add_theme_stylebox_override("normal", _palette_style(get_color("button"), get_color("border"), 7))
	button.add_theme_stylebox_override("hover", _palette_style(get_color("accent_hover"), get_color("gold"), 7))
	button.add_theme_stylebox_override("pressed", _palette_style(get_color("button_pressed"), get_color("gold"), 7))
	button.add_theme_stylebox_override("focus", _palette_style(get_color("button"), get_color("focus"), 7))
	button.add_theme_stylebox_override("disabled", _palette_style(get_color("button_disabled"), get_color("border_dim"), 7))
	button.add_theme_color_override("font_color", get_color("text"))
	button.add_theme_color_override("font_hover_color", get_color("text"))
	button.add_theme_color_override("font_pressed_color", get_color("text"))
	button.add_theme_color_override("font_disabled_color", get_color("muted"))
	_apply_popup_menu_palette(button.get_popup())


static func _apply_popup_menu_palette(popup: PopupMenu) -> void:
	if popup == null or not is_instance_valid(popup):
		return
	# Alpha is forced to 1.0: no translucent grey OS-style dropdown remains.
	popup.add_theme_stylebox_override("panel", _palette_style(get_color("panel"), get_color("border"), 8))
	popup.add_theme_stylebox_override("hover", _palette_style(get_color("accent_hover"), get_color("gold"), 5))
	popup.add_theme_stylebox_override("pressed", _palette_style(get_color("button_pressed"), get_color("gold"), 5))
	popup.add_theme_stylebox_override("disabled", _palette_style(get_color("panel_alt"), get_color("border_dim"), 5))
	popup.add_theme_stylebox_override("separator", _palette_style(get_color("border_soft"), get_color("border_soft"), 0))
	popup.add_theme_stylebox_override("labeled_separator_left", _palette_style(get_color("border_soft"), get_color("border_soft"), 0))
	popup.add_theme_stylebox_override("labeled_separator_right", _palette_style(get_color("border_soft"), get_color("border_soft"), 0))
	popup.add_theme_color_override("font_color", get_color("text"))
	popup.add_theme_color_override("font_hover_color", get_color("text"))
	popup.add_theme_color_override("font_accelerator_color", get_color("muted"))
	popup.add_theme_color_override("font_disabled_color", get_color("muted"))
	popup.add_theme_color_override("font_separator_color", get_color("border_soft"))
	for index in popup.item_count:
		# get_item_submenu() returns a NodePath/StringName, not a PopupMenu.
		# Resolve that path before applying the palette to the actual submenu node.
		var submenu_path: StringName = popup.get_item_submenu(index)
		if not submenu_path.is_empty():
			var submenu_node := popup.get_node_or_null(NodePath(submenu_path))
			if submenu_node is PopupMenu:
				_apply_popup_menu_palette(submenu_node as PopupMenu)
	for child in popup.get_children():
		if child is PopupMenu:
			_apply_popup_menu_palette(child as PopupMenu)


static func _palette_style(bg: Color, border: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(bg.r, bg.g, bg.b, 1.0)
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	return style


static func _map_palette_color(value: Color) -> Color:
	# Recognize both the original Classic colors and every palette. This allows
	# switching repeatedly without losing the semantic role of a UI color.
	var legacy := {
		"background": Color("#1D120C"),
		"panel": Color("#281B12"),
		"panel_alt": Color("#24170F"),
		"button": Color("#2B1A12"),
		"border": Color("#8A6A3A"),
		"border_soft": Color("#725532"),
		"border_dim": Color("#51412D"),
		"text": Color("#F3E6C8"),
		"muted": Color("#A8957A"),
		"gold": Color("#E8C36A"),
		"accent": Color("#C98A2B"),
		"accent_hover": Color("#49301C"),
		"accent_text": Color("#241505"),
		"focus": Color("#FFE9A8"),
		"button_pressed": Color("#17100B"),
		"button_disabled": Color("#211A14")
	}
	for role in legacy:
		if value.is_equal_approx(legacy[role]):
			return get_color(str(role))
	for id in PALETTE_ORDER:
		var palette: Dictionary = PALETTES[id]
		for role in palette:
			if role == "title" or role == "description":
				continue
			if typeof(palette[role]) == TYPE_COLOR and value.is_equal_approx(palette[role]):
				return get_color(str(role))

	# Re-map lightened/darkened button states generated from any palette.
	for id in PALETTE_ORDER:
		var source_palette: Dictionary = PALETTES[id]
		for role in ["accent", "button"]:
			var source_color: Color = source_palette[role]
			if value.is_equal_approx(source_color.lightened(0.15)):
				return get_color(str(role)).lightened(0.15)
			if value.is_equal_approx(source_color.darkened(0.15)):
				return get_color(str(role)).darkened(0.15)
		for role in ["border", "gold"]:
			var source_color: Color = source_palette[role]
			if value.is_equal_approx(source_color.lightened(0.2)):
				return get_color(str(role)).lightened(0.2)
	return value


static func is_voice_key_binding_supported() -> bool:
	return not OS.has_feature("mobile") and not OS.has_feature("web")


static func set_voice_ptt_key(keycode: int) -> void:
	if not is_voice_key_binding_supported() or keycode <= 0:
		return
	voice_ptt_keycode = keycode
	apply_voice_input()
	save()


static func apply_voice_input() -> void:
	if not InputMap.has_action(VOICE_PTT_ACTION):
		InputMap.add_action(VOICE_PTT_ACTION)
	InputMap.action_erase_events(VOICE_PTT_ACTION)
	if is_voice_key_binding_supported() and voice_ptt_keycode > 0:
		var event := InputEventKey.new()
		event.physical_keycode = voice_ptt_keycode
		InputMap.action_add_event(VOICE_PTT_ACTION, event)



static func apply_audio() -> void:
	_set_bus(BUS_MUSIC, music_volume)
	_set_bus(BUS_SFX, sfx_volume)


static func _ensure_bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) != -1:
		return
	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, "Master")


static func _set_bus(bus_name: String, linear: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		return
	AudioServer.set_bus_mute(idx, linear <= 0.001)
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, 0.001)))

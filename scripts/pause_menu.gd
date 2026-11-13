class_name PauseMenu
extends CanvasLayer
## Меню паузы по ESC. Целиком строится в коде, GameManager добавляет его сам.
## Внутри фона главного меню (SubViewport) отключается.

signal lobby_requested

var _root: Control
var _page_main: VBoxContainer
var _page_settings: SettingsPanel
var _resume_button: Button
var _lobby_button: Button

const GOLD := Color("#e8c36a")
const TEXT := Color("#f3e6c8")


func _ready() -> void:
	layer = 50
	process_mode = Node.PROCESS_MODE_ALWAYS
	if get_viewport() is SubViewport:
		queue_free()
		return
	GameSettings.ensure_loaded()
	_build()
	_root.visible = false


func _input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	if _root.visible:
		if _page_settings.visible:
			_show_settings(false)
		else:
			_close()
	else:
		_open()
	get_viewport().set_input_as_handled()


# --- Открыть / закрыть ---

func _open() -> void:
	var cm := _find(get_tree().current_scene, func(n): return n is CardManager)
	if cm != null:
		cm._cancel_drag()
	_show_settings(false)
	_root.visible = true
	get_tree().paused = true
	_resume_button.grab_focus()


func _close() -> void:
	GameSettings.save()
	_root.visible = false
	get_tree().paused = false


func _show_settings(value: bool) -> void:
	_page_main.visible = not value
	_page_settings.visible = value
	if value:
		_page_settings.refresh()
		_page_settings.focus_back()
	else:
		GameSettings.save()
		_resume_button.grab_focus()


# --- Действия ---

func _on_restart() -> void:
	var gm := _find(get_tree().current_scene, func(n): return n is GameManager) as GameManager
	_close()
	if gm != null:
		gm.start_game(gm.current_mode)


func _on_create_or_find_lobby() -> void:
	# Защита на случай, если кнопка осталась в уже открытом меню.
	if NetworkMatchState.active or NetworkMatchSync.is_network_match():
		return
	# Не закрываем паузу: обработчик сетевого меню сам решит,
	# открывать ли LobbyMenu поверх игры или переходить в отдельную сцену.
	lobby_requested.emit()


func _on_to_menu() -> void:
	_close()
	var path := GameSession.MAIN_MENU_SCENE
	if not ResourceLoader.exists(path):
		path = str(ProjectSettings.get_setting("application/run/main_scene", ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		push_error("PauseMenu: не найдена сцена главного меню. Укажите путь в GameSession.MAIN_MENU_SCENE.")
		return
	get_tree().change_scene_to_file(path)


func _supports_lobby_for_current_game() -> bool:
	# Нельзя предлагать создание/поиск новой комнаты внутри активного матча.
	if NetworkMatchState.active or NetworkMatchSync.is_network_match():
		return false

	var gm := get_parent() as GameManager
	if gm == null:
		gm = _find(get_tree().current_scene, func(n): return n is GameManager) as GameManager
	if gm == null:
		return false

	var mode := gm.current_mode
	if mode != GameSession.MODE_SPIDER and mode != GameSession.MODE_KLONDIKE:
		mode = gm.mode_id
	var layout := GameSession.get_board_layout(mode)
	return (
		layout == GameSession.BOARD_LAYOUT_MIRRORED
		or layout == GameSession.BOARD_LAYOUT_RING
	)


# --- Построение интерфейса ---

func _build() -> void:
	_root = Control.new()
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.02, 0.01, 0.65)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var center := CenterContainer.new()
	_root.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var panel := PanelContainer.new()
	var panel_style := _box(Color("#1d120c"), Color("#8a6a3a"))
	panel_style.set_corner_radius_all(18)
	panel.add_theme_stylebox_override("panel", panel_style)
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 32)
	panel.add_child(margin)

	var stack := VBoxContainer.new()
	margin.add_child(stack)

	_page_main = _make_main_page()
	_page_settings = _make_settings_page()
	stack.add_child(_page_main)
	stack.add_child(_page_settings)
	_page_settings.visible = false


func _make_settings_page() -> SettingsPanel:
	var p := SettingsPanel.new()
	p.back_pressed.connect(func(): _show_settings(false))
	return p


func _make_main_page() -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	v.add_child(_label("Пауза", 44, GOLD))

	_resume_button = _button("Продолжить", _close, true)
	v.add_child(_resume_button)
	v.add_child(_button("Новая партия", _on_restart))
	v.add_child(_button("Настройки", func(): _show_settings(true)))

	if _supports_lobby_for_current_game():
		_lobby_button = _button("Создать / найти лобби", _on_create_or_find_lobby)
		v.add_child(_lobby_button)

	v.add_child(_button("В главное меню", _on_to_menu))
	return v


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _button(text: String, on_press: Callable, primary := false) -> Button:
	var b := Button.new()
	b.text = text
	var base := Color("#c98a2b") if primary else Color("#2b1a12")
	var border := Color("#e8c36a") if primary else Color("#8a6a3a")
	b.add_theme_stylebox_override("normal", _box(base, border))
	b.add_theme_stylebox_override("hover", _box(base.lightened(0.15), border.lightened(0.2)))
	b.add_theme_stylebox_override("pressed", _box(base.darkened(0.15), border))
	b.add_theme_stylebox_override("focus", _box(base.lightened(0.15), Color("#ffe9a8")))
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_font_size_override("font_size", 28 if primary else 24)
	b.custom_minimum_size = Vector2(380, 68 if primary else 58)
	b.pressed.connect(on_press)
	return b


func _box(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(2)
	s.set_corner_radius_all(14)
	s.shadow_color = Color(0, 0, 0, 0.45)
	s.shadow_size = 8
	s.content_margin_left = 24
	s.content_margin_right = 24
	return s


func _find(node: Node, test: Callable) -> Node:
	if node == null:
		return null
	if test.call(node):
		return node
	for c in node.get_children():
		var r := _find(c, test)
		if r != null:
			return r
	return null

extends Node3D
## Главное меню. Выбор режима и отдельно — сложность (под кнопкой «Режим»).

const MODE_SPIDER := 1
const MODE_KLONDIKE := 2
var _statistics_panel: StatisticsPanel
var _settings_overlay: Control
var _settings_panel: SettingsPanel
var _layout_selector: OptionButton
## Отдельная кнопка сложности на главном экране (под «Режим»)
var _diff_button: Button
## Оверлей выбора сложности
var _diff_overlay: Control
var _diff_title: Label
var _diff_options: VBoxContainer
var _diff_one_btn: Button
var _diff_three_btn: Button
var _diff_hint: Label

## Отдельная кнопка дополнительных правил выбранного режима
var _rules_settings_button: Button
## Оверлей дополнительных правил Draw 3
var _rules_settings_overlay: Control
var _rules_settings_title: Label
var _rules_settings_hint: Label
var _conveyor_toggle: CheckButton
var _shuffle_toggle: CheckButton
@export_file("*.tscn") var lobby_scene_path := "res://scenes/LobbyRoom.tscn"
var _lobby_button: Button

## «Настройки режима»: добор карт, раскладка и доп. правила в одном окне,
## чтобы не перегружать главный экран.
var _mode_settings_button: Button
var _mode_settings_overlay: Control
var _mode_settings_title: Label
var _ms_draw_box: VBoxContainer
var _ms_draw_one: Button
var _ms_draw_three: Button
var _ms_rules_box: VBoxContainer


func _ready() -> void:
	GameSettings.ensure_loaded()
	GameAudio.get_instance(get_tree()).play_music()
	if GameSession.mode == 0:
		GameSession.mode = MODE_KLONDIKE
	if GameSession.draw_mode == 0:
		GameSession.draw_mode = GameSession.DRAW_ONE

	%PlayButton.pressed.connect(_on_play)
	%ModeButton.pressed.connect(_open_modes)
	%StatsButton.pressed.connect(_on_stats)
	%SettingsButton.pressed.connect(_on_settings)
	%QuitButton.pressed.connect(get_tree().quit)

	%KlondikeButton.pressed.connect(_select_mode.bind(MODE_KLONDIKE))
	%SpiderButton.pressed.connect(_select_mode.bind(MODE_SPIDER))
	%BackButton.pressed.connect(_close_modes)

	for b: Button in [%ModeButton, %StatsButton, %SettingsButton, %QuitButton,
			%KlondikeButton, %SpiderButton, %BackButton]:
		_style_button(b)
	_style_button(%PlayButton, true)
	_style_panel(%ModePanel)

	%KlondikeButton.text = str(GameSession.MODE_NAMES[MODE_KLONDIKE])
	%SpiderButton.text = str(GameSession.MODE_NAMES[MODE_SPIDER])
	%SpiderButton.disabled = false

	_build_lobby_button()
	_build_difficulty_ui()
	_build_rules_settings_ui()
	_build_layout_ui()
	_build_mode_settings_ui()
	_build_settings_overlay()
	_update_mode_label()
	_update_diff_button()
	_update_layout_selector()
	GameSettings.apply_palette_tree(get_tree().root)

	%ModeOverlay.visible = false
	%PlayButton.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	if _settings_overlay != null and _settings_overlay.visible:
		_close_settings()
		get_viewport().set_input_as_handled()
	elif _mode_settings_overlay != null and _mode_settings_overlay.visible:
		_close_mode_settings()
		get_viewport().set_input_as_handled()
	elif _rules_settings_overlay != null and _rules_settings_overlay.visible:
		_close_rules_settings()
		get_viewport().set_input_as_handled()
	elif _diff_overlay != null and _diff_overlay.visible:
		_close_diff()
		get_viewport().set_input_as_handled()
	elif %ModeOverlay.visible:
		_close_modes()
		get_viewport().set_input_as_handled()


# --- Кнопки главного экрана ---
func _build_lobby_button() -> void:
	var play_button: Button = %PlayButton
	var parent := play_button.get_parent()
	_lobby_button = Button.new()
	_lobby_button.name = "LobbyButton"
	_lobby_button.text = "Лобби"
	_style_button(_lobby_button)
	_lobby_button.pressed.connect(_on_lobby)
	parent.add_child(_lobby_button)
	parent.move_child(_lobby_button, play_button.get_index() + 1)


func _on_lobby() -> void:
	if lobby_scene_path.is_empty() or not ResourceLoader.exists(lobby_scene_path):
		push_error("MainMenu: не найдена сцена лобби: %s" % lobby_scene_path)
		return
	var result := get_tree().change_scene_to_file(lobby_scene_path)
	if result != OK:
		push_error("MainMenu: не удалось открыть сцену лобби. Код: %d" % result)

func _build_layout_ui() -> void:
	var parent := _diff_button.get_parent()

	_layout_selector = OptionButton.new()
	_layout_selector.name = "LayoutSelector"

	_layout_selector.add_item(
		"Раскладка: Классическая",
		GameSession.BOARD_LAYOUT_CLASSIC
	)

	_layout_selector.add_item(
		"Раскладка: Отражённая",
		GameSession.BOARD_LAYOUT_MIRRORED
	)

	_layout_selector.add_item(
		"Раскладка: Круговая",
		GameSession.BOARD_LAYOUT_RING
	)

	_layout_selector.item_selected.connect(_on_layout_selected)

	parent.add_child(_layout_selector)

	# Размещаем сразу после выбора сложности.
	parent.move_child(_layout_selector, _diff_button.get_index() + 1)

	_style_button(_layout_selector)
	_layout_selector.add_theme_font_size_override("font_size", 20)
	_layout_selector.custom_minimum_size = Vector2(280, 60)

	_update_layout_selector()


func _on_layout_selected(index: int) -> void:
	var layout_id: int = _layout_selector.get_item_id(index)

	if GameSession.mode == MODE_SPIDER:
		GameSession.spider_board_layout = layout_id
	else:
		GameSession.klondike_board_layout = layout_id
	_update_mode_settings_button()

	print(
		"Раскладка сохранена. Режим: ",
		GameSession.mode,
		" Раскладка: ",
		layout_id
	)


func _update_layout_selector() -> void:
	if _layout_selector == null:
		return

	# Получаем раскладку именно текущего режима.
	var layout_id: int = GameSession.get_board_layout(GameSession.mode)

	var selected_index := _layout_selector.get_item_index(layout_id)

	if selected_index < 0:
		selected_index = 0
		layout_id = GameSession.BOARD_LAYOUT_CLASSIC

		if GameSession.mode == MODE_SPIDER:
			GameSession.spider_board_layout = layout_id
		else:
			GameSession.klondike_board_layout = layout_id

	_layout_selector.select(selected_index)

	# Раскладки доступны обоим режимам.
	_layout_selector.disabled = false

	_layout_selector.tooltip_text = (
        "Выбрать расположение игрового стола для текущего режима"
	)
	
func _on_play() -> void:
	var mode := GameSession.mode if GameSession.mode != 0 else MODE_KLONDIKE
	var path: String = str(GameSession.LEVEL_SCENES.get(mode, ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		push_error("Главное меню: сцена уровня не найдена: '%s' (режим %d)" % [path, mode])
		return
	var draw := GameSession.effective_draw_mode()
	GameSession.start_level(get_tree(), mode, draw)


func _on_stats() -> void:
	if is_instance_valid(_statistics_panel):
		_statistics_panel.queue_free()
	_statistics_panel = StatisticsPanel.new()
	add_child(_statistics_panel)
	_statistics_panel.closed.connect(func() -> void:
		_statistics_panel = null
	)


func _on_settings() -> void:
	_settings_panel.refresh()
	_settings_overlay.visible = true
	%Menu.process_mode = Node.PROCESS_MODE_DISABLED
	_settings_panel.focus_back()


func _close_settings() -> void:
	GameSettings.save()
	_settings_overlay.visible = false
	%Menu.process_mode = Node.PROCESS_MODE_INHERIT
	%SettingsButton.grab_focus()


# --- Выбор режима (только список режимов, без сложности) ---

func _open_modes() -> void:
	%ModeOverlay.visible = true
	%Menu.process_mode = Node.PROCESS_MODE_DISABLED
	%KlondikeButton.grab_focus()


func _close_modes() -> void:
	%ModeOverlay.visible = false
	%Menu.process_mode = Node.PROCESS_MODE_INHERIT
	%ModeButton.grab_focus()


func _select_mode(mode: int) -> void:
	GameSession.mode = mode
	_update_mode_label()
	_update_diff_button()
	_update_layout_selector()
	_close_modes()


# --- Настройки режима: добор, раскладка, доп. правила ---

func _build_mode_settings_ui() -> void:
	# Старые отдельные кнопки на главном экране больше не нужны — всё в одном окне.
	_diff_button.visible = false
	_rules_settings_button.visible = false

	var mode_btn: Button = %ModeButton
	var parent := mode_btn.get_parent()
	_mode_settings_button = Button.new()
	_mode_settings_button.name = "ModeSettingsButton"
	_mode_settings_button.text = "Настройки режима"
	_style_button(_mode_settings_button)
	_mode_settings_button.pressed.connect(_open_mode_settings)
	parent.add_child(_mode_settings_button)
	parent.move_child(_mode_settings_button, mode_btn.get_index() + 1)

	_mode_settings_overlay = Control.new()
	_mode_settings_overlay.name = "ModeSettingsOverlay"
	_mode_settings_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_mode_settings_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	%ModeOverlay.get_parent().add_child(_mode_settings_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.02, 0.01, 0.6)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed:
			_close_mode_settings()
	)
	_mode_settings_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mode_settings_overlay.add_child(center)

	var panel := PanelContainer.new()
	var style := _box(Color("#1d120c"), Color("#8a6a3a"))
	style.set_corner_radius_all(18)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	panel.add_child(margin)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	margin.add_child(v)

	_mode_settings_title = _section_label("", 30, Color("#e8c36a"))
	_mode_settings_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_mode_settings_title)

	# Добор карт (Клондайк)
	_ms_draw_box = VBoxContainer.new()
	_ms_draw_box.add_theme_constant_override("separation", 8)
	v.add_child(_ms_draw_box)
	_ms_draw_box.add_child(_section_label("Добор карт из колоды", 18, Color("#a8957a")))
	var draw_row := HBoxContainer.new()
	draw_row.add_theme_constant_override("separation", 10)
	_ms_draw_box.add_child(draw_row)
	_ms_draw_one = Button.new()
	_ms_draw_three = Button.new()
	_ms_draw_one.text = str(GameSession.DRAW_NAMES[GameSession.DRAW_ONE])
	_ms_draw_three.text = str(GameSession.DRAW_NAMES[GameSession.DRAW_THREE])
	_ms_draw_one.pressed.connect(_set_draw_in_settings.bind(GameSession.DRAW_ONE))
	_ms_draw_three.pressed.connect(_set_draw_in_settings.bind(GameSession.DRAW_THREE))
	draw_row.add_child(_ms_draw_one)
	draw_row.add_child(_ms_draw_three)

	# Раскладка стола (перенесён существующий выбор)
	v.add_child(_section_label("Раскладка стола", 18, Color("#a8957a")))
	_layout_selector.reparent(v)

	# Доп. правила для Клондайка по 3 карты (перенесены переключатели)
	_ms_rules_box = VBoxContainer.new()
	_ms_rules_box.add_theme_constant_override("separation", 6)
	v.add_child(_ms_rules_box)
	_ms_rules_box.add_child(_section_label("Правила сброса (по 3 карты)", 18, Color("#a8957a")))
	_conveyor_toggle.reparent(_ms_rules_box)
	_shuffle_toggle.reparent(_ms_rules_box)

	var done := Button.new()
	done.text = "Готово"
	_style_button(done)
	done.pressed.connect(_close_mode_settings)
	v.add_child(done)

	_mode_settings_overlay.visible = false


func _section_label(text_value: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


func _open_mode_settings() -> void:
	_refresh_mode_settings()
	_mode_settings_overlay.visible = true
	%Menu.process_mode = Node.PROCESS_MODE_DISABLED
	_layout_selector.grab_focus()


func _close_mode_settings() -> void:
	if _mode_settings_overlay == null:
		return
	_mode_settings_overlay.visible = false
	%Menu.process_mode = Node.PROCESS_MODE_INHERIT
	_mode_settings_button.grab_focus()


func _set_draw_in_settings(draw_id: int) -> void:
	GameSession.draw_mode = draw_id
	_refresh_mode_settings()


func _refresh_mode_settings() -> void:
	var mode := GameSession.mode if GameSession.mode != 0 else MODE_KLONDIKE
	_mode_settings_title.text = "Настройки · %s" % str(GameSession.MODE_NAMES.get(mode, "?"))
	var has_draw := GameSession.supports_draw_mode(mode)
	_ms_draw_box.visible = has_draw
	if has_draw:
		var cur := GameSession.effective_draw_mode()
		_style_draw_button(_ms_draw_one, cur == GameSession.DRAW_ONE)
		_style_draw_button(_ms_draw_three, cur == GameSession.DRAW_THREE)
	var draw_three := has_draw and GameSession.effective_draw_mode() == GameSession.DRAW_THREE
	_ms_rules_box.visible = draw_three
	_conveyor_toggle.disabled = not draw_three
	_shuffle_toggle.disabled = not draw_three
	_conveyor_toggle.set_pressed_no_signal(GameSession.waste_conveyor_enabled)
	_shuffle_toggle.set_pressed_no_signal(GameSession.shuffle_waste_on_recycle)
	_update_layout_selector()
	_update_mode_settings_button()


func _update_mode_settings_button() -> void:
	if _mode_settings_button == null:
		return
	var mode := GameSession.mode if GameSession.mode != 0 else MODE_KLONDIKE
	var parts: PackedStringArray = []
	if GameSession.supports_draw_mode(mode):
		parts.append("по %d" % (3 if GameSession.effective_draw_mode() == GameSession.DRAW_THREE else 1))
	var layout_names := {
		GameSession.BOARD_LAYOUT_CLASSIC: "классика",
		GameSession.BOARD_LAYOUT_MIRRORED: "зеркало",
		GameSession.BOARD_LAYOUT_RING: "кольцо",
	}
	parts.append(str(layout_names.get(GameSession.get_board_layout(mode), "")))
	_mode_settings_button.text = "Настройки режима · %s" % ", ".join(parts)


func _update_mode_label() -> void:
	var label: String = str(GameSession.MODE_NAMES.get(GameSession.mode, "?"))
	%ModeButton.text = "Режим: %s" % label


# --- Сложность: отдельная кнопка под «Режим» + свой оверлей ---

func _build_difficulty_ui() -> void:
	# Кнопка на главном экране — сразу под ModeButton
	var _menu: Control = %Menu
	var mode_btn: Button = %ModeButton
	var parent := mode_btn.get_parent()
	var idx := mode_btn.get_index()

	_diff_button = Button.new()
	_diff_button.name = "DiffButton"
	_style_button(_diff_button)
	_diff_button.pressed.connect(_open_diff)
	parent.add_child(_diff_button)
	parent.move_child(_diff_button, idx + 1)

	# Оверлей сложности (как ModeOverlay, но свой)
	var overlay_parent := %ModeOverlay.get_parent()
	_diff_overlay = Control.new()
	_diff_overlay.name = "DiffOverlay"
	_diff_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_diff_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay_parent.add_child(_diff_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.02, 0.01, 0.55)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed:
			_close_diff()
	)
	_diff_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_diff_overlay.add_child(center)

	var panel := PanelContainer.new()
	var style := _box(Color("#1d120c"), Color("#8a6a3a"))
	style.set_corner_radius_all(18)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	panel.add_child(margin)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	margin.add_child(v)

	_diff_title = Label.new()
	_diff_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_diff_title.add_theme_font_size_override("font_size", 32)
	_diff_title.add_theme_color_override("font_color", Color("#e8c36a"))
	v.add_child(_diff_title)

	_diff_hint = Label.new()
	_diff_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_diff_hint.add_theme_font_size_override("font_size", 18)
	_diff_hint.add_theme_color_override("font_color", Color("#a8957a"))
	_diff_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_diff_hint.custom_minimum_size = Vector2(280, 0)
	v.add_child(_diff_hint)

	_diff_options = VBoxContainer.new()
	_diff_options.add_theme_constant_override("separation", 10)
	v.add_child(_diff_options)

	_diff_one_btn = Button.new()
	_diff_three_btn = Button.new()
	_diff_one_btn.text = str(GameSession.DRAW_NAMES[GameSession.DRAW_ONE])
	_diff_three_btn.text = str(GameSession.DRAW_NAMES[GameSession.DRAW_THREE])
	_diff_one_btn.pressed.connect(_select_draw.bind(GameSession.DRAW_ONE))
	_diff_three_btn.pressed.connect(_select_draw.bind(GameSession.DRAW_THREE))
	_diff_options.add_child(_diff_one_btn)
	_diff_options.add_child(_diff_three_btn)

	var back := Button.new()
	back.text = "Назад"
	_style_button(back)
	back.pressed.connect(_close_diff)
	v.add_child(back)

	_diff_overlay.visible = false
	_update_diff_button()


func _open_diff() -> void:
	_refresh_diff_overlay()
	_diff_overlay.visible = true
	%Menu.process_mode = Node.PROCESS_MODE_DISABLED
	if _diff_one_btn.visible:
		_diff_one_btn.grab_focus()


func _close_diff() -> void:
	_diff_overlay.visible = false
	%Menu.process_mode = Node.PROCESS_MODE_INHERIT
	if _diff_button != null:
		_diff_button.grab_focus()


func _select_draw(draw_id: int) -> void:
	GameSession.draw_mode = draw_id
	_update_diff_button()
	_close_diff()


func _update_diff_button() -> void:
	if _diff_button == null:
		return
	var mode := GameSession.mode if GameSession.mode != 0 else MODE_KLONDIKE
	if GameSession.supports_draw_mode(mode):
		var dname: String = str(GameSession.DRAW_NAMES[GameSession.effective_draw_mode()])
		_diff_button.text = "Сложность: %s" % dname
	else:
		_diff_button.text = "Сложность: стандарт"
	# Выбор добора теперь в «Настройках режима».
	_diff_button.visible = false
	_update_rules_settings_button()
	_update_mode_settings_button()


func _refresh_diff_overlay() -> void:
	var mode := GameSession.mode if GameSession.mode != 0 else MODE_KLONDIKE
	var mode_name: String = str(GameSession.MODE_NAMES.get(mode, "?"))
	_diff_title.text = "Сложность · %s" % mode_name

	if GameSession.supports_draw_mode(mode):
		_diff_hint.text = "Сколько карт открывать из колоды за раз"
		_diff_options.visible = true
		var cur := GameSession.effective_draw_mode()
		_style_draw_button(_diff_one_btn, cur == GameSession.DRAW_ONE)
		_style_draw_button(_diff_three_btn, cur == GameSession.DRAW_THREE)
	else:
		_diff_hint.text = "Для этого режима пока нет отдельных уровней сложности"
		_diff_options.visible = false


# --- Дополнительные правила выбранного режима ---

func _build_rules_settings_ui() -> void:
	# Кнопка размещается сразу под выбором количества карт.
	_rules_settings_button = Button.new()
	_rules_settings_button.name = "RulesSettingsButton"
	_style_button(_rules_settings_button)
	_rules_settings_button.pressed.connect(_open_rules_settings)

	var parent := _diff_button.get_parent()
	parent.add_child(_rules_settings_button)
	parent.move_child(_rules_settings_button, _diff_button.get_index() + 1)

	_rules_settings_overlay = Control.new()
	_rules_settings_overlay.name = "RulesSettingsOverlay"
	_rules_settings_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_rules_settings_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	%ModeOverlay.get_parent().add_child(_rules_settings_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.02, 0.01, 0.6)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed:
			_close_rules_settings()
	)
	_rules_settings_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rules_settings_overlay.add_child(center)

	var panel := PanelContainer.new()
	var style := _box(Color("#1d120c"), Color("#8a6a3a"))
	style.set_corner_radius_all(18)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	panel.add_child(margin)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	margin.add_child(v)

	_rules_settings_title = Label.new()
	_rules_settings_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rules_settings_title.add_theme_font_size_override("font_size", 30)
	_rules_settings_title.add_theme_color_override("font_color", Color("#e8c36a"))
	v.add_child(_rules_settings_title)

	_rules_settings_hint = Label.new()
	_rules_settings_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rules_settings_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rules_settings_hint.custom_minimum_size = Vector2(320, 0)
	_rules_settings_hint.add_theme_font_size_override("font_size", 17)
	_rules_settings_hint.add_theme_color_override("font_color", Color("#a8957a"))
	v.add_child(_rules_settings_hint)

	_conveyor_toggle = CheckButton.new()
	_conveyor_toggle.text = "Конвейерная стопка сброса"
	_style_rules_toggle(_conveyor_toggle)
	_conveyor_toggle.toggled.connect(_on_conveyor_toggled)
	v.add_child(_conveyor_toggle)

	var conveyor_info := Label.new()
	conveyor_info.text = "Показывает последние три карты веером. При снятии верхней карты веер сдвигается."
	conveyor_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	conveyor_info.add_theme_font_size_override("font_size", 15)
	conveyor_info.add_theme_color_override("font_color", Color("#a8957a"))
	v.add_child(conveyor_info)

	_shuffle_toggle = CheckButton.new()
	_shuffle_toggle.text = "Перетасовывать сброс при возврате"
	_style_rules_toggle(_shuffle_toggle)
	_shuffle_toggle.toggled.connect(_on_shuffle_toggled)
	v.add_child(_shuffle_toggle)

	var shuffle_info := Label.new()
	shuffle_info.text = "Когда колода закончится, карты из сброса возвращаются в неё в случайном порядке."
	shuffle_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	shuffle_info.add_theme_font_size_override("font_size", 15)
	shuffle_info.add_theme_color_override("font_color", Color("#a8957a"))
	v.add_child(shuffle_info)

	var back := Button.new()
	back.text = "Готово"
	_style_button(back)
	back.pressed.connect(_close_rules_settings)
	v.add_child(back)

	_rules_settings_overlay.visible = false
	_update_rules_settings_button()


func _style_rules_toggle(b: CheckButton) -> void:
	b.add_theme_font_size_override("font_size", 20)
	b.add_theme_color_override("font_color", Color("#f3e6c8"))
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color("#e8c36a"))
	b.custom_minimum_size = Vector2(340, 44)


func _open_rules_settings() -> void:
	_refresh_rules_settings_overlay()
	_rules_settings_overlay.visible = true
	%Menu.process_mode = Node.PROCESS_MODE_DISABLED
	_conveyor_toggle.grab_focus()


func _close_rules_settings() -> void:
	if _rules_settings_overlay == null:
		return
	_rules_settings_overlay.visible = false
	%Menu.process_mode = Node.PROCESS_MODE_INHERIT
	if _rules_settings_button != null:
		_rules_settings_button.grab_focus()


func _refresh_rules_settings_overlay() -> void:
	var mode := GameSession.mode if GameSession.mode != 0 else MODE_KLONDIKE
	var mode_name: String = str(GameSession.MODE_NAMES.get(mode, "?"))
	_rules_settings_title.text = "Настройки: %s" % mode_name

	var is_draw_three := (
		GameSession.supports_draw_mode(mode)
		and GameSession.effective_draw_mode() == GameSession.DRAW_THREE
	)
	_rules_settings_hint.text = (
		"Настройки дополнительных правил для режима «Сброс по 3 карты»."
		if is_draw_three
		else "Эти дополнительные правила доступны в Клондайке со сбросом по 3 карты."
	)

	_conveyor_toggle.set_pressed_no_signal(GameSession.waste_conveyor_enabled)
	_shuffle_toggle.set_pressed_no_signal(GameSession.shuffle_waste_on_recycle)
	_conveyor_toggle.disabled = not is_draw_three
	_shuffle_toggle.disabled = not is_draw_three


func _on_conveyor_toggled(enabled: bool) -> void:
	GameSession.waste_conveyor_enabled = enabled


func _on_shuffle_toggled(enabled: bool) -> void:
	GameSession.shuffle_waste_on_recycle = enabled


func _update_rules_settings_button() -> void:
	if _rules_settings_button == null:
		return
	var mode := GameSession.mode if GameSession.mode != 0 else MODE_KLONDIKE
	var visible_for_mode := (
		GameSession.supports_draw_mode(mode)
		and GameSession.effective_draw_mode() == GameSession.DRAW_THREE
	)
	# Доп. правила теперь в «Настройках режима» — отдельная кнопка скрыта.
	_rules_settings_button.visible = false
	if visible_for_mode:
		var mode_name: String = str(GameSession.MODE_NAMES.get(mode, "?"))
		_rules_settings_button.text = "Настройки: %s" % mode_name


func _style_draw_button(b: Button, selected: bool) -> void:
	var base := GameSettings.get_color("accent") if selected else GameSettings.get_color("button")
	var border := GameSettings.get_color("gold") if selected else GameSettings.get_color("border")
	b.add_theme_stylebox_override("normal", _box(base, border))
	b.add_theme_stylebox_override("hover", _box(GameSettings.get_color("accent_hover"), border.lightened(0.12)))
	b.add_theme_stylebox_override("pressed", _box(GameSettings.get_color("button_pressed"), border))
	b.add_theme_stylebox_override("focus", _box(base.lightened(0.15), GameSettings.get_color("focus")))
	b.add_theme_color_override("font_color", GameSettings.get_color("accent_text") if selected else GameSettings.get_color("text"))
	b.add_theme_color_override("font_hover_color", GameSettings.get_color("text"))
	b.add_theme_font_size_override("font_size", 24)
	b.custom_minimum_size = Vector2(280, 56)


# --- Настройки ---

func _build_settings_overlay() -> void:
	_settings_overlay = Control.new()
	_settings_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	%ModeOverlay.get_parent().add_child(_settings_overlay)
	_settings_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.02, 0.01, 0.7)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_settings_overlay.add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var center := CenterContainer.new()
	_settings_overlay.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var panel := PanelContainer.new()
	var style := _box(Color("#1d120c"), Color("#8a6a3a"))
	style.set_corner_radius_all(18)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 32)
	panel.add_child(margin)

	_settings_panel = SettingsPanel.new()
	_settings_panel.show_camera_options = false
	_settings_panel.back_pressed.connect(_close_settings)
	margin.add_child(_settings_panel)

	_settings_overlay.visible = false


# --- Оформление ---

func _style_button(b: Button, primary := false) -> void:
	var base := Color("#c98a2b") if primary else Color("#2b1a12")
	var border := Color("#e8c36a") if primary else Color("#8a6a3a")
	b.add_theme_stylebox_override("normal", _box(base, border))
	b.add_theme_stylebox_override("hover", _box(base.lightened(0.15), border.lightened(0.2)))
	b.add_theme_stylebox_override("pressed", _box(base.darkened(0.15), border))
	b.add_theme_stylebox_override("disabled", _box(base.darkened(0.3), border.darkened(0.4)))
	b.add_theme_stylebox_override("focus", _box(base.lightened(0.15), Color("#ffe9a8")))
	b.add_theme_color_override("font_color", Color("#f3e6c8"))
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_font_size_override("font_size", 28)
	if b.custom_minimum_size == Vector2.ZERO:
		b.custom_minimum_size = Vector2(280, 60)


func _style_panel(p: PanelContainer) -> void:
	var s := _box(Color("#1d120c"), Color("#8a6a3a"))
	s.set_corner_radius_all(18)
	p.add_theme_stylebox_override("panel", s)


func _box(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(2)
	s.set_corner_radius_all(14)
	s.shadow_color = Color(0, 0, 0, 0.4)
	s.shadow_size = 6
	s.content_margin_left = 20
	s.content_margin_right = 20
	s.content_margin_top = 12
	s.content_margin_bottom = 12
	return s

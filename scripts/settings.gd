class_name SettingsPanel
extends VBoxContainer
## Settings panel shared by the main menu and pause menu.

signal back_pressed
signal palette_selected(palette_id: String)

var show_camera_options := true

var _music: HSlider
var _sfx: HSlider
var _look: CheckBox
var _back: Button
var _track_label: Label
var _theme_status: Label
var _theme_buttons: Dictionary = {}
var _display_selector: OptionButton
var _voice_volume: HSlider
var _voice_sensitivity: HSlider
var _voice_quality: OptionButton
var _voice_key_button: Button
var _capturing_voice_key := false


func _ready() -> void:
	GameSettings.ensure_loaded()
	set_process_unhandled_key_input(true)
	add_theme_constant_override("separation", 14)
	_build_tabs()
	_back = _button("Назад", _on_back)
	add_child(_back)
	GameSettings.apply_palette_tree(get_tree().root)


func _build_tabs() -> void:
	var tabs := TabContainer.new()
	tabs.name = "SettingsTabs"
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.custom_minimum_size = Vector2(540, 400)
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_theme_font_size_override("font_size", 18)

	# The default TabContainer theme is square and grey. Give the tab strip and
	# its content panel the same palette treatment as the rest of the settings UI.
	var selected_tab := _box(GameSettings.get_color("accent"), GameSettings.get_color("gold"))
	var idle_tab := _box(GameSettings.get_color("button"), GameSettings.get_color("border"))
	var hover_tab := _box(GameSettings.get_color("accent_hover"), GameSettings.get_color("gold"))
	var disabled_tab := _box(GameSettings.get_color("button_disabled"), GameSettings.get_color("border_dim"))
	tabs.add_theme_stylebox_override("tab_selected", selected_tab)
	tabs.add_theme_stylebox_override("tab_unselected", idle_tab)
	tabs.add_theme_stylebox_override("tab_hovered", hover_tab)
	tabs.add_theme_stylebox_override("tab_disabled", disabled_tab)
	tabs.add_theme_stylebox_override("panel", _box(GameSettings.get_color("panel"), GameSettings.get_color("border")))
	tabs.add_theme_color_override("font_selected_color", GameSettings.get_color("text"))
	tabs.add_theme_color_override("font_unselected_color", GameSettings.get_color("muted"))
	tabs.add_theme_color_override("font_hovered_color", GameSettings.get_color("text"))
	tabs.add_theme_color_override("font_disabled_color", GameSettings.get_color("muted"))
	add_child(tabs)

	# Each tab is wrapped in a MarginContainer. This restores the inset that was
	# lost when the display tab was added, keeping all controls away from the
	# dark panel edges instead of pinning them to the top-left corner.
	var audio_page := VBoxContainer.new()
	audio_page.name = "Звук и камера" if show_camera_options else "Звук"
	_prepare_tab_page(tabs, audio_page)
	audio_page.add_theme_constant_override("separation", 16)
	audio_page.add_child(_label("ЗВУК И КАМЕРА", 22, GameSettings.get_color("gold")))
	_music = _add_slider(audio_page, "Музыка", GameSettings.music_volume, _on_music_changed, Callable())
	_add_track_row(audio_page)
	_sfx = _add_slider(audio_page, "Движение карт", GameSettings.sfx_volume, _on_sfx_changed, _on_sfx_released)

	if show_camera_options:
		_look = CheckBox.new()
		_look.text = "Камера следует за мышью"
		_look.button_pressed = GameSettings.mouse_look
		_look.add_theme_font_size_override("font_size", 21)
		_look.add_theme_color_override("font_color", GameSettings.get_color("text"))
		_look.toggled.connect(func(on: bool):
			GameSettings.mouse_look = on
			GameSettings.save()
		)
		audio_page.add_child(_look)
		var hint := _label("Колесо мыши: масштаб. СКМ или ПКМ: сдвиг. Home: сбросить вид.", 15, GameSettings.get_color("muted"))
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.custom_minimum_size = Vector2(480, 0)
		audio_page.add_child(hint)

	var voice_page := VBoxContainer.new()
	voice_page.name = "Голосовой чат"
	_prepare_tab_page(tabs, voice_page)
	voice_page.add_theme_constant_override("separation", 16)
	voice_page.add_child(_label("ГОЛОСОВАЯ СВЯЗЬ", 22, GameSettings.get_color("gold")))
	var voice_description := _label(
		"Настрой передачу микрофона и громкость голоса второго игрока.", 14,
		GameSettings.get_color("muted")
	)
	voice_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	voice_page.add_child(voice_description)
	_voice_volume = _add_slider(
		voice_page, "Громкость собеседника", GameSettings.voice_volume,
		_on_voice_volume_changed, _on_voice_settings_released
	)
	_voice_volume.focus_exited.connect(_on_voice_settings_released)
	_voice_sensitivity = _add_slider(
		voice_page, "Чувствительность микрофона", GameSettings.voice_input_threshold,
		_on_voice_sensitivity_changed, _on_voice_settings_released,
		0.001, 0.1, 0.001
	)
	_voice_sensitivity.focus_exited.connect(_on_voice_settings_released)

	var sensitivity_hint := _label(
		"Чем ниже порог, тем чувствительнее микрофон: он будет улавливать более тихие звуки.",
		14,
		GameSettings.get_color("muted")
	)
	sensitivity_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	voice_page.add_child(sensitivity_hint)
	_add_voice_quality_selector(voice_page)
	if GameSettings.is_voice_key_binding_supported():
		_voice_key_button = _button(_voice_key_text(), _on_voice_key_capture_pressed)
		_voice_key_button.custom_minimum_size = Vector2(260, 46)
		voice_page.add_child(_voice_key_button)
		var ptt_hint := _label("Удерживай выбранную клавишу, чтобы говорить.", 14, GameSettings.get_color("muted"))
		ptt_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		voice_page.add_child(ptt_hint)
	else:
		var mobile_hint := _label("На мобильном клавиша не назначается: используй экранную кнопку микрофона в партии.", 15, GameSettings.get_color("muted"))
		mobile_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		voice_page.add_child(mobile_hint)

	if GameSettings.is_display_mode_supported():
		var display_page := VBoxContainer.new()
		display_page.name = "Экран"
		_prepare_tab_page(tabs, display_page)
		display_page.add_theme_constant_override("separation", 16)
		display_page.add_child(_label("РЕЖИМ ОТОБРАЖЕНИЯ", 22, GameSettings.get_color("gold")))
		var display_description := _label("Выбери, как игра будет отображаться на мониторе. Изменение применяется сразу.", 14, GameSettings.get_color("muted"))
		display_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		display_page.add_child(display_description)
		var display_row := HBoxContainer.new()
		display_row.add_theme_constant_override("separation", 14)
		var display_label := _label("Окно игры", 21, GameSettings.get_color("text"))
		display_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		display_label.custom_minimum_size = Vector2(160, 0)
		display_row.add_child(display_label)
		_display_selector = OptionButton.new()
		_display_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_display_selector.custom_minimum_size = Vector2(220, 44)
		_display_selector.add_item("Окно")
		_display_selector.set_item_metadata(0, GameSettings.DISPLAY_MODE_WINDOWED)
		_display_selector.add_item("Без рамок")
		_display_selector.set_item_metadata(1, GameSettings.DISPLAY_MODE_BORDERLESS)
		_display_selector.add_item("Полный экран")
		_display_selector.set_item_metadata(2, GameSettings.DISPLAY_MODE_FULLSCREEN)
		_display_selector.select(maxi(0, GameSettings.DISPLAY_MODES.find(GameSettings.display_mode)))
		_display_selector.item_selected.connect(func(index: int):
			GameSettings.set_display_mode(str(_display_selector.get_item_metadata(index)))
		)
		display_row.add_child(_display_selector)
		display_page.add_child(display_row)

	var theme_page := VBoxContainer.new()
	theme_page.name = "Тематика"
	_prepare_tab_page(tabs, theme_page)
	var theme_scroll := ScrollContainer.new()
	theme_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	theme_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	theme_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	theme_page.add_child(theme_scroll)
	var theme_content := VBoxContainer.new()
	theme_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	theme_content.add_theme_constant_override("separation", 12)
	theme_scroll.add_child(theme_content)
	theme_content.add_child(_label("ЦВЕТОВАЯ ТЕМА", 22, GameSettings.get_color("gold")))
	var description := _label("Выбери палитру интерфейса. Изменения применяются сразу и сохраняются автоматически.", 14, GameSettings.get_color("muted"))
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	theme_content.add_child(description)

	_theme_status = _label("", 16, GameSettings.get_color("gold"))
	theme_content.add_child(_theme_status)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	theme_content.add_child(grid)

	for id in GameSettings.PALETTE_ORDER:
		var palette: Dictionary = GameSettings.get_palette(id)
		var card := VBoxContainer.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.add_theme_constant_override("separation", 5)
		grid.add_child(card)

		var choose := Button.new()
		choose.custom_minimum_size = Vector2(210, 46)
		choose.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		choose.set_meta("skip_palette_recolor", true)
		choose.pressed.connect(_select_palette.bind(id))
		_theme_buttons[id] = choose
		card.add_child(choose)

		var swatches := HBoxContainer.new()
		swatches.add_theme_constant_override("separation", 4)
		card.add_child(swatches)
		for role in ["background", "panel", "accent", "gold"]:
			var chip := ColorRect.new()
			chip.color = palette[role]
			chip.custom_minimum_size = Vector2(0, 18)
			chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			swatches.add_child(chip)
	_refresh_theme_cards()


func _prepare_tab_page(tabs: TabContainer, page_content: Control) -> void:
	page_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var margin := MarginContainer.new()
	margin.name = str(page_content.name)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Все вкладки получают одинаковую рабочую область: высота содержимого
	# конкретной вкладки больше не меняет геометрию TabContainer при переключении.
	margin.custom_minimum_size = Vector2(540, 400)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	tabs.add_child(margin)
	margin.add_child(page_content)


func refresh() -> void:
	GameSettings.ensure_loaded()
	if _music != null:
		_music.set_value_no_signal(GameSettings.music_volume)
	if _sfx != null:
		_sfx.set_value_no_signal(GameSettings.sfx_volume)
	if _look != null:
		_look.set_pressed_no_signal(GameSettings.mouse_look)
	if _display_selector != null:
		_display_selector.select(maxi(0, GameSettings.DISPLAY_MODES.find(GameSettings.display_mode)))
	if _voice_volume != null:
		_voice_volume.set_value_no_signal(GameSettings.voice_volume)
	if _voice_sensitivity != null:
		_voice_sensitivity.set_value_no_signal(GameSettings.voice_input_threshold)
	if _voice_quality != null:
		_voice_quality.select(clampi(GameSettings.voice_quality, 0, 3))
	if _voice_key_button != null and not _capturing_voice_key:
		_voice_key_button.text = _voice_key_text()
	_refresh_track_label()
	_refresh_theme_cards()
	GameSettings.apply_palette_tree(get_tree().root)


func focus_back() -> void:
	if _back != null:
		_back.grab_focus()


func _on_back() -> void:
	GameSettings.save()
	back_pressed.emit()


func _select_palette(id: String) -> void:
	GameSettings.set_palette(id)
	_refresh_theme_cards()
	GameSettings.apply_palette_tree(get_tree().root)
	palette_selected.emit(str(id))


func _refresh_theme_cards() -> void:
	if _theme_status != null:
		var palette := GameSettings.get_palette()
		_theme_status.text = "Активная тема: %s" % str(palette.get("title", GameSettings.palette_id))
	for id in _theme_buttons:
		var button: Button = _theme_buttons[id]
		var palette: Dictionary = GameSettings.get_palette(id)
		var selected: bool = str(id) == str(GameSettings.palette_id)
		button.text = ("✓  " if selected else "") + str(palette.get("title", id))
		var base: Color = palette["accent"] if selected else palette["button"]
		var border: Color = palette["gold"] if selected else palette["border"]
		button.add_theme_stylebox_override("normal", _box(base, border))
		button.add_theme_stylebox_override("hover", _box(base.lightened(0.12), border.lightened(0.12)))
		button.add_theme_color_override("font_color", palette["text"])
		button.add_theme_font_size_override("font_size", 17)


func _on_music_changed(value: float) -> void:
	GameSettings.music_volume = value
	GameSettings.apply_audio()


func _on_sfx_changed(value: float) -> void:
	GameSettings.sfx_volume = value
	GameSettings.apply_audio()


func _on_sfx_released() -> void:
	GameAudio.card(get_tree())


func _on_voice_volume_changed(value: float) -> void:
	GameSettings.voice_volume = clampf(value, 0.0, 1.0)

func _on_voice_sensitivity_changed(value: float) -> void:
	GameSettings.voice_input_threshold = clampf(value, 0.001, 0.1)

func _on_voice_settings_released() -> void:
	GameSettings.save()
	
func _add_voice_quality_selector(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	var caption := _label("Качество голоса", 21, GameSettings.get_color("text"))
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	caption.custom_minimum_size = Vector2(160, 0)
	row.add_child(caption)
	_voice_quality = OptionButton.new()
	_voice_quality.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_voice_quality.custom_minimum_size = Vector2(220, 44)
	_voice_quality.add_item("Очень высокое")
	_voice_quality.add_item("Высокое")
	_voice_quality.add_item("Среднее")
	_voice_quality.add_item("Низкое")
	_voice_quality.select(clampi(GameSettings.voice_quality, 0, 3))
	_voice_quality.item_selected.connect(func(index: int):
		GameSettings.voice_quality = clampi(index, 0, 3)
		GameSettings.save()
	)
	GameSettings.apply_option_button_palette(_voice_quality)
	row.add_child(_voice_quality)
	parent.add_child(row)


func _voice_key_text() -> String:
	return "Клавиша микрофона: %s" % OS.get_keycode_string(GameSettings.voice_ptt_keycode)


func _on_voice_key_capture_pressed() -> void:
	_capturing_voice_key = true
	if _voice_key_button != null:
		_voice_key_button.text = "НАЖМИ НОВУЮ КЛАВИШУ..."


func _unhandled_key_input(event: InputEvent) -> void:
	if not _capturing_voice_key or not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if key_event.keycode == KEY_ESCAPE:
		_capturing_voice_key = false
		if _voice_key_button != null:
			_voice_key_button.text = _voice_key_text()
		get_viewport().set_input_as_handled()
		return
	var keycode := int(key_event.physical_keycode if key_event.physical_keycode != 0 else key_event.keycode)
	GameSettings.set_voice_ptt_key(keycode)
	GameSettings.save()
	_capturing_voice_key = false
	if _voice_key_button != null:
		_voice_key_button.text = _voice_key_text()
	get_viewport().set_input_as_handled()


## Track selector: ◀ name ▶.
func _add_track_row(parent: VBoxContainer) -> void:
	var audio := GameAudio.get_instance(get_tree())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var caption := _label("Трек", 21, GameSettings.get_color("text"))
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	caption.custom_minimum_size = Vector2(160, 0)
	row.add_child(caption)
	row.add_child(_small_button("◀", func(): audio.prev_track()))
	_track_label = _label("", 18, GameSettings.get_color("gold"))
	_track_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_track_label.clip_text = true
	_track_label.custom_minimum_size = Vector2(180, 0)
	row.add_child(_track_label)
	row.add_child(_small_button("▶", func(): audio.next_track()))
	parent.add_child(row)
	if not audio.track_changed.is_connected(_on_track_changed):
		audio.track_changed.connect(_on_track_changed)
	_update_track_label()


func _on_track_changed(_name: String, _index: int, _count: int) -> void:
	_update_track_label()


func _update_track_label() -> void:
	if _track_label == null:
		return
	var audio := GameAudio.get_instance(get_tree())
	if not audio.is_node_ready():
		_track_label.text = "…"
		if not audio.ready.is_connected(_update_track_label):
			audio.ready.connect(_update_track_label, CONNECT_ONE_SHOT)
		return
	var count := audio.get_track_count()
	_track_label.text = audio.get_track_name() if count <= 1 \
		else "%s  (%d/%d)" % [audio.get_track_name(), audio.get_track_index() + 1, count]


func _refresh_track_label() -> void:
	_update_track_label()


func _small_button(text: String, on_press: Callable) -> Button:
	var b := _button(text, on_press)
	b.custom_minimum_size = Vector2(54, 46)
	b.add_theme_font_size_override("font_size", 20)
	return b


func _add_slider(
	parent: VBoxContainer, caption: String, value: float,	on_change: Callable, on_release: Callable,
	minimum: float = 0.0, maximum: float = 1.0, step_value: float = 0.01
) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	var label := _label(caption, 21, GameSettings.get_color("text"))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.custom_minimum_size = Vector2(160, 0)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step_value
	slider.value = value
	slider.custom_minimum_size = Vector2(250, 30)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var track := _box(GameSettings.get_color("button"), GameSettings.get_color("border"))
	track.set_corner_radius_all(6)
	track.content_margin_top = 5
	track.content_margin_bottom = 5
	var fill := _box(GameSettings.get_color("accent"), GameSettings.get_color("gold"))
	fill.set_corner_radius_all(6)
	fill.content_margin_top = 5
	fill.content_margin_bottom = 5
	slider.add_theme_stylebox_override("slider", track)
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_stylebox_override("grabber_area_highlight", fill)
	slider.value_changed.connect(on_change)
	if on_release.is_valid():
		slider.drag_ended.connect(func(_changed: bool): on_release.call())
	row.add_child(slider)
	parent.add_child(row)
	return slider


func _label(value: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


func _button(value: String, on_press: Callable) -> Button:
	var button := Button.new()
	button.text = value
	var base := GameSettings.get_color("accent")
	var border := GameSettings.get_color("gold")
	button.add_theme_stylebox_override("normal", _box(base, border))
	button.add_theme_stylebox_override("hover", _box(base.lightened(0.15), border.lightened(0.2)))
	button.add_theme_stylebox_override("pressed", _box(base.darkened(0.15), border))
	button.add_theme_stylebox_override("focus", _box(base.lightened(0.15), GameSettings.get_color("focus")))
	button.add_theme_color_override("font_color", GameSettings.get_color("text"))
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_font_size_override("font_size", 22)
	button.custom_minimum_size = Vector2(320, 54)
	button.pressed.connect(on_press)
	return button


func _box(bg: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.shadow_color = Color(0, 0, 0, 0.35)
	style.shadow_size = 5
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	return style

extends CanvasLayer
class_name StatisticsPanel

signal closed

const BG := Color("#1D120C")
const CARD_BG := Color("#281B12")
const BORDER := Color("#725532")
const TEXT := Color("#F3E6C8")
const MUTED := Color("#A8957A")
const GOLD := Color("#E8C36A")
const ACCENT := Color("#C98A2B")


func _ready() -> void:
	GameSettings.ensure_loaded()
	layer = 80
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	GameSettings.apply_palette_tree(get_tree().root)


func _build() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0.015, 0.012, 0.01, 0.80)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)

	# Размер окна рассчитывается от текущего viewport, чтобы UI не сжимался
	# в узкие вертикальные полосы на небольших разрешениях.
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var panel_width: float = clampf(viewport_size.x - 40.0, 420.0, 760.0)
	var scroll_height: float = clampf(viewport_size.y - 70.0, 320.0, 650.0)
	var content_width: float = maxf(320.0, panel_width - 24.0 - 36.0 - 16.0)
	var use_two_columns: bool = content_width >= 600.0

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(panel_width, 0)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	panel.add_theme_stylebox_override("panel", _style_box(BG, BORDER, 18))
	center.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(panel_width - 24.0, scroll_height)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	scroll.add_child(margin)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.custom_minimum_size.x = content_width
	content.add_theme_constant_override("separation", 14)
	margin.add_child(content)

	var header := HBoxContainer.new()
	header.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_child(header)

	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title_box)

	var title := _label("СТАТИСТИКА", 30, GOLD)
	title_box.add_child(title)
	var subtitle := _label("Ваши результаты и рекорды", 14, MUTED)
	title_box.add_child(subtitle)

	var close_button := Button.new()
	close_button.text = "✕"
	close_button.custom_minimum_size = Vector2(44, 44)
	close_button.add_theme_font_size_override("font_size", 19)
	close_button.add_theme_color_override("font_color", TEXT)
	close_button.add_theme_stylebox_override("normal", _style_box(CARD_BG, BORDER, 10))
	close_button.add_theme_stylebox_override("hover", _style_box(Color("#49301C"), GOLD, 10))
	close_button.pressed.connect(close)
	header.add_child(close_button)

	content.add_child(HSeparator.new())

	var data: Dictionary = GameStatistics.get_summary()
	var won := int(data.get("games_won", 0))
	var lost := int(data.get("games_lost", 0))
	var completed := won + lost
	var win_rate := 100.0 * float(won) / float(completed) if completed > 0 else 0.0
	var avg_moves := float(data.get("total_moves", 0)) / float(won) if won > 0 else 0.0
	var avg_seconds := float(data.get("total_win_seconds", 0)) / float(won) if won > 0 else 0.0

	content.add_child(_section_title("ОБЩИЕ РЕЗУЛЬТАТЫ"))
	var grid := GridContainer.new()
	grid.columns = 2 if use_two_columns else 1
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 10)
	content.add_child(grid)

	_add_metric(grid, "СЫГРАНО", str(completed), "Завершённые партии")
	_add_metric(grid, "ПОБЕДЫ", str(won), "Успешные партии")
	_add_metric(grid, "ПОБЕД", "%.1f%%" % win_rate, "Доля побед")
	_add_metric(grid, "ПОРАЖЕНИЯ", str(lost), "Завершились неудачей")
	_add_metric(grid, "СЕРИЯ СЕЙЧАС", str(int(data.get("current_streak", 0))), "Побед подряд")
	_add_metric(grid, "ЛУЧШАЯ СЕРИЯ", str(int(data.get("best_streak", 0))), "Рекорд побед подряд")

	content.add_child(_section_title("РЕКОРДЫ И СРЕДНИЕ ПОКАЗАТЕЛИ"))
	var records := GridContainer.new()
	records.columns = 2 if use_two_columns else 1
	records.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	records.add_theme_constant_override("h_separation", 12)
	records.add_theme_constant_override("v_separation", 8)
	content.add_child(records)
	_add_record_row(records, "Лучшее время", _format_time(int(data.get("best_time", 0))))
	_add_record_row(records, "Минимум ходов", _positive_or_dash(int(data.get("best_moves", 0))))
	_add_record_row(records, "Среднее время победы", _format_time(roundi(avg_seconds)))
	_add_record_row(records, "Среднее число ходов", "%.1f" % avg_moves if won > 0 else "—")
	_add_record_row(records, "Всего ходов в победах", str(int(data.get("total_moves", 0))))
	_add_record_row(records, "Использовано отмен", str(int(data.get("total_undos", 0))))

	content.add_child(HSeparator.new())
	content.add_child(_section_title("ПО РЕЖИМАМ"))
	var mode_grid := GridContainer.new()
	mode_grid.columns = 2 if use_two_columns else 1
	mode_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mode_grid.add_theme_constant_override("h_separation", 12)
	mode_grid.add_theme_constant_override("v_separation", 10)
	content.add_child(mode_grid)
	var modes: Dictionary = data.get("per_mode", {})
	_add_mode_card(mode_grid, "КЛОНДАЙК", modes.get("2", {}))
	_add_mode_card(mode_grid, "ПАУК", modes.get("1", {}))

	var footer := HBoxContainer.new()
	footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_child(footer)
	var footer_close := Button.new()
	footer_close.text = "ЗАКРЫТЬ"
	footer_close.custom_minimum_size = Vector2(220, 48)
	footer_close.add_theme_font_size_override("font_size", 17)
	footer_close.add_theme_color_override("font_color", TEXT)
	footer_close.add_theme_stylebox_override("normal", _style_box(ACCENT, GOLD, 10))
	footer_close.add_theme_stylebox_override("hover", _style_box(ACCENT.lightened(0.15), Color("#FFE9A8"), 10))
	footer_close.pressed.connect(close)
	footer.add_child(footer_close)
	footer_close.grab_focus()


func _section_title(value: String) -> Label:
	return _label(value, 15, GOLD)


func _add_metric(parent: GridContainer, caption: String, value: String, note: String) -> void:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(260, 102)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", _style_box(CARD_BG, BORDER, 12))
	parent.add_child(card)

	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 3)
	card.add_child(box)
	var value_label := _label(value, 27, TEXT)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(value_label)
	var caption_label := _label(caption, 11, GOLD)
	caption_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(caption_label)
	var note_label := _label(note, 10, MUTED)
	note_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(note_label)


func _add_record_row(parent: GridContainer, caption: String, value: String) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 260
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _style_box(Color("#24170F"), Color("#51412D"), 8))
	parent.add_child(panel)
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 8)
	panel.add_child(row)
	var name_label := _label(caption, 13, MUTED)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)
	var value_label := _label(value, 14, TEXT)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_label)


func _add_mode_card(parent: GridContainer, title_text: String, value: Variant) -> void:
	var mode_data: Dictionary = value if value is Dictionary else {}
	var won := int(mode_data.get("won", 0))
	var lost := int(mode_data.get("lost", 0))
	var played := won + lost
	var rate := 100.0 * float(won) / float(played) if played > 0 else 0.0
	var average_moves := float(mode_data.get("total_moves", 0)) / float(won) if won > 0 else 0.0
	var average_time := float(mode_data.get("total_seconds", 0)) / float(won) if won > 0 else 0.0

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(300, 150)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", _style_box(CARD_BG, BORDER, 12))
	parent.add_child(card)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 6)
	card.add_child(box)
	box.add_child(_label(title_text, 16, GOLD))
	box.add_child(_label("Партии: %d   ·   Победы: %d   ·   Поражения: %d" % [played, won, lost], 12, TEXT))
	box.add_child(_label("Процент побед: %.1f%%" % rate, 12, TEXT))
	box.add_child(_label("Рекорд времени: %s" % _format_time(int(mode_data.get("best_time", 0))), 12, MUTED))
	box.add_child(_label("Минимум ходов: %s" % _positive_or_dash(int(mode_data.get("best_moves", 0))), 12, MUTED))
	var average_text := "Среднее: %.1f ходов · %s" % [average_moves, _format_time(roundi(average_time))] if won > 0 else "Средние показатели: —"
	box.add_child(_label(average_text, 11, MUTED))


func _positive_or_dash(value: int) -> String:
	return str(value) if value > 0 else "—"


func _label(value: String, size: int, color: Color) -> Label:
	var result := Label.new()
	result.text = value
	result.add_theme_font_size_override("font_size", size)
	result.add_theme_color_override("font_color", color)
	result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return result


func _style_box(bg: Color, border: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	style.shadow_color = Color(0, 0, 0, 0.35)
	style.shadow_size = 5
	return style


func _format_time(total_seconds: int) -> String:
	if total_seconds <= 0:
		return "—"
	var hours: int = floori(float(total_seconds) / 3600.0)
	var minutes: int = floori(float(total_seconds % 3600) / 60.0)
	var seconds: int = total_seconds % 60
	if hours > 0:
		return "%d:%02d:%02d" % [hours, minutes, seconds]
	return "%02d:%02d" % [minutes, seconds]


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func close() -> void:
	closed.emit()
	queue_free()

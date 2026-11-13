
extends Node3D
class_name GameConsole

@export_group("Победа")
@export_range(0.0, 5.0, 0.1) var victory_show_delay := 0.6

@export_file("*.tscn")
var main_menu_scene_path := "res://scenes/main_menu.tscn"
@export_group("Анимация возврата карт")
@export_range(0.1, 2.0, 0.05) var card_return_duration := 0.65
@export_range(0.0, 0.08, 0.005) var card_return_stagger := 0.025
@export_range(0.0, 1.0, 0.05) var card_return_arc_height := 0.28
## Сколько оборотов делает «вихрь» карт перед посадкой в колоду
@export_range(0.0, 3.0, 0.25) var swirl_turns := 1.0
## Дополнительное время на вихрь (к card_return_duration), секунды
@export_range(0.0, 3.0, 0.1) var swirl_duration := 0.9

var _elapsed_seconds: float = 0.0
var _tracking_started: bool = false
var _result_recorded: bool = false
var _preview_instance: bool = false

@export_group("GameManager")
@export var game_manager_path: NodePath

var game_manager: GameManager
var victory_sequence_started := false
var victory_input_layer: CanvasLayer
var _network_sync: NetworkMatchSync
var victory_new_game_button: Button
var _rematch_invitation_layer: CanvasLayer


func _ready() -> void:
	# MenuBackdrop запускает полноценный уровень внутри SubViewport.
	# Такие демонстрационные партии не должны записываться в статистику.
	_preview_instance = get_viewport() is SubViewport
	if _preview_instance:
		return
	call_deferred("_connect_game_manager")

# ==================================================
# GAME MANAGER
# ==================================================

func _connect_game_manager() -> void:
	if game_manager_path != NodePath():
		game_manager = get_node_or_null(game_manager_path) as GameManager
	if game_manager == null:
		game_manager = get_tree().get_first_node_in_group("game_manager") as GameManager
	if game_manager == null:
		push_warning("GameConsole: GameManager не найден.")
		return

	if not game_manager.game_won.is_connected(_on_game_won):
		game_manager.game_won.connect(_on_game_won)
	if not game_manager.game_lost.is_connected(_on_game_lost):
		game_manager.game_lost.connect(_on_game_lost)
	if not game_manager.deal_finished.is_connected(_on_deal_finished):
		game_manager.deal_finished.connect(_on_deal_finished)

	_network_sync = NetworkMatchSync.find_in(get_tree())
	if _network_sync != null:
		if not _network_sync.rematch_invitation_received.is_connected(_on_rematch_invitation_received):
			_network_sync.rematch_invitation_received.connect(_on_rematch_invitation_received)
		if not _network_sync.rematch_state_changed.is_connected(_on_rematch_state_changed):
			_network_sync.rematch_state_changed.connect(_on_rematch_state_changed)

	# На случай, если GameConsole подключился после завершения раздачи.
	if not game_manager.is_dealing and not game_manager.game_finished:
		_begin_game_tracking()

	if game_manager.game_finished and game_manager.rules != null and game_manager.rules.is_won():
		call_deferred("_on_game_won")


func _process(delta: float) -> void:
	if _preview_instance or not _tracking_started or _result_recorded:
		return
	if not is_instance_valid(game_manager):
		return
	if game_manager.game_finished:
		# Победа записывается синхронно сигналом game_won.
		# Если игра закончилась без game_won — записываем поражение.
		_result_recorded = true
		GameStatistics.record_loss(int(game_manager.current_mode))
		return
	_elapsed_seconds += delta


func _on_deal_finished() -> void:
	if _preview_instance:
		return
	# Новая раздача в той же сцене («Новая партия» из паузы): предыдущая партия,
	# если её не доиграли, записывается поражением, и учёт начинается заново.
	if _tracking_started and not _result_recorded:
		GameStatistics.record_loss(int(game_manager.current_mode))
	_tracking_started = false
	_result_recorded = false
	victory_sequence_started = false
	await get_tree().process_frame
	if not is_inside_tree() or not is_instance_valid(game_manager):
		return
	_begin_game_tracking()


## Выход из партии (в меню, закрытие игры) до её окончания — поражение.
func _exit_tree() -> void:
	if _preview_instance or not _tracking_started or _result_recorded:
		return
	if is_instance_valid(game_manager) and game_manager.moves_count > 0:
		_result_recorded = true
		GameStatistics.record_loss(int(game_manager.current_mode))


func _begin_game_tracking() -> void:
	if _tracking_started or _result_recorded or not is_instance_valid(game_manager):
		return
	_elapsed_seconds = 0.0
	_tracking_started = true
	GameStatistics.record_started(int(game_manager.current_mode))


func _record_win() -> void:
	if _result_recorded or not is_instance_valid(game_manager):
		return
	if not _tracking_started:
		_begin_game_tracking()
	_result_recorded = true
	_tracking_started = false
	if _is_network_loss():
		GameStatistics.record_loss(int(game_manager.current_mode))
		return
	GameStatistics.record_win(
		int(game_manager.current_mode),
		int(game_manager.moves_count),
		roundi(_elapsed_seconds),
		int(game_manager.undo_count)
	)


## Партия закончилась не в пользу этого игрока: сдача в одиночной игре,
## своя сдача в сети или победа соперника (соревновательный режим).
func _is_network_loss() -> bool:
	if not is_instance_valid(game_manager):
		return false
	var sync := NetworkMatchSync.find_in(get_tree())
	var local_field := sync.field_of_slot(sync.local_slot) if sync != null else ""
	if not game_manager.surrendered_field.is_empty():
		return sync == null or game_manager.surrendered_field == local_field
	var winner := game_manager.winner_field
	return sync != null and not winner.is_empty() and winner != local_field


func _result_text() -> String:
	if not is_instance_valid(game_manager):
		return ""
	if not game_manager.surrendered_field.is_empty():
		return "Партия сдана: окончательный тупик." if _is_network_loss() else "Соперник сдался."
	if _is_network_loss():
		if game_manager.current_mode == GameSession.MODE_SPIDER:
			return "Соперник первым собрал 3 масти."
		return "Соперник первым завершил все 4 масти."
	return "Поздравляем! Партия завершена."


func _format_elapsed_time() -> String:
	var seconds := maxi(0, roundi(_elapsed_seconds))
	return "%02d:%02d" % [seconds / 60, seconds % 60]


## Сдача (окончательный тупик): без анимации сбора карт — сразу итоги.
func _on_game_lost(_winner_field: String) -> void:
	if victory_sequence_started:
		return
	victory_sequence_started = true
	if _is_network_loss():
		if not _result_recorded and is_instance_valid(game_manager):
			_result_recorded = true
			GameStatistics.record_loss(int(game_manager.current_mode))
	else:
		_record_win()
	_block_gameplay_mouse()
	await get_tree().create_timer(victory_show_delay).timeout
	if is_inside_tree():
		_show_victory_window()


func _animate_cards_to_stock() -> float:
	if not is_instance_valid(game_manager):
		return 0.0

	var stocks: Array[Pile] = game_manager.get_piles(PileMarker.Kind.STOCK)
	if stocks.is_empty():
		push_warning("GameConsole: не найдена колода STOCK для анимации победы.")
		return 0.0

	var animated_ids: Dictionary = {}
	var moving_cards: Array[Dictionary] = []

	# Берём карты из всех стопок, кроме STOCK. Содержимое Pile.cards не меняем:
	# после победы это чисто визуальная последовательность, а новая партия
	# создаётся заново через GameSession.start_level().
	for source_pile: Pile in game_manager.piles:
		if not is_instance_valid(source_pile) or stocks.has(source_pile):
			continue
		for card_variant in source_pile.cards:
			var card: Card = card_variant as Card
			if not is_instance_valid(card):
				continue
			var instance_id: int = card.get_instance_id()
			if animated_ids.has(instance_id):
				continue
			animated_ids[instance_id] = true

			var target_stock: Pile = stocks[0]
			var nearest_distance: float = source_pile.global_position.distance_squared_to(target_stock.global_position)
			for candidate: Pile in stocks:
				var distance: float = source_pile.global_position.distance_squared_to(candidate.global_position)
				if distance < nearest_distance:
					nearest_distance = distance
					target_stock = candidate

			moving_cards.append({"card": card, "stock": target_stock})

	if moving_cards.is_empty():
		return 0.0

	# Перемешиваем порядок по полю, чтобы карты летели не одной длинной колонной.
	moving_cards.shuffle()
	var stack_offsets: Dictionary = {}
	var longest_time: float = 0.0

	# Центр «вихря» — середина всех стопок на столе.
	var center := Vector3.ZERO
	var pile_count := 0
	for pile: Pile in game_manager.piles:
		if is_instance_valid(pile):
			center += pile.global_position
			pile_count += 1
	if pile_count > 0:
		center /= float(pile_count)

	for index in range(moving_cards.size()):
		var entry: Dictionary = moving_cards[index]
		var card: Card = entry["card"]
		var stock: Pile = entry["stock"]
		var stock_id: int = stock.get_instance_id()
		var stack_index: int = int(stack_offsets.get(stock_id, stock.cards.size()))
		stack_offsets[stock_id] = stack_index + 1

		# stack_step у стопки — Vector3 (раньше здесь был float(...) и игра падала).
		var target: Vector3 = stock.global_position + stock.layout_basis * (stock.stack_step * float(stack_index))
		var delay: float = float(index) * card_return_stagger
		var duration: float = card_return_duration + swirl_duration

		var path := {
			"start": card.global_position,
			"center": center,
			"target": target,
			"turn": 1.0 if index % 2 == 0 else -1.0,
		}
		var tween: Tween = create_tween()
		tween.tween_interval(delay)
		tween.tween_method(_place_swirl_card.bind(card, path), 0.0, 1.0, duration)
		tween.tween_callback(_set_card_face_down.bind(card))
		longest_time = maxf(longest_time, delay + duration)

	return longest_time


## Положение карты на спирали: сначала закручивается вокруг центра стола
## и поднимается, затем по сужающейся спирали садится в колоду.
func _place_swirl_card(t: float, card: Card, path: Dictionary) -> void:
	if not is_instance_valid(card):
		return
	var start: Vector3 = path["start"]
	var center: Vector3 = path["center"]
	var target: Vector3 = path["target"]
	var turn: float = path["turn"]

	var from_offset := start - center
	from_offset.y = 0.0
	var to_offset := target - center
	to_offset.y = 0.0
	var start_angle := atan2(from_offset.z, from_offset.x)
	var end_angle := atan2(to_offset.z, to_offset.x)
	var eased := t * t * (3.0 - 2.0 * t)

	var radius := lerpf(from_offset.length(), to_offset.length(), eased)
	radius *= 1.0 - 0.35 * sin(t * PI)   # затягивает внутрь в середине пути
	var angle := lerpf(start_angle, end_angle + turn * TAU * swirl_turns, eased)
	var height := lerpf(start.y, target.y, eased) + sin(t * PI) * card_return_arc_height
	card.global_position = center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius) + Vector3(0.0, height - center.y, 0.0)
	card.rotation.y = angle * 0.5


func _set_card_face_down(card: Card) -> void:
	if is_instance_valid(card):
		card.set_face_up(false)

# ==================================================
# VICTORY
# ==================================================

func _on_game_won() -> void:
	if victory_sequence_started:
		return
	victory_sequence_started = true
	_record_win()
	_block_gameplay_mouse()

	await get_tree().create_timer(victory_show_delay).timeout
	if not is_inside_tree():
		return

	var animation_time: float = _animate_cards_to_stock()
	if animation_time > 0.0:
		await get_tree().create_timer(animation_time + 0.08).timeout
	if not is_inside_tree():
		return

	_show_victory_window()


func _block_gameplay_mouse() -> void:
	if is_instance_valid(victory_input_layer):
		return

	victory_input_layer = CanvasLayer.new()
	victory_input_layer.name = "VictoryInputBlocker"
	victory_input_layer.layer = 90

	add_child(victory_input_layer)

	var blocker := Control.new()
	blocker.name = "MouseBlocker"
	blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP

	victory_input_layer.add_child(blocker)


# ==================================================
# VICTORY WINDOW
# ==================================================

func _show_victory_window() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 100
	layer.name = "VictoryWindow"

	add_child(layer)

	var overlay := ColorRect.new()
	overlay.color = Color(0.02, 0.015, 0.01, 0.72)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP

	layer.add_child(overlay)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE

	overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(440, 0)

	var panel_style := _victory_box(
		Color("#1d120c"),
		Color("#8a6a3a")
	)

	panel_style.set_corner_radius_all(18)
	panel.add_theme_stylebox_override("panel", panel_style)

	center.add_child(panel)

	var margin := MarginContainer.new()

	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override(
			"margin_" + side,
			28
		)

	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)

	margin.add_child(box)

	var lost := _is_network_loss()

	var title := Label.new()
	title.text = "ПОРАЖЕНИЕ" if lost else "ПОБЕДА!"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override(
		"font_color",
		Color("#e8c36a")
	)

	box.add_child(title)

	var description := Label.new()
	description.text = _result_text()
	description.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	description.add_theme_font_size_override("font_size", 18)
	description.add_theme_color_override(
		"font_color",
		Color("#a8957a")
	)

	box.add_child(description)

	# Итоги именно этой партии, а не общая статистика профиля.
	var stats := Label.new()
	stats.text = "Ходы: %d     Отмены: %d\nВремя: %s" % [
		game_manager.moves_count,
		game_manager.undo_count,
		_format_elapsed_time(),
	]
	stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stats.add_theme_font_size_override("font_size", 18)
	stats.add_theme_color_override("font_color", Color("#f3e6c8"))
	box.add_child(stats)

	var new_game_button := Button.new()
	new_game_button.text = "НОВАЯ ПАРТИЯ"
	new_game_button.custom_minimum_size = Vector2(280, 56)

	_style_victory_button(new_game_button, true)
	new_game_button.pressed.connect(_on_victory_new_game)

	victory_new_game_button = new_game_button
	box.add_child(new_game_button)

	var menu_button := Button.new()
	menu_button.text = "ГЛАВНОЕ МЕНЮ"
	menu_button.custom_minimum_size = Vector2(280, 56)

	_style_victory_button(menu_button)
	menu_button.pressed.connect(_on_victory_main_menu)

	box.add_child(menu_button)

	# Анимация появления окна.
	overlay.modulate.a = 0.0
	panel.modulate.a = 0.0
	panel.scale = Vector2(0.85, 0.85)

	await get_tree().process_frame

	panel.pivot_offset = panel.size / 2.0

	var tween := create_tween()
	tween.set_parallel(true)

	tween.tween_property(
		overlay,
		"modulate:a",
		1.0,
		0.25
	)

	tween.tween_property(
		panel,
		"modulate:a",
		1.0,
		0.25
	)

	tween.tween_property(
		panel,
		"scale",
		Vector2.ONE,
		0.4
	).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	new_game_button.grab_focus()


# ==================================================
# VICTORY STYLE
# ==================================================

func _victory_box(bg: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()

	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(14)

	style.shadow_color = Color(0, 0, 0, 0.4)
	style.shadow_size = 6

	style.content_margin_left = 20
	style.content_margin_right = 20
	style.content_margin_top = 12
	style.content_margin_bottom = 12

	return style


func _style_victory_button(
	button: Button,
	primary := false
) -> void:
	var base := Color("#c98a2b") if primary else Color("#2b1a12")
	var border := Color("#e8c36a") if primary else Color("#8a6a3a")

	button.add_theme_stylebox_override(
		"normal",
		_victory_box(base, border)
	)

	button.add_theme_stylebox_override(
		"hover",
		_victory_box(
			base.lightened(0.15),
			border.lightened(0.2)
		)
	)

	button.add_theme_stylebox_override(
		"pressed",
		_victory_box(base.darkened(0.15), border)
	)

	button.add_theme_stylebox_override(
		"focus",
		_victory_box(
			base.lightened(0.15),
			Color("#ffe9a8")
		)
	)

	button.add_theme_color_override(
		"font_color",
		Color("#f3e6c8")
	)

	button.add_theme_color_override(
		"font_hover_color",
		Color.WHITE
	)

	button.add_theme_font_size_override("font_size", 22)


func _on_rematch_state_changed(state: String, _message: String) -> void:
	if is_instance_valid(victory_new_game_button):
		match state:
			"WAITING":
				victory_new_game_button.text = "ОТМЕНИТЬ ЗАПРОС"
				victory_new_game_button.disabled = false
			"DECLINED":
				victory_new_game_button.text = "ПОВТОРИТЬ ЗАПРОС"
				victory_new_game_button.disabled = false
			"STARTING":
				victory_new_game_button.text = "ЗАПУСК..."
				victory_new_game_button.disabled = true
			"IDLE":
				victory_new_game_button.text = "НОВАЯ ПАРТИЯ"
				victory_new_game_button.disabled = false
	if state != "INVITATION" and is_instance_valid(_rematch_invitation_layer):
		_rematch_invitation_layer.queue_free()
		_rematch_invitation_layer = null


func _on_rematch_invitation_received(requester_slot: int) -> void:
	if is_instance_valid(_rematch_invitation_layer):
		return
	_rematch_invitation_layer = CanvasLayer.new()
	_rematch_invitation_layer.name = "RematchInvitation"
	_rematch_invitation_layer.layer = 110
	add_child(_rematch_invitation_layer)

	var overlay := ColorRect.new()
	overlay.color = Color(0.02, 0.015, 0.01, 0.78)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_rematch_invitation_layer.add_child(overlay)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(420, 0)
	panel.add_theme_stylebox_override("panel", _victory_box(Color("#1d120c"), Color("#8a6a3a")))
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	margin.add_child(box)

	var title := Label.new()
	title.text = "НОВАЯ ПАРТИЯ?"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color("#e8c36a"))
	box.add_child(title)

	var description := Label.new()
	description.text = "%s предлагает сыграть ещё раз. Начать новую партию у обоих игроков?" % NetworkMatchState.name_of(requester_slot)
	description.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.add_theme_font_size_override("font_size", 18)
	description.add_theme_color_override("font_color", Color("#f3e6c8"))
	box.add_child(description)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 12)
	box.add_child(buttons)

	var accept := Button.new()
	accept.text = "ПРИНЯТЬ"
	accept.custom_minimum_size = Vector2(150, 52)
	_style_victory_button(accept, true)
	accept.pressed.connect(_answer_rematch_invitation.bind(true))
	buttons.add_child(accept)

	var decline := Button.new()
	decline.text = "ОТКЛОНИТЬ"
	decline.custom_minimum_size = Vector2(150, 52)
	_style_victory_button(decline, false)
	decline.pressed.connect(_answer_rematch_invitation.bind(false))
	buttons.add_child(decline)


func _answer_rematch_invitation(accepted: bool) -> void:
	if is_instance_valid(_rematch_invitation_layer):
		_rematch_invitation_layer.queue_free()
		_rematch_invitation_layer = null
	if _network_sync != null:
		_network_sync.answer_rematch(accepted)



# ==================================================
# BUTTON ACTIONS
# ==================================================

func _on_victory_new_game() -> void:
	if NetworkMatchState.active:
		if _network_sync == null:
			_network_sync = NetworkMatchSync.find_in(get_tree())
		if _network_sync == null:
			push_warning("GameConsole: сетевой узел синхронизации не найден; локальный перезапуск отменён.")
			return
		_network_sync.request_rematch()
		return
	if not is_instance_valid(game_manager):
		get_tree().reload_current_scene()
		return

	GameSession.start_level(
		get_tree(),
		game_manager.current_mode,
		game_manager.draw_mode,
		game_manager.spider_suits
	)


func _on_victory_main_menu() -> void:
	if main_menu_scene_path.is_empty():
		push_error("GameConsole: не указан путь к главному меню.")
		return

	if not ResourceLoader.exists(main_menu_scene_path):
		push_error(
			"GameConsole: сцена меню не найдена: " +
			main_menu_scene_path
		)
		return

	get_tree().change_scene_to_file(main_menu_scene_path)

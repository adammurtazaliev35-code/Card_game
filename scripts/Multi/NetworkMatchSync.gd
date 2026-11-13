extends Node
class_name NetworkMatchSync

## Синхронизация партии между двумя клиентами GD-Sync.
##
## Создаётся GameManager-ом в сетевой партии как дочерний узел с именем
## "NetworkMatchSync", поэтому путь /root/<Level>/NetworkMatchSync одинаков
## на обоих клиентах (GD-Sync находит узлы по NodePath).
##
## Модель — «снимок поля», а не повтор ходов:
##  - после каждого локального изменения истории (ход, взятие из колоды,
##    переворот, Foundation, сбор масти, отмена) GameManager шлёт history_changed;
##  - мы отправляем сопернику точный состав всех стопок своего поля;
##  - соперник раскладывает уже существующие карты по этим стопкам.
## Снимок идемпотентен: повторное получение ничего не меняет, а применение
## чужого снимка не пишет историю и не вызывает history_changed — поэтому
## полученное событие никогда не отправляется обратно в сеть.

signal session_state_changed(active: bool, opponent_connected: bool, local_slot: int)
signal remote_stats_changed(slot: int, stats: Dictionary)
## Invite/consent flow for starting a fresh match after the current result.
signal rematch_invitation_received(requester_slot: int)
signal rematch_state_changed(state: String, message: String)

const NODE_NAME := "NetworkMatchSync"
const VOICE_CHAT_CONTROLLER := preload("res://scripts/Multi/NetworkVoiceChat.gd")
const SNAPSHOT_VERSION := 1
const FIELD_MAIN := "main"
const FACE_UP_FLAG := 1024

var game_manager: GameManager
var local_slot := 0
var opponent_connected := false

var _send_seq := 0
var _last_remote_seq := -1
var _pending_snapshot: Dictionary = {}
var _applying_remote := false
var _local_deal_done := false
var _remote_stats: Dictionary = {}   # slot -> {"moves", "undos", "available", "charges"}
var _shared_lock_until_ms := 0
const SHARED_LOCK_MS := 600

var _rematch_outgoing_id := 0
var _rematch_incoming_id := 0
var _rematch_incoming_slot := 0
var _rematch_start_sent := false
var _rematch_scene_started := false


static func is_network_match() -> bool:
	return NetworkMatchState.active and GDSync.is_active()


static func find_in(tree: SceneTree) -> NetworkMatchSync:
	if tree == null:
		return null
	return tree.get_first_node_in_group("network_match_sync") as NetworkMatchSync


func setup(manager: GameManager) -> void:
	game_manager = manager


func _ready() -> void:
	# Пауза в сетевой партии не должна останавливать приём ходов соперника.
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("network_match_sync")
	if game_manager == null:
		game_manager = get_parent() as GameManager

	local_slot = NetworkMatchState.slot_of(int(GDSync.get_client_id()))
	var voice_controller := VOICE_CHAT_CONTROLLER.new()
	voice_controller.name = "NetworkVoiceChat"
	add_child(voice_controller)
	if local_slot == 0:
		push_warning("NetworkMatchSync: локальный клиент %d не найден в составе партии." % GDSync.get_client_id())

	GDSync.expose_func(_receive_snapshot)
	GDSync.expose_func(_receive_hello)
	GDSync.expose_func(_receive_surrender)
	GDSync.expose_func(_receive_match_result)
	GDSync.expose_func(_receive_rematch_invitation)
	GDSync.expose_func(_receive_rematch_response)
	GDSync.expose_func(_receive_rematch_cancel)
	GDSync.expose_func(_receive_rematch_start)

	game_manager.history_changed.connect(_on_history_changed)
	game_manager.deal_finished.connect(_on_deal_finished)
	GDSync.client_left.connect(_on_client_left)
	GDSync.client_joined.connect(_on_client_joined)
	GDSync.disconnected.connect(_on_disconnected)

	opponent_connected = GDSync.lobby_get_all_clients().has(get_opponent_id())
	_send_hello(true)
	_emit_session_state()


# ==================================================
# ВЛАДЕНИЕ ПОЛЯМИ
# ==================================================
func get_opponent_slot() -> int:
	return 2 if local_slot == 1 else (1 if local_slot == 2 else 0)


func get_opponent_id() -> int:
	return NetworkMatchState.id_of(get_opponent_slot())


## Зеркальная раскладка (Клондайк и Паук): у каждого игрока своё поле и своя колода.
## Кольцевая раскладка — одно общее поле.
func is_split_ownership() -> bool:
	if game_manager == null:
		return false
	return GameSession.get_board_layout(game_manager.current_mode) == GameSession.BOARD_LAYOUT_MIRRORED


## Идентификатор поля игрока: "main" — поле игрока 1, Coop_MIRRORED — поле игрока 2.
func field_of_slot(slot: int) -> String:
	if slot == 2 and is_split_ownership():
		return "Coop_MIRRORED"
	return FIELD_MAIN


func get_field_id(pile: Pile) -> String:
	if pile == null or not is_instance_valid(pile.owner_marker) or game_manager == null:
		return FIELD_MAIN
	var root: Node3D = game_manager._resolve_markers_root()
	if root == null:
		return FIELD_MAIN
	var coop_root := root.get_node_or_null("CoopPresets")
	var node: Node = pile.owner_marker
	while node != null and node != root:
		if coop_root != null and node.get_parent() == coop_root:
			return str(node.name)
		node = node.get_parent()
	return FIELD_MAIN


## Владелец стопки: 1, 2 или 0 (общая стопка).
func get_pile_owner_slot(pile: Pile) -> int:
	if not is_split_ownership():
		return 0
	return 2 if get_field_id(pile) == field_of_slot(2) else 1


## Может ли локальный игрок трогать эту стопку и её карты.
func can_local_interact(pile: Pile) -> bool:
	if not is_network_match():
		return true
	if local_slot == 0:
		return false
	var owner_slot := get_pile_owner_slot(pile)
	return owner_slot == 0 or owner_slot == local_slot


## Общее поле (кольцо): пока не улёгся чужой ход, свою раздачу из общей колоды
## не начинаем — иначе два одновременных клика перекидывают карты туда-обратно.
func is_shared_pile_locked(pile: Pile) -> bool:
	if not is_network_match() or get_pile_owner_slot(pile) != 0:
		return false
	return Time.get_ticks_msec() < _shared_lock_until_ms


func get_remote_stats(slot: int) -> Dictionary:
	return _remote_stats.get(slot, {})


# ==================================================
# ОТПРАВКА
# ==================================================
func _on_history_changed(_count: int) -> void:
	# history_changed шлют commit() и undo() — то есть только локальные действия.
	# Во время применения чужого снимка истории никто не касается,
	# но флаг дополнительно страхует от эха.
	if _applying_remote or not _local_deal_done:
		return
	_send_snapshot()


func _on_deal_finished() -> void:
	_local_deal_done = true
	# Раздача у обоих одинаковая (общий сид), но снимок гарантирует совпадение
	# даже если сид не дошёл, и сообщает сопернику, что мы готовы.
	_send_hello(false)
	_send_snapshot()
	if not _pending_snapshot.is_empty():
		var pending := _pending_snapshot
		_pending_snapshot = {}
		_apply_snapshot(pending)


func _send_snapshot() -> void:
	if not is_network_match() or local_slot == 0 or game_manager == null:
		return
	_send_seq += 1
	var piles_data := {}
	for pile in _local_scope_piles():
		piles_data[_pile_key(pile)] = _encode_pile(pile)
	var undo_history_count := game_manager.history.size()
	if is_split_ownership():
		undo_history_count = game_manager.get_field_history_count(field_of_slot(local_slot))
	var payload := {
		"v": SNAPSHOT_VERSION,
		"seq": _send_seq,
		"slot": local_slot,
		"piles": piles_data,
		"stats": {
			"moves": game_manager.moves_count,
			"undos": game_manager.undo_count,
			"available": mini(undo_history_count, game_manager.undo_charges),
			"charges": game_manager.undo_charges,
		},
	}
	GDSync.call_func(_receive_snapshot, payload)


func _send_hello(want_reply: bool) -> void:
	if not is_network_match() or local_slot == 0:
		return
	GDSync.call_func(_receive_hello, local_slot, want_reply)


## Стопки, состояние которых этот клиент имеет право публиковать.
func _local_scope_piles() -> Array[Pile]:
	var result: Array[Pile] = []
	for pile in game_manager.piles:
		if not is_instance_valid(pile):
			continue
		if is_split_ownership() and get_pile_owner_slot(pile) != local_slot:
			continue
		result.append(pile)
	return result


func _pile_key(pile: Pile) -> String:
	var root: Node3D = game_manager._resolve_markers_root()
	if root != null and is_instance_valid(pile.owner_marker):
		return str(root.get_path_to(pile.owner_marker))
	return "#%d" % game_manager.piles.find(pile)


## Ключ стопки, одинаковый на обоих клиентах (путь маркера от Markers).
func get_pile_key(pile: Pile) -> String:
	if pile == null or game_manager == null:
		return ""
	return _pile_key(pile)


func find_pile_by_key(key: String) -> Pile:
	if key.is_empty() or game_manager == null:
		return null
	for pile in game_manager.piles:
		if is_instance_valid(pile) and _pile_key(pile) == key:
			return pile
	return null


func _encode_card(card: Card) -> int:
	return (int(card.suit) << 5) | int(card.rank) | (FACE_UP_FLAG if card.face_up else 0)


func _encode_pile(pile: Pile) -> Array:
	var codes: Array = []
	for card in pile.cards:
		if is_instance_valid(card):
			codes.append(_encode_card(card))
	return codes


# ==================================================
# ПРИЁМ
# ==================================================
func _receive_hello(sender_slot: int, want_reply: bool) -> void:
	if not is_network_match() or sender_slot == local_slot:
		return
	if NetworkMatchState.slot_of(int(GDSync.get_sender_id())) != sender_slot:
		return
	_set_opponent_connected(true)
	if want_reply:
		_send_hello(false)
	# Соперник только что загрузил сцену (или вернулся): отдаём ему актуальное поле.
	if _local_deal_done:
		_send_snapshot()


func _receive_snapshot(payload: Dictionary) -> void:
	if not is_network_match():
		return
	if int(payload.get("v", 0)) != SNAPSHOT_VERSION:
		push_warning("NetworkMatchSync: несовместимая версия снимка.")
		return
	var sender_slot := int(payload.get("slot", 0))
	if sender_slot == 0 or sender_slot == local_slot:
		return
	# Слот из данных должен совпадать с реальным отправителем GD-Sync.
	if NetworkMatchState.slot_of(int(GDSync.get_sender_id())) != sender_slot:
		return
	var seq := int(payload.get("seq", 0))
	if seq <= _last_remote_seq:
		return   # дубликат или устаревший снимок
	_last_remote_seq = seq
	_set_opponent_connected(true)

	var stats: Dictionary = payload.get("stats", {})
	_remote_stats[sender_slot] = stats
	remote_stats_changed.emit(sender_slot, stats)

	if game_manager.is_dealing or not _local_deal_done:
		# Наша раздача ещё идёт: применим после deal_finished (последний снимок важнее).
		_pending_snapshot = payload
		return
	_apply_snapshot(payload)


func _apply_snapshot(payload: Dictionary) -> void:
	var sender_slot := int(payload.get("slot", 0))
	var piles_data: Dictionary = payload.get("piles", {})
	var by_key := {}
	for pile in game_manager.piles:
		if is_instance_valid(pile):
			by_key[_pile_key(pile)] = pile

	# 1. Проверяем, что все стопки существуют и принадлежат отправителю.
	var targets: Array[Pile] = []
	var wanted: Array = []
	var changed := false
	for key in piles_data.keys():
		var pile := by_key.get(str(key)) as Pile
		if pile == null:
			push_warning("NetworkMatchSync: стопка '%s' не найдена — раскладки клиентов различаются." % key)
			return
		if is_split_ownership() and get_pile_owner_slot(pile) != sender_slot:
			push_warning("NetworkMatchSync: отклонён снимок чужого поля (%s)." % key)
			return
		var codes: Array = piles_data[key]
		targets.append(pile)
		wanted.append(codes)
		if codes != _encode_pile(pile):
			changed = true
	if not changed:
		return

	# 2. Пул реальных карт этих стопок: карты не создаются и не удаляются.
	var pool := {}
	var total_cards := 0
	for pile in targets:
		for card in pile.cards:
			if not is_instance_valid(card):
				continue
			var base := _encode_card(card) & ~FACE_UP_FLAG
			if not pool.has(base):
				pool[base] = []
			pool[base].append(card)
			total_cards += 1
	var wanted_total := 0
	for codes in wanted:
		wanted_total += (codes as Array).size()
	if wanted_total != total_cards:
		push_warning("NetworkMatchSync: число карт в снимке (%d) не совпадает с полем (%d)." % [wanted_total, total_cards])
		return

	var plan: Array = []   # [pile, Array[Card], Array[bool]]
	for i in targets.size():
		var cards_for_pile: Array[Card] = []
		var faces: Array[bool] = []
		for code_variant in wanted[i]:
			var code := int(code_variant)
			var base := code & ~FACE_UP_FLAG
			var bucket: Array = pool.get(base, [])
			if bucket.is_empty():
				push_warning("NetworkMatchSync: в снимке есть карта, которой нет на поле (%d)." % base)
				return
			cards_for_pile.append(bucket.pop_back())
			faces.append((code & FACE_UP_FLAG) != 0)
		plan.append([targets[i], cards_for_pile, faces])

	# 3. Применяем. Если локальный игрок тянет карты из этих стопок (общее поле) — отменяем.
	_applying_remote = true
	_cancel_local_drag_if_touching(targets)
	for entry in plan:
		var pile: Pile = entry[0]
		var cards_for_pile: Array[Card] = entry[1]
		var faces: Array[bool] = entry[2]
		for j in cards_for_pile.size():
			var card := cards_for_pile[j]
			if card.face_up != faces[j]:
				card.set_face_up(faces[j])
			pile.add_card(card)
	for pile in targets:
		pile.relayout()
	if not is_split_ownership():
		_shared_lock_until_ms = Time.get_ticks_msec() + SHARED_LOCK_MS
		if not game_manager.history.is_empty():
			# Общее поле: старые записи отмены ссылаются на позиции до хода соперника.
			game_manager.history.clear()
	_applying_remote = false

	game_manager.notify_external_change()


func _cancel_local_drag_if_touching(targets: Array[Pile]) -> void:
	var card_manager := get_tree().get_first_node_in_group("card_manager") as CardManager
	if card_manager != null and card_manager.is_dragging_from_any(targets):
		card_manager._cancel_drag()


# ==================================================
# ОТМЕНА ХОДА (кнопки UndoBtnP1/P2 на табло)
# ==================================================
func handle_undo_request(player_slot: int) -> void:
	if player_slot != local_slot or game_manager == null:
		return
	var field_id := field_of_slot(local_slot)
	if game_manager.get_field_history_count(field_id) <= 0 or game_manager.undo_charges <= 0:
		return
	# undo() шлёт history_changed — снимок уйдёт сопернику автоматически.
	game_manager.undo(true, field_id)


# ==================================================
# СДАЧА (окончательный тупик)
# ==================================================
func send_surrender(field_id: String) -> void:
	if not is_network_match() or local_slot == 0:
		return
	if field_id != field_of_slot(local_slot):
		return   # сдаваться можно только за своё поле
	GDSync.call_func(_receive_surrender, local_slot)


func _receive_surrender(sender_slot: int) -> void:
	if not is_network_match() or sender_slot == local_slot:
		return
	if NetworkMatchState.slot_of(int(GDSync.get_sender_id())) != sender_slot:
		return
	# Соперник сдался — его поле проиграло, победа за нами.
	game_manager.surrender(field_of_slot(sender_slot), false)

# ==================================================
# РЕЗУЛЬТАТ СОРЕВНОВАТЕЛЬНОГО МАТЧА
# ==================================================

## Отправляет результат, когда локальное поле первым завершило цель.
func send_match_result(winning_field: String) -> void:
	if not is_network_match() or not is_split_ownership() or local_slot == 0:
		return
	if winning_field != field_of_slot(local_slot):
		return
	GDSync.call_func(_receive_match_result, local_slot, winning_field)


## Получает объявление победителя. Проверяем реального отправителя и то,
## что он объявляет победителем именно собственное поле.
func _receive_match_result(sender_slot: int, winning_field: String) -> void:
	if not is_network_match() or not is_split_ownership() or game_manager == null:
		return
	if sender_slot == local_slot or sender_slot not in [1, 2]:
		return
	if NetworkMatchState.slot_of(int(GDSync.get_sender_id())) != sender_slot:
		return
	if winning_field != field_of_slot(sender_slot):
		push_warning("NetworkMatchSync: отклонён недостоверный результат матча.")
		return
	game_manager._finish_competitive_match(winning_field, false)


# ==================================================
# ПОВТОРНАЯ ПАРТИЯ (оба игрока должны согласиться)
# ==================================================

## Первый клик отправляет приглашение. Повторный клик отменяет свой запрос.
func request_rematch() -> void:
	if not is_network_match() or local_slot == 0:
		rematch_state_changed.emit("ERROR", "Сетевая партия больше не активна.")
		return
	if not opponent_connected:
		rematch_state_changed.emit("ERROR", "Соперник отключён.")
		return
	if _rematch_outgoing_id != 0:
		cancel_rematch_request()
		return
	if _rematch_incoming_id != 0:
		answer_rematch(true)
		return

	_rematch_outgoing_id = maxi(1, int(Time.get_ticks_usec() & 0x7fffffff))
	_rematch_start_sent = false
	GDSync.call_func(_receive_rematch_invitation, local_slot, _rematch_outgoing_id)
	rematch_state_changed.emit("WAITING", "Ожидаем согласия соперника. Повторное нажатие отменит запрос.")


func cancel_rematch_request() -> void:
	if _rematch_outgoing_id == 0:
		return
	var request_id := _rematch_outgoing_id
	_rematch_outgoing_id = 0
	GDSync.call_func(_receive_rematch_cancel, local_slot, request_id)
	rematch_state_changed.emit("IDLE", "Запрос новой партии отменён.")


## Вызывается интерфейсом приглашённого игрока.
func answer_rematch(accepted: bool) -> void:
	if _rematch_incoming_id == 0 or _rematch_incoming_slot == 0:
		return
	var request_id := _rematch_incoming_id
	var requester_slot := _rematch_incoming_slot
	_rematch_incoming_id = 0
	_rematch_incoming_slot = 0

	if not accepted:
		GDSync.call_func(_receive_rematch_response, local_slot, request_id, false)
		rematch_state_changed.emit("IDLE", "Приглашение отклонено.")
		return

	if GDSync.is_host():
		# Хост единственный выбирает параметры и запускает смену сцены.
		_start_rematch_as_host()
	else:
		# Гость подтверждает приглашение хоста; запуск выполняет хост.
		if requester_slot != NetworkMatchState.slot_of(int(GDSync.get_host())):
			push_warning("NetworkMatchSync: только хост может подтвердить запуск новой партии.")
			rematch_state_changed.emit("ERROR", "Новая партия должна быть запущена хостом.")
			return
		GDSync.call_func(_receive_rematch_response, local_slot, request_id, true)
		rematch_state_changed.emit("WAITING", "Согласие отправлено. Ожидаем запуск от хоста.")


func _receive_rematch_invitation(requester_slot: int, request_id: int) -> void:
	if not is_network_match() or requester_slot != get_opponent_slot() or request_id <= 0:
		return
	if NetworkMatchState.slot_of(int(GDSync.get_sender_id())) != requester_slot:
		return
	if _rematch_incoming_id == request_id:
		return

	# Если оба игрока почти одновременно нажали «Новая партия», это взаимное согласие.
	if _rematch_outgoing_id != 0:
		if GDSync.is_host():
			_start_rematch_as_host()
		else:
			GDSync.call_func(_receive_rematch_response, local_slot, request_id, true)
			rematch_state_changed.emit("WAITING", "Оба игрока запросили новую партию. Ожидаем хоста.")
		return

	_rematch_incoming_id = request_id
	_rematch_incoming_slot = requester_slot
	rematch_state_changed.emit("INVITATION", "Соперник предлагает начать новую партию.")
	rematch_invitation_received.emit(requester_slot)


func _receive_rematch_response(responder_slot: int, request_id: int, accepted: bool) -> void:
	if not is_network_match():
		return
	if responder_slot != get_opponent_slot() or request_id != _rematch_outgoing_id:
		return
	if NetworkMatchState.slot_of(int(GDSync.get_sender_id())) != responder_slot:
		return
	if not accepted:
		_rematch_outgoing_id = 0
		rematch_state_changed.emit("DECLINED", "Соперник отклонил приглашение.")
		return
	# Положительный ответ запускает матч только на хосте. Если ответ пришёл
	# гостю, это лишь подтверждение встречного запроса; хост пришлёт Start.
	if GDSync.is_host():
		_start_rematch_as_host()
	else:
		rematch_state_changed.emit("WAITING", "Согласие получено. Ожидаем запуск от хоста.")


func _receive_rematch_cancel(sender_slot: int, request_id: int) -> void:
	if not is_network_match() or sender_slot != get_opponent_slot():
		return
	if NetworkMatchState.slot_of(int(GDSync.get_sender_id())) != sender_slot:
		return
	if _rematch_incoming_id != request_id or _rematch_incoming_slot != sender_slot:
		return
	_rematch_incoming_id = 0
	_rematch_incoming_slot = 0
	rematch_state_changed.emit("IDLE", "Соперник отменил приглашение.")


func _start_rematch_as_host() -> void:
	if not is_network_match() or not GDSync.is_host() or _rematch_start_sent:
		return
	if game_manager == null:
		push_warning("NetworkMatchSync: нельзя начать новую партию без GameManager.")
		return
	_rematch_start_sent = true
	var seed_value := randi_range(1, 2147483646)
	var mode := game_manager.current_mode
	var draw := game_manager.draw_mode
	var suits := game_manager.spider_suits
	# call_func направляет событие только второму игроку; локальный запуск
	# выполняем отдельно, чтобы сцены сменились на обоих клиентах ровно один раз.
	GDSync.call_func(_receive_rematch_start, seed_value, mode, draw, suits)
	rematch_state_changed.emit("STARTING", "Соперник согласился. Запускаем новую партию.")
	call_deferred("_apply_rematch_start", seed_value, mode, draw, suits)


func _receive_rematch_start(seed_value: int, mode: int, draw: int, suits: int) -> void:
	if not is_network_match() or GDSync.is_host() or _rematch_scene_started:
		return
	if int(GDSync.get_sender_id()) != int(GDSync.get_host()):
		return
	_apply_rematch_start(seed_value, mode, draw, suits)


func _apply_rematch_start(seed_value: int, mode: int, draw: int, suits: int) -> void:
	if _rematch_scene_started or not is_network_match():
		return
	rematch_state_changed.emit("STARTING", "Соперник согласился. Запускаем новую партию.")
	if mode not in [GameSession.MODE_KLONDIKE, GameSession.MODE_SPIDER]:
		push_warning("NetworkMatchSync: получен неизвестный режим новой партии.")
		return
	if draw not in [GameSession.DRAW_ONE, GameSession.DRAW_THREE]:
		push_warning("NetworkMatchSync: получен неизвестный режим раздачи.")
		return
	_rematch_scene_started = true
	_rematch_outgoing_id = 0
	_rematch_incoming_id = 0
	_rematch_incoming_slot = 0
	NetworkMatchState.deal_seed = maxi(1, seed_value)
	NetworkMatchState.field_decks.clear()
	GameSession.is_multiplayer = true
	GameSession.start_level(get_tree(), mode, draw, suits)



# ==================================================
# ПОДКЛЮЧЕНИЕ
# ==================================================
func _on_client_left(client_id: int) -> void:
	if client_id == get_opponent_id():
		_set_opponent_connected(false)
		_rematch_outgoing_id = 0
		_rematch_incoming_id = 0
		_rematch_incoming_slot = 0
		rematch_state_changed.emit("IDLE", "Соперник отключился.")


func _on_client_joined(client_id: int) -> void:
	if client_id == get_opponent_id():
		_set_opponent_connected(true)
		_send_hello(false)
		if _local_deal_done:
			_send_snapshot()


func _on_disconnected() -> void:
	opponent_connected = false
	_rematch_outgoing_id = 0
	_rematch_incoming_id = 0
	_rematch_incoming_slot = 0
	_emit_session_state()
	rematch_state_changed.emit("IDLE", "Сетевое соединение закрыто.")


func _set_opponent_connected(value: bool) -> void:
	if opponent_connected == value:
		return
	opponent_connected = value
	_emit_session_state()


func _emit_session_state() -> void:
	session_state_changed.emit(is_network_match(), opponent_connected, local_slot)

extends Node3D
class_name GameManager

enum GameMode { SPIDER = 1, KLONDIKE = 2 }
@export var spider_done_scene: PackedScene
@export_group("Раскладки стола")
@export var markers_root: Node3D
var active_markers: Array[PileMarker] = []
signal deal_finished
signal moves_state_changed(can_move: bool)
signal history_changed(move_count: int)
signal no_moves_left
signal game_won
signal statistics_changed(
	moves_count: int,
	undo_count: int,
	available_undos: int,
	undo_charges: int
)
signal board_counts_changed(deck_count: int, field_count: int)
## Вердикт предсказателя по полю (KlondikePredictor.Verdict) — для табло и тупика.
signal field_verdict_changed(field_id: String, verdict: int, info: Dictionary)
## Подсказка готова: entries — описания ходов (text, from_pile, to_pile, card_index).
signal hint_ready(field_id: String, entries: Array)
## Подсказки/отмены закончились — момент предложить rewarded-рекламу.
signal hint_limit_reached
signal undo_limit_reached
signal hints_changed(hint_charges: int, hints_used: int)
## Партия проиграна (сдача). winner_field — поле победителя ("" в одиночной игре).
signal game_lost(winner_field: String)

## Поле победителя: соревновательные режимы и сдача. "" — не определено.
var winner_field := ""
## Поле, игрок которого сдался ("" — никто).
var surrendered_field := ""

## Баланс лимитов (отмены, подсказки, награды). Пусто — res://resources/game_limits.tres.
@export var limits: GameLimits
# Пока режим выбирается числом в инспекторе. Из меню приходит через GameSession.
@export_range(1, 2, 1) var mode_id: int = 2
## Сложность колоды в Клондайке: 1 = по одной карте (draw 1), 2 = по три (draw 3)
@export_range(1, 2, 1) var draw_mode_id: int = 1

@export var deal_delay: float = 0.06
@export var tableau_scene: PackedScene
@export var foundation_scene: PackedScene
@export var stock_scene: PackedScene
@export var waste_scene: PackedScene

@export_group("Паук")
## Сложность Паука: сколько мастей в колоде
@export_enum("1 масть:1", "2 масти:2", "4 масти:4") var spider_suits: int = 4
## Во сколько раз закрытые карты в колонке лежат плотнее открытых
@export_range(0.2, 1.0, 0.05) var spider_facedown_ratio := 0.45
## Максимальная длина колонки по Z, метры (0 = без ограничения). Подберите под размер стола.
@export var spider_column_max_length := 0.3

var piles: Array[Pile] = []
var active_marker_container: Node3D
var current_mode: int = 0
var draw_mode: int = 1
var rules: GameRules = null

var history: Array[MoveRecord] = []
var moves_count: int = 0
var undo_count: int = 0

# Стартовый запас отмен на одну партию (берётся из limits.undo_start).
var undo_limit: int = 3

# Сколько отмен осталось потратить.
var undo_charges: int = 3

# Подсказки: сколько осталось и сколько уже использовано в партии.
var hint_charges: int = 3
var hints_used: int = 0

## Последние вердикты предсказателя: field_id -> {"verdict", ...}
var field_verdicts: Dictionary = {}
var _analysis_queued := false
var _analysis_task := -1
var _analysis_rerun := false
var _board_version := 0

# Защита от повторной обработки победы.
var game_finished: bool = false
var is_dealing := false

var _deal_token := 0

## Статистика по полям (зеркальная раскладка): field_id -> {"moves", "undos"}.
## field_id: "main" — поле Markers, иначе имя пресета (например "Coop_MIRRORED").
var field_stats: Dictionary = {}

const FIELD_MAIN := "main"
const DEADEND_PRESERVED_MOVES := 10


## Поле, которому принадлежит стопка.
func get_field_id(pile: Pile) -> String:
	if pile == null or not is_instance_valid(pile.owner_marker):
		return FIELD_MAIN
	var root := _resolve_markers_root()
	if root == null:
		return FIELD_MAIN
	var coop_root := root.get_node_or_null("CoopPresets")
	var node: Node = pile.owner_marker
	while node != null and node != root:
		if coop_root != null and node.get_parent() == coop_root:
			return str(node.name)
		node = node.get_parent()
	return FIELD_MAIN


func get_field_stats(field_id: String) -> Dictionary:
	var s: Dictionary = field_stats.get(field_id, {})
	return {
		"moves": int(s.get("moves", 0)),
		"undos": int(s.get("undos", 0)),
		"normal_resets": int(s.get("normal_resets", 0))
	}


## Количество записей истории, принадлежащих только этому полю.
func get_field_history_count(field_id: String) -> int:
	var count := 0
	for record in history:
		if _record_field(record) == field_id:
			count += 1
	return count


## Сколько последних ходов поля следует отменить при тупиковом сбросе.
## Первые десять записей текущей партии всегда сохраняются.
func get_deadend_reset_undo_count(field_id: String) -> int:
	return maxi(0, get_field_history_count(field_id) - DEADEND_PRESERVED_MOVES)


## Цена следующего обычного сброса для указанного поля.
func get_normal_reset_cost(field_id: String) -> int:
	return 10 + 5 * int(get_field_stats(field_id)["normal_resets"])


## Поле хода — по исходной стопке первой перенесённой карты.
func _record_field(record: MoveRecord) -> String:
	for s in record.steps:
		if s["type"] == "move" and s["from"] is Pile:
			return get_field_id(s["from"])
	for s in record.steps:
		var card: Card = s["card"]
		if is_instance_valid(card) and card.pile is Pile:
			return get_field_id(card.pile)
	return FIELD_MAIN



func _add_field_stat(field_id: String, key: String, delta: int) -> void:
	if not field_stats.has(field_id):
		field_stats[field_id] = {"moves": 0, "undos": 0, "normal_resets": 0}
	var stats: Dictionary = field_stats[field_id]
	stats[key] = maxi(0, int(stats.get(key, 0)) + delta)
	field_stats[field_id] = stats
func _ready() -> void:
	add_to_group("game_manager")
	if limits == null:
		limits = GameLimits.load_default()
	undo_limit = limits.undo_start
	no_moves_left.connect(func(): print("Ходов не осталось"))   # заменить на UI
	game_won.connect(func(): print("Победа!"))
	if not _is_background():
		GameAudio.get_instance(get_tree()).play_music()
		if get_node_or_null("PauseMenu") == null:
			var pm := PauseMenu.new()
			pm.name = "PauseMenu"
			add_child(pm)
		_setup_network_sync()
	start_game(mode_id)


## Сетевая партия: узел синхронизации ходов. Имя фиксированное, чтобы путь
## совпадал на обоих клиентах. В одиночной игре узел не создаётся.
func _setup_network_sync() -> void:
	if not NetworkMatchSync.is_network_match():
		return
	if get_node_or_null(NetworkMatchSync.NODE_NAME) != null:
		return
	var sync := NetworkMatchSync.new()
	sync.name = NetworkMatchSync.NODE_NAME
	sync.setup(self)
	add_child(sync)


## Поле изменилось не локальным ходом (пришёл снимок соперника):
## обновляем табло и проверяем победу, но историю не трогаем.
func notify_external_change() -> void:
	if is_dealing:
		return
	_emit_statistics()
	_emit_board_counts()
	_check_state()


## true, если уровень играет фоном в меню (внутри SubViewport): без звука и без паузы.
func _is_background() -> bool:
	return get_viewport() != get_tree().root




func get_deck_card_count() -> int:
	var total := 0

	for pile in piles:
		if not is_instance_valid(pile):
			continue

		if pile.kind == PileMarker.Kind.STOCK:
			total += pile.cards.size()

	return total


func get_field_card_count() -> int:
	var total := 0

	for pile in piles:
		if not is_instance_valid(pile):
			continue

		# Всё, что не находится в стопке добора.
		total += pile.cards.size() if pile.kind != PileMarker.Kind.STOCK else 0

	return total


func _emit_board_counts() -> void:
	board_counts_changed.emit(
		get_deck_card_count(),
		get_field_card_count()
	)


func _emit_statistics() -> void:
	var available := mini(history.size(), undo_charges)

	statistics_changed.emit(
		moves_count,
		undo_count,
		available,
		undo_charges
	)


# Единая точка входа: сюда приходит выбор из главного меню.
func start_game(mode: int) -> void:
	_clear_board()

	current_mode = mode
	draw_mode = GameSession.draw_mode if GameSession.draw_mode != 0 else draw_mode_id

	if not _is_background() and GameSession.spider_suits in [1, 2, 4]:
		spider_suits = GameSession.spider_suits
	match mode:
		GameMode.KLONDIKE:
			_setup_klondike()
		GameMode.SPIDER:
			_setup_spider()
		_:
			push_warning("Неизвестный режим: %d" % mode)


## Переключатель сложности: 1 = draw 1, 2 = draw 3. Перезапускает партию.
func set_draw_mode(id: int) -> void:
	GameSession.draw_mode = clampi(id, 1, 2)
	start_game(current_mode)


# --- Режимы ---

func _setup_klondike() -> void:
	var draw_count := 1 if draw_mode == GameSession.DRAW_ONE else 3
	rules = KlondikeRules.new(self, draw_count)
	_build_piles()
	rules.on_board_built()
	rules.deal()      # корутина, идёт в фоне


func _setup_spider() -> void:
	rules = SpiderRules.new(self, spider_suits)
	_build_piles()
	rules.on_board_built()
	rules.deal()      # корутина, идёт в фоне


# --- Раздача (вызывается из правил) ---

func begin_deal() -> int:
	_deal_token += 1
	is_dealing = true
	return _deal_token


func deal_cancelled(token: int) -> bool:
	return token != _deal_token or not is_inside_tree()


func end_deal() -> void:
	is_dealing = false

	deal_finished.emit()

	_emit_statistics()
	_emit_board_counts()

	_check_state()


# --- Ходы и история ---

## Перенос группы карт. true только если ход выполнен и записан.
func try_move(group: Array[Card], target: Pile) -> bool:
	if game_finished:
		return false
	if rules == null or group.is_empty() or target == null:
		return false
	var source: Pile = group[0].pile
	if source == null or source == target:
		return false
	if not rules.can_drop(group, target):
		return false

	var record := MoveRecord.new()
	for c in group:
		move_card(c, target, record)
	rules.after_move(record, source)
	commit(record)
	return true


func move_card(card: Card, to: Pile, record: MoveRecord) -> void:
	var from: Pile = card.pile
	var idx := from.cards.find(card) if from != null else -1
	record.add_move(card, from, idx)
	to.add_card(card)


func set_face_up(card: Card, value: bool, record: MoveRecord) -> void:
	if card.face_up == value:
		return
	record.add_flip(card, card.face_up)
	card.set_face_up(value)
	if card.pile != null:
		card.pile.relayout()      # закрытые и открытые карты каскада лежат с разным шагом


func commit(record: MoveRecord) -> void:
	if game_finished or record.steps.is_empty():
		return

	history.append(record)
	moves_count += 1
	_add_field_stat(_record_field(record), "moves", 1)

	history_changed.emit(history.size())

	_emit_statistics()
	_emit_board_counts()

	_check_state()



func undo(use_charge: bool = true, field_id: String = "") -> bool:
	if game_finished or is_dealing or history.is_empty():
		return false

	# По умолчанию отменяем глобально последний ход. Для кнопок отдельного
	# поля и автоматических сбросов ищем последнюю запись именно этого поля.
	var record_index := history.size() - 1
	if not field_id.is_empty():
		record_index = -1
		for i in range(history.size() - 1, -1, -1):
			if _record_field(history[i]) == field_id:
				record_index = i
				break
	if record_index < 0:
		return false

	var record: MoveRecord = history[record_index]

	# Сеть: отменять можно только записи своего поля.
	var sync := NetworkMatchSync.find_in(get_tree())
	if sync != null:
		for step in record.steps:
			var step_card: Card = step["card"]
			if is_instance_valid(step_card) and step_card.pile is Pile \
					and not sync.can_local_interact(step_card.pile):
				return false
			var from_pile: Variant = step.get("from")
			if from_pile is Pile and not sync.can_local_interact(from_pile):
				return false

	if use_charge and undo_charges <= 0:
		undo_limit_reached.emit()
		return false

	history.remove_at(record_index)
	if use_charge:
		undo_charges -= 1
		# Счётчик ручных отмен увеличивается только от действия игрока.
		undo_count += 1

	moves_count = maxi(0, moves_count - 1)
	var undo_field := _record_field(record)
	_add_field_stat(undo_field, "moves", -1)
	if use_charge:
		_add_field_stat(undo_field, "undos", 1)

	for i in range(record.steps.size() - 1, -1, -1):
		var s: Dictionary = record.steps[i]
		var card: Card = s["card"]
		if not is_instance_valid(card):
			continue

		if s["type"] == "flip":
			card.set_face_up(s["face_up"])
			if card.pile != null:
				card.pile.relayout()
		else:
			var from: Pile = s["from"]
			if is_instance_valid(from):
				from.add_card(card, s["index"])

	history_changed.emit(history.size())
	_emit_statistics()
	_emit_board_counts()
	_check_state()
	return true
func grant_ad_undo_reward() -> int:
	if game_finished:
		return 0

	var reward := randi_range(limits.ad_undo_reward_min, maxi(limits.ad_undo_reward_min, limits.ad_undo_reward_max))

	undo_charges += reward

	_emit_statistics()
	_queue_analysis()   # с новыми отменами тупик может стать преодолимым

	return reward


func grant_ad_hint_reward() -> int:
	if game_finished:
		return 0
	hint_charges += limits.ad_hint_reward
	hints_changed.emit(hint_charges, hints_used)
	return limits.ad_hint_reward


# --- Предсказатель и подсказки (Клондайк) ---

func _make_predictor(field_id: String) -> KlondikePredictor:
	if not rules is KlondikeRules:
		return null
	var predictor := KlondikePredictor.new()
	predictor.node_budget = limits.predictor_node_budget
	predictor.hint_length = limits.hint_moves
	if not predictor.setup(self, field_id, (rules as KlondikeRules).draw_count):
		return null
	return predictor


## Поля текущей раскладки (у каждого свои стопки Клондайка).
func get_field_ids() -> Array[String]:
	var ids: Array[String] = []
	for p in piles:
		if is_instance_valid(p) and p.kind == PileMarker.Kind.STOCK:
			var id := get_field_id(p)
			if not id in ids:
				ids.append(id)
	return ids


## Полный анализ одного поля. Пустой словарь — режим без предсказателя (Паук).
func analyze_field(field_id: String) -> Dictionary:
	var predictor := _make_predictor(field_id)
	if predictor == null:
		return {}
	return predictor.analyze(history, mini(history.size(), undo_charges))


## Визуальная подсказка для выбранного поля.
## Клондайк использует BFS-предиктор, Паук — поиск допустимого хода по своим правилам.
## Возвращаются реальные стопки и индекс ведущей карты; текст нужен только для логов.
func request_hint(field_id: String) -> Array:
	if game_finished or is_dealing:
		return []
	if hint_charges <= 0:
		hint_limit_reached.emit()
		return []

	var entries: Array = []
	if rules is KlondikeRules:
		var predictor := _make_predictor(field_id)
		if predictor == null:
			return []
		var result := predictor.search(predictor.state_from_board())
		entries = predictor.describe_hint(result["hint"])
	elif rules is SpiderRules:
		entries = _make_spider_hint(field_id)
	else:
		return []

	if entries.is_empty():
		return []
	hint_charges -= 1
	hints_used += 1
	hints_changed.emit(hint_charges, hints_used)
	hint_ready.emit(field_id, entries)
	return entries


## Для Паука выбирает допустимый ход с приоритетом открытия закрытой карты,
## сохранения последовательности одной масти и завершения королевского ряда.
func _make_spider_hint(field_id: String) -> Array:
	var spider_rules := rules as SpiderRules
	if spider_rules == null:
		return []

	var tableau: Array[Pile] = []
	var stock: Pile = null
	for pile: Pile in piles:
		if not is_instance_valid(pile) or get_field_id(pile) != field_id:
			continue
		if pile.kind == PileMarker.Kind.TABLEAU:
			tableau.append(pile)
		elif pile.kind == PileMarker.Kind.STOCK:
			stock = pile

	var best_entry: Dictionary = {}
	var best_score := -1.0
	for source: Pile in tableau:
		for card_index in range(source.cards.size()):
			var card := source.cards[card_index] as Card
			if not card.face_up:
				continue
			var group: Array[Card] = spider_rules.get_group(card)
			if group.is_empty():
				continue
			for target: Pile in tableau:
				if target == source or not spider_rules.can_drop(group, target):
					continue
				if card_index == 0 and target.cards.is_empty():
					continue
				var score := 1.0 + float(group.size()) * 0.25
				if card_index > 0 and not source.cards[card_index - 1].face_up:
					score += 100.0
				if group.size() >= 13:
					score += 50.0
				if target.cards.is_empty():
					score += 3.0
				elif target.cards.back().suit == card.suit:
					score += 12.0
				if score > best_score:
					best_score = score
					best_entry = {
						"from_pile": source,
						"to_pile": target,
						"card_index": card_index,
						"text": "перенос последовательности"
					}

	if not best_entry.is_empty():
		return [best_entry]

	# Когда между колонками нет полезного переноса, показываем разрешённую раздачу.
	if is_instance_valid(stock) and not stock.cards.is_empty():
		for pile: Pile in tableau:
			if pile.cards.is_empty():
				return []
		return [{"from_pile": stock, "card_index": stock.cards.size() - 1, "draw": true, "text": "раздать карты"}]
	return []


func _queue_analysis() -> void:
	_board_version += 1
	if _analysis_queued or not rules is KlondikeRules:
		return
	_analysis_queued = true
	call_deferred("_run_analysis")


## Анализ всех полей после хода. Состояния снимаются на главном потоке,
## перебор идёт в WorkerThreadPool — ход не подтормаживает даже при большом бюджете.
func _run_analysis() -> void:
	_analysis_queued = false
	if rules == null or is_dealing or game_finished or not rules is KlondikeRules:
		return
	if _analysis_task != -1:
		_analysis_rerun = true   # дождёмся текущего расчёта и пересчитаем
		return
	var jobs: Array = []
	var available := mini(history.size(), undo_charges)
	for field_id in get_field_ids():
		var predictor := _make_predictor(field_id)
		if predictor == null:
			continue
		var undo_states: Array = []
		for k in range(1, available + 1):
			var undone: Variant = predictor.state_after_undos(history, k)
			if undone == null:
				break
			undo_states.append(undone)
		jobs.append([field_id, predictor, predictor.state_from_board(), undo_states])
	if jobs.is_empty():
		return
	_analysis_task = WorkerThreadPool.add_task(_analysis_worker.bind(jobs, _board_version))


func _analysis_worker(jobs: Array, version: int) -> void:
	var results: Array = []
	for job in jobs:
		var predictor: KlondikePredictor = job[1]
		results.append([job[0], predictor.analyze_states(job[2], job[3])])
	call_deferred("_apply_analysis", results, version)



func _apply_analysis(results: Array, version: int) -> void:
	if _analysis_task != -1:
		WorkerThreadPool.wait_for_task_completion(_analysis_task)
		_analysis_task = -1
	if not is_inside_tree() or game_finished or is_dealing:
		return
	if version != _board_version or _analysis_rerun:
		# Пока считали, поле изменилось — результат устарел.
		_analysis_rerun = false
		_analysis_queued = true
		call_deferred("_run_analysis")
		return
	var any_progress := false
	for entry in results:
		var field_id: String = entry[0]
		var info: Dictionary = entry[1]
		var verdict := int(info["verdict"])
		var prev: Dictionary = field_verdicts.get(field_id, {})
		field_verdicts[field_id] = info

		# Сигнал также нужен при изменении uncertain / undo_steps_needed,
		# даже если основной вердикт не поменялся.
		var info_changed := (
			prev.is_empty()
			or int(prev.get("verdict", -1)) != verdict
			or bool(prev.get("uncertain", false)) != bool(info.get("uncertain", false))
			or int(prev.get("undo_steps_needed", 0)) != int(info.get("undo_steps_needed", 0))
		)
		if info_changed:
			field_verdict_changed.emit(field_id, verdict, info)

		if verdict == KlondikePredictor.Verdict.PROGRESS or verdict == KlondikePredictor.Verdict.WON:
			any_progress = true
	moves_state_changed.emit(any_progress)
	if not any_progress:
		no_moves_left.emit()
func surrender(field_id: String, notify_network: bool = true) -> void:
	if game_finished:
		return
	surrendered_field = field_id
	winner_field = ""
	for other in get_field_ids():
		if other != field_id and NetworkMatchSync.is_network_match():
			winner_field = other
	if notify_network:
		var sync := NetworkMatchSync.find_in(get_tree())
		if sync != null:
			sync.send_surrender(field_id)
	game_finished = true
	moves_state_changed.emit(false)
	_lock_board_after_win()
	game_lost.emit(winner_field)


## Окончательный тупик: перетасовать карты поля (кроме уже собранных в дом)
## и разложить заново по схеме Клондайка. История отмен поля сбрасывается.

## Совместимость со старым вызовом: обычный redeal здесь считается тупиковым сбросом.
func redeal_field(field_id: String) -> bool:
	return deadend_reset_field(field_id)


## Обычный сброс: цена растёт на 5 после каждого успешного обычного сброса.
func normal_reset_field(field_id: String) -> bool:
	return _redeal_field(field_id, get_normal_reset_cost(field_id), true)


## Тупиковый сброс отменяет только ходы после первых десяти.
## При числе ходов <= 10 поле просто перетасовывается без отката истории.
func deadend_reset_field(field_id: String) -> bool:
	return _redeal_field(field_id, get_deadend_reset_undo_count(field_id), false)



func _redeal_field(field_id: String, undo_steps: int, count_normal_reset: bool) -> bool:
	if game_finished or is_dealing or not rules is KlondikeRules or undo_steps < 0:
		return false

	# Выбираем только последние N записей целевого поля.
	# Нулевой откат допустим: ранний тупик до десятого хода просто перемешивает поле.
	var selected_indices: Array[int] = []
	if undo_steps > 0:
		for history_index in range(history.size() - 1, -1, -1):
			if _record_field(history[history_index]) == field_id:
				selected_indices.append(history_index)
				if selected_indices.size() >= undo_steps:
					break
		if selected_indices.size() < undo_steps:
			return false

	var stock: Pile = null
	var waste: Pile = null
	var tableau: Array[Pile] = []
	for p in piles:
		if not is_instance_valid(p) or get_field_id(p) != field_id:
			continue
		match p.kind:
			PileMarker.Kind.STOCK:
				stock = p
			PileMarker.Kind.WASTE:
				waste = p
			PileMarker.Kind.TABLEAU:
				tableau.append(p)
	if stock == null or tableau.is_empty():
		return false

	tableau.sort_custom(func(a: Pile, b: Pile) -> bool:
		return KlondikePredictor._marker_number(a) < KlondikePredictor._marker_number(b))

	# Предварительно проверяем все целевые записи: сетевой отказ не должен
	# отменить часть ходов и оставить поле в промежуточном состоянии.
	var sync := NetworkMatchSync.find_in(get_tree())
	if sync != null:
		for history_index in selected_indices:
			var record: MoveRecord = history[history_index]
			for step in record.steps:
				var step_card: Card = step["card"]
				if is_instance_valid(step_card) and step_card.pile is Pile \
						and not sync.can_local_interact(step_card.pile):
					return false
				var from_pile: Variant = step.get("from")
				if from_pile is Pile and not sync.can_local_interact(from_pile):
					return false

	# Отменяем именно выбранные записи поля через штатный Undo без расхода
	# зарядов. Записи другого поля остаются в истории и не затрагиваются.
	for step_index in range(undo_steps):
		if not undo(false, field_id):
			push_warning("GameManager: сброс прерван — не удалось отменить ход %d." % (step_index + 1))
			return false

	# Перетасовываем только STOCK / WASTE / TABLEAU. Foundation сохраняется.
	var pool: Array[Card] = []
	for p in [waste] + tableau + [stock]:
		if p == null:
			continue
		for c in p.cards.duplicate():
			pool.append(c)
	pool.shuffle()
	for c in pool:
		c.set_face_up(false)
		stock.add_card(c)

	for row in tableau.size():
		for col in range(row, tableau.size()):
			if stock.cards.is_empty():
				break
			var card: Card = stock.cards.back()
			card.set_face_up(col == row)
			tableau[col].add_card(card)

	# После перемешивания старые записи этого поля больше невалидны.
	var keep: Array[MoveRecord] = []
	for record in history:
		if _record_field(record) != field_id:
			keep.append(record)
	history = keep

	if count_normal_reset:
		_add_field_stat(field_id, "normal_resets", 1)

	field_verdicts.erase(field_id)
	history_changed.emit(history.size())
	_emit_statistics()
	_emit_board_counts()
	_check_state()
	return true
func _check_state() -> void:
	if rules == null or is_dealing or game_finished:
		return

	if rules.is_won():
		if rules is SpiderRules:
			winner_field = (rules as SpiderRules).winner_field
		elif rules is KlondikeRules:
			winner_field = (rules as KlondikeRules).winner_field

		# В зеркальной сетевой игре достаточно победы одного поля.
		# Второй клиент получит тот же результат через NetworkMatchSync.
		if (
			NetworkMatchSync.is_network_match()
			and GameSession.get_board_layout(current_mode) == GameSession.BOARD_LAYOUT_MIRRORED
		):
			if winner_field.is_empty():
				push_warning("GameManager: сетевое поле завершилось без определённого победителя.")
				return
			_finish_competitive_match(winner_field, true)
			return

		_finish_game()
		return

	if rules is KlondikeRules:
		# Клондайк: вместо has_moves — анализатор состояний по каждому полю.
		_queue_analysis()
		return
	var can_move := rules.has_moves()
	moves_state_changed.emit(can_move)
	if not can_move:
		no_moves_left.emit()

func _unhandled_key_input(event: InputEvent) -> void:
	if _is_background():
		return

	if event is InputEventKey:
		if event.pressed and not event.echo:
			if event.physical_keycode == KEY_L:
				_debug_force_win()
				get_viewport().set_input_as_handled()


func _debug_force_win() -> void:
	if game_finished:
		return

	if is_dealing:
		print("Сначала дождись завершения раздачи!")
		return

	print("DEBUG: Принудительная победа!")

	_finish_game()
	
## Завершает сетевой соревновательный матч по победе одного поля.
## notify_network=false используется на клиенте, который получил результат по RPC.
func _finish_competitive_match(winning_field: String, notify_network: bool = true) -> void:
	if game_finished or winning_field.is_empty():
		return

	winner_field = winning_field
	surrendered_field = ""

	if notify_network:
		var sync := NetworkMatchSync.find_in(get_tree())
		if sync != null:
			sync.send_match_result(winning_field)

	_finish_game()


func _finish_game() -> void:
	if game_finished:
		return
	game_finished = true
	moves_state_changed.emit(false)
	_lock_board_after_win()
	game_won.emit()
	
func _lock_board_after_win() -> void:
	for pile in piles:
		if not is_instance_valid(pile):
			continue

		pile.input_ray_pickable = false
		pile.monitoring = false
		pile.monitorable = false

		for card in pile.cards:
			if not is_instance_valid(card):
				continue

			if card is CollisionObject3D:
				card.input_ray_pickable = false
				card.collision_layer = 0
				card.collision_mask = 0
				
# --- Доступ к стопкам ---

func get_piles(kind: PileMarker.Kind) -> Array[Pile]:
	var result: Array[Pile] = []
	for p in piles:
		if is_instance_valid(p) and p.kind == kind:
			result.append(p)
	return result


func get_pile(kind: PileMarker.Kind) -> Pile:
	for p in piles:
		if is_instance_valid(p) and p.kind == kind:
			return p
	return null


# --- Построение стола ---

func _exit_tree() -> void:
	# Не оставляем фоновый расчёт висеть после выхода со сцены.
	if _analysis_task != -1:
		WorkerThreadPool.wait_for_task_completion(_analysis_task)
		_analysis_task = -1


func _clear_board() -> void:
	game_finished = false
	_board_version += 1
	_deal_token += 1
	is_dealing = false

	for pile in piles:
		if is_instance_valid(pile):
			pile.queue_free()

	piles.clear()
	history.clear()
	field_stats.clear()

	moves_count = 0
	undo_count = 0
	undo_charges = undo_limit
	hint_charges = limits.hint_start if limits != null else 3
	hints_used = 0
	field_verdicts.clear()
	winner_field = ""
	surrendered_field = ""
	hints_changed.emit(hint_charges, hints_used)

	rules = null

	history_changed.emit(0)
	_emit_statistics()
	_emit_board_counts()


func _resolve_markers_root() -> Node3D:
	if is_instance_valid(markers_root):
		return markers_root

	var found: Node = find_child("Markers", true, false)

	if found is Node3D:
		markers_root = found as Node3D

	if markers_root == null:
		push_error("GameManager: не назначен узел Markers!")
		return null

	return markers_root


func _prepare_active_marker_container() -> bool:
	var root: Node3D = _resolve_markers_root()
	if root == null:
		return false

	var layout_id: int = GameSession.get_board_layout(current_mode)
	var coop_root := root.get_node_or_null("CoopPresets") as Node3D

	root.visible = true
	active_markers.clear()

	# Собираем классические маркеры, расположенные прямо в Markers.
	var classic_markers: Array[PileMarker] = []

	for child in root.get_children():
		if child is PileMarker:
			classic_markers.append(child as PileMarker)

	var selected_preset: Node3D = null

	match layout_id:

		GameSession.BOARD_LAYOUT_CLASSIC:
			# Оставляем только классическое поле.
			active_markers.append_array(classic_markers)
			active_marker_container = root

			# Убираем все дополнительные пресеты из игровой сцены.
			_remove_runtime_node(coop_root)

		GameSession.BOARD_LAYOUT_MIRRORED:
			# Оставляем классическое поле и добавляем зеркальное.
			selected_preset = _get_layout_preset(coop_root, "Coop_MIRRORED")
			if selected_preset == null:
				return false

			active_markers.append_array(classic_markers)
			active_markers.append_array(_collect_markers_from(selected_preset))

			active_marker_container = selected_preset

			# Удаляем остальные пресеты, оставляя только зеркальный.
			if coop_root != null:
				coop_root.visible = true

				for preset in coop_root.get_children():
					if preset != selected_preset:
						_remove_runtime_node(preset)

			selected_preset.visible = true

		GameSession.BOARD_LAYOUT_RING:
			# Оставляем только кольцевую раскладку.
			selected_preset = _get_layout_preset(coop_root, "Coop_RING")
			if selected_preset == null:
				return false

			active_markers.append_array(_collect_markers_from(selected_preset))
			active_marker_container = selected_preset

			# Удаляем классические маркеры.
			for marker in classic_markers:
				_remove_runtime_node(marker)

			# Удаляем все пресеты, кроме кольцевого.
			if coop_root != null:
				coop_root.visible = true

				for preset in coop_root.get_children():
					if preset != selected_preset:
						_remove_runtime_node(preset)

			selected_preset.visible = true

		_:
			push_error("GameManager: неизвестный ID раскладки: " + str(layout_id))
			return false
	if current_mode == GameMode.SPIDER:
		var done_root := root.get_node_or_null("SpiderDoneMarkers") as Node3D
		if done_root != null:
			active_markers.append_array(_collect_markers_from(done_root))
		else:
			push_error("GameManager: SpiderDoneMarkers не найден!")
			return false
		# Зеркальный Паук: у второго поля свои 4 стопки собранных рядов.
		if layout_id == GameSession.BOARD_LAYOUT_MIRRORED and selected_preset != null:
			active_markers.append_array(_ensure_mirrored_done_markers(root, done_root, selected_preset))
	if active_markers.is_empty():
		push_error("GameManager: выбранная раскладка не содержит маркеров!")
		return false

	print("Активная раскладка: ", layout_id)
	print("Количество активных маркеров: ", active_markers.size())

	return true


## Маркеры стопок собранных рядов для поля 2 зеркального Паука.
## Если в сцене уже есть узел SpiderDoneMarkers_P2 в Coop_MIRRORED — берём его.
## Иначе создаём копии SpiderDoneMarkers тем же преобразованием, которым поле 1
## переходит в поле 2 (Stock → Stock_P2), — они встают на свою сторону стола.
func _ensure_mirrored_done_markers(root: Node3D, done_root: Node3D, preset: Node3D) -> Array[PileMarker]:
	var existing := preset.get_node_or_null("SpiderDoneMarkers_P2") as Node3D
	if existing != null:
		# При перезапуске партии они уже попали в active_markers вместе с пресетом.
		var fresh: Array[PileMarker] = []
		for m in _collect_markers_from(existing):
			if not m in active_markers:
				fresh.append(m)
		return fresh

	var result: Array[PileMarker] = []
	var stock_1: Node3D = null
	for child in root.get_children():
		if child is PileMarker and (child as PileMarker).kind == PileMarker.Kind.STOCK:
			stock_1 = child
			break
	var stock_2: Node3D = null
	for child in preset.get_children():
		if child is PileMarker and (child as PileMarker).kind == PileMarker.Kind.STOCK:
			stock_2 = child
			break
	if stock_1 == null or stock_2 == null:
		push_error("GameManager: не найдены Stock/Stock_P2 для зеркальных стопок Паука.")
		return result

	var field_to_field := stock_2.global_transform * stock_1.global_transform.affine_inverse()
	var holder := Node3D.new()
	holder.name = "SpiderDoneMarkers_P2"
	preset.add_child(holder)
	for marker in _collect_markers_from(done_root):
		var copy := marker.duplicate() as PileMarker
		copy.name = str(marker.name) + "_P2"
		holder.add_child(copy)
		copy.global_transform = field_to_field * marker.global_transform
		result.append(copy)
	return result


func _get_layout_preset(coop_root: Node3D, preset_name: String) -> Node3D:
	if coop_root == null:
		push_error("GameManager: не найдена нода CoopPresets!")
		return null

	var preset := coop_root.get_node_or_null(preset_name) as Node3D

	if preset == null:
		push_error("GameManager: не найден пресет " + preset_name)

	return preset


func _remove_runtime_node(node: Node) -> void:
	if not is_instance_valid(node):
		return

	var parent := node.get_parent()

	if parent != null:
		parent.remove_child(node)

	node.queue_free()

func _collect_markers_from(container: Node3D) -> Array[PileMarker]:
	var result: Array[PileMarker] = []

	if container == null:
		return result

	_find_markers(container, result)

	return result


func _build_piles() -> void:
	if not _prepare_active_marker_container():
		return

	var stocks: Array[Stock] = []

	# Зеркальный Паук: у каждого поля своя колода (соревновательный режим),
	# раздача соперника не затрагивает моё поле.
	for marker in active_markers:
		if not is_instance_valid(marker):
			continue

		var scene := _scene_for(marker.kind)
		if scene == null:
			continue

		var pile := scene.instantiate() as Pile
		if pile == null:
			continue

		pile.rules = rules
		marker.add_child(pile)
		pile.global_transform = marker.global_transform
		pile.setup(marker)

		piles.append(pile)

		if pile is Stock:
			stocks.append(pile as Stock)

	# Создаём колоду только после того, как известны все Stock.
	if rules == null or stocks.is_empty():
		return

	# Правила могут собрать колоду для конкретного поля (Паук: полный набор мастей
	# на каждое поле). Иначе — общая колода делится между Stock поровну.
	if rules.has_method("build_stock_deck"):
		for stock in stocks:
			if stock.cards.is_empty():
				stock.create_deck(rules.build_stock_deck(stock))
		return

	var full_deck: Array[Vector2i] = rules.build_deck()

	if full_deck.size() % stocks.size() != 0:
		push_error("GameManager: колоду нельзя равномерно распределить между Stock.")
		return

	var cards_per_stock := int(full_deck.size() / stocks.size())

	for i in range(stocks.size()):
		if not stocks[i].cards.is_empty():
			continue

		var stock_deck: Array[Vector2i] = []
		var start_index := i * cards_per_stock
		var end_index := start_index + cards_per_stock

		for j in range(start_index, end_index):
			stock_deck.append(full_deck[j])

		stocks[i].create_deck(stock_deck)


func _create_player_piles(
	marker_root: MarkerLayout,
	destination: Array[Pile],
	use_current_rules: bool
) -> void:
	var markers: Array[PileMarker] = []
	_find_markers(marker_root, markers)

	for marker in markers:
		var scene := _scene_for(marker.kind)

		if scene == null:
			push_warning("Не найдена сцена для маркера: " + marker.name)
			continue

		var pile := scene.instantiate() as Pile

		if pile == null:
			push_warning("Сцена маркера не содержит Pile: " + marker.name)
			continue

		# Правила пока назначаем только первому игроку.
		if use_current_rules:
			pile.rules = rules

		marker.add_child(pile)
		pile.global_transform = marker.global_transform
		pile.setup(marker)

		destination.append(pile)
		
func _find_markers(node: Node, result: Array[PileMarker]) -> void:
	for child in node.get_children():

		# Архив завершённых рядов нужен только Пауку.
		if child.name == "SpiderDoneMarkers":
			if current_mode != GameMode.SPIDER:
				continue

		if child is PileMarker:
			result.append(child as PileMarker)
		else:
			_find_markers(child, result)

func _scene_for(kind: PileMarker.Kind) -> PackedScene:
	match kind:
		PileMarker.Kind.TABLEAU:
			return tableau_scene

		PileMarker.Kind.FOUNDATION:
			if current_mode == GameMode.SPIDER and spider_done_scene != null:
				return spider_done_scene
			return foundation_scene

		PileMarker.Kind.STOCK:
			return stock_scene

		PileMarker.Kind.WASTE:
			return waste_scene

	return null

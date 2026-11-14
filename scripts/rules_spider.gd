class_name SpiderRules
extends GameRules
## Паук: 104 карты, 10 колонок, 1 колода (stock). Foundation нет:
## собранный ряд K..A одной масти убирается со стола (уходит в стопку PileSpiderDone своей масти).
##
## Раздача:   колонки 1-4 по 6 карт, 5-10 по 5 карт, верхняя открыта (54 карты).
## Колода:    клик раздаёт по одной открытой карте в каждую колонку (50 карт = 5 раздач).
##            Нельзя, если хотя бы одна колонка пуста.
## Перенос:   группа из карт одной масти по убыванию. Класть можно на карту на 1 старше
##            (любая масть) или на пустую колонку.
## Победа:    собраны все ряды.
##
## Зеркальная раскладка (два поля, соревнование):
##   у каждого поля своя колода, свои 10 колонок и свои 4 стопки собранных рядов
##   (по одной масти на стопку). Раздача и переносы не выходят за пределы поля.
##   Победа: первым полностью заполнить 3 из 4 мастевых стопок своего поля
##   (если мастей в партии меньше трёх — все используемые масти).

const SEQUENCE_LENGTH := 13
const MIRRORED_WIN_FOUNDATIONS := 3

var suit_count := 1          # 1, 2 или 4 масти
var deal_size := 10          # карт за один клик по колоде
## field_id -> {suit: Pile}
var _foundations_by_field: Dictionary = {}
## field_id -> {suit: сколько рядов этой масти в колоде поля}
var _sequences_by_field: Dictionary = {}
var _layout_settings: SpiderLayoutSettings
## Поле-победитель (зеркальная раскладка), "" — пока никто.
var winner_field := ""

func _init(b: GameManager, suits: int = 1) -> void:
	super(b)
	suit_count = suits if suits in [1, 2, 4] else 1


## Два независимых поля (зеркальная раскладка).
func is_split_fields() -> bool:
	return GameSession.get_board_layout(board.current_mode) == GameSession.BOARD_LAYOUT_MIRRORED


func _field(pile: Pile) -> String:
	return board.get_field_id(pile) if is_split_fields() else GameManager.FIELD_MAIN


func _same_field(a: Pile, b: Pile) -> bool:
	return not is_split_fields() or _field(a) == _field(b)


# --- Колода: 8 наборов по 13 карт, масти зависят от сложности ---
func _get_layout_settings() -> SpiderLayoutSettings:
	if is_instance_valid(_layout_settings):
		return _layout_settings

	var settings_node := board.get_node_or_null(
		"SpiderLayoutSettings"
	)

	if settings_node is SpiderLayoutSettings:
		_layout_settings = settings_node as SpiderLayoutSettings
	else:
		push_warning(
			"Spider: SpiderLayoutSettings не найден. Используются настройки по умолчанию."
		)
		_layout_settings = SpiderLayoutSettings.new()

	return _layout_settings


func build_deck() -> Array[Vector2i]:
	return _deck_for_tableau(board.get_piles(PileMarker.Kind.TABLEAU).size())


## Колода для конкретной колоды-стопки (вызывает GameManager._build_piles).
## Зеркальная раскладка: каждое поле получает полный набор мастей на свои колонки.
func build_stock_deck(stock: Pile) -> Array[Vector2i]:
	if not is_split_fields():
		return build_deck()
	return _deck_for_tableau(_field_tableau(stock).size())


func _deck_for_tableau(detected_count: int) -> Array[Vector2i]:
	var deck: Array[Vector2i] = []
	var settings := _get_layout_settings()
	var tableau_count := settings.resolve_tableau_count(detected_count)

	if tableau_count <= 0:
		push_error("Spider: не удалось определить число Tableau.")
		return deck

	var sequence_count := settings.get_sequence_count(tableau_count, suit_count)
	var copies_per_suit := int(sequence_count / suit_count)

	for s in range(suit_count):
		for _copy in range(copies_per_suit):
			for rank in range(1, 14):
				deck.append(Vector2i(s + 1, rank))

	return deck


func on_board_built() -> void:
	_foundations_by_field.clear()
	_sequences_by_field.clear()
	winner_field = ""

	for foundation in board.get_piles(PileMarker.Kind.FOUNDATION):
		if foundation.marker_suit < 1 or foundation.marker_suit > 4:
			continue
		var field := _field(foundation)
		if not _foundations_by_field.has(field):
			_foundations_by_field[field] = {}
		_foundations_by_field[field][foundation.marker_suit] = foundation

	for field in _foundations_by_field.keys():
		for suit in range(1, suit_count + 1):
			if not (_foundations_by_field[field] as Dictionary).has(suit):
				push_error("Spider: на поле %s нет стопки для масти %d." % [field, suit])

	# Сколько рядов каждой масти лежит в колоде поля (нужно для условия победы).
	for stock in board.get_piles(PileMarker.Kind.STOCK):
		var field := _field(stock)
		var counts := {1: 0, 2: 0, 3: 0, 4: 0}
		for c in stock.cards:
			counts[c.suit] = int(counts[c.suit]) + 1
		for suit in counts.keys():
			counts[suit] = int(counts[suit]) / SEQUENCE_LENGTH
		_sequences_by_field[field] = counts

	for t in board.get_piles(PileMarker.Kind.TABLEAU):
		t.facedown_ratio = board.spider_facedown_ratio
		t.cascade_max_length = board.spider_column_max_length


# --- Раздача ---

func deal() -> void:
	var stocks := board.get_piles(PileMarker.Kind.STOCK)
	if stocks.is_empty():
		push_warning("Spider: не найдена STOCK.")
		return

	# Проверяем все поля до начала раздачи.
	var plans: Array = []   # [stock, tableau, per_col]
	var settings := _get_layout_settings()
	for stock in stocks:
		var tableau := _field_tableau(stock)
		if tableau.is_empty():
			push_warning("Spider: у колоды %s нет колонок." % stock.name)
			return
		var tableau_count := settings.resolve_tableau_count(tableau.size())
		if tableau_count != tableau.size():
			push_error(
				"Spider: настройки ожидают %d Tableau, найдено %d."
				% [tableau_count, tableau.size()]
			)
			return
		var expected_cards := settings.get_sequence_count(tableau_count, suit_count) * SEQUENCE_LENGTH
		if stock.cards.size() != expected_cards:
			push_error(
				"Spider: ожидалось %d карт в Stock, найдено %d."
				% [expected_cards, stock.cards.size()]
			)
			return
		# 40% колонок получают по 6 карт, остальные — по 5.
		var per_col: Array[int] = []
		for i in range(tableau.size()):
			per_col.append(settings.get_cards_in_column(i, tableau.size()))
		plans.append([stock, tableau, per_col])

	var token := board.begin_deal()
	var max_initial_cards := settings.base_cards_per_column + 1

	for row in range(max_initial_cards):
		for plan in plans:
			var stock: Pile = plan[0]
			var tableau: Array[Pile] = plan[1]
			var per_col: Array[int] = plan[2]
			for col in tableau.size():
				if row >= per_col[col]:
					continue
				if stock.cards.is_empty():
					push_error("Spider: колода закончилась раньше времени.")
					board.end_deal()
					return

				var card: Card = stock.cards.back()
				card.set_face_up(row == per_col[col] - 1)
				tableau[col].add_card(card)

				await board.get_tree().create_timer(board.deal_delay).timeout

				if not is_instance_valid(board):
					return
				if board.deal_cancelled(token):
					return

	board.end_deal()


# --- Правила переноса ---

func is_valid_group(group: Array[Card]) -> bool:
	for i in group.size():
		if not group[i].face_up:
			return false
		if i > 0:
			var prev := group[i - 1]
			if group[i].rank != prev.rank - 1 or group[i].suit != prev.suit:
				return false
	return true


func can_drop(group: Array[Card], pile: Pile) -> bool:
	if group.is_empty() or pile == null or pile.kind != PileMarker.Kind.TABLEAU:
		return false
	var source := group[0].pile as Pile
	if source != null and not _same_field(source, pile):
		return false                                  # чужое поле
	if pile.cards.is_empty():
		return true                                   # на пустую колонку можно любую группу
	var top: Card = pile.cards.back()
	return top.face_up and group[0].rank == top.rank - 1


func after_move(record: MoveRecord, source: Pile) -> void:
	_resolve(record, _field(source) if source != null else "")


## Убрать собранные ряды и открыть верхние карты колонок (только на поле хода).
func _resolve(record: MoveRecord, field: String = "") -> void:
	for t in board.get_piles(PileMarker.Kind.TABLEAU):
		if is_split_fields() and not field.is_empty() and _field(t) != field:
			continue
		_try_complete(t, record)
		if not t.cards.is_empty():
			var top: Card = t.cards.back()
			if not top.face_up:
				board.set_face_up(top, true, record)


func _try_complete(pile: Pile, record: MoveRecord) -> void:
	if pile.cards.size() < SEQUENCE_LENGTH:
		return
	var start := pile.cards.size() - SEQUENCE_LENGTH
	var first: Card = pile.cards[start]
	if first.rank != 13:
		return
	var run: Array[Card] = []
	run.assign(pile.cards.slice(start))
	if not is_valid_group(run):
		return
	var by_suit: Dictionary = _foundations_by_field.get(_field(pile), {})
	var destination := by_suit.get(first.suit) as Pile
	if destination == null:
		push_error("Spider: не найдена стопка для масти %d на поле %s." % [first.suit, _field(pile)])
		return

	# Карты перемещаются настоящими объектами.
	# Все перемещения записываются в один MoveRecord.
	for card in run:
		board.move_card(card, destination, record)

# --- Колода ---

func on_pile_clicked(pile: Pile) -> bool:
	if pile.kind != PileMarker.Kind.STOCK:
		return false
	if board.is_dealing or pile.cards.is_empty():
		return true

	var tableau := _field_tableau(pile)
	for t in tableau:
		if t.cards.is_empty():
			return true       # нельзя раздавать, пока есть пустая колонка

	var record := MoveRecord.new()
	for t in tableau:
		if pile.cards.is_empty():
			break
		var c: Card = pile.cards.back()
		board.set_face_up(c, true, record)
		board.move_card(c, t, record)
	_resolve(record, _field(pile))
	board.commit(record)
	return true


# --- Победа и проверка ходов ---

func is_won() -> bool:
	# Соревнование «первым 3 из 4» — в сетевой зеркальной партии.
	# В одиночной зеркальной игре, как и раньше, нужно собрать всё.
	if is_split_fields() and NetworkMatchState.active:
		for field in _foundations_by_field.keys():
			if _field_won(field):
				winner_field = field
				return true
		return false

	var total_cards := 0
	var completed_cards := 0

	for pile in board.piles:
		if not is_instance_valid(pile):
			continue

		total_cards += pile.cards.size()

		if pile.kind == PileMarker.Kind.FOUNDATION:
			completed_cards += pile.cards.size()

	return total_cards > 0 and completed_cards == total_cards


## Зеркальная раскладка: стопка масти «заполнена», когда в ней все ряды этой масти
## из колоды поля. Победа — заполнить MIRRORED_WIN_FOUNDATIONS стопок
## (или все используемые масти, если их меньше).
func _field_won(field: String) -> bool:
	var sequences: Dictionary = _sequences_by_field.get(field, {})
	var by_suit: Dictionary = _foundations_by_field.get(field, {})
	var used_suits := 0
	var filled := 0
	for suit in range(1, 5):
		var need := int(sequences.get(suit, 0))
		if need <= 0:
			continue
		used_suits += 1
		var pile := by_suit.get(suit) as Pile
		if pile != null and pile.cards.size() >= need * SEQUENCE_LENGTH:
			filled += 1
	return used_suits > 0 and filled >= mini(MIRRORED_WIN_FOUNDATIONS, used_suits)


## Сколько стопок мастей заполнено на поле (для табло).
func get_filled_foundations(field: String) -> int:
	var sequences: Dictionary = _sequences_by_field.get(field, {})
	var by_suit: Dictionary = _foundations_by_field.get(field, {})
	var filled := 0
	for suit in range(1, 5):
		var need := int(sequences.get(suit, 0))
		var pile := by_suit.get(suit) as Pile
		if need > 0 and pile != null and pile.cards.size() >= need * SEQUENCE_LENGTH:
			filled += 1
	return filled


## Эвристика «ходы ещё есть». Ошибается только в безопасную сторону
## (может сказать «есть», когда остались лишь бесполезные перестановки).
func has_moves() -> bool:
	for stock in board.get_piles(PileMarker.Kind.STOCK):
		if _field_has_moves(stock):
			return true
	return false


func field_has_moves(stock: Pile) -> bool:
	return _field_has_moves(stock)


func _field_has_moves(stock: Pile) -> bool:
	var tableau := _field_tableau(stock)

	if not stock.cards.is_empty():
		var any_empty := false
		for t in tableau:
			if t.cards.is_empty():
				any_empty = true
				break
		if not any_empty:
			return true      # можно раздать

	for src in tableau:
		for i in src.cards.size():
			if not src.cards[i].face_up:
				continue
			var group: Array[Card] = []
			group.assign(src.cards.slice(i))
			if not is_valid_group(group):
				continue
			for t in tableau:
				if t == src or not can_drop(group, t):
					continue
				# перенос всей колонки на пустую ничего не меняет
				if i == 0 and t.cards.is_empty():
					continue
				return true
	return false


## Колонки поля этой колоды (все колонки, если поле одно), по порядку слева направо.
func _field_tableau(stock: Pile) -> Array[Pile]:
	var tableau: Array[Pile] = []
	for t in board.get_piles(PileMarker.Kind.TABLEAU):
		if stock == null or _same_field(stock, t):
			tableau.append(t)
	tableau.sort_custom(func(a: Pile, b: Pile): return a.global_position.x < b.global_position.x)
	return tableau


func _sorted_tableau() -> Array[Pile]:
	return _field_tableau(null)

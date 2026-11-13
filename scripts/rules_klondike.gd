class_name KlondikeRules
extends GameRules

var draw_count: int = 1
var winner_field: String = ""

func _init(b: GameManager, draw: int = 1) -> void:
	super(b)
	draw_count = draw

func build_deck() -> Array[Vector2i]:
	var deck: Array[Vector2i] = []
	var target_count := GameSession.get_max_cards(board.current_mode)

	var base_deck := super.build_deck()
	var copies := ceili(float(target_count) / base_deck.size())

	for _i in range(copies):
		deck.append_array(base_deck)

	return deck


# --------------------------------------------------
# ПРИНАДЛЕЖНОСТЬ К ИГРОВОМУ ПОЛЮ
# --------------------------------------------------

# Основное поле возвращает Markers.
# Зеркальное поле возвращает Coop_MIRRORED.
func _get_field_root(pile: Pile) -> Node:
	if pile == null or pile.owner_marker == null:
		return board.markers_root

	var root: Node3D = board.markers_root

	if root == null:
		root = board._resolve_markers_root()

	if root == null:
		return null

	var coop_root := root.get_node_or_null("CoopPresets")
	var node: Node = pile.owner_marker

	while node != null and node != root:
		if coop_root != null and node.get_parent() == coop_root:
			return node

		node = node.get_parent()

	return root


func _same_field(a: Pile, b: Pile) -> bool:
	if a == null or b == null:
		return false

	return _get_field_root(a) == _get_field_root(b)


# Все стопки указанного типа, принадлежащие полю source.
func _get_field_piles(source: Pile, kind: PileMarker.Kind) -> Array[Pile]:
	var result: Array[Pile] = []

	for p in board.get_piles(kind):
		if _same_field(source, p):
			result.append(p)

	return result


func _find_field_pile(source: Pile, kind: PileMarker.Kind) -> Pile:
	for p in board.get_piles(kind):
		if _same_field(source, p):
			return p

	return null


# --------------------------------------------------
# НАСТРОЙКА ПОЛЯ
# --------------------------------------------------

func on_board_built() -> void:
	# Настраиваем каждый сброс отдельно.
	for waste in board.get_piles(PileMarker.Kind.WASTE):
		if waste is PileWaste:
			(waste as PileWaste).fan_count = draw_count


# --------------------------------------------------
# РАЗДАЧА
# --------------------------------------------------

func deal() -> void:
	var stocks := board.get_piles(PileMarker.Kind.STOCK)

	if stocks.is_empty():
		push_error("Klondike: нет ни одной колоды STOCK.")
		return

	var layout_id := GameSession.get_board_layout(board.current_mode)

	var is_mirrored := layout_id == GameSession.BOARD_LAYOUT_MIRRORED
	var is_ring := layout_id == GameSession.BOARD_LAYOUT_RING

	var expected_stocks := 1
	var expected_tableau := 7
	var expected_foundations := 4
	var expected_cards := GameSession.get_max_cards_per_stock(
		board.current_mode,
		stocks.size()
	)

	if is_mirrored:
		expected_stocks = 2

	elif is_ring:
		expected_tableau = 10
		expected_foundations = 8
		expected_cards = 104

	if stocks.size() != expected_stocks:
		push_error(
			"Klondike: ожидалось %d STOCK, найдено %d."
			% [expected_stocks, stocks.size()]
		)
		return

	# Проверяем каждое поле до начала раздачи.
	for stock in stocks:
		print("Stock cards: ", stock.cards.size())
		var tableau := _get_field_piles(
			stock,
			PileMarker.Kind.TABLEAU
		)

		var foundations := _get_field_piles(
			stock,
			PileMarker.Kind.FOUNDATION
		)

		var waste := _find_field_pile(
			stock,
			PileMarker.Kind.WASTE
		)

		if tableau.size() != expected_tableau:
			push_error(
				"Klondike: ожидалось %d Tableau, найдено %d."
				% [expected_tableau, tableau.size()]
			)
			return

		if foundations.size() != expected_foundations:
			push_error(
				"Klondike: ожидалось %d Foundation, найдено %d."
				% [expected_foundations, foundations.size()]
			)
			return

		if waste == null:
			push_error("Klondike: не найден Waste для одной из колод.")
			return

		if stock.cards.size() != expected_cards:
			push_error(
				"Klondike: ожидалось %d карт в Stock, найдено %d."
				% [expected_cards, stock.cards.size()]
			)
			return

	var token := board.begin_deal()

	# Каждая колода раздаёт карты только своему полю.
	for stock in stocks:
		var tableau := _get_field_piles(
			stock,
			PileMarker.Kind.TABLEAU
		)

		# Порядок колонок — по номеру маркера (Tableau1..7 / Tableau1_P2..7_P2),
		# а не по X: у развёрнутого поля игрока 2 так раздача идёт слева направо
		# с его стороны стола, и «одинаковая раскидка» выглядит одинаково у обоих.
		tableau.sort_custom(
			func(a: Pile, b: Pile):
				return KlondikePredictor._marker_number(a) < KlondikePredictor._marker_number(b)
		)

		# Первая колонка — 1 карта,
		# вторая — 2, последняя — количество колонок.
		for row in tableau.size():
			for col in range(row, tableau.size()):
				if stock.cards.is_empty():
					push_error("Klondike: колода закончилась раньше раздачи.")
					board.end_deal()
					return

				var card: Card = stock.cards.back()

				card.set_face_up(col == row)
				tableau[col].add_card(card)

				await board.get_tree().create_timer(
					board.deal_delay
				).timeout

				if not is_instance_valid(board):
					return

				if board.deal_cancelled(token):
					return

	board.end_deal()


# --------------------------------------------------
# ПРАВИЛА ПЕРЕНОСА
# --------------------------------------------------

func is_valid_group(group: Array[Card]) -> bool:
	for i in group.size():
		if not group[i].face_up:
			return false

		if i > 0:
			var prev := group[i - 1]
			var cur := group[i]

			if cur.rank != prev.rank - 1:
				return false

			if cur.is_red() == prev.is_red():
				return false

	return true


func can_drop(group: Array[Card], pile: Pile) -> bool:
	if group.is_empty() or pile == null:
		return false

	var source: Pile = group[0].pile

	if source == null or not _same_field(source, pile):
		return false

	var lead := group[0]

	match pile.kind:
		PileMarker.Kind.TABLEAU:
			if pile.cards.is_empty():
				return lead.rank == 13

			var top: Card = pile.cards.back()

			return (
				top.face_up
				and lead.rank == top.rank - 1
				and lead.is_red() != top.is_red()
			)

		PileMarker.Kind.FOUNDATION:
			if group.size() != 1:
				return false

			if pile.marker_suit != 0 and lead.suit != pile.marker_suit:
				return false

			if pile.cards.is_empty():
				return lead.rank == 1

			var f_top: Card = pile.cards.back()

			return (
				lead.suit == f_top.suit
				and lead.rank == f_top.rank + 1
			)

	return false


func after_move(record: MoveRecord, source: Pile) -> void:
	# Открываем верхнюю карту исходной колонки.
	if (
		source != null
		and source.kind == PileMarker.Kind.TABLEAU
		and not source.cards.is_empty()
	):
		var top: Card = source.cards.back()

		if not top.face_up:
			board.set_face_up(top, true, record)


# --------------------------------------------------
# КОЛОДА И СБРОС
# --------------------------------------------------

func on_pile_clicked(pile: Pile) -> bool:
	if pile.kind != PileMarker.Kind.STOCK:
		return false

	# Находим Waste именно этого поля.
	var waste := _find_field_pile(
		pile,
		PileMarker.Kind.WASTE
	)

	if waste == null:
		push_warning("Klondike: для STOCK не найден собственный Waste.")
		return true

	var record := MoveRecord.new()

	if pile.cards.is_empty():
		# Возвращаем карты из собственного Waste в собственный Stock.
		var recycle: Array[Card] = []
		recycle.assign(waste.cards)
		recycle.reverse()

		for c in recycle:
			board.set_face_up(c, false, record)
			board.move_card(c, pile, record)

	else:
		var n := mini(draw_count, pile.cards.size())

		for i in n:
			var c: Card = pile.cards.back()

			board.set_face_up(c, true, record)
			board.move_card(c, waste, record)

	board.commit(record)
	return true


# --------------------------------------------------
# ПОБЕДА
# --------------------------------------------------

func is_won() -> bool:
	winner_field = ""

	var layout_id := GameSession.get_board_layout(board.current_mode)

	# Зеркальный сетевой Клондайк: победа засчитывается, когда ОДИН
	# игрок собрал все 52 карты своего поля в четыре Foundation.
	# Поле соперника больше не должно блокировать завершение матча.
	if (
		layout_id == GameSession.BOARD_LAYOUT_MIRRORED
		and NetworkMatchSync.is_network_match()
	):
		var stocks := board.get_piles(PileMarker.Kind.STOCK)
		var cards_per_field := GameSession.get_max_cards_per_stock(
			board.current_mode,
			stocks.size()
		)

		for stock in stocks:
			if not is_instance_valid(stock):
				continue

			var field_total := 0
			var field_done := 0

			for pile in board.piles:
				if not is_instance_valid(pile) or not _same_field(stock, pile):
					continue

				field_total += pile.cards.size()
				if pile.kind == PileMarker.Kind.FOUNDATION:
					field_done += pile.cards.size()

			if field_total == cards_per_field and field_done == cards_per_field:
				winner_field = board.get_field_id(stock)
				return true

		return false

	# Одиночная зеркальная игра сохраняет прежнее правило:
	# должны быть собраны обе колоды (104 карты).
	var total := 0
	var done := 0

	for pile in board.piles:
		if not is_instance_valid(pile):
			continue

		total += pile.cards.size()
		if pile.kind == PileMarker.Kind.FOUNDATION:
			done += pile.cards.size()

	if layout_id == GameSession.BOARD_LAYOUT_MIRRORED:
		return total == 104 and done == 104

	if layout_id == GameSession.BOARD_LAYOUT_RING:
		return total == 104 and done == 104

	return total == 52 and done == 52

# --------------------------------------------------
# ПРОВЕРКА ДОСТУПНЫХ ХОДОВ
# --------------------------------------------------

func has_moves() -> bool:
	# Проверяем каждое поле отдельно.
	for stock in board.get_piles(PileMarker.Kind.STOCK):
		var waste := _find_field_pile(
			stock,
			PileMarker.Kind.WASTE
		)

		var tableau := _get_field_piles(
			stock,
			PileMarker.Kind.TABLEAU
		)

		var reachable: Array[Card] = []

		reachable.append_array(stock.cards)

		if waste != null:
			reachable.append_array(waste.cards)

		# Карты Stock и Waste могут быть перенесены
		# только в Foundation или Tableau своего поля.
		for c in reachable:
			var single: Array[Card] = [c]

			if _can_play(single):
				return true

		# Проверяем перемещения между колонками
		# внутри текущего поля.
		for src in tableau:
			for i in src.cards.size():
				var lead: Card = src.cards[i]

				if not lead.face_up:
					continue

				var group: Array[Card] = []
				group.assign(src.cards.slice(i))

				if not is_valid_group(group):
					continue

				if _meaningful_move(src, i, group, tableau):
					return true

	return false


func _can_play(group: Array[Card]) -> bool:
	for p in board.get_piles(PileMarker.Kind.FOUNDATION):
		if can_drop(group, p):
			return true

	for p in board.get_piles(PileMarker.Kind.TABLEAU):
		if can_drop(group, p):
			return true

	return false


func _foundation_accepts(card: Card) -> bool:
	var single: Array[Card] = [card]

	for p in board.get_piles(PileMarker.Kind.FOUNDATION):
		if can_drop(single, p):
			return true

	return false

func _is_mirrored_field(pile: Pile) -> bool:
	if GameSession.get_board_layout(board.current_mode) \
			!= GameSession.BOARD_LAYOUT_MIRRORED:
		return false

	var root: Node3D = board.markers_root

	if root == null:
		root = board._resolve_markers_root()

	return _get_field_root(pile) != root


func get_group(card: Card) -> Array[Card]:
	var result: Array[Card] = []

	if card == null or card.pile == null:
		return result

	# Из сброса на обоих полях берётся верхняя карта (стандартное поведение).
	# Раньше на зеркальном поле разрешалась только самая нижняя карта сброса —
	# компенсация веера, развёрнутого не в ту сторону. Из-за этого второе поле
	# не могло сыграть открытую карту. Теперь веер разворачивается вместе с полем
	# (PileWaste.relayout), и правило одно для всех.
	return super.get_group(card)
	
func _meaningful_move(
	src: Pile,
	i: int,
	group: Array[Card],
	tableau: Array[Pile]
) -> bool:
	# Перенос верхней карты в Foundation.
	if i == src.cards.size() - 1:
		if _foundation_accepts(group[0]):
			return true

	var below: Card = src.cards[i - 1] if i > 0 else null

	var reveals := (
		below != null
		and not below.face_up
	)

	var exposes := (
		below != null
		and below.face_up
		and _foundation_accepts(below)
	)

	var frees := below == null

	for t in tableau:
		if t == src or not can_drop(group, t):
			continue

		if reveals or exposes:
			return true

		if frees and not t.cards.is_empty():
			return true

	return false

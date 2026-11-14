class_name KlondikePredictor
extends RefCounted
## Анализатор состояний Клондайка для одного игрового поля (замена простой has_moves).
##
## Строит абстрактное состояние поля (колода, сброс, foundation, колонки) и
## перебирает достижимые состояния поиском в ширину с хэшированием состояний.
## «Прогресс» = карта ушла в foundation или открылась закрытая карта.
##
## Вердикты:
##   WON                — поле собрано;
##   PROGRESS           — есть цепочка ходов, ведущая к прогрессу (hint — первые ходы);
##   STUCK_RECOVERABLE  — без отмены прогресса нет, но отмена (в пределах оставшихся
##                        отмен) возвращает в состояние, откуда прогресс есть;
##   DEAD_END           — окончательный тупик: ни ходами, ни доступными отменами не выйти.
## Если бюджет узлов исчерпан раньше, чем перебор закончился, вердикт PROGRESS
## с uncertain = true: безопаснее не объявлять тупик, которого может не быть.

enum Verdict { PROGRESS, STUCK_RECOVERABLE, DEAD_END, WON }

const VERDICT_NAMES := {
	Verdict.PROGRESS: "PROGRESS",
	Verdict.STUCK_RECOVERABLE: "STUCK_RECOVERABLE",
	Verdict.DEAD_END: "DEAD_END",
	Verdict.WON: "WON",
}

const IDX_STOCK := 0
const IDX_WASTE := 1
const FIRST_FOUNDATION := 2

var draw_count := 1
var node_budget := 2500
var hint_length := 4

# Порядок реальных стопок: [stock, waste, foundation..., tableau...]
var piles: Array[Pile] = []
var foundation_suits: Array[int] = []
var foundation_count := 0
var tableau_count := 0
var total_cards := 0
var waste_play_front := false


static func _marker_number(p: Pile) -> int:
	if not is_instance_valid(p.owner_marker):
		return 0
	var regex := RegEx.new()
	regex.compile("([0-9]+)")
	var m := regex.search(str(p.owner_marker.name))
	return int(m.get_string(1)) if m != null else 0


# ==================================================
# ПОСТРОЕНИЕ
# ==================================================
## Абстрактное поле без сцены (генератор раздач): [stock, waste, 4 foundation, 7 колонок].
func setup_abstract(draw: int, suits_of_foundations: Array[int] = [1, 2, 3, 4], tableau_n: int = 7) -> void:
	draw_count = maxi(1, draw)
	piles.clear()
	foundation_suits = suits_of_foundations.duplicate()
	foundation_count = foundation_suits.size()
	tableau_count = tableau_n
	total_cards = 52


## Состояние после стандартной раздачи из колоды spec (spec.back() раздаётся первой),
## повторяет KlondikeRules.deal: колонка c получает c+1 карт, открыта верхняя.
func state_from_deck(spec: Array) -> Array:
	var deck: Array = spec.duplicate()
	var tableau: Array = []
	for _i in tableau_count:
		tableau.append([])
	for row in tableau_count:
		for col in range(row, tableau_count):
			var code := int(deck.pop_back())
			tableau[col].append(code if col == row else -code)
	var state: Array = []
	var stock: Array = []
	for code in deck:
		stock.append(-absi(int(code)))
	state.append(stock)
	state.append([])
	for _f in foundation_count:
		state.append([])
	state.append_array(tableau)
	return state


## Решатель: ищет полное решение (все карты в foundation) жадным поиском по оценке.
## banned_first — ход из стартового состояния, который запрещён (поиск «другого» решения).
## Возвращает путь (Array ходов) или [] если в пределах бюджета решения нет.
func solve(start: Array, budget: int, banned_first: Variant = null) -> Array:
	var states: Array = [start]
	var parents: PackedInt32Array = [-1]
	var moves: Array = [null]
	var visited := {hash(start): true}
	var buckets := {}         # score -> Array индексов (очередь с приоритетом)
	var best_score := _score(start)
	buckets[best_score] = [0]
	var scores_present: Array = [best_score]
	var expanded := 0
	while expanded < budget and not scores_present.is_empty():
		scores_present.sort()
		var top_score: int = scores_present.back()
		var bucket: Array = buckets[top_score]
		var index: int = bucket.pop_back()
		if bucket.is_empty():
			buckets.erase(top_score)
			scores_present.pop_back()
		expanded += 1
		var state: Array = states[index]
		for mv in _generate_moves(state):
			if index == 0 and banned_first != null and mv == banned_first:
				continue
			var child := _apply(state, mv)
			var h := hash(child)
			if visited.has(h):
				continue
			visited[h] = true
			states.append(child)
			parents.append(index)
			moves.append(mv)
			var child_index := states.size() - 1
			if _foundation_total(child) == total_cards:
				var path: Array = []
				var node := child_index
				while node > 0:
					path.push_front(moves[node])
					node = parents[node]
				return path
			var sc := _score(child)
			if not buckets.has(sc):
				buckets[sc] = []
				scores_present.append(sc)
			buckets[sc].append(child_index)
	return []


## Собирает стопки поля. false — поле не похоже на Клондайк (нет колоды/сброса).
func setup(gm: GameManager, field_id: String, draw: int) -> bool:
	draw_count = maxi(1, draw)
	piles.clear()
	foundation_suits.clear()
	var stock: Pile = null
	var waste: Pile = null
	var foundations: Array[Pile] = []
	var tableau: Array[Pile] = []
	for p in gm.piles:
		if not is_instance_valid(p) or gm.get_field_id(p) != field_id:
			continue
		match p.kind:
			PileMarker.Kind.STOCK:
				stock = p
			PileMarker.Kind.WASTE:
				waste = p
			PileMarker.Kind.FOUNDATION:
				foundations.append(p)
			PileMarker.Kind.TABLEAU:
				tableau.append(p)
	if stock == null or waste == null or tableau.is_empty():
		return false
	tableau.sort_custom(func(a: Pile, b: Pile) -> bool: return _marker_number(a) < _marker_number(b))
	# Из сброса всегда играется верхняя (последняя) карта — на обоих полях.
	waste_play_front = false
	piles.append(stock)
	piles.append(waste)
	for f in foundations:
		piles.append(f)
		foundation_suits.append(f.marker_suit)
	for t in tableau:
		piles.append(t)
	foundation_count = foundations.size()
	tableau_count = tableau.size()
	total_cards = 0
	for p in piles:
		total_cards += p.cards.size()
	return true


static func encode(card: Card, face_up: bool) -> int:
	var code := (int(card.suit) << 4) | int(card.rank)
	return code if face_up else -code


func state_from_board() -> Array:
	var state: Array = []
	for p in piles:
		var arr: Array = []
		for c in p.cards:
			arr.append(encode(c, c.face_up))
		state.append(arr)
	return state


## Состояние поля после отмены последних undo_steps ходов истории.
## Ходы другого поля пропускаются (их отмена наше поле не меняет). null — не удалось.

func state_after_undos(history: Array[MoveRecord], undo_steps: int) -> Variant:
	var content: Array = []    # для каждой стопки: Array of [Card, face_up]
	for p in piles:
		var arr: Array = []
		for c in p.cards:
			arr.append([c, c.face_up])
		content.append(arr)

	var steps_done := 0
	var i := history.size() - 1
	while i >= 0 and steps_done < undo_steps:
		var record: MoveRecord = history[i]
		var belongs_to_field := false

		# История может содержать ходы нескольких независимых полей.
		# Запись считается нашей, если затрагивает карту/стопку этого предсказателя.
		for step in record.steps:
			var step_card: Card = step["card"]
			if _find_in_content(content, step_card).x >= 0:
				belongs_to_field = true
				break
			var from_pile: Variant = step.get("from")
			if from_pile is Pile and piles.has(from_pile):
				belongs_to_field = true
				break

		if not belongs_to_field:
			i -= 1
			continue

		for s_index in range(record.steps.size() - 1, -1, -1):
			var s: Dictionary = record.steps[s_index]
			var card: Card = s["card"]
			var where := _find_in_content(content, card)
			if s["type"] == "flip":
				if where.x >= 0:
					content[where.x][where.y][1] = bool(s["face_up"])
				continue

			var from_index := piles.find(s["from"])
			if where.x < 0 or from_index < 0:
				return null
			var entry: Array = content[where.x][where.y]
			content[where.x].remove_at(where.y)
			var dest: Array = content[from_index]
			var at := int(s["index"])
			if at < 0 or at >= dest.size():
				dest.append(entry)
			else:
				dest.insert(at, entry)

		steps_done += 1
		i -= 1

	# Нельзя подставлять повторяющееся состояние, если ходов этого поля меньше,
	# чем запрошено: иначе анализатор ошибочно завысит число нужных отмен.
	if steps_done < undo_steps:
		return null

	var state: Array = []
	for arr in content:
		var codes: Array = []
		for entry in arr:
			codes.append(encode(entry[0], entry[1]))
		state.append(codes)
	return state
func _find_in_content(content: Array, card: Card) -> Vector2i:
	for pi in content.size():
		var arr: Array = content[pi]
		for ci in arr.size():
			if arr[ci][0] == card:
				return Vector2i(pi, ci)
	return Vector2i(-1, -1)


# ==================================================
# АНАЛИЗ
# ==================================================
## Полный анализ поля. available_undos — сколько отмен игрок реально может сделать.
func analyze(history: Array[MoveRecord], available_undos: int) -> Dictionary:
	var undo_states: Array = []
	for k in range(1, available_undos + 1):
		var undone: Variant = state_after_undos(history, k)
		if undone == null:
			break
		undo_states.append(undone)
	return analyze_states(state_from_board(), undo_states)


## Чистый анализ без обращения к узлам сцены — безопасно вызывать из потока.
## undo_states[k-1] — состояние поля после отмены k ходов.
func analyze_states(start: Array, undo_states: Array) -> Dictionary:
	var result := search(start)
	if result["won"]:
		result["verdict"] = Verdict.WON
		return result
	if result["progress"] or not result["exhausted"]:
		result["verdict"] = Verdict.PROGRESS
		result["uncertain"] = not result["progress"]
		return result

	# Из текущего состояния прогресса нет. Проверяем, спасает ли отмена ходов.
	var undo_budget := maxi(300, node_budget / 3)
	for k in undo_states.size():
		var sub := search(undo_states[k] as Array, undo_budget, false)
		if sub["progress"] or not sub["exhausted"]:
			result["verdict"] = Verdict.STUCK_RECOVERABLE
			result["undo_steps_needed"] = k + 1
			return result
	result["verdict"] = Verdict.DEAD_END
	return result


## BFS по состояниям. Возвращает: progress, exhausted, won, explored, hint (Array ходов).
func search(start: Array, budget: int = -1, want_hint: bool = true) -> Dictionary:
	if budget < 0:
		budget = node_budget
	var start_found := _foundation_total(start)
	var start_hidden := _hidden_total(start)
	var out := {
		"progress": false, "exhausted": false, "won": start_found == total_cards,
		"explored": 0, "hint": [],
	}
	if out["won"]:
		out["exhausted"] = true
		return out

	var states: Array = [start]
	var parents: PackedInt32Array = [-1]
	var moves: Array = [null]
	var depths: PackedInt32Array = [0]
	var visited := {hash(start): true}
	var head := 0
	var best_index := -1
	var best_score := _score(start)

	while head < states.size():
		if head >= budget:
			break
		var state: Array = states[head]
		var depth := depths[head]
		for mv in _generate_moves(state):
			var child := _apply(state, mv)
			var h := hash(child)
			if visited.has(h):
				continue
			visited[h] = true
			states.append(child)
			parents.append(head)
			moves.append(mv)
			depths.append(depth + 1)
			var child_index := states.size() - 1
			var found := _foundation_total(child)
			var hidden := _hidden_total(child)
			if found > start_found or hidden < start_hidden:
				out["progress"] = true
				var sc := _score(child) * 100 - (depth + 1)
				if best_index < 0 or sc > best_score:
					best_score = sc
					best_index = child_index
				if not want_hint:
					out["explored"] = head + 1
					return out
		head += 1
		# Для подсказки нужен лучший результат в пределах hint_length ходов —
		# дальше этой глубины не ищем, если прогресс уже найден.
		if out["progress"] and head < depths.size() and depths[head] >= hint_length:
			break

	out["explored"] = head
	out["exhausted"] = head >= states.size()
	if best_index >= 0:
		var path: Array = []
		var node := best_index
		while node > 0:
			path.push_front(moves[node])
			node = parents[node]
		out["hint"] = path.slice(0, hint_length)
	return out


func _score(state: Array) -> int:
	return _foundation_total(state) * 3 - _hidden_total(state) * 2


func _foundation_total(state: Array) -> int:
	var n := 0
	for i in foundation_count:
		n += (state[FIRST_FOUNDATION + i] as Array).size()
	return n


func _hidden_total(state: Array) -> int:
	var n := 0
	for i in range(FIRST_FOUNDATION + foundation_count, state.size()):
		for code in state[i]:
			if int(code) < 0:
				n += 1
	return n


# ==================================================
# ХОДЫ (повторяют KlondikeRules)
# ==================================================
static func _rank(code: int) -> int:
	return absi(code) & 15


static func _suit(code: int) -> int:
	return absi(code) >> 4


static func _red(code: int) -> bool:
	var s := _suit(code)
	return s == Card.Suit.HEARTS or s == Card.Suit.DIAMONDS


func _tableau_accepts(pile: Array, lead: int) -> bool:
	if pile.is_empty():
		return _rank(lead) == 13
	var top := int(pile.back())
	return top > 0 and _rank(lead) == _rank(top) - 1 and _red(lead) != _red(top)


func _foundation_accepts(f_index: int, pile: Array, card: int) -> bool:
	var marker := foundation_suits[f_index]
	if marker != 0 and _suit(card) != marker:
		return false
	if pile.is_empty():
		return _rank(card) == 1
	var top := int(pile.back())
	return _suit(card) == _suit(top) and _rank(card) == _rank(top) + 1


func _generate_moves(state: Array) -> Array:
	var result: Array = []
	var t_start := FIRST_FOUNDATION + foundation_count

	# Сброс → foundation / колонки
	var waste: Array = state[IDX_WASTE]
	if not waste.is_empty():
		var top := int(waste.front()) if waste_play_front else int(waste.back())
		for fi in foundation_count:
			if _foundation_accepts(fi, state[FIRST_FOUNDATION + fi], top):
				result.append({"from": IDX_WASTE, "to": FIRST_FOUNDATION + fi, "count": 1})
				break
		for ti in tableau_count:
			if _tableau_accepts(state[t_start + ti], top):
				result.append({"from": IDX_WASTE, "to": t_start + ti, "count": 1})

	# Колонки → foundation / другие колонки
	for si in tableau_count:
		var src: Array = state[t_start + si]
		if src.is_empty():
			continue
		var top := int(src.back())
		if top > 0:
			for fi in foundation_count:
				if _foundation_accepts(fi, state[FIRST_FOUNDATION + fi], top):
					result.append({"from": t_start + si, "to": FIRST_FOUNDATION + fi, "count": 1})
					break
		# Группы: от каждой открытой карты до верха, если последовательность правильная.
		var i := src.size() - 1
		while i >= 0 and int(src[i]) > 0:
			if i < src.size() - 1:
				var lower := int(src[i + 1])
				var upper := int(src[i])
				if _rank(lower) != _rank(upper) - 1 or _red(lower) == _red(upper):
					break
			var lead := int(src[i])
			var whole_column := i == 0
			for ti in tableau_count:
				if ti == si:
					continue
				var dst: Array = state[t_start + ti]
				# Король со дна колонки на пустую — бессмысленная перестановка.
				if whole_column and dst.is_empty():
					continue
				if _tableau_accepts(dst, lead):
					result.append({"from": t_start + si, "to": t_start + ti, "count": src.size() - i})
			i -= 1

	# Колода
	var stock: Array = state[IDX_STOCK]
	if not stock.is_empty():
		result.append({"draw": true})
	elif not waste.is_empty():
		result.append({"recycle": true})
	return result


func _apply(state: Array, mv: Dictionary) -> Array:
	var next := state.duplicate(true)
	if mv.has("draw"):
		var stock: Array = next[IDX_STOCK]
		var waste: Array = next[IDX_WASTE]
		for _i in mini(draw_count, stock.size()):
			waste.append(absi(int(stock.pop_back())))
		return next
	if mv.has("recycle"):
		var stock: Array = next[IDX_STOCK]
		var waste: Array = next[IDX_WASTE]
		while not waste.is_empty():
			stock.append(-absi(int(waste.pop_back())))
		return next
	var src: Array = next[mv["from"]]
	var dst: Array = next[mv["to"]]
	var count := int(mv["count"])
	if int(mv["from"]) == IDX_WASTE and waste_play_front:
		dst.append(src.pop_front())
		return next
	var group := src.slice(src.size() - count)
	src.resize(src.size() - count)
	dst.append_array(group)
	# Как KlondikeRules.after_move: открывается верхняя карта колонки-источника.
	if int(mv["from"]) >= FIRST_FOUNDATION + foundation_count and not src.is_empty() and int(src.back()) < 0:
		src[src.size() - 1] = absi(int(src.back()))
	return next


# ==================================================
# ПОДСКАЗКА: ходы → реальные карты и стопки
# ==================================================
## Переводит ходы подсказки в описания с реальными стопками (на текущем поле).
func describe_hint(hint: Array) -> Array:
	var out: Array = []
	var state := state_from_board()
	for mv in hint:
		var entry := {"move": mv}
		if mv.has("draw"):
			# Подсказка показывает направление от верхней карты Stock к Waste.
			entry["from_pile"] = piles[IDX_STOCK]
			entry["to_pile"] = piles[IDX_WASTE]
			entry["card_index"] = (piles[IDX_STOCK] as Pile).cards.size() - 1
		elif mv.has("recycle"):
			# При recycle игрок нажимает пустой Stock: карты возвращаются из Waste.
			entry["from_pile"] = piles[IDX_WASTE]
			entry["to_pile"] = piles[IDX_STOCK]
			entry["card_index"] = (piles[IDX_WASTE] as Pile).cards.size() - 1
		else:
			var src: Array = state[mv["from"]]
			var from_front := int(mv["from"]) == IDX_WASTE and waste_play_front
			var lead_index := 0 if from_front else src.size() - int(mv["count"])
			var lead := int(src[lead_index])
			entry["from_pile"] = piles[mv["from"]]
			entry["to_pile"] = piles[mv["to"]]
			entry["card_index"] = lead_index
		out.append(entry)
		state = _apply(state, mv)
	return out


static func card_text(code: int) -> String:
	var ranks := ["", "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]
	var suits := ["", "♠", "♥", "♦", "♣"]
	return ranks[_rank(code)] + suits[clampi(_suit(code), 0, 4)]


func _pile_text(index: int) -> String:
	if index >= FIRST_FOUNDATION and index < FIRST_FOUNDATION + foundation_count:
		return "дом"
	return "колонка %d" % (index - FIRST_FOUNDATION - foundation_count + 1)

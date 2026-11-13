class_name KlondikeDealGenerator
extends RefCounted
## Генератор раздач для сетевого зеркального Клондайка.
##
## Три независимые опции (любая комбинация):
##   same_deck   — одинаковая колода: оставшиеся в колоде (stock) 24 карты идут
##                 в одном порядке у обоих игроков;
##   same_layout — одинаковая раскидка: 28 карт на столе разложены одинаково
##                 (с точки зрения каждого игрока — колонки по номерам маркеров);
##   winnable    — каждому полю выдаётся гарантированно решаемая раздача
##                 (решатель нашёл решение; по возможности два с разными первыми ходами).
## Ничего не выбрано — у каждого игрока своя случайная раздача.
##
## Колода описывается как Array кодов (suit << 4 | rank) в порядке Stock.create_deck:
## последний элемент раздаётся первым.

const TABLEAU_CARDS := 28
const STOCK_CARDS := 24

var draw_count := 1
## Бюджет решателя на одну проверку и число попыток на поле
var solve_budget := 5000
var max_attempts := 14
var rng := RandomNumberGenerator.new()

var _predictor := KlondikePredictor.new()


func _init(draw: int = 1, seed_value: int = 0) -> void:
	draw_count = maxi(1, draw)
	_predictor.setup_abstract(draw_count)
	if seed_value != 0:
		rng.seed = seed_value
	else:
		rng.randomize()


static func full_deck() -> Array:
	var deck: Array = []
	for suit in range(1, 5):
		for rank in range(1, 14):
			deck.append((suit << 4) | rank)
	return deck


static func to_spec(codes: Array) -> Array[Vector2i]:
	var spec: Array[Vector2i] = []
	for code in codes:
		spec.append(Vector2i(int(code) >> 4, int(code) & 15))
	return spec


## Возвращает {"field_1": Array, "field_2": Array, "info": String}.
func generate(same_deck: bool, same_layout: bool, winnable: bool) -> Dictionary:
	var a := _make_deck(func(): return _shuffled(full_deck()), winnable)
	var stock_a: Array = a["deck"].slice(0, STOCK_CARDS)
	var deal_a: Array = a["deck"].slice(STOCK_CARDS)
	var b: Dictionary
	if same_deck and same_layout:
		b = a
	elif same_layout:
		b = _make_deck(func(): return _shuffled(stock_a) + deal_a, winnable)
	elif same_deck:
		b = _make_deck(func(): return stock_a + _shuffled(deal_a), winnable)
	else:
		b = _make_deck(func(): return _shuffled(full_deck()), winnable)
	return {
		"field_1": a["deck"],
		"field_2": b["deck"],
		"info": "P1: %s · P2: %s" % [a["info"], b["info"]],
	}


## Пытается построить колоду (из make_candidate), подходящую под условие winnable.
func _make_deck(make_candidate: Callable, winnable: bool) -> Dictionary:
	if not winnable:
		return {"deck": make_candidate.call(), "info": "случайная"}
	var best_single: Array = []
	for attempt in max_attempts:
		var deck: Array = make_candidate.call()
		var solutions := count_solutions(deck, 2)
		if solutions >= 2:
			return {"deck": deck, "info": "решаемая (≥2 пути)"}
		if solutions == 1 and best_single.is_empty():
			best_single = deck
	if not best_single.is_empty():
		return {"deck": best_single, "info": "решаемая (1 путь)"}
	# Решатель не уложился в бюджет — отдаём случайную, но честно помечаем.
	return {"deck": make_candidate.call(), "info": "не проверена"}


## Сколько решений с РАЗНЫМИ первыми ходами удалось найти (до limit).
func count_solutions(deck: Array, limit: int = 2) -> int:
	var start := _predictor.state_from_deck(deck)
	var first := _predictor.solve(start, solve_budget)
	if first.is_empty():
		return 0
	if limit <= 1:
		return 1
	var second := _predictor.solve(start, solve_budget, first[0])
	return 1 if second.is_empty() else 2


func _shuffled(cards: Array) -> Array:
	var out := cards.duplicate()
	for i in range(out.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = out[i]
		out[i] = out[j]
		out[j] = tmp
	return out

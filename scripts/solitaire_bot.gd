class_name SolitaireBot
extends Node
## Играет за игрока через те же GameRules, что и обычная партия.
## Ходы выбираются случайно, но с весами: foundation > открытие закрытой карты > остальное.
## Когда ходов нет (или партия выиграна, или лимит шагов) шлёт сигнал finished.
## Без await: таймер лежит внутри узла и умирает вместе с ним.

signal finished

@export var step_delay := 0.9
@export var max_steps := 120

var _gm: GameManager
var _timer: Timer
var _steps := 0
var _idle := 0                 # сколько раз подряд кликнули по колоде без хода
var _done := false
var _last_card: Card = null    # чтобы не гонять одну карту туда-сюда
var _last_from: Pile = null


func start(gm: GameManager) -> void:
	_gm = gm
	gm.game_won.connect(_finish)
	gm.no_moves_left.connect(_finish)
	_timer = Timer.new()
	_timer.one_shot = true
	add_child(_timer)
	_timer.timeout.connect(_tick)
	_schedule()


func _schedule() -> void:
	if _done:
		return
	_timer.start(step_delay * randf_range(0.7, 1.3))


func _tick() -> void:
	if _done or not is_instance_valid(_gm) or _gm.rules == null:
		return
	if _gm.is_dealing:
		_schedule()
		return

	_steps += 1
	if _steps > max_steps:
		_finish()
		return

	if not _play_move():
		_click_stock()
	_schedule()


func _play_move() -> bool:
	var rules := _gm.rules
	var options: Array[Dictionary] = []
	var total := 0.0

	for pile in _gm.piles:
		if not is_instance_valid(pile):
			continue
		if pile.kind != PileMarker.Kind.TABLEAU and pile.kind != PileMarker.Kind.WASTE:
			continue
		for i in pile.cards.size():
			var card: Card = pile.cards[i]
			if not card.face_up:
				continue
			var group := rules.get_group(card)
			if group.is_empty():
				continue
			for target in _gm.piles:
				if target == pile or not is_instance_valid(target):
					continue
				if target.kind != PileMarker.Kind.TABLEAU and target.kind != PileMarker.Kind.FOUNDATION:
					continue
				if not rules.can_drop(group, target):
					continue
				if card == _last_card and target == _last_from:
					continue
				var score := _score(pile, i, target)
				if score <= 0.0:
					continue
				options.append({"group": group, "target": target, "score": score,
						"card": card, "from": pile})
				total += score

	if options.is_empty():
		return false

	var roll := randf() * total
	var chosen: Dictionary = options[0]
	for o in options:
		roll -= o["score"]
		if roll <= 0.0:
			chosen = o
			break

	var grp: Array[Card] = chosen["group"]
	if _gm.try_move(grp, chosen["target"]):
		_idle = 0
		_last_card = chosen["card"]
		_last_from = chosen["from"]
		return true
	return false


## Чем больше, тем охотнее бот делает такой ход. <= 0 = бессмысленный ход, не рассматриваем.
func _score(src: Pile, index: int, target: Pile) -> float:
	var s := 0.0
	if target.kind == PileMarker.Kind.FOUNDATION:
		s += 3.0
	if src.kind == PileMarker.Kind.WASTE:
		s += 1.0
	if src.kind == PileMarker.Kind.TABLEAU:
		if index > 0 and not src.cards[index - 1].face_up:
			s += 2.0                                  # откроем закрытую карту
		if index == 0 and target.kind == PileMarker.Kind.TABLEAU:
			# переносить всю колонку на пустую (король с пустого места) бессмысленно
			s += 1.0 if not target.cards.is_empty() else -10.0
	# сборка по масти (важно для Паука)
	if target.kind == PileMarker.Kind.TABLEAU and not target.cards.is_empty():
		if target.cards.back().suit == src.cards[index].suit:
			s += 1.5
	return s


func _click_stock() -> void:
	var stock := _gm.get_pile(PileMarker.Kind.STOCK)
	var waste := _gm.get_pile(PileMarker.Kind.WASTE)
	if stock == null:
		_finish()
		return
	var total := stock.cards.size() + (waste.cards.size() if waste != null else 0)
	if total == 0:
		_finish()
		return

	_gm.rules.on_pile_clicked(stock)
	_idle += 1

	# полный круг по колоде без единого хода = партия зашла в тупик
	var draw = _gm.rules.get("draw_count")
	if draw == null:
		draw = _gm.rules.get("deal_size")      # Паук: за клик раздаётся 10 карт
	var per_pass := ceili(total / float(maxi(int(draw) if draw != null else 1, 1))) + 2
	if _idle > per_pass:
		_finish()


func _finish() -> void:
	if _done:
		return
	_done = true
	if _timer != null:
		_timer.stop()
	finished.emit()

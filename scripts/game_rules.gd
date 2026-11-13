class_name GameRules
extends RefCounted
## Базовый набор правил. Каждый режим наследует его и переопределяет нужное.

var board: GameManager


func _init(b: GameManager) -> void:
	board = b


## Вызывается после создания стопок.
func on_board_built() -> void:
	pass


## Раздача (может быть корутиной с await).
func deal() -> void:
	pass


## Состав колоды: x = масть (1..4), y = ранг (1..13). По умолчанию обычные 52 карты.
func build_deck() -> Array[Vector2i]:
	var deck: Array[Vector2i] = []
	for suit in range(1, 5):
		for rank in range(1, 14):
			deck.append(Vector2i(suit, rank))
	return deck


## Какие карты поднимутся вместе с нажатой. Пустой массив = брать нельзя.
func get_group(card: Card) -> Array[Card]:
	var result: Array[Card] = []
	var pile: Pile = card.pile
	if pile == null or not card.face_up:
		return result
	var idx := pile.cards.find(card)
	if idx == -1:
		return result

	var only_top := pile.kind != PileMarker.Kind.TABLEAU \
			or not GameSession.supports_group_move(board.current_mode)
	if only_top:
		if idx == pile.cards.size() - 1:
			result.append(card)
		return result

	result.assign(pile.cards.slice(idx))
	if not is_valid_group(result):
		result.clear()
	return result


## Допустима ли такая последовательность для переноса.
func is_valid_group(_group: Array[Card]) -> bool:
	return true


func can_drop(_group: Array[Card], _pile: Pile) -> bool:
	return false


## Клик по стопке (например, по колоде). true = клик обработан.
func on_pile_clicked(_pile: Pile) -> bool:
	return false


## Дополнительные действия после успешного переноса (переворот карты и т.п.).
func after_move(_record: MoveRecord, _source: Pile) -> void:
	pass


func has_moves() -> bool:
	return true


func is_won() -> bool:
	return false

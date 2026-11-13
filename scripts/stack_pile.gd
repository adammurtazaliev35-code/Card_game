extends Pile
class_name Stock

@export var card_scene: PackedScene
## Размер колоды, только если правил нет (тест сцены). Иначе состав задают GameRules.build_deck().
@export_range(0, 52) var deck_size: int = 52


func _ready() -> void:
	super._ready()

	# В тестовой сцене без GameRules оставляем старое поведение.
	if cards.is_empty() and rules == null:
		create_deck()


func create_deck(deck_spec: Array[Vector2i] = []) -> void:
	if card_scene == null:
		push_error("Stock: не назначена сцена карты!")
		return

	var spec: Array[Vector2i] = deck_spec.duplicate()

	if spec.is_empty():
		if rules != null:
			spec = rules.build_deck()
		else:
			for i in mini(deck_size, 52):
				spec.append(Vector2i(int(i / 13.0) + 1, (i % 13) + 1))

	# Сетевая партия: хост прислал готовую колоду для этого поля — берём её как есть.
	var marker_key := str(owner_marker.name) if is_instance_valid(owner_marker) else ""
	if NetworkMatchState.active and not _is_background_board() \
			and NetworkMatchState.field_decks.has(marker_key) \
			and (NetworkMatchState.field_decks[marker_key] as Array).size() == spec.size():
		spec = KlondikeDealGenerator.to_spec(NetworkMatchState.field_decks[marker_key])
	else:
		_shuffle_spec(spec)

	for entry in spec:
		var new_card := card_scene.instantiate() as Card
		if new_card == null:
			push_error("Stock: сцена не содержит скрипт Card!")
			continue

		new_card.suit = entry.x
		new_card.rank = entry.y
		new_card.face_up = false

		add_child(new_card)
		new_card.pile = self
		new_card.update_card_appearance()
		cards.append(new_card)

	relayout()


func _shuffle_spec(spec: Array[Vector2i]) -> void:
	var rng := RandomNumberGenerator.new()
	if NetworkMatchState.active and NetworkMatchState.deal_seed != 0 and not _is_background_board():
		# Сетевая партия: одинаковая тасовка на обоих клиентах.
		# Имя маркера разводит колоды разных полей (Stock / Stock_P2).
		var marker_name := str(owner_marker.name) if is_instance_valid(owner_marker) else str(name)
		rng.seed = hash("%d|%s" % [NetworkMatchState.deal_seed, marker_name])
	else:
		rng.randomize()
	for i in range(spec.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := spec[i]
		spec[i] = spec[j]
		spec[j] = tmp


## Демо-стол в фоне меню живёт внутри SubViewport и в сетевой партии не участвует.
func _is_background_board() -> bool:
	return is_inside_tree() and get_viewport() != get_tree().root

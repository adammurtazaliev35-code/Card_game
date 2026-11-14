extends Node3D
class_name CardManager

const LAYER_CARDS := 1
const LAYER_PILES := 2

@export var game_manager: GameManager
@export var camera: Camera3D
@export var ray_length: float = 100.0
@export var table_height: float = 0.0
@export var card_fly_height: float = 0.15

## Минимальный интервал между кликами по колоде: защищает от двойной раздачи
## при дребезге кнопки / двойном клике.
@export var stock_click_cooldown := 0.25

var _last_stock_click_ms := -100000
var _dragging: Array[Card] = []     # [0] - ведущая карта, остальные тянутся за ней
var _offsets: Array[Vector3] = []   # смещения остальных карт относительно ведущей
var _hint_visual_root: Node3D
var _hint_animation_tween: Tween


func _ready() -> void:
	add_to_group("card_manager")
	set_process(false)


## Сеть: можно ли локальному игроку трогать эту стопку (своё поле или общее).
func _can_interact(pile: Pile) -> bool:
	var sync := NetworkMatchSync.find_in(get_tree())
	return sync == null or pile == null or sync.can_local_interact(pile)


func _feedback() -> NetworkBoardFeedback:
	return get_tree().get_first_node_in_group("network_board_feedback") as NetworkBoardFeedback


## Для какого поля нужна подсказка: в сети — своё; в одиночке — поле под курсором,
## а если курсор не над полем — первое поле, где есть продвигающий ход.
func _hint_field_id() -> String:
	var sync := NetworkMatchSync.find_in(get_tree())
	if sync != null and NetworkMatchSync.is_network_match():
		return sync.field_of_slot(sync.local_slot)
	var hovered := _pile_under_cursor(get_viewport().get_mouse_position(), [])
	if hovered != null:
		return game_manager.get_field_id(hovered)
	for field_id in game_manager.get_field_ids():
		var info: Dictionary = game_manager.field_verdicts.get(field_id, {})
		if not info.is_empty() and int(info["verdict"]) == KlondikePredictor.Verdict.PROGRESS:
			return field_id
	var ids := game_manager.get_field_ids()
	return ids[0] if not ids.is_empty() else GameManager.FIELD_MAIN


## Публичный вход для кнопки на интерфейсе игрока.
func show_hint(entries: Array) -> void:
	_show_hint(entries)


## Подсказка очищается только когда игрок начинает действие с картой/колодой.
func clear_hint() -> void:
	_clear_hint_visual()


## Визуальная подсказка: копия карты летит к целевой стопке и остаётся видимой до действия игрока или тайм-аута.
func _show_hint(entries: Array) -> void:
	_clear_hint_visual()
	if entries.is_empty() or game_manager == null:
		return

	var first: Dictionary = entries[0]
	var move: Dictionary = first.get("move", {})
	var source := first.get("from_pile") as Pile
	var target := first.get("to_pile") as Pile
	if not is_instance_valid(source):
		return

	# В predictor тип действия draw/recycle лежит внутри вложенного словаря move.
	# Для таких действий цель и источник определяем по типу действия.
	var card_source := source
	if move.has("draw"):
		target = _find_field_pile(source, PileMarker.Kind.WASTE)
	elif move.has("recycle"):
		card_source = _find_field_pile(source, PileMarker.Kind.WASTE)
		target = source

	if not is_instance_valid(card_source) or not is_instance_valid(target):
		return
	if card_source.cards.is_empty():
		return

	var index := clampi(
		int(first.get("card_index", card_source.cards.size() - 1)),
		0,
		card_source.cards.size() - 1
	)
	var card := card_source.cards[index] as Card
	if not is_instance_valid(card) or not is_instance_valid(card.visual):
		return

	_play_hint_card_flight(card, target)


func _find_field_pile(reference: Pile, wanted_kind: PileMarker.Kind) -> Pile:
	if not is_instance_valid(reference) or game_manager == null:
		return null
	var field_id := game_manager.get_field_id(reference)
	for pile in game_manager.piles:
		if is_instance_valid(pile) and pile.kind == wanted_kind and game_manager.get_field_id(pile) == field_id:
			return pile
	return null


func _play_hint_card_flight(card: Card, target: Pile) -> void:
	if not is_instance_valid(card) or not is_instance_valid(target):
		return

	# Отдельная копия визуала не двигает настоящую карту и не вмешивается
	# в её физику, стопку или историю ходов.
	_hint_visual_root = Node3D.new()
	_hint_visual_root.name = "HintCardFlight"
	_hint_visual_root.top_level = true
	add_child(_hint_visual_root)
	_hint_visual_root.global_transform = card.global_transform

	var visual_copy := card.visual.duplicate() as Marker3D
	if visual_copy == null:
		_hint_visual_root.queue_free()
		_hint_visual_root = null
		return
	visual_copy.transform = card.visual.transform
	_hint_visual_root.add_child(visual_copy)

	var destination := target.global_position + Vector3.UP * 0.045
	if not target.cards.is_empty():
		destination = target.cards.back().global_position + Vector3.UP * 0.045

	# Перелёт занимает около половины секунды, затем карта остаётся в точке
	# назначения до общего лимита показа в 5 секунд.
	_hint_animation_tween = create_tween()
	_hint_animation_tween.tween_property(
		_hint_visual_root,
		"global_position",
		destination,
		0.55
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_hint_animation_tween.tween_interval(4.45)
	_hint_animation_tween.tween_callback(_finish_hint_visual)


func _finish_hint_visual() -> void:
	# Callback вызывается самим Tween по завершении, поэтому здесь не kill()им
	# выполняющуюся анимацию изнутри её же шага.
	_hint_animation_tween = null
	if is_instance_valid(_hint_visual_root):
		_hint_visual_root.queue_free()
	_hint_visual_root = null


func _clear_hint_visual() -> void:
	if _hint_animation_tween != null and _hint_animation_tween.is_valid():
		_hint_animation_tween.kill()
	_hint_animation_tween = null

	if is_instance_valid(_hint_visual_root):
		_hint_visual_root.queue_free()
	_hint_visual_root = null

## Защита раздачи из колоды: не во время раздачи, не чаще stock_click_cooldown,
## и (в сети, общее поле) не пока применяется чужая раздача.
func _stock_click_allowed(pile: Pile) -> bool:
	if pile == null or pile.kind != PileMarker.Kind.STOCK:
		return true
	if game_manager == null or game_manager.is_dealing or game_manager.game_finished:
		return false
	var now := Time.get_ticks_msec()
	if now - _last_stock_click_ms < int(stock_click_cooldown * 1000.0):
		return false
	var sync := NetworkMatchSync.find_in(get_tree())
	if sync != null and sync.is_shared_pile_locked(pile):
		return false
	_last_stock_click_ms = now
	return true


## true, если сейчас тянется карта из одной из этих стопок (нужно NetworkMatchSync).
func is_dragging_from_any(piles_to_check: Array[Pile]) -> bool:
	for c in _dragging:
		if is_instance_valid(c) and c.pile in piles_to_check:
			return true
	return false


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_cancel_drag()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_try_pick_card(event.position)
		else:
			_drop_card(event.position)
	elif event is InputEventKey and event.pressed and not event.echo:
		# Ctrl+Z - отмена хода
		if event.keycode == KEY_Z and (event.ctrl_pressed or event.meta_pressed):
			if _dragging.is_empty() and game_manager:
				game_manager.undo()
		# H — подсказка (тратит одну подсказку из лимита партии)
		elif event.keycode == KEY_H and _dragging.is_empty() and game_manager:
			var entries := game_manager.request_hint(_hint_field_id())
			_show_hint(entries)


func _process(delta: float) -> void:
	if _dragging.is_empty() or not is_instance_valid(_dragging[0]):
		_dragging.clear()
		set_process(false)
		return

	var mouse_pos := get_viewport().get_mouse_position()
	var origin := camera.project_ray_origin(mouse_pos)
	var direction := camera.project_ray_normal(mouse_pos)
	var plane := Plane(Vector3.UP, table_height + card_fly_height)
	var point = plane.intersects_ray(origin, direction)
	if point == null:
		return

	var lead := _dragging[0]
	lead.drag_to(point, delta)
	for i in range(1, _dragging.size()):
		_dragging[i].follow_to(lead.global_position + _offsets[i], delta)


# --- Захват / отпускание ---

func _try_pick_card(screen_pos: Vector2) -> void:
	if game_manager == null or game_manager.rules == null or game_manager.is_dealing:
		return
	if not _dragging.is_empty():
		return
	var rules := game_manager.rules

	var hit := _ray(screen_pos, LAYER_CARDS)
	var card := hit.get("collider") as Card

	if card == null:
		# пустая колода: клик по самой зоне стопки
		var pile := _resolve_pile(_ray(screen_pos, LAYER_PILES).get("collider"))
		if pile != null and pile.kind == PileMarker.Kind.STOCK and _can_interact(pile) and _stock_click_allowed(pile):
			clear_hint()
			rules.on_pile_clicked(pile)
		return

	# Сеть: поле соперника только для просмотра.
	if card.pile is Pile and not _can_interact(card.pile):
		return

	# клик по колоде: правила сами решат, что делать (взять карту / перевернуть сброс)
	if card.pile is Pile and (card.pile as Pile).kind == PileMarker.Kind.STOCK:
		if _stock_click_allowed(card.pile):
			clear_hint()
			rules.on_pile_clicked(card.pile)
		return
	if card.pile != null and rules.on_pile_clicked(card.pile):
		clear_hint()
		return

	var group := rules.get_group(card)
	if group.is_empty():
		return

	# Любой успешный захват карты — начало следующего хода, поэтому гасим подсказку.
	clear_hint()
	_dragging = group
	_offsets.clear()
	for c in group:
		_offsets.append(c.global_position - group[0].global_position)
	for c in group:
		c.pick_up(hit.position, table_height + card_fly_height)
	set_process(true)

	var feedback := _feedback()
	if feedback != null:
		feedback.set_local_selected_card(group[0], group.size())


func _drop_card(screen_pos: Vector2) -> void:
	if _dragging.is_empty():
		return
	var group: Array[Card] = []
	group.assign(_dragging)
	_dragging.clear()
	_offsets.clear()
	set_process(false)

	for c in group:
		c.drop()

	var source: Pile = group[0].pile
	var moved := false
	if game_manager != null:
		var target := _pile_under_cursor(screen_pos, group)
		moved = target != null and game_manager.try_move(group, target)

	# неудачный ход: карты возвращаются на место, в историю ничего не пишется
	if not moved and source != null:
		source.relayout()

	var feedback := _feedback()
	if feedback != null:
		feedback.clear_local_selected_card(group[0], moved)


func _cancel_drag() -> void:
	if _dragging.is_empty():
		return
	var group: Array[Card] = []
	group.assign(_dragging)
	_dragging.clear()
	_offsets.clear()
	set_process(false)
	for c in group:
		c.drop()
	if group[0].pile != null:
		group[0].pile.relayout()
	var feedback := _feedback()
	if feedback != null:
		feedback.clear_local_selected_card(group[0], false)


# --- Рейкасты ---

func _pile_under_cursor(screen_pos: Vector2, group: Array[Card]) -> Pile:
	var exclude: Array[RID] = []
	for c in group:
		exclude.append(c.get_rid())
	var hit := _ray(screen_pos, LAYER_CARDS | LAYER_PILES, exclude)
	return _resolve_pile(hit.get("collider"))


func _resolve_pile(obj: Object) -> Pile:
	if obj is Pile:
		return obj as Pile
	if obj is Card:
		return (obj as Card).pile
	return null


func _ray(screen_pos: Vector2, mask: int, exclude: Array[RID] = []) -> Dictionary:
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * ray_length
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = mask
	query.collide_with_areas = true
	query.collide_with_bodies = false
	query.hit_from_inside = true
	query.exclude = exclude
	return get_world_3d().direct_space_state.intersect_ray(query)

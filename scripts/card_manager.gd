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

var _hint_visual: Node3D
var _hint_pulse: Tween


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


## Показывает постоянную 3D-стрелку от карты-источника к целевой стопке.
## Подсказка остаётся на столе, пока игрок не возьмёт карту или не нажмёт колоду.
func show_hint(entries: Array) -> void:
	_clear_hint()
	if entries.is_empty():
		return

	var first: Dictionary = entries[0]
	var source_pile := first.get("from_pile") as Pile
	var target_pile := first.get("to_pile") as Pile
	if not is_instance_valid(source_pile) or not is_instance_valid(target_pile):
		return

	var start_position := source_pile.global_position + Vector3.UP * 0.14
	if not source_pile.cards.is_empty():
		var card_index := int(first.get("card_index", source_pile.cards.size() - 1))
		if card_index >= 0 and card_index < source_pile.cards.size():
			var source_card := source_pile.cards[card_index] as Card
			if is_instance_valid(source_card):
				start_position = source_card.global_position + Vector3.UP * 0.14

	var target_position := target_pile.global_position + Vector3.UP * 0.16
	var direction := target_position - start_position
	var distance := direction.length()
	if distance < 0.06:
		return

	var arrow_direction := direction / distance
	var head_length := clampf(distance * 0.28, 0.035, 0.075)
	var shaft_length := maxf(distance - head_length, 0.025)

	_hint_visual = Node3D.new()
	_hint_visual.name = "PredictorHintArrow"
	add_child(_hint_visual)
	_hint_visual.global_transform = Transform3D(
		Basis(Quaternion(Vector3.UP, arrow_direction)),
		start_position
	)

	var hint_material := StandardMaterial3D.new()
	hint_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hint_material.albedo_color = Color("#F2C35B")
	hint_material.emission_enabled = true
	hint_material.emission = Color("#F2C35B")
	hint_material.emission_energy_multiplier = 1.8

	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = 0.006
	shaft_mesh.bottom_radius = 0.006
	shaft_mesh.height = shaft_length
	shaft_mesh.radial_segments = 8
	var shaft := MeshInstance3D.new()
	shaft.name = "ArrowShaft"
	shaft.mesh = shaft_mesh
	shaft.material_override = hint_material
	shaft.position = Vector3.UP * (shaft_length * 0.5)
	shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_hint_visual.add_child(shaft)

	var head_mesh := CylinderMesh.new()
	head_mesh.top_radius = 0.0
	head_mesh.bottom_radius = 0.028
	head_mesh.height = head_length
	head_mesh.radial_segments = 8
	var head := MeshInstance3D.new()
	head.name = "ArrowHead"
	head.mesh = head_mesh
	head.material_override = hint_material
	head.position = Vector3.UP * (shaft_length + head_length * 0.5)
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_hint_visual.add_child(head)

	_hint_pulse = create_tween().set_loops()
	_hint_pulse.tween_property(
		_hint_visual,
		"scale",
		Vector3(1.0, 1.12, 1.0),
		0.45
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_hint_pulse.tween_property(
		_hint_visual,
		"scale",
		Vector3.ONE,
		0.45
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func clear_hint() -> void:
	_clear_hint()


func _clear_hint() -> void:
	if _hint_pulse != null and _hint_pulse.is_running():
		_hint_pulse.kill()
	_hint_pulse = null

	if is_instance_valid(_hint_visual):
		_hint_visual.queue_free()
	_hint_visual = null


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
		if pile != null and _can_interact(pile) and _stock_click_allowed(pile):
			if rules.on_pile_clicked(pile):
				_clear_hint()
		return

	# Сеть: поле соперника только для просмотра.
	if card.pile is Pile and not _can_interact(card.pile):
		return

	# клик по колоде: правила сами решат, что делать (взять карту / перевернуть сброс)
	if card.pile is Pile and (card.pile as Pile).kind == PileMarker.Kind.STOCK:
		if _stock_click_allowed(card.pile):
			rules.on_pile_clicked(card.pile)
		return
	if card.pile != null and rules.on_pile_clicked(card.pile):
		_clear_hint()
		return

	var group := rules.get_group(card)
	if group.is_empty():
		return

	_clear_hint()
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


func _exit_tree() -> void:
	_clear_hint()


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

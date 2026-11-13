extends Node3D
class_name NetworkBoardFeedback

## Указатель соперника на столе и его действия с картами (сетевая партия).
## Узел лежит по одному и тому же пути в сценах уровней на обоих клиентах.
##
## Проекция: отправитель переводит экранную позицию мыши в МИРОВУЮ точку на
## столе (луч из своей камеры). Сцена стола одинакова у обоих клиентов, поэтому
## мировая точка однозначна; получатель просто ставит указатель в эту точку,
## и его собственная камера (поворот, зум, сдвиг) показывает её правильно.
## Экранные координаты по сети не передаются.
##
## CardManager вызывает set_local_selected_card() при захвате карты
## и clear_local_selected_card() при отпускании.

enum CardPlane { XZ, XY }
enum PointerState { MOVE, HOVER, DRAG, RELEASE }

@export_group("Указатель")
@export var camera_path: NodePath
@export_flags_3d_physics var pointer_collision_mask: int = 0xFFFFFFFF
@export var pointer_max_distance := 200.0
@export var pointer_plane_height := 0.0
@export var cursor_radius := 0.045
@export var cursor_tube_radius := 0.0025
@export var cursor_surface_offset := 0.006
@export_range(5.0, 30.0, 1.0) var send_rate_hz := 20.0
## Не отправлять движение меньше этого расстояния (метры)
@export var min_send_distance := 0.003
## Раз в столько секунд шлём «я тут», даже если мышь стоит
@export var keepalive_interval := 1.0
## Указатель прячется, если от соперника давно ничего не приходило
@export var remote_timeout := 3.5
## Запас вокруг стопок, внутри которого указатель считается «на поле» (метры)
@export var field_margin := 0.12
@export_range(1.0, 30.0, 0.5) var remote_smoothing := 14.0

@export_group("Подсветка выбранной карты")
@export var card_plane: CardPlane = CardPlane.XZ
@export var fallback_card_size := Vector3(0.072, 0.004, 0.102)
@export var outline_line_thickness := 0.003
@export var outline_surface_offset := 0.002

const CARD_RAY_LAYER := 1

var _camera: Camera3D
var _local_slot := 0
var _remote_slot := 0
var _send_timer := 0.0
var _since_last_send := 0.0
var _mouse_inside := true

# Что уже отправлено (чтобы не слать одно и то же)
var _sent_valid := false
var _sent_position := Vector3.ZERO
var _sent_state := -1
var _sent_hover_key := ""
var _sent_hover_index := -1

# Локальное перетаскивание
var _local_selected_card: Card
var _local_drag_id := 0

# Соперник
var _remote_cursor: MeshInstance3D
var _remote_cursor_material: StandardMaterial3D
var _remote_label: Label3D
var _remote_outline_root: Node3D
var _remote_outline_material: StandardMaterial3D
var _remote_outline_parts: Array[MeshInstance3D] = []
var _remote_target := Vector3.ZERO
var _remote_valid := false
var _remote_state := PointerState.MOVE
var _remote_last_seen := -1000.0
var _remote_hover_card: Card
var _remote_drag_id := 0
var _remote_drag_cards: Array[Card] = []
var _remote_drag_offsets: Array[Vector3] = []
var _remote_drag_target := Vector3.ZERO
var _release_flash := 0.0


func _ready() -> void:
	add_to_group("network_board_feedback")
	process_mode = Node.PROCESS_MODE_ALWAYS
	_camera = get_node_or_null(camera_path) as Camera3D if not camera_path.is_empty() else get_viewport().get_camera_3d()
	_create_remote_cursor()
	_create_remote_outline()

	if not _is_network_match():
		return

	_local_slot = NetworkMatchState.slot_of(int(GDSync.get_client_id()))
	_remote_slot = 2 if _local_slot == 1 else 1
	_apply_remote_colors()

	GDSync.expose_func(_receive_remote_pointer)
	GDSync.expose_func(_receive_remote_drag)
	if not GDSync.client_left.is_connected(_on_client_left):
		GDSync.client_left.connect(_on_client_left)
	if not GDSync.disconnected.is_connected(_on_disconnected):
		GDSync.disconnected.connect(_on_disconnected)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_MOUSE_EXIT, NOTIFICATION_APPLICATION_FOCUS_OUT:
			_mouse_inside = false
		NOTIFICATION_WM_MOUSE_ENTER, NOTIFICATION_APPLICATION_FOCUS_IN:
			_mouse_inside = true


func _process(delta: float) -> void:
	if not _is_network_match():
		_hide_remote()
		return

	_update_remote_visuals(delta)

	_send_timer += delta
	_since_last_send += delta
	if _send_timer < 1.0 / maxf(send_rate_hz, 1.0):
		return
	_send_timer = 0.0
	_update_and_send_pointer()


# ==================================================
# ЛОКАЛЬНЫЙ ИГРОК → СЕТЬ
# ==================================================
func set_local_selected_card(card: Node3D, group_size: int = 1) -> void:
	## Вызывается CardManager при захвате карты (начало перетаскивания).
	_local_selected_card = card as Card
	if not _is_network_match() or _local_selected_card == null:
		return
	var sync := NetworkMatchSync.find_in(get_tree())
	var pile := _local_selected_card.pile as Pile
	if sync == null or pile == null:
		return
	_local_drag_id += 1
	GDSync.call_func(
		_receive_remote_drag,
		_local_slot,
		_local_drag_id,
		"pick",
		sync.get_pile_key(pile),
		pile.cards.find(_local_selected_card),
		maxi(1, group_size),
		_local_selected_card.global_position
	)
	_send_pointer_now(PointerState.DRAG)


func clear_local_selected_card(card: Node3D = null, _moved: bool = false) -> void:
	## Вызывается CardManager при отпускании карты (ход сделан или отменён).
	if card != null and is_instance_valid(_local_selected_card) and card != _local_selected_card:
		return
	var had_card := is_instance_valid(_local_selected_card)
	_local_selected_card = null
	if not _is_network_match() or not had_card:
		return
	GDSync.call_func(_receive_remote_drag, _local_slot, _local_drag_id, "release", "", -1, 0, Vector3.ZERO)
	_send_pointer_now(PointerState.RELEASE)


func _is_network_match() -> bool:
	# The main menu may create local demo boards while GD-Sync remains connected.
	# Only the explicit match flag enables remote cursors/outlines.
	if not GDSync.is_active():
		return false
	return NetworkMatchState.active


func _get_camera() -> Camera3D:
	if is_instance_valid(_camera):
		return _camera
	_camera = get_viewport().get_camera_3d()
	return _camera


func _get_pointer_world_position() -> Dictionary:
	var invalid := {"valid": false, "position": Vector3.ZERO}
	var camera := _get_camera()
	if camera == null or not _mouse_inside:
		return invalid

	var mouse_position := get_viewport().get_mouse_position()
	if not get_viewport().get_visible_rect().has_point(mouse_position):
		return invalid
	var ray_origin := camera.project_ray_origin(mouse_position)
	var ray_direction := camera.project_ray_normal(mouse_position)
	var position_now := Vector3.ZERO
	var found := false

	# Точность: луч ловит и карты (Area3D), и стол. Раньше карты пропускались,
	# а запасная плоскость стояла на y=0 (ниже сукна) — с камеры соперника
	# такая точка видна выше/ниже реальной карты.
	var query := PhysicsRayQueryParameters3D.create(
		ray_origin,
		ray_origin + ray_direction * pointer_max_distance,
		pointer_collision_mask
	)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	query.hit_from_inside = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var table_y := _get_play_surface_y()
	if not hit.is_empty() and float((hit["position"] as Vector3).y) >= table_y - 0.02:
		position_now = hit["position"]
		found = true
	else:
		# Плоскость на высоте стопок (сукно), а не на y=0.
		var plane_hit: Variant = Plane(Vector3.UP, table_y).intersects_ray(ray_origin, ray_direction)
		if plane_hit is Vector3:
			position_now = plane_hit
			found = true

	# Вне игровых полей (стены, пол, край стола) указатель не показываем.
	if not found or not _is_inside_play_area(position_now):
		return invalid
	return {"valid": true, "position": position_now}


## Высота игровой поверхности: средняя высота стопок (pointer_plane_height — если стопок нет).
func _get_play_surface_y() -> float:
	var gm := get_tree().get_first_node_in_group("game_manager") as GameManager
	if gm == null:
		return pointer_plane_height
	var total := 0.0
	var count := 0
	for pile in gm.piles:
		if is_instance_valid(pile) and pile.visible:
			total += pile.global_position.y
			count += 1
	return total / float(count) if count > 0 else pointer_plane_height


func _is_inside_play_area(world_position: Vector3) -> bool:
	var gm := get_tree().get_first_node_in_group("game_manager") as GameManager
	if gm == null or gm.piles.is_empty():
		return false
	var has_bounds := false
	var bounds := AABB()
	for pile in gm.piles:
		if not is_instance_valid(pile) or not pile.visible:
			continue
		if not has_bounds:
			bounds = AABB(pile.global_position, Vector3.ZERO)
			has_bounds = true
		else:
			bounds = bounds.expand(pile.global_position)
	if not has_bounds:
		return false
	bounds = bounds.grow(field_margin)
	return (
		world_position.x >= bounds.position.x and world_position.x <= bounds.end.x
		and world_position.z >= bounds.position.z and world_position.z <= bounds.end.z
	)


## Карта под мышью (для состояния «наведение»): ключ стопки + индекс.
func _get_hover_target() -> Dictionary:
	var none := {"key": "", "index": -1}
	var camera := _get_camera()
	var sync := NetworkMatchSync.find_in(get_tree())
	if camera == null or sync == null or not _mouse_inside:
		return none
	var mouse_position := get_viewport().get_mouse_position()
	var origin := camera.project_ray_origin(mouse_position)
	var query := PhysicsRayQueryParameters3D.create(
		origin,
		origin + camera.project_ray_normal(mouse_position) * pointer_max_distance,
		CARD_RAY_LAYER
	)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	query.hit_from_inside = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var card := hit.get("collider") as Card
	if card == null or not card.pile is Pile:
		return none
	var pile := card.pile as Pile
	return {"key": sync.get_pile_key(pile), "index": pile.cards.find(card)}


func _current_local_state(hover: Dictionary) -> int:
	if is_instance_valid(_local_selected_card):
		return PointerState.DRAG
	if int(hover["index"]) >= 0:
		return PointerState.HOVER
	return PointerState.MOVE


func _update_and_send_pointer() -> void:
	var pointer := _get_pointer_world_position()
	var valid: bool = pointer["valid"]
	var position_now: Vector3 = pointer["position"]
	var hover := _get_hover_target() if valid and not is_instance_valid(_local_selected_card) else {"key": "", "index": -1}
	var state := _current_local_state(hover)
	if not valid and state != PointerState.DRAG:
		state = PointerState.MOVE

	var state_changed := (
		valid != _sent_valid
		or state != _sent_state
		or str(hover["key"]) != _sent_hover_key
		or int(hover["index"]) != _sent_hover_index
	)
	var moved := valid and position_now.distance_to(_sent_position) >= min_send_distance
	var keepalive := _since_last_send >= keepalive_interval
	if not state_changed and not moved and not keepalive:
		return   # ничего нового — сеть не трогаем

	var drag_position := _local_selected_card.global_position if is_instance_valid(_local_selected_card) else Vector3.ZERO
	_sent_valid = valid
	_sent_position = position_now
	# Наведение на карту: точку шлём в координатах карты — у соперника она
	# пересчитается от его копии той же карты и совпадёт с ней точно.
	var hover_card := _find_card(str(hover["key"]), int(hover["index"])) if int(hover["index"]) >= 0 else null
	if hover_card != null:
		position_now = hover_card.global_transform.affine_inverse() * position_now
	_sent_state = state
	_sent_hover_key = str(hover["key"])
	_sent_hover_index = int(hover["index"])
	_since_last_send = 0.0

	if state_changed:
		# Смена состояния важна — доставляем гарантированно.
		GDSync.call_func(_receive_remote_pointer, _local_slot, position_now, valid, state, _sent_hover_key, _sent_hover_index, _local_drag_id, drag_position)
	else:
		# Обычное движение: частое, потеря одного пакета не страшна.
		GDSync.call_func_unreliable(_receive_remote_pointer, _local_slot, position_now, valid, state, _sent_hover_key, _sent_hover_index, _local_drag_id, drag_position)


func _send_pointer_now(state: int) -> void:
	var pointer := _get_pointer_world_position()
	_sent_valid = pointer["valid"]
	_sent_position = pointer["position"]
	_sent_state = state
	_sent_hover_key = ""
	_sent_hover_index = -1
	_since_last_send = 0.0
	var drag_position := _local_selected_card.global_position if is_instance_valid(_local_selected_card) else Vector3.ZERO
	GDSync.call_func(_receive_remote_pointer, _local_slot, _sent_position, _sent_valid, state, "", -1, _local_drag_id, drag_position)


# ==================================================
# СЕТЬ → ОТОБРАЖЕНИЕ СОПЕРНИКА
# ==================================================
func _is_from_opponent(sender_slot: int) -> bool:
	if not _is_network_match() or sender_slot == 0 or sender_slot == _local_slot:
		return false
	return NetworkMatchState.slot_of(int(GDSync.get_sender_id())) == sender_slot


func _receive_remote_pointer(
	sender_slot: int,
	world_position: Vector3,
	is_valid: bool,
	state: int,
	hover_key: String,
	hover_index: int,
	drag_id: int,
	drag_position: Vector3
) -> void:
	if not _is_from_opponent(sender_slot):
		return
	_remote_slot = sender_slot
	_remote_last_seen = _now()
	if state == PointerState.HOVER and hover_index >= 0:
		var anchor := _find_card(hover_key, hover_index)
		if anchor == null:
			return   # карта ещё не доехала по снимку — ждём следующего пакета
		world_position = anchor.global_transform * world_position
	if is_valid and not _remote_valid:
		# Указатель появился — не «летим» из старой точки.
		_remote_cursor.global_position = world_position + Vector3.UP * cursor_surface_offset
	_remote_valid = is_valid
	_remote_target = world_position
	_remote_state = state as PointerState
	if state == PointerState.RELEASE:
		_release_flash = 1.0

	_remote_hover_card = null
	if state == PointerState.HOVER:
		_remote_hover_card = _find_card(hover_key, hover_index)

	if state == PointerState.DRAG and drag_id == _remote_drag_id and not _remote_drag_cards.is_empty():
		_remote_drag_target = drag_position


func _receive_remote_drag(
	sender_slot: int,
	drag_id: int,
	phase: String,
	pile_key: String,
	card_index: int,
	group_size: int,
	lead_position: Vector3
) -> void:
	if not _is_from_opponent(sender_slot):
		return
	_remote_last_seen = _now()
	match phase:
		"pick":
			_end_remote_drag()
			_remote_drag_id = drag_id
			var lead := _find_card(pile_key, card_index)
			if lead == null:
				return
			var pile := lead.pile as Pile
			var group: Array[Card] = []
			group.assign(pile.cards.slice(card_index, card_index + group_size))
			_remote_drag_cards = group
			_remote_drag_offsets.clear()
			for c in group:
				_remote_drag_offsets.append(c.global_position - lead.global_position)
			_remote_drag_target = lead_position
		"release":
			if drag_id == _remote_drag_id:
				_end_remote_drag()
				_release_flash = 1.0


func _find_card(pile_key: String, card_index: int) -> Card:
	var sync := NetworkMatchSync.find_in(get_tree())
	if sync == null or card_index < 0:
		return null
	var pile := sync.find_pile_by_key(pile_key)
	if pile == null or card_index >= pile.cards.size():
		return null
	return pile.cards[card_index] as Card


## Карты, которые «держит» соперник, возвращаются туда, где они лежат по данным.
## Если ход прошёл, снимок поля уже перенёс их в новую стопку — relayout кладёт их туда.
func _end_remote_drag() -> void:
	var piles_to_relayout: Array[Pile] = []
	for c in _remote_drag_cards:
		if is_instance_valid(c) and c.pile is Pile and not (c.pile in piles_to_relayout):
			piles_to_relayout.append(c.pile)
	_remote_drag_cards.clear()
	_remote_drag_offsets.clear()
	for p in piles_to_relayout:
		p.relayout()


func _update_remote_visuals(delta: float) -> void:
	var alive := _now() - _remote_last_seen <= remote_timeout
	if not alive:
		if not _remote_drag_cards.is_empty():
			_end_remote_drag()
		_hide_remote()
		return

	var t := 1.0 - exp(-remote_smoothing * delta)

	# Указатель
	_remote_cursor.visible = _remote_valid
	_remote_label.visible = _remote_valid
	if _remote_valid:
		var goal := _remote_target + Vector3.UP * cursor_surface_offset
		_remote_cursor.global_position = _remote_cursor.global_position.lerp(goal, t)
		_remote_label.global_position = _remote_cursor.global_position + Vector3(0.0, 0.03, -cursor_radius * 1.4)
	var scale_goal := 1.0
	match _remote_state:
		PointerState.HOVER:
			scale_goal = 1.2
		PointerState.DRAG:
			scale_goal = 0.75
	_release_flash = maxf(0.0, _release_flash - delta * 3.0)
	scale_goal += _release_flash * 0.8
	_remote_cursor.scale = _remote_cursor.scale.lerp(Vector3.ONE * scale_goal, t)
	_remote_label.text = "%s · %s" % [NetworkMatchState.name_of(_remote_slot), _state_caption()]

	# Карты, которые соперник тащит, плавно следуют за его рукой.
	if not _remote_drag_cards.is_empty():
		var lead := _remote_drag_cards[0]
		if not is_instance_valid(lead):
			_remote_drag_cards.clear()
		else:
			for i in _remote_drag_cards.size():
				var c := _remote_drag_cards[i]
				if not is_instance_valid(c):
					continue
				var goal_pos := _remote_drag_target + _remote_drag_offsets[i]
				c.global_position = c.global_position.lerp(goal_pos, t)

	# Рамка: вокруг карты, которую соперник держит или на которую навёлся.
	var outline_card: Card = null
	if not _remote_drag_cards.is_empty() and is_instance_valid(_remote_drag_cards[0]):
		outline_card = _remote_drag_cards[0]
	elif _remote_state == PointerState.HOVER and is_instance_valid(_remote_hover_card):
		outline_card = _remote_hover_card
	_remote_outline_root.visible = outline_card != null
	if outline_card != null:
		_remote_outline_root.global_transform = outline_card.global_transform
		var bounds := _get_card_local_bounds(outline_card)
		_update_outline_geometry(bounds.position + bounds.size * 0.5, bounds.size)


func _state_caption() -> String:
	match _remote_state:
		PointerState.HOVER:
			return "наводит"
		PointerState.DRAG:
			return "тянет карту"
		PointerState.RELEASE:
			return "отпустил"
	return "ход"


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _hide_remote() -> void:
	_remote_cursor.visible = false
	_remote_label.visible = false
	_remote_outline_root.visible = false


# ==================================================
# ВИЗУАЛ
# ==================================================
func _apply_remote_colors() -> void:
	var color := NetworkMatchState.color_of(_remote_slot)
	_remote_cursor_material.albedo_color = Color(color.r, color.g, color.b, 0.65)
	_remote_cursor_material.emission = color
	_remote_outline_material.albedo_color = color
	_remote_outline_material.emission = color
	_remote_label.modulate = color


func _create_remote_cursor() -> void:
	_remote_cursor = MeshInstance3D.new()
	_remote_cursor.name = "RemotePlayerCursor"
	_remote_cursor.top_level = true
	var torus := TorusMesh.new()
	torus.inner_radius = maxf(0.005, cursor_radius - cursor_tube_radius)
	torus.outer_radius = cursor_radius + cursor_tube_radius
	torus.rings = 24
	torus.ring_segments = 8
	_remote_cursor.mesh = torus
	_remote_cursor.visible = false
	_remote_cursor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_remote_cursor_material = StandardMaterial3D.new()
	_remote_cursor_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_remote_cursor_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_remote_cursor_material.albedo_color = Color(1.0, 1.0, 1.0, 0.65)
	_remote_cursor_material.emission_enabled = true
	_remote_cursor_material.emission_energy_multiplier = 1.2
	_remote_cursor_material.no_depth_test = true
	_remote_cursor.material_override = _remote_cursor_material
	add_child(_remote_cursor)

	_remote_label = Label3D.new()
	_remote_label.name = "RemotePlayerName"
	_remote_label.top_level = true
	_remote_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_remote_label.no_depth_test = true
	_remote_label.fixed_size = true
	_remote_label.pixel_size = 0.0008
	_remote_label.font_size = 22
	_remote_label.outline_size = 6
	_remote_label.visible = false
	add_child(_remote_label)


func _create_remote_outline() -> void:
	_remote_outline_root = Node3D.new()
	_remote_outline_root.name = "RemoteSelectedCardOutline"
	_remote_outline_root.top_level = true
	_remote_outline_root.visible = false
	add_child(_remote_outline_root)
	_remote_outline_material = StandardMaterial3D.new()
	_remote_outline_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_remote_outline_material.albedo_color = Color.WHITE
	_remote_outline_material.emission_enabled = true
	_remote_outline_material.emission_energy_multiplier = 1.35

	for i in range(4):
		var part := MeshInstance3D.new()
		part.name = "OutlineEdge%d" % i
		var box := BoxMesh.new()
		part.mesh = box
		part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		part.material_override = _remote_outline_material
		_remote_outline_root.add_child(part)
		_remote_outline_parts.append(part)


func _get_card_local_bounds(card: Node3D) -> AABB:
	var inverse_root := card.global_transform.affine_inverse()
	var bounds := AABB()
	var has_bounds := false
	var stack: Array[Node] = [card]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			var mesh_instance := node as MeshInstance3D
			if mesh_instance.mesh != null:
				var mesh_bounds := mesh_instance.mesh.get_aabb()
				for x in range(2):
					for y in range(2):
						for z in range(2):
							var corner := mesh_bounds.position + Vector3(
								mesh_bounds.size.x * x,
								mesh_bounds.size.y * y,
								mesh_bounds.size.z * z
							)
							var world_corner: Vector3 = mesh_instance.global_transform * corner
							var local_corner: Vector3 = inverse_root * world_corner
							if not has_bounds:
								bounds = AABB(local_corner, Vector3.ZERO)
								has_bounds = true
							else:
								bounds = bounds.expand(local_corner)
		for child in node.get_children():
			stack.append(child)

	if not has_bounds:
		return AABB(-fallback_card_size * 0.5, fallback_card_size)
	return bounds


func _update_outline_geometry(center: Vector3, size: Vector3) -> void:
	var safe_size := Vector3(maxf(size.x, 0.01), maxf(size.y, 0.001), maxf(size.z, 0.01))
	var line := outline_line_thickness

	if card_plane == CardPlane.XZ:
		var top_y := safe_size.y * 0.5 + outline_surface_offset
		_set_outline_edge(0, center + Vector3(0.0, top_y, -safe_size.z * 0.5), Vector3(safe_size.x, line, line))
		_set_outline_edge(1, center + Vector3(0.0, top_y, safe_size.z * 0.5), Vector3(safe_size.x, line, line))
		_set_outline_edge(2, center + Vector3(-safe_size.x * 0.5, top_y, 0.0), Vector3(line, line, safe_size.z))
		_set_outline_edge(3, center + Vector3(safe_size.x * 0.5, top_y, 0.0), Vector3(line, line, safe_size.z))
	else:
		var front_z := safe_size.z * 0.5 + outline_surface_offset
		_set_outline_edge(0, center + Vector3(0.0, -safe_size.y * 0.5, front_z), Vector3(safe_size.x, line, line))
		_set_outline_edge(1, center + Vector3(0.0, safe_size.y * 0.5, front_z), Vector3(safe_size.x, line, line))
		_set_outline_edge(2, center + Vector3(-safe_size.x * 0.5, 0.0, front_z), Vector3(line, safe_size.y, line))
		_set_outline_edge(3, center + Vector3(safe_size.x * 0.5, 0.0, front_z), Vector3(line, safe_size.y, line))


func _set_outline_edge(index: int, local_position: Vector3, box_size: Vector3) -> void:
	var part := _remote_outline_parts[index]
	part.position = local_position
	var box := part.mesh as BoxMesh
	if box != null:
		box.size = box_size


# ==================================================
# ОТКЛЮЧЕНИЕ
# ==================================================
func _on_client_left(client_id: int) -> void:
	if NetworkMatchState.slot_of(client_id) == _remote_slot:
		_remote_last_seen = -1000.0
		_end_remote_drag()
		_hide_remote()


func _on_disconnected() -> void:
	NetworkMatchState.clear()
	_remote_last_seen = -1000.0
	_end_remote_drag()
	_hide_remote()

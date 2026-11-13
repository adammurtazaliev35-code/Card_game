extends Node3D
class_name LobbyCardsAmbience
## Декоративные экземпляры существующей игровой сцены карты.
## Назначьте card_scene в Inspector. Каждой карте задаются случайные rank_id 1..13
## и suit_id 1..4 через instance shader parameters, без изменения исходного ресурса.

@export_group("Сцена карты")
@export var card_scene: PackedScene
@export var card_scale := Vector3.ONE
@export var card_rotation_offset_degrees := Vector3.ZERO
@export var show_face := true

@export_group("Количество и область")
@export_range(1, 16, 1) var card_count := 7
@export var area_x := Vector2(-0.05, 1.35)
@export var area_z := Vector2(-0.95, 0.95)
@export var fall_height := 1.35
@export var land_height := 0.16

@export_group("Анимация")
@export_range(0.03, 1.0, 0.01) var fall_speed_min := 0.07
@export_range(0.03, 1.0, 0.01) var fall_speed_max := 0.14
@export_range(0.0, 2.0, 0.05) var spin_speed := 0.45
@export var tilt_amount := 0.42
@export var hide_at_cycle_edges := true

var _rng := RandomNumberGenerator.new()
var _cards: Array[Dictionary] = []

func _ready() -> void:
	_rng.randomize()
	if card_scene == null:
		push_warning("LobbyCardsAmbience: назначь свою сцену карты в поле Card Scene.")
		return
	if not card_scene.can_instantiate():
		push_error("LobbyCardsAmbience: Card Scene не может быть создана.")
		return
	for i in range(card_count):
		_create_card(i)

func _process(delta: float) -> void:
	for entry in _cards:
		var pivot := entry["pivot"] as Node3D
		if not is_instance_valid(pivot):
			continue
		var progress := float(entry["progress"]) + float(entry["speed"]) * delta
		if progress >= 1.0:
			progress = fmod(progress, 1.0)
			entry["x"] = _random_range(area_x)
			entry["z"] = _random_range(area_z)
			entry["speed"] = _rng.randf_range(fall_speed_min, fall_speed_max)
			entry["phase"] = _rng.randf_range(0.0, TAU)
			entry["rank"] = _rng.randi_range(1, 13)
			entry["suit"] = _rng.randi_range(1, 4)
			_apply_card_data(entry["instance"], int(entry["rank"]), int(entry["suit"]))
		entry["progress"] = progress

		var phase := float(entry["phase"])
		var wave := sin(progress * TAU + phase)
		pivot.position = Vector3(
			float(entry["x"]) + sin(progress * PI + phase) * 0.07,
			lerpf(fall_height, land_height, progress),
			float(entry["z"]) + cos(progress * PI + phase) * 0.045
		)
		pivot.rotation = Vector3(
			deg_to_rad(card_rotation_offset_degrees.x) + progress * PI + wave * tilt_amount,
			deg_to_rad(card_rotation_offset_degrees.y) + phase + progress * spin_speed * TAU,
			deg_to_rad(card_rotation_offset_degrees.z) + cos(progress * TAU + phase) * tilt_amount * 0.65
		)
		if hide_at_cycle_edges:
			pivot.visible = progress > 0.025 and progress < 0.975

func _create_card(index: int) -> void:
	var pivot := Node3D.new()
	pivot.name = "FloatingCard_%02d" % (index + 1)
	add_child(pivot)

	var instance := card_scene.instantiate()
	if instance is Node3D:
		pivot.add_child(instance)
		(instance as Node3D).scale *= card_scale
	else:
		var wrapper := Node3D.new()
		pivot.add_child(wrapper)
		wrapper.add_child(instance)
		wrapper.scale = card_scale

	var rank := _rng.randi_range(1, 13)
	var suit := _rng.randi_range(1, 4)
	_apply_card_data(instance, rank, suit)
	_cards.append({
		"pivot": pivot,
		"instance": instance,
		"progress": _rng.randf(),
		"speed": _rng.randf_range(fall_speed_min, fall_speed_max),
		"x": _random_range(area_x),
		"z": _random_range(area_z),
		"phase": _rng.randf_range(0.0, TAU),
		"rank": rank,
		"suit": suit
	})

func _apply_card_data(card_root: Node, rank: int, suit: int) -> void:
	var pending: Array[Node] = [card_root]
	while not pending.is_empty():
		var current = pending.pop_back()
		if current is GeometryInstance3D:
			var geometry := current as GeometryInstance3D
			# Выставляем параметр только если он объявлен в одном из шейдеров
			# конкретного меша. Это не вызывает ошибок на декоративных частях
			# сцены карты, у которых могут быть обычные StandardMaterial3D.
			if _geometry_has_instance_uniform(geometry, &"rank_id"):
				geometry.set_instance_shader_parameter(&"rank_id", float(rank))
			if _geometry_has_instance_uniform(geometry, &"suit_id"):
				geometry.set_instance_shader_parameter(&"suit_id", float(suit))
			if _geometry_has_instance_uniform(geometry, &"face_up"):
				geometry.set_instance_shader_parameter(&"face_up", 1.0 if show_face else 0.0)
		for child in current.get_children():
			if child is Node:
				pending.append(child)

func _random_range(bounds: Vector2) -> float:
	return _rng.randf_range(minf(bounds.x, bounds.y), maxf(bounds.x, bounds.y))


func _geometry_has_instance_uniform(geometry: GeometryInstance3D, parameter_name: StringName) -> bool:
	var materials: Array[Material] = []
	if geometry.material_override != null:
		materials.append(geometry.material_override)
	if geometry is MeshInstance3D:
		var mesh_instance := geometry as MeshInstance3D
		if mesh_instance.mesh != null:
			for surface_index in range(mesh_instance.mesh.get_surface_count()):
				var active_material := mesh_instance.get_active_material(surface_index)
				if active_material != null:
					materials.append(active_material)
	for material in materials:
		if material is ShaderMaterial:
			var shader_material := material as ShaderMaterial
			if shader_material.shader == null:
				continue
			for uniform_info in shader_material.shader.get_shader_uniform_list():
				if StringName(uniform_info.get("name", "")) == parameter_name:
					return true
	return false

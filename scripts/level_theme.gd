@tool
extends Node
class_name LevelTheme
## Тёплая палитра уровня. Вешается на пустой Node в уровне.
## Стол и комнату достаточно перетащить в инспектор как корни сцен:
## меши внутри скрипт находит сам, Editable Children включать не нужно.

@export_group("Свет")
@export var sun: DirectionalLight3D
@export var sun_color := Color("ffd7a8")
@export_range(0.0, 4.0, 0.05) var sun_energy := 1.1

@export_group("Окружение")
@export var background_color := Color("1f120c")
@export var ambient_color := Color("c98f62")
@export_range(0.0, 2.0, 0.05) var ambient_energy := 0.55
@export var fog_color := Color("3a1f12")
@export_range(0.0, 0.1, 0.001) var fog_density := 0.008

@export_group("Стол")
## Корень сцены table (узел table в дереве уровня)
@export var table_root: Node3D
## Часть имени MeshInstance3D с сукном (без учёта регистра). Пусто = первый меш стола.
@export var felt_mesh_name := ""
## Номер поверхности (surface) меша, которая является сукном
@export var felt_surface := 0
@export var felt_color := Color("7a3b2a")
@export_range(0.0, 1.0, 0.05) var felt_roughness := 0.95
## Убрать текстуру из материала сукна: иначе цвет умножается на зелёную текстуру и выходит оливковый
@export var felt_clear_texture := true

@export_group("Комната")
## Корень сцены room (узел room в дереве уровня)
@export var room_root: Node3D
## Множитель цвета всех материалов комнаты (белый = без изменений)
@export var room_tint := Color("ffdcb0")

@export_group("Отладка")
## Поставьте галочку: в консоль выведутся имена мешей и номера поверхностей стола и комнаты
@export var print_mesh_info := false:
	set(value):
		print_mesh_info = false
		if value and is_inside_tree():
			_print_info()


var _sig := ""


func _ready() -> void:
	apply()


## Только в редакторе: следим за изменением любого экспорта и пересчитываем тему.
func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	var sig := ""
	for p in get_property_list():
		if (p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE) and (p.usage & PROPERTY_USAGE_EDITOR):
			sig += str(get(p.name)) + "|"
	if sig != _sig:
		_sig = sig
		apply()


func apply() -> void:
	_apply_light_and_env()
	_apply_felt()
	_apply_room()


func _apply_light_and_env() -> void:
	if sun != null:
		sun.light_color = sun_color
		sun.light_energy = sun_energy
		sun.shadow_enabled = true

	# используем уже существующий WorldEnvironment сцены, чтобы не было двух (Godot ругается на это)
	var scene_root: Node = owner if owner != null else get_tree().current_scene
	var we := _find_world_env(scene_root)
	if we == null:
		we = WorldEnvironment.new()
		we.name = "WorldEnvironment"
		add_child(we)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = background_color
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = ambient_color
	env.ambient_light_energy = ambient_energy
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = fog_density > 0.0
	env.fog_light_color = fog_color
	env.fog_density = fog_density
	env.glow_enabled = true
	env.glow_intensity = 0.4
	env.glow_bloom = 0.05
	we.environment = env


func _find_world_env(node: Node) -> WorldEnvironment:
	if node == null:
		return null
	if node is WorldEnvironment:
		return node
	for c in node.get_children():
		var r := _find_world_env(c)
		if r != null:
			return r
	return null


func _apply_felt() -> void:
	if table_root == null:
		return
	var meshes := _collect_meshes(table_root)
	var target: MeshInstance3D = null
	for mi in meshes:
		if felt_mesh_name.is_empty() or String(mi.name).to_lower().contains(felt_mesh_name.to_lower()):
			target = mi
			break
	if target == null:
		push_warning("LevelTheme: меш сукна не найден (felt_mesh_name = '%s')" % felt_mesh_name)
		return
	if target.mesh == null or felt_surface >= target.mesh.get_surface_count():
		push_warning("LevelTheme: у меша %s нет поверхности %d" % [target.name, felt_surface])
		return

	# берём текущий материал (ваш override) и меняем только цвет,
	# так текстура и настройки ткани сохраняются
	var src := target.get_active_material(felt_surface) as BaseMaterial3D
	var mat: BaseMaterial3D
	if src != null:
		mat = src.duplicate() as BaseMaterial3D
	else:
		mat = StandardMaterial3D.new()
		mat.roughness = felt_roughness
	mat.albedo_color = felt_color
	if felt_clear_texture:
		mat.albedo_texture = null
	target.set_surface_override_material(felt_surface, mat)


func _apply_room() -> void:
	if room_root == null:
		return
	for mi in _collect_meshes(room_root):
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			# берём исходный материал меша, а не override, чтобы тон не накапливался
			var base := mi.mesh.surface_get_material(i) as BaseMaterial3D
			if base == null:
				base = mi.get_active_material(i) as BaseMaterial3D
			if base == null:
				continue
			var mat := base.duplicate() as BaseMaterial3D
			mat.albedo_color = base.albedo_color * room_tint
			mi.set_surface_override_material(i, mat)


func _collect_meshes(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_collect_meshes(child))
	return result


func _print_info() -> void:
	for root in [table_root, room_root]:
		if root == null:
			continue
		print("--- %s ---" % root.name)
		for mi in _collect_meshes(root):
			var count := mi.mesh.get_surface_count() if mi.mesh else 0
			print("  %s  (поверхностей: %d)" % [mi.name, count])

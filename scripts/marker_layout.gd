@tool
extends Node3D
class_name MarkerLayout
## Вешается на узел Markers. Расставляет PileMarker по пресету режима.
## В инспекторе выберите пресет, подберите slot_pitch и поставьте галочку Rebuild.
## Маркеры сохраняются в сцене как обычные узлы, их можно потом двигать руками.

enum Preset { KLONDIKE, SPIDER }
enum CoopPreset {
	MIRRORED,
	RING
}

@export_group("Coop")
@export var ring_center_node: Node3D
## Включить кооперативную раскладку.
@export var coop_enabled := false

## Выбор генератора кооперативной раскладки.
@export var coop_preset: CoopPreset = CoopPreset.MIRRORED

@export var ring_tableau_count: int = 12
@export var ring_radius: float = 0.8

## Пересоздать только выбранный кооперативный пресет.
@export var rebuild_coop := false:
	set(value):
		rebuild_coop = false
		if value and is_inside_tree() and Engine.is_editor_hint():
			_rebuild_coop()
			
@export var preset: Preset = Preset.KLONDIKE
## Расстояние между центрами колонок по X (должно быть больше ширины карты)
@export var slot_pitch := 0.11
## Расстояние по Z между верхним рядом (колода, сброс, foundation) и колонками
@export var row_gap := 0.15
## Центр всей раскладки относительно узла Markers
@export var center := Vector3.ZERO

## При запуске игры убирать маркеры, созданные не этим пресетом (старые из другого режима
## или унаследованные из базовой сцены). Включается, только если Rebuild уже нажимали.
@export var purge_stale_markers := true

## Поставьте галочку, чтобы пересоздать маркеры (сама сбрасывается)
@export var rebuild := false:
	set(value):
		rebuild = false
		if value and is_inside_tree() and Engine.is_editor_hint():
			_rebuild()


const META_KEY := "layout_preset"


func _ready() -> void:
	if Engine.is_editor_hint() or not purge_stale_markers:
		return

	# есть ли хоть один маркер, созданный текущим пресетом (значит Rebuild уже нажимали)
	var has_current := false
	for c in get_children():
		if c is PileMarker and int(c.get_meta(META_KEY, -1)) == int(preset):
			has_current = true
			break
	if not has_current:
		push_warning("MarkerLayout: маркеры не созданы пресетом %s. Нажмите Rebuild и сохраните сцену." \
				% Preset.keys()[preset])
		return

	var removed := 0
	for c in get_children():
		if c is PileMarker and int(c.get_meta(META_KEY, -1)) != int(preset):
			remove_child(c)       # именно remove_child: queue_free убрал бы узел только в конце кадра
			c.queue_free()
			removed += 1
	if removed > 0:
		push_warning("MarkerLayout: убрано %d лишних маркеров (старые или из базовой сцены). Удалите их из level_base.tscn." % removed)


func _rebuild() -> void:
	for c in get_children():
		if c is PileMarker:
			remove_child(c)
			c.queue_free()

	match preset:
		Preset.KLONDIKE:
			_build_klondike()
		Preset.SPIDER:
			_build_spider()

	print("MarkerLayout: %s, маркеров: %d" % [Preset.keys()[preset], get_child_count()])

func _rebuild_coop() -> void:
	var presets_root := get_node_or_null("CoopPresets") as Node3D

	if presets_root == null:
		presets_root = Node3D.new()
		presets_root.name = "CoopPresets"
		add_child(presets_root)
		presets_root.owner = get_tree().edited_scene_root

	var preset_name: String

	match coop_preset:
		CoopPreset.MIRRORED:
			preset_name = "Coop_MIRRORED"
		CoopPreset.RING:
			preset_name = "Coop_RING"
		_:
			push_error("Неизвестный CoopPreset")
			return

	var preset_root := presets_root.get_node_or_null(preset_name) as Node3D

	if preset_root == null:
		preset_root = Node3D.new()
		preset_root.name = preset_name
		presets_root.add_child(preset_root)
		preset_root.owner = get_tree().edited_scene_root

	# Удаляем только маркеры выбранного пресета.
	for child in preset_root.get_children():
		if child is PileMarker:
			preset_root.remove_child(child)
			child.queue_free()

	match coop_preset:
		CoopPreset.MIRRORED:
			_build_coop_mirrored(preset_root)
		CoopPreset.RING:
			_build_coop_ring(preset_root)

	print("Создан пресет: ", preset_name)
	print("Количество дочерних узлов: ", preset_root.get_child_count())


func _build_coop_ring(root: Node3D) -> void:
	print("Ring count: ", ring_tableau_count)

	var count: int = maxi(ring_tableau_count, 4)
	var step: float = TAU / float(count)

	var ring_center: Vector3 = Vector3.ZERO

	if ring_center_node != null:
		ring_center = to_local(ring_center_node.global_position)

	print("Ring center: ", ring_center)
	print("Ring radius: ", ring_radius)

	for i in range(count):
		var angle: float = step * float(i)

		var marker := PileMarker.new()
		marker.name = "Tableau%d" % (i + 1)
		marker.kind = PileMarker.Kind.TABLEAU
		marker.suit = PileMarker.Suit.NONE

		marker.position = ring_center + Vector3(
			sin(angle) * ring_radius,
			0.0,
			cos(angle) * ring_radius
		)

		marker.rotation.y = angle

		root.add_child(marker)
		marker.owner = get_tree().edited_scene_root
		marker.set_meta("coop_preset", int(CoopPreset.RING))

	print("Ring: создано маркеров: ", count)
	

func _build_coop_mirrored(root: Node3D) -> void:
	var p_rotation := Basis(Vector3.UP, PI)

	for source in get_children():
		if not source is PileMarker:
			continue

		var copy := source.duplicate() as PileMarker

		if copy == null:
			continue

		copy.name = source.name + "_P2"

		# Поворачиваем позицию относительно центра раскладки.
		var relative_position: Vector3 = source.position - center

		copy.position = center + p_rotation * relative_position

		# Разворачиваем ориентацию маркера.
		copy.basis = p_rotation * source.basis

		root.add_child(copy)
		copy.owner = get_tree().edited_scene_root


func _build_klondike() -> void:
	var cols := 7
	_add("Stock", PileMarker.Kind.STOCK, PileMarker.Suit.NONE, 0, 0, cols)
	_add("Waste", PileMarker.Kind.WASTE, PileMarker.Suit.NONE, 1, 0, cols)
	# foundation привязаны к мастям (так требуют правила Клондайка)
	var suits := [PileMarker.Suit.SPADES, PileMarker.Suit.HEARTS,
			PileMarker.Suit.DIAMONDS, PileMarker.Suit.CLUBS]
	for i in 4:
		_add("Foundation%d" % (i + 1), PileMarker.Kind.FOUNDATION, suits[i], 3 + i, 0, cols)
	for i in cols:
		_add("Tableau%d" % (i + 1), PileMarker.Kind.TABLEAU, PileMarker.Suit.NONE, i, 1, cols)


func _build_spider() -> void:
	var cols := 10
	# Паук: одна колода справа сверху и 10 колонок. Foundation нет:
	# собранные ряды убираются со стола правилами.
	_add("Stock", PileMarker.Kind.STOCK, PileMarker.Suit.NONE, cols - 1, 0, cols)
	for i in cols:
		_add("Tableau%d" % (i + 1), PileMarker.Kind.TABLEAU, PileMarker.Suit.NONE, i, 1, cols)


func _add(marker_name: String, kind: PileMarker.Kind, suit: PileMarker.Suit,
		slot: int, row: int, cols: int) -> void:
	var m := PileMarker.new()
	m.name = marker_name
	m.kind = kind
	m.suit = suit
	m.set_meta(META_KEY, int(preset))
	var x := (slot - (cols - 1) * 0.5) * slot_pitch
	var z := (-0.5 if row == 0 else 0.5) * row_gap
	m.position = center + Vector3(x, 0.0, z)
	add_child(m)
	# owner нужен, чтобы узел сохранился в .tscn
	m.owner = get_tree().edited_scene_root

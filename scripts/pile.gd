extends Area3D
class_name Pile
# РОДИТЕЛЬ - ОБЫЧНАЯ СТОПКА игровых карт. Правила берёт у GameRules.

enum Layout { STACK, CASCADE }

## Значения suit_id в шейдере границы стопки:
## 0 = пусто, 1..4 = масти (для foundation), 5 = tableau, 6 = waste/discard, 7 = stock
const SHADER_TABLEAU := 5.0
const SHADER_WASTE := 6.0
const SHADER_STOCK := 7.0

@export var layout: Layout = Layout.STACK
@export var stack_step := Vector3(0, 0.00025, 0)
@export var cascade_step := Vector3(0, 0.00025, 0.015)
## Во сколько раз закрытые карты каскада лежат плотнее открытых (1 = одинаково)
@export_range(0.1, 1.0, 0.05) var facedown_ratio := 1.0
## Максимальная длина каскада по Z в метрах. Если карты не влезают, шаг сжимается. 0 = без лимита.
@export var cascade_max_length := 0.0
## Приподнимает меш границы над сукном, чтобы он не пропадал из-за z-fighting
@export var outline_lift := 0.0006
@export var initial_cards: Array[Card] = []   # для теста: перетащите карты в инспекторе

var kind: PileMarker.Kind = PileMarker.Kind.TABLEAU
var owner_marker: PileMarker
var marker_suit: int = 0
var rules: GameRules = null        # назначает GameManager
var layout_basis: Basis = Basis.IDENTITY
var cascade_basis: Basis = Basis.IDENTITY
var cards: Array[Card] = []


func _ready() -> void:
	collision_layer = 2
	collision_mask = 0
	for c in initial_cards:
		add_card(c)


func setup(marker: PileMarker) -> void:
	owner_marker = marker
	kind = marker.kind
	marker_suit = marker.suit
	# Запоминаем поворот маркера, но не поворачиваем саму стопку.
	var marker_basis := marker.global_basis

	# Ориентация карт.
	layout_basis = marker_basis.orthonormalized()

	# Направление каскада с сохранением отражения.
	cascade_basis = Basis(
		marker_basis.x.normalized(),
		marker_basis.y.normalized(),
		marker_basis.z.normalized()
	)
	var mesh: MeshInstance3D = null
	for child in get_children():
		if child is MeshInstance3D:
			mesh = child
			break
	if mesh == null:
		if kind == PileMarker.Kind.FOUNDATION:
			push_warning("У стопки %s не найден MeshInstance3D" % name)
		return
	mesh.position.y += outline_lift
	mesh.set_instance_shader_parameter("suit_id", _shader_id())


func _shader_id() -> float:
	match kind:
		PileMarker.Kind.TABLEAU: return SHADER_TABLEAU
		PileMarker.Kind.WASTE: return SHADER_WASTE
		PileMarker.Kind.STOCK: return SHADER_STOCK
	return float(marker_suit)


## Принимает ли стопка эту группу карт. Решают правила текущего режима.
func can_accept(group: Array[Card]) -> bool:
	return rules != null and rules.can_drop(group, self)


## index = -1 - положить сверху; иначе вставить на позицию (нужно для отмены хода).
func add_card(card: Card, index: int = -1) -> void:
	if card == null:
		return

	var old: Pile = card.pile
	if old != null and old != self:
		old.cards.erase(card)
		old._on_card_removed(card)

	if card.get_parent() != self:
		if card.get_parent() == null:
			add_child(card)
		else:
			card.reparent(self, true)

	card.pile = self
	card.update_card_appearance()

	cards.erase(card)
	if index < 0 or index >= cards.size():
		cards.append(card)
	else:
		cards.insert(index, card)

	_on_card_added(card)
	relayout()
	if old != null and old != self:
		old.relayout()


## Хуки для наследников (например, PileVault прячет карты).
func _on_card_added(_card: Card) -> void:
	pass


func _on_card_removed(_card: Card) -> void:
	pass

func relayout() -> void:
	if layout == Layout.CASCADE:
		_relayout_cascade()
		return

	for i in cards.size():
		if not is_instance_valid(cards[i]) or not cards[i].is_inside_tree():
			continue

		cards[i].set_board_basis(layout_basis)

		var offset := layout_basis * (stack_step * i)
		cards[i].move_to(global_position + offset)


func _relayout_cascade() -> void:
	var n := cards.size()

	var before := PackedFloat32Array()
	before.resize(n)

	var total := 0.0

	for i in n:
		before[i] = total
		total += 1.0 if cards[i].face_up else facedown_ratio

	var fit := 1.0

	if cascade_max_length > 0.0 and total * cascade_step.z > cascade_max_length:
		fit = cascade_max_length / (total * cascade_step.z)

	for i in n:
		if not is_instance_valid(cards[i]):
			continue

		if not cards[i].is_inside_tree():
			continue

		var local_offset := Vector3(
			cascade_step.x * before[i] * fit,
			cascade_step.y * i,
			cascade_step.z * before[i] * fit
		)

		# Используем реальные оси маркера,
		# а не восстанавливаем направление через Euler.
		var horizontal_offset := (
			cascade_basis.x * local_offset.x
			+ cascade_basis.z * local_offset.z
		)

		var world_offset := Vector3(
			horizontal_offset.x,
			local_offset.y,
			horizontal_offset.z
		)

		cards[i].move_to(global_position + world_offset)
		cards[i].set_board_basis(layout_basis)

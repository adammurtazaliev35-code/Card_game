extends Pile
class_name PileWaste
# Сброс (waste). При draw 3 последние fan_count карт раскладываются веером вправо.

@export var fan_step := Vector3(0.02, 0.0, 0.0)

var fan_count: int = 1    # 1 = без веера (draw 1), 3 = draw 3; задаёт GameRules


func relayout() -> void:
	var n := cards.size()
	var fan_start := n - mini(fan_count, n) if fan_count > 1 else n
	for i in n:
		if not cards[i].is_inside_tree():
			continue
		var pos := global_position + stack_step * i
		if i >= fan_start:
			# Веер идёт по оси маркера: на развёрнутом (зеркальном) поле — в его сторону.
			pos += layout_basis * fan_step * float(i - fan_start)
		cards[i].move_to(pos)
		cards[i].set_board_basis(layout_basis)

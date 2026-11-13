class_name MoveRecord
extends RefCounted
## Один ход игрока = набор шагов (перенос карты или переворот).
## Откат выполняется шагами в обратном порядке.

var steps: Array[Dictionary] = []


func add_move(card: Card, from: Pile, index: int) -> void:
	steps.append({"type": "move", "card": card, "from": from, "index": index})


func add_flip(card: Card, was_face_up: bool) -> void:
	steps.append({"type": "flip", "card": card, "face_up": was_face_up})

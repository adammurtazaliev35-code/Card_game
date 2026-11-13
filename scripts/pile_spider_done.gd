extends Pile
class_name PileSpiderDone


func _on_card_added(card: Card) -> void:
	if not card.has_meta("spider_done_original_layer"):
		card.set_meta("spider_done_original_layer", card.collision_layer)
		card.set_meta("spider_done_original_mask", card.collision_mask)
		card.set_meta("spider_done_original_ray", card.input_ray_pickable)

	card.collision_layer = 0
	card.collision_mask = 0
	card.input_ray_pickable = false
	card.visible = true


func _on_card_removed(card: Card) -> void:
	# После победы GameManager блокирует всё поле.
	# Не включаем коллизии обратно во время финальной анимации.
	var gm := get_tree().get_first_node_in_group("game_manager") as GameManager
	if gm != null and gm.game_finished:
		card.collision_layer = 0
		card.collision_mask = 0
		card.input_ray_pickable = false
		return

	if card.has_meta("spider_done_original_layer"):
		card.collision_layer = int(card.get_meta("spider_done_original_layer"))
		card.collision_mask = int(card.get_meta("spider_done_original_mask"))
		card.input_ray_pickable = bool(card.get_meta("spider_done_original_ray"))

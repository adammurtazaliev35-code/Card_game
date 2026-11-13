extends Pile
class_name PileVault
## Невидимая стопка для собранных рядов Паука. Создаётся правилами, маркера у неё нет.
## Карты внутри скрыты и не ловят клики; при отмене хода возвращаются обратно.


func _ready() -> void:
	super._ready()
	visible = false
	kind = PileMarker.Kind.FOUNDATION


func _on_card_added(card: Card) -> void:
	if not card.has_meta("orig_layer"):
		card.set_meta("orig_layer", card.collision_layer)
	card.collision_layer = 0
	card.visible = false


func _on_card_removed(card: Card) -> void:
	card.collision_layer = int(card.get_meta("orig_layer", 1))
	card.visible = true

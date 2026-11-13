extends RefCounted
class_name NetworkMatchState

## Local state shared across scene changes. GameSession is a static class,
## so network match metadata must not be stored on it with Node.set_meta().
static var active: bool = false
static var player_one_name: String = "Игрок 1"
static var player_two_name: String = "Игрок 2"
static var player_one_id: int = -1
static var player_two_id: int = -1
## Общий сид тасовки: одинаковый на обоих клиентах, задаётся хостом при старте.
## 0 = сид не задан (одиночная игра или старая версия лобби).
static var deal_seed: int = 0
## Готовые колоды полей от хоста (Клондайк, зеркальная раскладка):
## имя маркера колоды ("Stock" / "Stock_P2") -> Array кодов (suit << 4 | rank).
## Пусто — колоды тасуются по deal_seed.
static var field_decks: Dictionary = {}

const PLAYER_ONE_COLOR := Color("#E8C36A")
const PLAYER_TWO_COLOR := Color("#63D6C2")


static func clear() -> void:
	active = false
	player_one_name = "Игрок 1"
	player_two_name = "Игрок 2"
	player_one_id = -1
	player_two_id = -1
	deal_seed = 0
	field_decks = {}


## Номер игрока (1 или 2) по его GD-Sync client id. 0 — не участник партии.
static func slot_of(client_id: int) -> int:
	if client_id < 0:
		return 0
	if client_id == player_one_id:
		return 1
	if client_id == player_two_id:
		return 2
	return 0


static func id_of(slot: int) -> int:
	return player_one_id if slot == 1 else (player_two_id if slot == 2 else -1)


static func name_of(slot: int) -> String:
	return player_one_name if slot == 1 else player_two_name


static func color_of(slot: int) -> Color:
	return PLAYER_TWO_COLOR if slot == 2 else PLAYER_ONE_COLOR

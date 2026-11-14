class_name GameSession
extends RefCounted
## Хранит выбор из главного меню между сценами и общие списки режимов.

const MODE_SPIDER := 1
const MODE_KLONDIKE := 2

const DRAW_ONE := 1      # по одной карте из колоды
const DRAW_THREE := 2    # по три карты из колоды

const BOARD_LAYOUT_CLASSIC := 0
const BOARD_LAYOUT_MIRRORED := 1
const BOARD_LAYOUT_RING := 2

static var board_layout: int = BOARD_LAYOUT_CLASSIC
static var klondike_board_layout: int = BOARD_LAYOUT_CLASSIC
static var spider_board_layout: int = BOARD_LAYOUT_CLASSIC


static func get_board_layout(mode_id: int) -> int:
	if mode_id == MODE_SPIDER:
		return spider_board_layout

	return klondike_board_layout
const DRAW_NAMES := {DRAW_ONE: "По 1 карте", DRAW_THREE: "По 3 карты"}
const MODE_NAMES := {MODE_KLONDIKE: "Клондайк", MODE_SPIDER: "Паук"}
const MENU_MODES: Array[int] = [MODE_KLONDIKE, MODE_SPIDER]
## Режимы, в которых бот может играть в фоне меню (нужны готовые правила)
const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"   # ваш путь
const DEMO_MODES: Array[int] = [MODE_KLONDIKE, MODE_SPIDER] 
## Режимы, в которых можно переносить группу карт из колонки.
## Чтобы включить механику в новом режиме, добавьте его сюда.
const GROUP_MOVE_MODES: Array[int] = [MODE_SPIDER, MODE_KLONDIKE]

const LEVEL_SCENES := {
	MODE_KLONDIKE: "res://scenes/level_klondike.tscn",   # поправьте пути
	MODE_SPIDER: "res://scenes/level_spider.tscn",
}
## 0 = не выбран (GameManager использует свои mode_id / draw_mode_id)
static var mode: int = 0
static var draw_mode: int = 0
## Паук: 1 / 2 / 4 масти. 0 = взять значение со сцены.
static var spider_suits: int = 0
static var waste_conveyor_enabled: bool = true
static var shuffle_waste_on_recycle: bool = true
static var is_multiplayer := false

static func start_level(tree: SceneTree, m: int, draw: int = DRAW_ONE, suits: int = 0) -> void:
	# This entry point is for a local launch from the menu or a local restart.
	# Network matches enter through GDSync.change_scene after NetworkMatchState
	# has been populated by the lobby, so a local launch must clear stale roster data.
	NetworkMatchState.clear()
	is_multiplayer = false
	mode = m
	draw_mode = draw
	if suits in [1, 2, 4]:
		spider_suits = suits
	elif m == MODE_SPIDER and spider_suits == 0:
		# В меню нет выбора сложности: полная колода, как в «рабочем» демо.
		spider_suits = 4
	tree.change_scene_to_file(LEVEL_SCENES[m])
	## Есть ли в режиме выбор снятия карт со колоды (сейчас только Клондайк).
static func supports_draw_mode(m: int) -> bool:
	return m == MODE_KLONDIKE
## Максимальное количество карт в классической раскладке.
static func get_classic_max_cards(mode_id: int) -> int:
	match mode_id:
		MODE_KLONDIKE:
			return 52
		MODE_SPIDER:
			return 104
	return 0


## Максимальное количество карт в зеркальной раскладке.
static func get_mirrored_max_cards(mode_id: int) -> int:
	return get_classic_max_cards(mode_id) * 2


## Максимальное количество карт в круговой раскладке.
static func get_ring_max_cards(mode_id: int) -> int:
	return get_classic_max_cards(mode_id) * 2


## Получить лимит для текущей раскладки.
static func get_max_cards(mode_id: int) -> int:
	match get_board_layout(mode_id):
		BOARD_LAYOUT_CLASSIC:
			return get_classic_max_cards(mode_id)

		BOARD_LAYOUT_MIRRORED:
			return get_mirrored_max_cards(mode_id)

		BOARD_LAYOUT_RING:
			return get_ring_max_cards(mode_id)

	return 0


## Лимит карт в одной стопке Stock.
static func get_max_cards_per_stock(mode_id: int, stock_count: int) -> int:
	var total := get_max_cards(mode_id)
	return int(total / maxi(stock_count, 1))
## Текущий выбранный draw-режим; 0 трактуем как «по умолчанию — по одной».
static func effective_draw_mode() -> int:
	return DRAW_ONE if draw_mode == 0 else draw_mode
	
static func supports_group_move(m: int) -> bool:
	return m in GROUP_MOVE_MODES

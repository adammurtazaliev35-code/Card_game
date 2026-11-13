class_name GameLimits
extends Resource
## Баланс лимитов партии в одном месте: отмены ходов, подсказки, награды за рекламу.
## Значения по умолчанию лежат в res://resources/game_limits.tres — его и правьте.

const DEFAULT_PATH := "res://resources/game_limits.tres"

@export_group("Отмены ходов")
## Сколько отмен даётся в начале партии
@export_range(0, 50, 1) var undo_start := 3
## Награда за просмотр rewarded-рекламы: случайно от min до max отмен
@export_range(0, 100, 1) var ad_undo_reward_min := 10
@export_range(0, 100, 1) var ad_undo_reward_max := 15

@export_group("Подсказки")
## Сколько подсказок даётся в начале партии
@export_range(0, 50, 1) var hint_start := 3
## Награда за просмотр rewarded-рекламы (подсказок)
@export_range(0, 50, 1) var ad_hint_reward := 3
## Сколько ходов вперёд показывает подсказка
@export_range(1, 6, 1) var hint_moves := 4

@export_group("Предсказатель")
## Максимум состояний, которые перебирает анализатор за одну проверку.
## Больше — точнее определение тупика, но дольше расчёт.
@export_range(200, 20000, 100) var predictor_node_budget := 2500


static func load_default() -> GameLimits:
	if ResourceLoader.exists(DEFAULT_PATH):
		var res := load(DEFAULT_PATH) as GameLimits
		if res != null:
			return res
	return GameLimits.new()

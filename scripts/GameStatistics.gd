extends RefCounted
class_name GameStatistics

## Local statistics plus a private GD-Sync account backup when the player is logged in.
const SAVE_PATH := "user://solitaire_statistics.cfg"
const CLOUD_PATH := "card_game/statistics"

static var _loaded: bool = false
static var _data: Dictionary = {}
static var _cloud_sync_running := false
static var _cloud_sync_dirty := false


static func _defaults() -> Dictionary:
	return {
		"games_started": 0,
		"games_won": 0,
		"games_lost": 0,
		"total_moves": 0,
		"total_undos": 0,
		"total_win_seconds": 0,
		"best_time": 0,
		"best_moves": 0,
		"current_streak": 0,
		"best_streak": 0,
		"per_mode": {
			"1": _default_mode(),
			"2": _default_mode()
		}
	}


static func _default_mode() -> Dictionary:
	return {
		"started": 0,
		"won": 0,
		"lost": 0,
		"total_moves": 0,
		"total_seconds": 0,
		"best_time": 0,
		"best_moves": 0
	}


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_data = _defaults()

	var config := ConfigFile.new()
	var err := config.load(SAVE_PATH)
	if err != OK:
		return

	var saved: Variant = config.get_value("statistics", "data", {})
	if saved is Dictionary:
		# Merge saved values into defaults so later versions can add new fields.
		for key in _data:
			if saved.has(key):
				_data[key] = saved[key]
		if not _data.get("per_mode", {}) is Dictionary:
			_data["per_mode"] = _defaults()["per_mode"]
		for mode_key in ["1", "2"]:
			if not _data["per_mode"].get(mode_key, {}) is Dictionary:
				_data["per_mode"][mode_key] = _default_mode()
			else:
				var mode_data: Dictionary = _data["per_mode"][mode_key]
				for mode_field in _default_mode():
					if not mode_data.has(mode_field):
						mode_data[mode_field] = _default_mode()[mode_field]


static func _save() -> void:
	var config := ConfigFile.new()
	config.set_value("statistics", "data", _data)
	var err := config.save(SAVE_PATH)
	if err != OK:
		push_warning("GameStatistics: не удалось сохранить статистику (%d)." % err)
	_queue_cloud_sync()


## Отправляет актуальную локальную сводку в приватный документ аккаунта.
## Локальное сохранение остаётся основным резервом, если игрок не вошёл
## в аккаунт или сервер/база данных GD-Sync недоступны.
static func _queue_cloud_sync() -> void:
	if not GDSync.account_is_logged_in():
		return
	_cloud_sync_dirty = true
	if _cloud_sync_running:
		return
	_cloud_sync_running = true
	_upload_cloud_stats()


static func _upload_cloud_stats() -> void:
	while _cloud_sync_dirty:
		_cloud_sync_dirty = false
		if not GDSync.account_is_logged_in():
			break
		var response_code: int = await GDSync.account_document_set(
			CLOUD_PATH,
			_data.duplicate(true),
			false
		)
		if response_code != ENUMS.ACCOUNT_DOCUMENT_SET_RESPONSE_CODE.SUCCESS:
			push_warning(
				"GameStatistics: облачная запись GD-Sync не выполнена. Код ответа: %d. "
				+ "Проверь вход в аккаунт и привязку базы данных к API-ключу."
				% response_code
			)
			break
	_cloud_sync_running = false


static func _mode_data(mode: int) -> Dictionary:
	_ensure_loaded()
	var key := str(mode)
	if not _data["per_mode"].has(key):
		_data["per_mode"][key] = _default_mode()
	return _data["per_mode"][key]


static func record_started(mode: int) -> void:
	_ensure_loaded()
	_data["games_started"] = int(_data["games_started"]) + 1
	var mode_data := _mode_data(mode)
	mode_data["started"] = int(mode_data["started"]) + 1
	_save()


static func record_win(mode: int, moves: int, seconds: int, undos: int) -> void:
	_ensure_loaded()
	moves = maxi(moves, 0)
	seconds = maxi(seconds, 0)
	undos = maxi(undos, 0)

	_data["games_won"] = int(_data["games_won"]) + 1
	_data["total_moves"] = int(_data["total_moves"]) + moves
	_data["total_undos"] = int(_data["total_undos"]) + undos
	_data["total_win_seconds"] = int(_data["total_win_seconds"]) + seconds

	var best_time := int(_data["best_time"])
	if best_time == 0 or seconds < best_time:
		_data["best_time"] = seconds
	var best_moves := int(_data["best_moves"])
	if best_moves == 0 or moves < best_moves:
		_data["best_moves"] = moves

	_data["current_streak"] = int(_data["current_streak"]) + 1
	_data["best_streak"] = maxi(int(_data["best_streak"]), int(_data["current_streak"]))

	var mode_data := _mode_data(mode)
	mode_data["won"] = int(mode_data["won"]) + 1
	mode_data["total_moves"] = int(mode_data["total_moves"]) + moves
	mode_data["total_seconds"] = int(mode_data["total_seconds"]) + seconds
	var mode_best_time := int(mode_data["best_time"])
	if mode_best_time == 0 or seconds < mode_best_time:
		mode_data["best_time"] = seconds
	var mode_best_moves := int(mode_data["best_moves"])
	if mode_best_moves == 0 or moves < mode_best_moves:
		mode_data["best_moves"] = moves
	_save()


static func record_loss(mode: int) -> void:
	_ensure_loaded()
	_data["games_lost"] = int(_data["games_lost"]) + 1
	_data["current_streak"] = 0
	var mode_data := _mode_data(mode)
	mode_data["lost"] = int(mode_data["lost"]) + 1
	_save()


static func get_summary() -> Dictionary:
	_ensure_loaded()
	return _data.duplicate(true)


static func reset_all() -> void:
	_ensure_loaded()
	_data = _defaults()
	_save()

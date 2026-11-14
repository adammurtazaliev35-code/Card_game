extends RefCounted
class_name GameStatistics

## Persistent local statistics. No Autoload is required.
const SAVE_PATH := "user://solitaire_statistics.cfg"

static var _loaded: bool = false
static var _data: Dictionary = {}


static func _default_mode() -> Dictionary:
	return {
		"started": 0,
		"won": 0,
		"lost": 0,
		"deadends": 0,
		"total_moves": 0,
		"total_seconds": 0,
		"best_time": 0,
		"best_moves": 0
	}


static func _default_track() -> Dictionary:
	return {
		"started": 0,
		"won": 0,
		"lost": 0,
		"deadends": 0,
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


static func _defaults() -> Dictionary:
	return {
		# Aggregate compatibility fields retained for older UI / save readers.
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
		},
		# The old format did not distinguish solo and network results.
		# Preserve that history separately instead of guessing its origin.
		"legacy_mixed": {
			"games_started": 0,
			"games_won": 0,
			"games_lost": 0
		},
		"deadends": 0,
		"deadends_by_type": {"solo": 0, "network": 0},
		"by_type": {
			"solo": _default_track(),
			"network": _default_track()
		}
	}


static func _merge_mode(target: Dictionary) -> void:
	var defaults := _default_mode()
	for key in defaults:
		if not target.has(key):
			target[key] = defaults[key]


static func _merge_track(target: Dictionary) -> void:
	var defaults := _default_track()
	for key in defaults:
		if not target.has(key):
			target[key] = defaults[key]
	if not target.get("per_mode", {}) is Dictionary:
		target["per_mode"] = {}
	var modes: Dictionary = target["per_mode"]
	for mode_key in ["1", "2"]:
		if not modes.has(mode_key) or not modes[mode_key] is Dictionary:
			modes[mode_key] = _default_mode()
		_merge_mode(modes[mode_key])
	target["per_mode"] = modes


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
	if not saved is Dictionary:
		return

	for key in _data:
		if saved.has(key):
			_data[key] = saved[key]

	# One-time migration: old saves have only aggregate totals. Keep them in
	# a dedicated "mixed legacy" bucket; never attribute them to solo or network.
	if not saved.has("legacy_mixed") or not saved["legacy_mixed"] is Dictionary:
		_data["legacy_mixed"] = {
			"games_started": int(saved.get("games_started", 0)),
			"games_won": int(saved.get("games_won", 0)),
			"games_lost": int(saved.get("games_lost", 0))
		}

	if not _data.get("per_mode", {}) is Dictionary:
		_data["per_mode"] = {}
	var legacy_modes: Dictionary = _data["per_mode"]
	for mode_key in ["1", "2"]:
		if not legacy_modes.has(mode_key) or not legacy_modes[mode_key] is Dictionary:
			legacy_modes[mode_key] = _default_mode()
		_merge_mode(legacy_modes[mode_key])
	_data["per_mode"] = legacy_modes

	if not _data.get("by_type", {}) is Dictionary:
		_data["by_type"] = {}
	var by_type: Dictionary = _data["by_type"]
	for type_key in ["solo", "network"]:
		if not by_type.has(type_key) or not by_type[type_key] is Dictionary:
			by_type[type_key] = _default_track()
		_merge_track(by_type[type_key])
	_data["by_type"] = by_type

	if not _data.get("deadends_by_type", {}) is Dictionary:
		_data["deadends_by_type"] = {"solo": 0, "network": 0}
	for type_key in ["solo", "network"]:
		if not _data["deadends_by_type"].has(type_key):
			_data["deadends_by_type"][type_key] = 0


static func _save() -> void:
	var config := ConfigFile.new()
	config.set_value("statistics", "data", _data)
	var err := config.save(SAVE_PATH)
	if err != OK:
		push_warning("GameStatistics: не удалось сохранить статистику (%d)." % err)


static func _type_key(is_network: bool) -> String:
	return "network" if is_network else "solo"


static func _track(is_network: bool) -> Dictionary:
	_ensure_loaded()
	return _data["by_type"][_type_key(is_network)]


static func _mode_data(mode: int) -> Dictionary:
	_ensure_loaded()
	var key := str(mode)
	if not _data["per_mode"].has(key):
		_data["per_mode"][key] = _default_mode()
	return _data["per_mode"][key]


static func _track_mode(track: Dictionary, mode: int) -> Dictionary:
	var key := str(mode)
	var modes: Dictionary = track["per_mode"]
	if not modes.has(key):
		modes[key] = _default_mode()
		track["per_mode"] = modes
	return modes[key]


static func record_started(mode: int, is_network: bool = false) -> void:
	_ensure_loaded()
	_data["games_started"] = int(_data["games_started"]) + 1
	var legacy_mode := _mode_data(mode)
	legacy_mode["started"] = int(legacy_mode["started"]) + 1

	var track := _track(is_network)
	track["started"] = int(track["started"]) + 1
	var track_mode := _track_mode(track, mode)
	track_mode["started"] = int(track_mode["started"]) + 1
	_save()


static func record_win(
	mode: int,
	moves: int,
	seconds: int,
	undos: int,
	is_network: bool = false
) -> void:
	_ensure_loaded()
	moves = maxi(moves, 0)
	seconds = maxi(seconds, 0)
	undos = maxi(undos, 0)

	# Maintain aggregate compatibility values.
	_data["games_won"] = int(_data["games_won"]) + 1
	_data["total_moves"] = int(_data["total_moves"]) + moves
	_data["total_undos"] = int(_data["total_undos"]) + undos
	_data["total_win_seconds"] = int(_data["total_win_seconds"]) + seconds
	if int(_data["best_time"]) == 0 or seconds < int(_data["best_time"]):
		_data["best_time"] = seconds
	if int(_data["best_moves"]) == 0 or moves < int(_data["best_moves"]):
		_data["best_moves"] = moves
	_data["current_streak"] = int(_data["current_streak"]) + 1
	_data["best_streak"] = maxi(int(_data["best_streak"]), int(_data["current_streak"]))

	var legacy_mode := _mode_data(mode)
	legacy_mode["won"] = int(legacy_mode["won"]) + 1
	legacy_mode["total_moves"] = int(legacy_mode["total_moves"]) + moves
	legacy_mode["total_seconds"] = int(legacy_mode["total_seconds"]) + seconds
	if int(legacy_mode["best_time"]) == 0 or seconds < int(legacy_mode["best_time"]):
		legacy_mode["best_time"] = seconds
	if int(legacy_mode["best_moves"]) == 0 or moves < int(legacy_mode["best_moves"]):
		legacy_mode["best_moves"] = moves

	var track := _track(is_network)
	track["won"] = int(track["won"]) + 1
	track["total_moves"] = int(track["total_moves"]) + moves
	track["total_undos"] = int(track["total_undos"]) + undos
	track["total_win_seconds"] = int(track["total_win_seconds"]) + seconds
	if int(track["best_time"]) == 0 or seconds < int(track["best_time"]):
		track["best_time"] = seconds
	if int(track["best_moves"]) == 0 or moves < int(track["best_moves"]):
		track["best_moves"] = moves
	track["current_streak"] = int(track["current_streak"]) + 1
	track["best_streak"] = maxi(int(track["best_streak"]), int(track["current_streak"]))

	var track_mode := _track_mode(track, mode)
	track_mode["won"] = int(track_mode["won"]) + 1
	track_mode["total_moves"] = int(track_mode["total_moves"]) + moves
	track_mode["total_seconds"] = int(track_mode["total_seconds"]) + seconds
	if int(track_mode["best_time"]) == 0 or seconds < int(track_mode["best_time"]):
		track_mode["best_time"] = seconds
	if int(track_mode["best_moves"]) == 0 or moves < int(track_mode["best_moves"]):
		track_mode["best_moves"] = moves
	_save()


static func record_loss(mode: int, is_network: bool = false) -> void:
	_ensure_loaded()
	_data["games_lost"] = int(_data["games_lost"]) + 1
	_data["current_streak"] = 0
	var legacy_mode := _mode_data(mode)
	legacy_mode["lost"] = int(legacy_mode["lost"]) + 1

	var track := _track(is_network)
	track["lost"] = int(track["lost"]) + 1
	track["current_streak"] = 0
	var track_mode := _track_mode(track, mode)
	track_mode["lost"] = int(track_mode["lost"]) + 1
	_save()


## A deadlock is its own result category and is deliberately excluded from losses.
static func record_deadlock(mode: int, is_network: bool = false) -> void:
	_ensure_loaded()
	var type_key := _type_key(is_network)
	_data["deadends"] = int(_data.get("deadends", 0)) + 1
	_data["deadends_by_type"][type_key] = int(_data["deadends_by_type"].get(type_key, 0)) + 1
	_data["current_streak"] = 0

	var track := _track(is_network)
	track["deadends"] = int(track["deadends"]) + 1
	track["current_streak"] = 0
	var track_mode := _track_mode(track, mode)
	track_mode["deadends"] = int(track_mode.get("deadends", 0)) + 1
	_save()


static func get_summary() -> Dictionary:
	_ensure_loaded()
	return _data.duplicate(true)


static func reset_all() -> void:
	_ensure_loaded()
	_data = _defaults()
	_save()

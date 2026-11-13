class_name GameAudio
extends Node
## Музыка и звук движения карты. Автозагрузку (Autoload) настраивать не нужно:
## узел создаётся сам при первом обращении и живёт между сценами.
##
## Файлы ищутся по имени в любой папке проекта (кроме addons):
##   music.ogg / .mp3 / .wav  - фоновая музыка
##   card.ogg  / .mp3 / .wav  - звук движения карты
## В Output при запуске будет написано, что найдено, а что нет.
##
## Использование:
##   GameAudio.get_instance(get_tree()).play_music()
##   GameAudio.card(get_tree())

const MUSIC_NAME := "music"
const CARD_NAME := "card"
## Плейлист: все треки из этой папки (ogg/mp3/wav) по алфавиту.
## Если папки нет — как раньше, один файл music.* из любой папки проекта.
const MUSIC_DIR := "res://audio/music"
const SPECTRUM_BANDS := 24

## Сменился трек (название без расширения) — для настроек и «Радио».
signal track_changed(track_name: String, index: int, count: int)
const EXTENSIONS := ["ogg", "mp3", "wav"]
const KNOWN_DIRS := ["res://audio", "res://Audio", "res://sounds", "res://sound",
		"res://assets/audio", "res://assets/sounds", "res://assets", "res:/"]
const MIN_INTERVAL_MS := 35          # не чаще, чтобы стопка карт не превращалась в кашу
const SFX_VOICES := 6

static var _inst: GameAudio

var _music: AudioStreamPlayer
var _voices: Array[AudioStreamPlayer] = []
var _card_stream: AudioStream
var _want_music := false
var _last_card_ms := 0
var _playlist: Array[String] = []
var _track_index := 0
var _spectrum: AudioEffectSpectrumAnalyzerInstance


static func get_instance(tree: SceneTree) -> GameAudio:
	if _inst == null or not is_instance_valid(_inst):
		_inst = GameAudio.new()
		_inst.name = "GameAudio"
		_inst.process_mode = Node.PROCESS_MODE_ALWAYS   # музыка не замолкает на паузе
		tree.root.add_child.call_deferred(_inst)
	return _inst


static func card(tree: SceneTree) -> void:
	get_instance(tree).play_card()


func _ready() -> void:
	GameSettings.ensure_loaded()

	_music = AudioStreamPlayer.new()
	_music.bus = GameSettings.BUS_MUSIC
	_music.finished.connect(_on_music_finished)     # зацикливание для любого формата
	add_child(_music)

	for i in SFX_VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = GameSettings.BUS_SFX
		add_child(p)
		_voices.append(p)

	_card_stream = _find_stream(CARD_NAME)
	_build_playlist()
	_setup_spectrum()
	if _want_music:
		_start_music()


func play_music() -> void:
	_want_music = true
	if is_node_ready():
		_start_music()


func play_card() -> void:
	if _card_stream == null:
		return
	var now := Time.get_ticks_msec()
	if now - _last_card_ms < MIN_INTERVAL_MS:
		return
	_last_card_ms = now
	for p in _voices:
		if not p.playing:
			p.stream = _card_stream
			p.pitch_scale = randf_range(0.94, 1.06)    # чуть разные звуки, чтобы не надоедало
			p.play()
			return


func _start_music() -> void:
	if _music.playing:
		return
	if _music.stream == null:
		_load_track(_track_index)
	if _music.stream == null:
		return
	_music.play()


func _on_music_finished() -> void:
	if not _want_music:
		return
	if _playlist.size() > 1:
		next_track()      # плейлист идёт по кругу
	else:
		_music.play()     # один трек — зацикливаем


# --- Плейлист ---

func _build_playlist() -> void:
	_playlist.clear()
	var dir := DirAccess.open(MUSIC_DIR)
	if dir != null:
		for f in dir.get_files():
			var real := f.trim_suffix(".import").trim_suffix(".remap")
			if real.get_extension().to_lower() in EXTENSIONS:
				var path := MUSIC_DIR.path_join(real)
				if not path in _playlist and ResourceLoader.exists(path):
					_playlist.append(path)
		_playlist.sort()
	if _playlist.is_empty():
		# Совместимость: один файл music.* где угодно в проекте.
		var single := _find_stream_path(MUSIC_NAME)
		if not single.is_empty():
			_playlist.append(single)
	_track_index = 0
	for i in _playlist.size():
		if _playlist[i].get_file() == GameSettings.music_track:
			_track_index = i
	print("GameAudio: треков в плейлисте: %d" % _playlist.size())


func _load_track(index: int) -> void:
	if _playlist.is_empty():
		return
	_track_index = posmod(index, _playlist.size())
	var stream := load(_playlist[_track_index]) as AudioStream
	_music.stream = stream
	GameSettings.music_track = _playlist[_track_index].get_file()
	track_changed.emit(get_track_name(), _track_index, _playlist.size())


func next_track() -> void:
	_switch_track(_track_index + 1)


func prev_track() -> void:
	_switch_track(_track_index - 1)


func _switch_track(index: int) -> void:
	if _playlist.is_empty():
		return
	var was_playing := _music.playing or _want_music
	_music.stop()
	_load_track(index)
	GameSettings.save()
	if was_playing and _music.stream != null:
		_music.play()


func get_track_name() -> String:
	if _playlist.is_empty():
		return "нет музыки"
	return _playlist[_track_index].get_file().get_basename()


func get_track_count() -> int:
	return _playlist.size()


func get_track_index() -> int:
	return _track_index


func is_music_playing() -> bool:
	return _music != null and _music.playing


# --- Спектр для визуализации (Радио) ---

func _setup_spectrum() -> void:
	var bus := AudioServer.get_bus_index(GameSettings.BUS_MUSIC)
	if bus == -1:
		return
	var effect_index := -1
	for i in AudioServer.get_bus_effect_count(bus):
		if AudioServer.get_bus_effect(bus, i) is AudioEffectSpectrumAnalyzer:
			effect_index = i
	if effect_index == -1:
		var analyzer := AudioEffectSpectrumAnalyzer.new()
		analyzer.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_1024
		AudioServer.add_bus_effect(bus, analyzer)
		effect_index = AudioServer.get_bus_effect_count(bus) - 1
	_spectrum = AudioServer.get_bus_effect_instance(bus, effect_index) as AudioEffectSpectrumAnalyzerInstance


## Уровни полос спектра 0..1 (логарифмические полосы 40 Гц – 12 кГц).
func get_spectrum(bands: int = SPECTRUM_BANDS) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(bands)
	if _spectrum == null or not is_music_playing():
		return out
	var low := 40.0
	var high := 12000.0
	for i in bands:
		var f0 := low * pow(high / low, float(i) / bands)
		var f1 := low * pow(high / low, float(i + 1) / bands)
		var mag := _spectrum.get_magnitude_for_frequency_range(f0, f1).length()
		out[i] = clampf((linear_to_db(maxf(mag, 1e-6)) + 60.0) / 60.0, 0.0, 1.0)
	return out


# --- Поиск файлов ---

func _find_stream(base_name: String) -> AudioStream:
	var path := _find_stream_path(base_name)
	if path == "":
		push_warning("GameAudio: не найден файл '%s.ogg/.mp3/.wav' ни в одной папке проекта." % base_name)
		return null
	var stream := load(path) as AudioStream
	if stream == null:
		push_warning("GameAudio: не удалось загрузить " + path)
		return null
	print("GameAudio: '%s' -> %s" % [base_name, path])
	return stream


func _find_stream_path(base_name: String) -> String:
	var path := ""
	# 1) типичные папки
	for dir in KNOWN_DIRS:
		for ext in EXTENSIONS:
			var candidate: String = "%s/%s.%s" % [dir, base_name, ext]
			if ResourceLoader.exists(candidate):
				path = candidate
				break
		if path != "":
			break
	# 2) иначе ищем по всему проекту
	if path == "":
		path = _scan("res://", base_name)
	return path


func _scan(dir_path: String, base_name: String) -> String:
	var d := DirAccess.open(dir_path)
	if d == null:
		return ""
	for f in d.get_files():
		var real := f.trim_suffix(".import").trim_suffix(".remap")
		if real.get_basename().to_lower() == base_name \
				and real.get_extension().to_lower() in EXTENSIONS:
			return dir_path.path_join(real)
	for sub in d.get_directories():
		if sub == "addons" or sub.begins_with("."):
			continue
		var r := _scan(dir_path.path_join(sub), base_name)
		if r != "":
			return r
	return ""

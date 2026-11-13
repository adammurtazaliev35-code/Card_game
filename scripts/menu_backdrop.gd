extends Control
class_name MenuBackdrop
## Живой 3D-фон главного меню.
## Кладётся первым ребёнком корня меню (под кнопками). Сам создаёт SubViewport,
## загружает случайный уровень из GameSession.DEMO_MODES, отключает ввод игрока,
## добавляет лампу и запускает SolitaireBot. Когда партия кончилась, плавно
## переключается на новый случайный уровень.

@export_group("Демо")
@export var step_delay := 0.9
@export var max_steps := 120
## Пауза после конца партии перед затуханием
@export var end_pause := 2.5
@export var fade_time := 0.8

@export_group("Кадр")
## Масштаб камеры в меню (больше = дальше, виден весь стол)
@export_range(0.5, 3.0, 0.05) var menu_zoom := 1.35
## Насколько стол уезжает вправо от центра экрана (доля ширины кадра), чтобы освободить место под меню
@export_range(0.0, 0.4, 0.01) var board_offset := 0.15
## Сдвиг стола вверх/вниз (метры по Z). Отрицательный = стол выше на экране.
@export var board_shift_z := 0.0
## Размытие дальнего плана (комната мягко уходит из фокуса)
@export var blur_background := true

@export_group("Лампа")
## Своя лампа меню. Если лампа уже есть в MoodLighting или в комнате, оставьте выключенной.
@export var add_menu_lamp := false
@export var lamp_color := Color("ffcf8a")
@export_range(0.0, 16.0, 0.1) var lamp_energy := 3.0
## Высота лампы над столом. Если лампу не видно в кадре, уменьшите высоту и увеличьте угол.
@export var lamp_height := 0.4
@export_range(10.0, 89.0, 1.0) var lamp_angle := 60.0
@export var show_bulb := true

@export_group("Мягкость")
## Множитель окружающего света (чуть ярче обычного уровня)
@export_range(0.0, 3.0, 0.05) var ambient_boost := 1.4
## Множитель основного света, чтобы лампа была главным источником
@export_range(0.0, 1.0, 0.05) var sun_scale := 0.6
## Затемнение слева под текстом меню
@export var shade_color := Color(0.09, 0.05, 0.03, 0.85)
@export_range(0.2, 1.0, 0.05) var shade_width := 0.55

var _bg: ColorRect
var _container: SubViewportContainer
var _viewport: SubViewport
var _level: Node3D
var _bot: SolitaireBot
var _switching := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_bg = ColorRect.new()
	_bg.color = Color("1f120c")
	_add_full(_bg)

	_container = SubViewportContainer.new()
	_container.stretch = true
	_add_full(_container)

	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.gui_disable_input = true
	_container.add_child(_viewport)

	_add_shade()
	_spawn_demo()


func _add_full(c: Control) -> void:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(c)
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _add_shade() -> void:
	var grad := Gradient.new()
	grad.colors = PackedColorArray([shade_color, Color(shade_color, 0.0)])
	grad.offsets = PackedFloat32Array([0.0, 1.0])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill_from = Vector2(0.0, 0.0)
	tex.fill_to = Vector2(1.0, 0.0)
	tex.width = 256
	tex.height = 4

	var shade := TextureRect.new()
	shade.texture = tex
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	_add_full(shade)
	shade.anchor_right = shade_width
	shade.offset_right = 0.0


# --- Демо-партия ---

var _last_mode := -1


## Случайный режим, но не тот же самый два раза подряд.
func _pick_mode() -> int:
	var modes: Array[int] = []
	modes.assign(GameSession.DEMO_MODES)
	if modes.is_empty():
		modes.append(GameSession.MODE_KLONDIKE)
	if modes.size() > 1:
		modes.erase(_last_mode)
	_last_mode = modes.pick_random()
	return _last_mode


func _spawn_demo() -> void:
	var mode := _pick_mode()
	var scene := load(GameSession.LEVEL_SCENES[mode]) as PackedScene
	if scene == null:
		push_warning("MenuBackdrop: не удалось загрузить уровень для режима %d" % mode)
		return

	_level = scene.instantiate() as Node3D
	var gm := _find(_level, func(n): return n is GameManager) as GameManager

	# Случайные параметры партии. Ставим ДО add_child: GameManager стартует в _ready.
	# Выбор игрока (GameSession.draw_mode) на время запуска подменяем и сразу возвращаем.
	if gm != null:
		gm.spider_suits = [1, 2, 4].pick_random()
	var saved_draw := GameSession.draw_mode
	GameSession.draw_mode = [GameSession.DRAW_ONE, GameSession.DRAW_THREE].pick_random()
	_viewport.add_child(_level)
	GameSession.draw_mode = saved_draw

	var cm := _find(_level, func(n): return n is CardManager)
	var cam := _find(_level, func(n): return n is Camera3D) as Camera3D
	var mood := _find(_level, func(n): return n is MoodLighting) as MoodLighting

	# игрок в фоне ничего не двигает
	if cm != null:
		cm.process_mode = Node.PROCESS_MODE_DISABLED

	# свет настраиваем до сдвига камеры: лампа и фокус считаются от центра стола
	if mood != null:
		mood.ambient_energy *= ambient_boost
		mood.sun_energy *= sun_scale
		mood.apply()

	var board_center := Vector3.ZERO
	if cam != null:
		board_center = cam.get("target")
		cam.set("mouse_look_enabled", false)
		cam.set("zoom_max", maxf(float(cam.get("zoom_max")), menu_zoom))
		cam.set("start_zoom", menu_zoom)
		cam.set("_zoom", menu_zoom)            # сразу, без наезда камеры
		cam.set("_zoom_goal", menu_zoom)
		# сдвиг в долях ширины кадра: не зависит от масштаба
		var view_w := float(cam.get("fit_width")) * float(cam.get("margin")) * menu_zoom
		var look_point := board_center + Vector3(-board_offset * view_w, 0.0, board_shift_z)
		cam.set("target", look_point)
		cam.make_current()
		if mood == null:
			_setup_blur(cam)      # без MoodLighting размытие настраиваем сами

	if add_menu_lamp:
		_add_lamp(board_center)

	if gm != null:
		_bot = SolitaireBot.new()
		_bot.step_delay = step_delay
		_bot.max_steps = max_steps
		add_child(_bot)
		_bot.finished.connect(_on_demo_finished)
		_bot.start(gm)

	_container.modulate.a = 0.0
	create_tween().tween_property(_container, "modulate:a", 1.0, fade_time)


func _setup_blur(cam: Camera3D) -> void:
	if not blur_background:
		return
	var attrs := CameraAttributesPractical.new()
	attrs.dof_blur_far_enabled = true
	var dist := float(cam.call("_distance"))     # расстояние камеры до стола с учётом масштаба
	attrs.dof_blur_far_distance = dist + 0.35 * menu_zoom
	attrs.dof_blur_far_transition = 0.6 * menu_zoom
	attrs.dof_blur_amount = 0.05
	cam.attributes = attrs


func _add_lamp(center: Vector3) -> void:
	var lamp := SpotLight3D.new()
	lamp.light_color = lamp_color
	lamp.light_energy = lamp_energy
	lamp.spot_range = lamp_height * 3.0 + 1.0
	lamp.spot_angle = lamp_angle
	lamp.spot_angle_attenuation = 1.5      # мягкий край светового пятна
	lamp.shadow_enabled = true
	lamp.shadow_blur = 2.0
	_level.add_child(lamp)
	lamp.global_position = center + Vector3(0.0, lamp_height, 0.0)
	lamp.global_rotation_degrees = Vector3(-90.0, 0.0, 0.0)   # светит строго вниз

	if show_bulb:
		var sphere := SphereMesh.new()
		sphere.radius = 0.02
		sphere.height = 0.04
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = lamp_color
		mat.emission_enabled = true
		mat.emission = lamp_color
		mat.emission_energy_multiplier = 4.0
		sphere.material = mat
		var bulb := MeshInstance3D.new()
		bulb.mesh = sphere
		bulb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_level.add_child(bulb)
		bulb.global_position = lamp.global_position + Vector3(0.0, 0.02, 0.0)


# --- Смена партии (без await: всё на твинах, безопасно при смене сцены) ---

func _on_demo_finished() -> void:
	if _switching:
		return
	_switching = true
	var t := create_tween()
	t.tween_interval(end_pause)
	t.tween_property(_container, "modulate:a", 0.0, fade_time)
	t.tween_callback(_swap_demo)


func _swap_demo() -> void:
	if is_instance_valid(_bot):
		_bot.queue_free()
	if is_instance_valid(_level):
		_level.queue_free()
	# даём старому уровню удалиться, затем поднимаем новый
	var t := create_tween()
	t.tween_interval(0.1)
	t.tween_callback(func():
		_switching = false
		_spawn_demo())


func _find(node: Node, test: Callable) -> Node:
	if test.call(node):
		return node
	for c in node.get_children():
		var r := _find(c, test)
		if r != null:
			return r
	return null

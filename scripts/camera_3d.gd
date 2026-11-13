extends Camera3D

@export var target := Vector3.ZERO          # центр игрового поля на поверхности стола
@export_range(30.0, 90.0) var pitch_deg := 58.0   # угол к горизонту (90 = строго сверху)
@export_range(20.0, 70.0) var hfov_deg := 20.0
@export var fit_width := 0.9                # ширина стола (или игрового поля) в метрах
@export var margin := 1.08                  # запас по краям

@export_group("Zoom / Pan")
@export var controls_enabled := true
## Множитель дистанции: меньше 1 = ближе
@export_range(0.3, 1.0, 0.05) var zoom_min := 0.2
## Множитель дистанции: больше 1 = дальше
@export_range(1.0, 3.0, 0.05) var zoom_max := 1.8
@export_range(0.3, 3.0, 0.05) var start_zoom := 1.0
@export_range(0.02, 0.5, 0.01) var zoom_step := 0.1
@export_range(1.0, 20.0, 0.5) var zoom_smoothing := 8.0
## Перемещение камеры средней кнопкой мыши
@export var pan_enabled := true
## Максимальный сдвиг от центра стола (метры)
@export_range(0.0, 1.0, 0.01) var pan_limit := 0.35
@export_range(1.0, 20.0, 0.5) var pan_smoothing := 10.0

@export_group("Mouse Look")
@export var mouse_look_enabled := true
## Пассивный поворот у самого края экрана (градусы)
@export_range(0.0, 10.0, 0.1) var yaw_max_deg := 2.5
@export_range(0.0, 10.0, 0.1) var pitch_max_deg := 1.5
## Центральная часть экрана (0..1), в которой камера не реагирует на мышь
@export_range(0.0, 0.9, 0.05) var dead_zone := 0.45
@export_range(1.0, 20.0, 0.5) var look_smoothing := 5.0
## true = пассивный поворот работает только пока зажата левая кнопка мыши
@export var only_while_pressed := false

@export_group("Manual Orbit")
## Ручное вращение: ПК — правая кнопка, смартфон — жест двумя пальцами
@export var orbit_enabled := true
## Ограничение ручного вращения по горизонтали (чуть больше пассивного поворота)
@export_range(0.0, 20.0, 0.5) var orbit_yaw_limit_deg := 5.0
## Ограничение ручного наклона по вертикали
@export_range(0.0, 15.0, 0.5) var orbit_pitch_limit_deg := 3.0
## Чувствительность правой кнопки: градусов на пиксель
@export_range(0.01, 0.3, 0.01) var mouse_orbit_sensitivity := 0.08
## Чувствительность поворота двумя пальцами на смартфоне
@export_range(0.1, 2.0, 0.05) var touch_rotate_sensitivity := 1.0
## Вращение по горизонтали при перемещении двух пальцев (градусов на пиксель)
@export_range(0.0, 0.15, 0.005) var touch_yaw_drag_sensitivity := 0.04
## Наклон камеры при вертикальном перемещении двух пальцев (градусов на пиксель)
@export_range(0.0, 0.15, 0.005) var touch_pitch_sensitivity := 0.04
## Чувствительность двухпальцевого жеста трекпада (градусов на единицу delta)
@export_range(0.001, 0.1, 0.001) var trackpad_orbit_sensitivity := 0.02
@export_range(1.0, 20.0, 0.5) var orbit_smoothing := 10.0
@export var gestures_enabled := true

var _look := Vector2.ZERO
var _zoom := 1.0
var _zoom_goal := 1.0
var _pan := Vector3.ZERO
var _pan_cur := Vector3.ZERO
var _panning := false
var _rotating := false

# Ручной поворот в градусах: x = yaw, y = pitch.
var _orbit := Vector2.ZERO
var _orbit_goal := Vector2.ZERO
var _network_yaw_offset := 0.0

# Позиции пальцев для pinch + twist на мобильных устройствах.
var _touch_points: Dictionary = {}
var _touch_prev_distance := 0.0
var _touch_prev_angle := 0.0


func _ready() -> void:
	add_to_group("solitaire_camera")
	_zoom = start_zoom
	_zoom_goal = start_zoom
	_update_camera()


## Игрок 2 смотрит на стол с противоположной стороны.
## Поворот применяется как базовый yaw, поэтому обычные жесты и панорамирование
## продолжают работать относительно нового направления.
func set_network_slot(slot: int) -> void:
	_network_yaw_offset = 180.0 if slot == 2 else 0.0
	_look = Vector2.ZERO
	_orbit = Vector2.ZERO
	_orbit_goal = Vector2.ZERO
	_update_camera()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_panning = false
		_rotating = false
		_touch_points.clear()
		_reset_touch_reference()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		_zoom = start_zoom
		_pan_cur = Vector3.ZERO
		_orbit = Vector2.ZERO
		_update_camera()
		return

	GameSettings.ensure_loaded()

	var goal := Vector2.ZERO
	if mouse_look_enabled and GameSettings.mouse_look and not _panning and not _rotating \
			and (not only_while_pressed or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)):
		goal = _edge_input()

	_look = _look.lerp(goal, 1.0 - exp(-look_smoothing * delta))
	_zoom = lerpf(_zoom, _zoom_goal, 1.0 - exp(-zoom_smoothing * delta))
	_pan_cur = _pan_cur.lerp(_pan, 1.0 - exp(-pan_smoothing * delta))
	_orbit = _orbit.lerp(_orbit_goal, 1.0 - exp(-orbit_smoothing * delta))
	_update_camera()


# --- Управление ---

func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or not controls_enabled:
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		var f := mb.factor if mb.factor > 0.0 else 1.0
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_zoom_by(pow(1.0 - zoom_step, f))
					get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_zoom_by(pow(1.0 / (1.0 - zoom_step), f))
					get_viewport().set_input_as_handled()
			MOUSE_BUTTON_MIDDLE:
				_panning = mb.pressed and pan_enabled
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_RIGHT:
				_rotating = mb.pressed and orbit_enabled
				get_viewport().set_input_as_handled()

	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _panning:
			var rel := motion.relative
			var k := _distance() * 0.0012
			var right := global_transform.basis.x
			right.y = 0.0
			var fwd := -global_transform.basis.z
			fwd.y = 0.0
			_pan += (-right.normalized() * rel.x + fwd.normalized() * rel.y) * k
			_pan.x = clampf(_pan.x, -pan_limit, pan_limit)
			_pan.z = clampf(_pan.z, -pan_limit, pan_limit)
			get_viewport().set_input_as_handled()
		elif _rotating and orbit_enabled:
			_orbit_goal.x = _limit_orbit_yaw(
				_orbit_goal.x - motion.relative.x * mouse_orbit_sensitivity
			)
			_orbit_goal.y = clampf(
				_orbit_goal.y + motion.relative.y * mouse_orbit_sensitivity,
				-orbit_pitch_limit_deg,
				orbit_pitch_limit_deg
			)
			get_viewport().set_input_as_handled()

	elif event is InputEventMagnifyGesture and gestures_enabled:
		# Запасной путь для системного pinch-жеста (например, Android gesture events).
		# Если отслеживаются два сырых touch-события, масштаб уже обрабатывается ниже.
		if _touch_points.size() < 2:
			var magnify := event as InputEventMagnifyGesture
			_zoom_by(1.0 / maxf(magnify.factor, 0.01))
			get_viewport().set_input_as_handled()

	elif event is InputEventPanGesture and gestures_enabled and orbit_enabled:
		# Двухпальцевое движение на тачпаде: влево/вправо — yaw, вверх/вниз — pitch.
		# Не дублируем жест, если уже обрабатываем два отдельных касания экрана.
		if _touch_points.size() < 2:
			var pan_gesture := event as InputEventPanGesture
			_orbit_goal.x = _limit_orbit_yaw(
				_orbit_goal.x - pan_gesture.delta.x * trackpad_orbit_sensitivity
			)	
			_orbit_goal.y = clampf(
				_orbit_goal.y + pan_gesture.delta.y * trackpad_orbit_sensitivity,
				-orbit_pitch_limit_deg,
				orbit_pitch_limit_deg
			)
			get_viewport().set_input_as_handled()

	elif event is InputEventScreenTouch and gestures_enabled:
		_handle_screen_touch(event as InputEventScreenTouch)

	elif event is InputEventScreenDrag and gestures_enabled:
		_handle_screen_drag(event as InputEventScreenDrag)

	elif event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_HOME:
			reset_view()
			get_viewport().set_input_as_handled()


func _handle_screen_touch(event: InputEventScreenTouch) -> void:
	var was_two_finger := _touch_points.size() >= 2
	if event.pressed and not event.canceled:
		_touch_points[event.index] = event.position
	else:
		_touch_points.erase(event.index)

	_reset_touch_reference()
	# Обычное касание одним пальцем не перехватываем — оно может использоваться
	# существующим управлением картами/перемещением камеры.
	if was_two_finger or _touch_points.size() >= 2:
		get_viewport().set_input_as_handled()


func _handle_screen_drag(event: InputEventScreenDrag) -> void:
	if not _touch_points.has(event.index):
		return

	_touch_points[event.index] = event.position
	if _touch_points.size() == 2:
		_update_two_finger_gesture(event.screen_relative)
		get_viewport().set_input_as_handled()
	else:
		_reset_touch_reference()


func _reset_touch_reference() -> void:
	if _touch_points.size() != 2:
		_touch_prev_distance = 0.0
		_touch_prev_angle = 0.0
		return

	var ids := _touch_points.keys()
	var a: Vector2 = _touch_points[ids[0]]
	var b: Vector2 = _touch_points[ids[1]]
	var diff := b - a
	_touch_prev_distance = diff.length()
	_touch_prev_angle = diff.angle()


func _update_two_finger_gesture(screen_relative: Vector2) -> void:
	var ids := _touch_points.keys()
	var a: Vector2 = _touch_points[ids[0]]
	var b: Vector2 = _touch_points[ids[1]]
	var diff := b - a
	var distance := diff.length()
	if distance < 8.0:
		return

	var angle := diff.angle()
	if _touch_prev_distance > 0.0:
		# Раздвигаем пальцы — приближаем камеру; сводим — отдаляем.
		_zoom_by(_touch_prev_distance / distance)

		if orbit_enabled:
			# Поворот линии между пальцами вращает камеру вокруг стола (yaw).
			var angle_delta := wrapf(angle - _touch_prev_angle, -PI, PI)
			_orbit_goal.x = _limit_orbit_yaw(
				_orbit_goal.x - rad_to_deg(angle_delta) * touch_rotate_sensitivity
			)

			# Движение двух пальцев влево/вправо вращает камеру вокруг стола.
			_orbit_goal.x = clampf(
				_orbit_goal.x - screen_relative.x * 0.5 * touch_yaw_drag_sensitivity,
				-orbit_yaw_limit_deg,
				orbit_yaw_limit_deg
			)

			# Одновременное движение двух пальцев вверх/вниз меняет наклон.
			_orbit_goal.y = clampf(
				_orbit_goal.y + screen_relative.y * 0.5 * touch_pitch_sensitivity,
				-orbit_pitch_limit_deg,
				orbit_pitch_limit_deg
			)

	_touch_prev_distance = distance
	_touch_prev_angle = angle


func _zoom_by(mult: float) -> void:
	_zoom_goal = clampf(_zoom_goal * mult, zoom_min, zoom_max)


## Вернуть масштаб, сдвиг и ручной поворот в исходное положение.
func reset_view() -> void:
	_zoom_goal = start_zoom
	_pan = Vector3.ZERO
	_orbit_goal = Vector2.ZERO


func set_zoom(value: float) -> void:
	_zoom_goal = clampf(value, zoom_min, zoom_max)


# --- Расчёт ---

func _distance() -> float:
	return (fit_width * 0.5 * margin) / tan(deg_to_rad(hfov_deg) * 0.5) * _zoom


## Положение курсора относительно краёв: (0,0) в центре и в мёртвой зоне, ±1 у края.
func _edge_input() -> Vector2:
	var vp := get_viewport()
	var vp_size := vp.get_visible_rect().size
	if vp_size.x <= 0.0 or vp_size.y <= 0.0:
		return Vector2.ZERO
	var n := (vp.get_mouse_position() / vp_size) * 2.0 - Vector2.ONE
	n = n.clamp(-Vector2.ONE, Vector2.ONE)
	return Vector2(_edge(n.x), _edge(n.y))


func _edge(v: float) -> float:
	var a := (absf(v) - dead_zone) / maxf(1.0 - dead_zone, 0.001)
	return -signf(v) * smoothstep(0.0, 1.0, clampf(a, 0.0, 1.0))

func _limit_orbit_yaw(value: float) -> float:
	var layout_id := GameSession.get_board_layout(GameSession.mode)

	if layout_id == GameSession.BOARD_LAYOUT_CLASSIC:
		return clampf(
			value,
			-orbit_yaw_limit_deg,
			orbit_yaw_limit_deg
		)

	# В Mirror и Ring горизонтальное вращение не ограничено.
	return value
	
func _update_camera() -> void:
	keep_aspect = Camera3D.KEEP_WIDTH
	projection = Camera3D.PROJECTION_PERSPECTIVE
	fov = hfov_deg
	var look_point := target + _pan_cur

	var p := deg_to_rad(clampf(
		pitch_deg - _look.y * pitch_max_deg + _orbit.y,
		10.0,
		89.0
	))
	var offset := Vector3(0.0, sin(p), cos(p)) * _distance()
	var yaw := _network_yaw_offset + _look.x * yaw_max_deg + _orbit.x
	offset = offset.rotated(Vector3.UP, deg_to_rad(yaw))

	global_position = look_point + offset
	look_at(look_point, Vector3.UP)

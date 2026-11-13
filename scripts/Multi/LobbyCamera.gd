extends Camera3D
class_name LobbyCamera
## Фиксированная камера сетевого лобби.
## Использует ту же геометрию расчёта, что и игровая Camera3D,
## но без управления мышью/касаниями и без зависимости от GameSession.

@export_group("Кадр")
@export var target := Vector3.ZERO
@export_range(30.0, 90.0, 1.0) var pitch_deg := 58.0
@export_range(20.0, 70.0, 1.0) var hfov_deg := 20.0
@export var fit_width := 0.9
@export var margin := 1.08
@export_range(0.3, 3.0, 0.05) var camera_zoom := 1.35

@export_group("Небольшое движение камеры")
@export var idle_motion := true
@export_range(0.0, 3.0, 0.1) var yaw_sway_deg := 0.55
@export_range(0.0, 2.0, 0.1) var pitch_sway_deg := 0.25
@export_range(0.01, 1.0, 0.01) var sway_speed := 0.12

var _elapsed := 0.0

func _ready() -> void:
	projection = Camera3D.PROJECTION_PERSPECTIVE
	keep_aspect = Camera3D.KEEP_WIDTH
	fov = hfov_deg
	make_current()
	_update_camera()

func _process(delta: float) -> void:
	_elapsed += delta
	_update_camera()

func _distance() -> float:
	var safe_fov := clampf(hfov_deg, 1.0, 90.0)
	return (fit_width * 0.5 * margin * camera_zoom) / tan(deg_to_rad(safe_fov) * 0.5)

func _update_camera() -> void:
	var yaw := 0.0
	var pitch := pitch_deg
	if idle_motion:
		yaw = sin(_elapsed * sway_speed) * yaw_sway_deg
		pitch += sin(_elapsed * sway_speed * 0.73) * pitch_sway_deg
	var p := deg_to_rad(clampf(pitch, 10.0, 89.0))
	var offset := Vector3(0.0, sin(p), cos(p)) * _distance()
	offset = offset.rotated(Vector3.UP, deg_to_rad(yaw))
	global_position = target + offset
	look_at(target, Vector3.UP)

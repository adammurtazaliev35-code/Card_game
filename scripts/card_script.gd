extends Area3D
class_name Card

enum Suit {
	SPADES = 1,    # Пики
	HEARTS = 2,    # Червы
	DIAMONDS = 3,  # Бубны
	CLUBS = 4      # Трефы
}
@onready var visual: Marker3D = $Visual
@onready var face_mesh: MeshInstance3D = $Visual/Plane
@export_range(0.0, 60.0, 0.5) var follow_smoothing: float = 0.0
@export var return_duration: float = .2
@export var object_color: Color = Color.WHITE
@export_range(1, 13, 1) var rank: int = 1

# Масть карты. Значения должны совпадать с PileMarker.Suit.
@export_enum("Пики:1", "Червы:2", "Бубны:3", "Трефы:4")
var suit: int = Suit.SPADES

var is_holding: bool = false
var face_up: bool = true
var pile: Variant = null
var _face_home_transform: Transform3D
var _drag_offset: Vector3 = Vector3.ZERO
var _flight_height: float
var _return_tween: Tween = null
var _visual_home: Transform3D
var _rest_basis: Basis = Basis.IDENTITY
var _visual_scale: float = 1.0

## Звук движения карты играет, если карта сдвигается дальше этого расстояния (метры)
const SOUND_MIN_DISTANCE := 0.012
var _last_move_target := Vector3.INF


func _ready() -> void:
	_visual_home = visual.transform
	_visual_scale = _visual_home.basis.get_scale().x
	_rest_basis = transform.basis.orthonormalized()

	_face_home_transform = face_mesh.transform

	update_card_appearance()

# --- Данные карты ---
## Устанавливает ориентацию карты относительно игровой стопки.
func set_board_basis(board_basis: Basis) -> void:
	global_basis = board_basis.orthonormalized() * _rest_basis
	
func is_red() -> bool:
	return suit == Suit.HEARTS or suit == Suit.DIAMONDS


func is_top_card() -> bool:
	return pile != null and not pile.cards.is_empty() and pile.cards.back() == self


func update_card_appearance() -> void:
	if face_mesh == null:
		return

	face_mesh.set_instance_shader_parameter("rank_id", float(rank))
	face_mesh.set_instance_shader_parameter("suit_id", float(suit))

	# Сначала возвращаем исходное положение.
	face_mesh.transform = _face_home_transform

	# Закрытая карта поворачивается рубашкой вверх.
	if not face_up:
		face_mesh.rotate_object_local(Vector3.FORWARD, PI)
		
func set_face_up(value: bool) -> void:
	face_up = value
	update_card_appearance()

# --- Перетаскивание (вызывает CardManager) ---

func pick_up(hit_point: Vector3, flight_height: float) -> void:
	if _return_tween and _return_tween.is_valid():
		_return_tween.kill()
	_return_tween = null

	is_holding = true
	_last_move_target = Vector3.INF
	_flight_height = flight_height
	_drag_offset = Vector3(
		hit_point.x - global_position.x,
		0.0,
		hit_point.z - global_position.z
	)


## Ведущая карта: следует за курсором на плоскости полёта.
func drag_to(plane_point: Vector3, delta: float = 0.0) -> void:
	if not is_holding:
		return
	var target := Vector3(
		plane_point.x - _drag_offset.x,
		_flight_height,
		plane_point.z - _drag_offset.z
	)
	_move_towards(target, delta)
	_face_camera()


## Остальные карты группы: тянутся за ведущей.
func follow_to(target: Vector3, delta: float = 0.0) -> void:
	if not is_holding:
		return
	_move_towards(target, delta)
	_face_camera()


func drop() -> void:
	if not is_holding:
		return
	is_holding = false
	visual.transform = _visual_home


func move_to(target: Vector3, duration: float = -1.0) -> Tween:
	if _return_tween and _return_tween.is_valid():
		_return_tween.kill()
	_play_move_sound(target)
	var move_duration := return_duration if duration < 0.0 else duration
	_return_tween = create_tween()
	_return_tween.tween_property(
		self,
		"global_position",
		target,
		move_duration
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	return _return_tween

## Звук движения: один раз на каждое новое перемещение карты.
## Повторные relayout() с той же целью и мелкие подвижки каскада тихие.
func _play_move_sound(target: Vector3) -> void:
	var same_target := target.is_equal_approx(_last_move_target)
	_last_move_target = target
	if same_target or not is_inside_tree() or not is_visible_in_tree():
		return
	if global_position.distance_to(target) < SOUND_MIN_DISTANCE:
		return
	GameAudio.card(get_tree())


# --- Внутреннее ---

func _move_towards(target: Vector3, delta: float) -> void:
	if follow_smoothing > 0.0 and delta > 0.0:
		var t := 1.0 - exp(-follow_smoothing * delta)
		global_position = global_position.lerp(target, t)
	else:
		global_position = target


## Разворачивает карту лицом к камере так, чтобы верх карты смотрел вверх на экране.
## Лёжа на столе карта смотрит нормалью в +Y, а верхним краем в -Z.
## Берём оси камеры: нормаль карты = +Z камеры (к зрителю),
## верх карты (-Z карты) = +Y камеры, право = +X камеры.
func _face_camera() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var b := cam.global_transform.basis
	visual.global_basis = Basis(b.x, b.z, -b.y) * _visual_scale

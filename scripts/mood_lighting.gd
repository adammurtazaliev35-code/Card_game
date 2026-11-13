@tool
extends Node
class_name MoodLighting
## Настроение сцены как на референсе: тёплый свет из окна, мягкие тени, золотистая дымка,
## зелёный отсвет от штор, лампа над столом, размытый задний план и лёгкая виньетка.
##
## Как подключить: добавьте пустой Node в уровень (например level_base.tscn), назовите Mood,
## повесьте этот скрипт. Дальше всё меняется в инспекторе и сразу видно во вьюпорте.
## Скрипт использует уже существующие в сцене DirectionalLight3D, WorldEnvironment
## и Camera3D. Если их нет, создаёт свои.
##
## Рендерер проекта: Forward Mobile. SSAO, SSIL и объёмный туман в нём не работают,
## они включатся автоматически только если вы переключитесь на Forward+.

@export_group("Солнце из окна")
@export var sun_color := Color("ffd9a3")
@export_range(0.0, 6.0, 0.05) var sun_energy := 1.7
## Поворот света в градусах. Подберите так, чтобы пятно света из окна падало на стол.
@export var sun_rotation_deg := Vector3(-34.0, 158.0, 0.0)
## Мягкость края теней
@export_range(0.0, 8.0, 0.1) var sun_shadow_blur := 2.0
@export_range(0.0, 6.0, 0.1) var sun_angular_distance := 1.2

@export_group("Заполняющий свет (отсвет от штор)")
@export var fill_color := Color("7f9c86")
@export_range(0.0, 2.0, 0.05) var fill_energy := 0.25
@export var fill_rotation_deg := Vector3(-30.0, 0.0, 0.0)

@export_group("Лампа над столом")
@export var lamp_enabled := true
@export var lamp_color := Color("ffb86b")
@export_range(0.0, 16.0, 0.1) var lamp_energy := 2.0
@export var lamp_height := 0.55
@export_range(10.0, 89.0, 1.0) var lamp_angle := 62.0
## Сдвиг лампы относительно центра стола (метры)
@export var lamp_offset := Vector3(-0.2, 0.0, -0.1)

@export_group("Окружение")
@export var background_color := Color("1a0f09")
@export var ambient_color := Color("b27a4d")
@export_range(0.0, 2.0, 0.05) var ambient_energy := 0.55
## Золотистая дымка в воздухе
@export var fog_color := Color("e8b878")
@export_range(0.0, 0.1, 0.001) var fog_density := 0.012
@export_range(0.0, 1.0, 0.05) var fog_sun_scatter := 0.25

@export_group("Цвет и свечение")
@export_range(0.2, 3.0, 0.05) var exposure := 1.05
@export_range(0.5, 1.5, 0.01) var contrast := 1.1
@export_range(0.5, 1.5, 0.01) var saturation := 1.1
@export_range(0.0, 2.0, 0.05) var glow_intensity := 0.7
@export_range(0.0, 1.0, 0.01) var glow_bloom := 0.08
@export_range(0.0, 4.0, 0.05) var glow_threshold := 0.9

@export_group("Размытие и виньетка")
## Размывает дальний план (комнату), стол остаётся в фокусе
@export var dof_enabled := true
## На сколько метров позади точки фокуса начинается размытие
@export_range(0.0, 3.0, 0.05) var dof_far_offset := 0.5
@export_range(0.1, 3.0, 0.05) var dof_far_transition := 0.9
@export_range(0.0, 0.5, 0.01) var dof_amount := 0.08
## Если у камеры нет свойства target, фокус на этой точке
@export var focus_point := Vector3.ZERO
## Затемнение по краям кадра (только в игре)
@export_range(0.0, 1.0, 0.05) var vignette_strength := 0.55
@export var vignette_color := Color(0.07, 0.035, 0.02)

@export_group("Качество мягкости")
@export var msaa_4x := true
@export var soft_shadows_high := true

const META := "mood_created"

var _sig := ""
var _vignette: CanvasLayer
var _cam: Camera3D


func _ready() -> void:
	apply()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		# живое обновление в редакторе при изменении любого параметра
		var sig := ""
		for p in get_property_list():
			if (p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE) and (p.usage & PROPERTY_USAGE_EDITOR):
				sig += str(get(p.name)) + "|"
		if sig != _sig:
			_sig = sig
			apply()
	else:
		_update_dof()


func apply() -> void:
	var root := _scene_root()
	_apply_environment(root)
	_apply_sun(root)
	_apply_fill()
	_apply_lamp()
	_update_dof()
	_apply_vignette()
	_apply_quality()


# --- Окружение ---

func _apply_environment(root: Node) -> void:
	var we := _find(root, func(n): return n is WorldEnvironment) as WorldEnvironment
	if we == null:
		we = WorldEnvironment.new()
		we.name = "MoodEnvironment"
		we.set_meta(META, true)
		add_child(we)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = background_color
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = ambient_color
	env.ambient_light_energy = ambient_energy

	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = exposure
	env.tonemap_white = 5.0

	env.adjustment_enabled = true
	env.adjustment_contrast = contrast
	env.adjustment_saturation = saturation

	env.glow_enabled = true
	env.glow_intensity = glow_intensity
	env.glow_bloom = glow_bloom
	env.glow_hdr_threshold = glow_threshold
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT

	env.fog_enabled = fog_density > 0.0
	env.fog_light_color = fog_color
	env.fog_density = fog_density
	env.fog_sun_scatter = fog_sun_scatter

	# эффекты только для Forward+
	if RenderingServer.get_current_rendering_method() == "forward_plus":
		env.ssao_enabled = true
		env.ssao_radius = 0.25
		env.ssao_intensity = 1.6
		env.ssil_enabled = true
		env.volumetric_fog_enabled = true
		env.volumetric_fog_density = 0.012
		env.volumetric_fog_albedo = fog_color
		env.volumetric_fog_length = 8.0

	we.environment = env


# --- Свет ---

func _apply_sun(root: Node) -> void:
	var sun := _find(root, func(n): return n is DirectionalLight3D and not n.has_meta(META)) as DirectionalLight3D
	if sun == null:
		sun = DirectionalLight3D.new()
		sun.name = "MoodSun"
		sun.set_meta(META, true)
		add_child(sun)
	sun.light_color = sun_color
	sun.light_energy = sun_energy
	sun.rotation_degrees = sun_rotation_deg
	sun.shadow_enabled = true
	sun.shadow_blur = sun_shadow_blur
	sun.light_angular_distance = sun_angular_distance
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 8.0
	sun.shadow_bias = 0.03
	sun.shadow_normal_bias = 1.5


func _apply_fill() -> void:
	var fill := get_node_or_null("MoodFill") as DirectionalLight3D
	if fill == null:
		fill = DirectionalLight3D.new()
		fill.name = "MoodFill"
		fill.set_meta(META, true)
		add_child(fill)
	fill.light_color = fill_color
	fill.light_energy = fill_energy
	fill.rotation_degrees = fill_rotation_deg
	fill.shadow_enabled = false
	fill.light_specular = 0.0       # только мягкая подсветка теней, без бликов
	fill.visible = fill_energy > 0.0


func _apply_lamp() -> void:
	var lamp := get_node_or_null("MoodLamp") as SpotLight3D
	if not lamp_enabled:
		if lamp != null:
			lamp.visible = false
		return
	if lamp == null:
		lamp = SpotLight3D.new()
		lamp.name = "MoodLamp"
		lamp.set_meta(META, true)
		add_child(lamp)
	lamp.visible = true
	lamp.light_color = lamp_color
	lamp.light_energy = lamp_energy
	lamp.spot_range = lamp_height * 3.0 + 1.0
	lamp.spot_angle = lamp_angle
	lamp.spot_angle_attenuation = 1.5      # мягкий край пятна
	lamp.shadow_enabled = true
	lamp.shadow_blur = 2.0
	lamp.position = _focus() + lamp_offset + Vector3(0.0, lamp_height, 0.0)
	lamp.rotation_degrees = Vector3(-90.0, 0.0, 0.0)    # светит вниз


# --- Размытие дальнего плана ---

func _update_dof() -> void:
	var cam := _get_camera()
	if cam == null:
		return
	# в редакторе размытие не включаем, чтобы не мешало править сцену
	if not dof_enabled or Engine.is_editor_hint():
		if cam.attributes is CameraAttributesPractical:
			(cam.attributes as CameraAttributesPractical).dof_blur_far_enabled = false
		return

	var attrs := cam.attributes as CameraAttributesPractical
	if attrs == null:
		attrs = CameraAttributesPractical.new()
		cam.attributes = attrs
	var dist := cam.global_position.distance_to(_focus())
	attrs.dof_blur_far_enabled = true
	attrs.dof_blur_far_distance = dist + dof_far_offset
	attrs.dof_blur_far_transition = dof_far_transition
	attrs.dof_blur_amount = dof_amount


# --- Виньетка и качество ---

func _apply_vignette() -> void:
	if Engine.is_editor_hint():
		return
	if _vignette != null and is_instance_valid(_vignette):
		_vignette.queue_free()
		_vignette = null
	if vignette_strength <= 0.0:
		return

	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	grad.colors = PackedColorArray([
		Color(vignette_color, 0.0),
		Color(vignette_color, 0.0),
		Color(vignette_color, vignette_strength)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 512
	tex.height = 512

	_vignette = CanvasLayer.new()
	_vignette.layer = 1
	var rect := TextureRect.new()
	rect.texture = tex
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	_vignette.add_child(rect)
	add_child(_vignette)
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _apply_quality() -> void:
	if Engine.is_editor_hint():
		return
	if soft_shadows_high:
		RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_HIGH)
		RenderingServer.positional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_HIGH)
	if msaa_4x:
		get_viewport().msaa_3d = Viewport.MSAA_4X


# --- Вспомогательное ---

func _scene_root() -> Node:
	if owner != null:
		return owner
	if get_parent() != null:
		return get_parent()
	return get_tree().current_scene


func _get_camera() -> Camera3D:
	if _cam == null or not is_instance_valid(_cam):
		_cam = _find(_scene_root(), func(n): return n is Camera3D) as Camera3D
	return _cam


## Точка, на которую смотрит камера (target у нашего camera_3d.gd), иначе focus_point.
func _focus() -> Vector3:
	var cam := _get_camera()
	if cam != null:
		var t = cam.get("target")
		if t is Vector3:
			return t
	return focus_point


func _find(node: Node, test: Callable) -> Node:
	if node == null:
		return null
	if test.call(node):
		return node
	for c in node.get_children():
		var r := _find(c, test)
		if r != null:
			return r
	return null

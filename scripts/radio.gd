extends Node3D
class_name Radio
## «Радио» на столе: переключение треков и экран с названием и спектром.
##
## Как подключить (по аналогии со screen_tabl):
##  1. Поставьте 3D-модель радио в сцену и повесьте этот скрипт на её корень.
##  2. Внутри модели должны быть два Area3D с коллизией: btn_next и btn_prev
##     (имена именно такие; глубина вложенности любая).
##  3. В инспекторе укажите screen_model — меш (или узел с мешем) маленького экрана
##     и screen_surface_index — поверхность, на которую выводится картинка.
## Общий менеджер музыки (GameAudio) подхватывает радио сам: переключение с модели
## и из настроек — одно и то же, экран обновляется в обоих случаях.

@export_group("Экран")
@export var screen_model: Node3D
@export_range(0, 10, 1) var screen_surface_index := 0
@export var screen_resolution := Vector2i(512, 192)
@export_range(0.1, 3.0, 0.1) var emission_energy := 1.4
## Повернуть изображение, если на модели экран развёрнут (0, 90, 180, 270)
@export_enum("0:0", "90:90", "180:180", "270:270") var screen_rotation := 0

@export_group("Вид")
@export var bar_color := Color("#86E8CF")
@export var peak_color := Color("#F2C35B")
@export var background_color := Color("#0D141D")
@export var text_color := Color("#EFE8D8")
@export_range(8, 48, 1) var bars := 24
@export_range(5.0, 60.0, 1.0) var refresh_hz := 30.0

const BUTTON_LAYER := 1 << 18

var _viewport: SubViewport
var _title: Label
var _counter: Label
var _bars_control: Control
var _levels := PackedFloat32Array()
var _peaks := PackedFloat32Array()
var _btn_next: Area3D
var _btn_prev: Area3D
var _accum := 0.0
var _marquee_offset := 0.0


func _ready() -> void:
	add_to_group("radio")
	_levels.resize(bars)
	_peaks.resize(bars)
	_build_screen()
	_apply_screen_material()
	_btn_next = _find_area(self, "btn_next")
	_btn_prev = _find_area(self, "btn_prev")
	for area in [_btn_next, _btn_prev]:
		if area == null:
			continue
		# Отдельный слой: карты и стопки эти кнопки не задевают.
		area.collision_layer |= BUTTON_LAYER
	if _btn_next == null or _btn_prev == null:
		push_warning("Radio: не найдены Area3D btn_next / btn_prev в модели.")

	var audio := GameAudio.get_instance(get_tree())
	audio.track_changed.connect(_on_track_changed)
	if audio.is_node_ready():
		_update_title()
	else:
		audio.ready.connect(_update_title, CONNECT_ONE_SHOT)


func _process(delta: float) -> void:
	_accum += delta
	_marquee_offset += delta * 40.0
	if _accum < 1.0 / refresh_hz:
		return
	var step := _accum
	_accum = 0.0
	var audio := GameAudio.get_instance(get_tree())
	if not audio.is_node_ready():
		return
	var spectrum := audio.get_spectrum(bars)
	for i in bars:
		# Плавный спад столбиков и «пики», как у настоящего эквалайзера.
		_levels[i] = maxf(spectrum[i], _levels[i] - step * 2.5)
		_peaks[i] = maxf(_levels[i], _peaks[i] - step * 0.6)
	_bars_control.queue_redraw()
	_scroll_title()


# --- Кнопки на модели ---

func _unhandled_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var origin := camera.project_ray_origin(mb.position)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + camera.project_ray_normal(mb.position) * 100.0, BUTTON_LAYER)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var collider: Object = hit.get("collider")
	if collider == null:
		return
	var audio := GameAudio.get_instance(get_tree())
	if collider == _btn_next:
		audio.next_track()
		_press_animation(_btn_next)
		get_viewport().set_input_as_handled()
	elif collider == _btn_prev:
		audio.prev_track()
		_press_animation(_btn_prev)
		get_viewport().set_input_as_handled()


func _press_animation(area: Area3D) -> void:
	var home := area.position
	var tween := create_tween()
	tween.tween_property(area, "position", home - area.basis.y * 0.003, 0.06)
	tween.tween_property(area, "position", home, 0.10)


func _find_area(root: Node, target: String) -> Area3D:
	if root is Area3D and str(root.name).to_lower() == target:
		return root as Area3D
	for child in root.get_children():
		var found := _find_area(child, target)
		if found != null:
			return found
	return null


# --- Экран ---

func _build_screen() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "RadioViewport"
	_viewport.size = screen_resolution
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)

	var root := ColorRect.new()
	root.color = background_color
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_viewport.add_child(root)

	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 12
	box.offset_right = -12
	box.offset_top = 8
	box.offset_bottom = -8
	root.add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	var clip := Control.new()
	clip.clip_contents = true
	clip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clip.custom_minimum_size = Vector2(0, screen_resolution.y * 0.22)
	header.add_child(clip)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", int(screen_resolution.y * 0.16))
	_title.add_theme_color_override("font_color", text_color)
	clip.add_child(_title)
	_counter = Label.new()
	_counter.add_theme_font_size_override("font_size", int(screen_resolution.y * 0.12))
	_counter.add_theme_color_override("font_color", peak_color)
	header.add_child(_counter)

	_bars_control = Control.new()
	_bars_control.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_bars_control.draw.connect(_draw_bars)
	box.add_child(_bars_control)

	var font_path := "res://fonts/Nunito-Black.ttf"
	if ResourceLoader.exists(font_path):
		var theme := Theme.new()
		theme.default_font = load(font_path)
		root.theme = theme


func _draw_bars() -> void:
	var rect_size := _bars_control.size
	if rect_size.x <= 0.0 or bars <= 0:
		return
	var gap := 3.0
	var w := (rect_size.x - gap * (bars - 1)) / bars
	for i in bars:
		var x := i * (w + gap)
		var h := maxf(2.0, _levels[i] * rect_size.y)
		_bars_control.draw_rect(Rect2(x, rect_size.y - h, w, h), bar_color.lerp(peak_color, _levels[i] * 0.6))
		var peak_y := rect_size.y - _peaks[i] * rect_size.y
		_bars_control.draw_rect(Rect2(x, clampf(peak_y - 3.0, 0.0, rect_size.y - 3.0), w, 3.0), peak_color)


func _on_track_changed(_name: String, _index: int, _count: int) -> void:
	_update_title()


func _update_title() -> void:
	var audio := GameAudio.get_instance(get_tree())
	_title.text = audio.get_track_name()
	var count := audio.get_track_count()
	_counter.text = "%d/%d" % [audio.get_track_index() + 1, count] if count > 0 else ""
	_marquee_offset = 0.0
	_title.position.x = 0.0


## Длинное название бежит строкой, короткое стоит на месте.
func _scroll_title() -> void:
	var clip := _title.get_parent() as Control
	var overflow := _title.get_minimum_size().x - clip.size.x
	if overflow <= 0.0:
		_title.position.x = 0.0
		return
	var span := overflow + 60.0
	_title.position.x = -fposmod(_marquee_offset, span * 2.0)
	if -_title.position.x > span:
		_title.position.x = -(span * 2.0 + _title.position.x)


func _apply_screen_material() -> void:
	if screen_model == null:
		push_warning("Radio: не назначен screen_model — экран не будет показан.")
		return
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D screen_texture : source_color, filter_linear;
uniform float emission_energy = 1.4;
uniform int rotation_deg = 0;
void fragment() {
	vec2 uv = UV;
	if (rotation_deg == 90) uv = vec2(uv.y, 1.0 - uv.x);
	else if (rotation_deg == 180) uv = vec2(1.0 - uv.x, 1.0 - uv.y);
	else if (rotation_deg == 270) uv = vec2(1.0 - uv.y, uv.x);
	vec3 c = texture(screen_texture, uv).rgb;
	ALBEDO = c;
	EMISSION = c * emission_energy;
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("screen_texture", _viewport.get_texture())
	material.set_shader_parameter("emission_energy", emission_energy)
	material.set_shader_parameter("rotation_deg", screen_rotation)
	var applied := _apply_to_meshes(screen_model, material)
	if applied == 0:
		push_warning("Radio: у screen_model нет поверхности %d." % screen_surface_index)


func _apply_to_meshes(node: Node, material: Material) -> int:
	var applied := 0
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null and screen_surface_index < mi.mesh.get_surface_count():
			mi.set_surface_override_material(screen_surface_index, material)
			applied += 1
	for child in node.get_children():
		applied += _apply_to_meshes(child, material)
	return applied

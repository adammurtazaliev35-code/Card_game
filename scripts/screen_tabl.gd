extends Node3D
class_name Screens
signal lobby_create_requested(
	mode: int,
	board_layout: int,
	draw_mode: int,
	spider_suits: int
)

signal network_undo_requested(player_slot: int)

var network_session_active := false
var network_opponent_connected := false
var local_player_slot := 1
# ==================================================
# CONFIGURATION
# ==================================================
enum DisplayMode {
	CLASSIC,
	MIRRORED,
	MULTIPLAYER,
	RING
}

const SCREEN_SHADER = preload("res://shaders/multiplayer_screen.gdshader")
const STARTING_SCORE := 50
const FOUNDATION_CARDS := 13
const FOUNDATION_COUNT := 4
const SUIT_SYMBOLS := ["♠", "♥", "♦", "♣"]
const FOUNDATION_RANKS := [
	"A", "2", "3", "4", "5", "6", "7",
	"8", "9", "10", "J", "Q", "K"
]

@export_group("Положение табло — классика")
@export var screen_rig: Node3D
@export var classic_position := Vector3.ZERO
@export var classic_rotation_degrees := Vector3.ZERO

@export_group("Свечение кнопок")
@export var button_glow_color := Color("#86E8CF")
@export_range(0.0, 5.0, 0.1) var button_glow_energy := 1.5
@export var button_glow_uses_texture := true

@export_group("Очки")
@export_range(3.0, 5.0, 1.0) var score_loss_interval := 4.0

@export_group("Модель экрана")
@export var screen_model: Node3D
@export_range(0, 10, 1) var screen_surface_index := 1
@export_range(0.1, 3.0, 0.1) var emission_energy := 1.3
@export var rotate_clockwise := true

@export_group("Viewport")
@export var viewport_resolution := Vector2i(1024, 512)

@export_group("GameManager")
@export var game_manager_path: NodePath
var default_screen_position := Vector3.ZERO
var default_screen_rotation := Vector3.ZERO
var screen_default_saved := false

var game_manager: GameManager
var undo_button_p1: Area3D
var undo_button_p2: Area3D
var screen_viewport: SubViewport
var screen_material: ShaderMaterial
var screen_refresh_queued := false

var ui_scale := 1.0
var classic_ui_root: Control
var ring_ui: Dictionary = {}
var ring_tableau_slots: Array[Dictionary] = []
var player_one_ui: Dictionary = {}
var player_two_ui: Dictionary = {}
var display_mode: DisplayMode = DisplayMode.CLASSIC

var player_one_stock: Pile = null
var player_two_stock: Pile = null
var current_score_p1 := STARTING_SCORE
var elapsed_time := 0.0
var timer_running := false
var last_displayed_second := -1


func _ready() -> void:
	add_to_group("screens")
	if is_instance_valid(screen_rig):
		default_screen_position = screen_rig.position
		default_screen_rotation = screen_rig.rotation_degrees
		screen_default_saved = true

	_setup_viewport()
	_setup_screen_material()
	_setup_screen_touch()
	_setup_undo_buttons()
	for ui in [player_one_ui, player_two_ui]:
		var deadend: Dictionary = ui["deadend"]
		(deadend["surrender"] as Button).pressed.connect(_on_deadend_surrender.bind(ui))
		(deadend["reshuffle"] as Button).pressed.connect(_on_deadend_reshuffle.bind(ui))
	call_deferred("_connect_game_manager")


func _process(delta: float) -> void:
	if not timer_running:
		return

	if game_manager == null or game_manager.game_finished:
		timer_running = false
		return

	elapsed_time += delta
	var current_second := floori(elapsed_time)

	if current_second != last_displayed_second:
		last_displayed_second = current_second
		_update_time_label()

func set_network_session_state(
	active: bool,
	opponent_connected: bool,
	player_slot: int = 1
) -> void:
	network_session_active = active
	network_opponent_connected = opponent_connected
	local_player_slot = clampi(player_slot, 1, 2)

	_refresh_undo_buttons()
	_queue_screen_refresh()


func request_create_lobby() -> void:
	if game_manager == null:
		push_warning("Screens: нельзя создать лобби — GameManager не найден.")
		return

	if network_session_active:
		push_warning("Screens: сетевая сессия уже активна.")
		return

	var layout := GameSession.get_board_layout(game_manager.current_mode)

	lobby_create_requested.emit(
		int(game_manager.current_mode),
		int(layout),
		int(game_manager.draw_mode),
		int(game_manager.spider_suits)
	)
	
# ==================================================
# DISPLAY TRANSFORM
# ==================================================
func _apply_display_transform() -> void:
	if not is_instance_valid(screen_rig):
		return

	if display_mode == DisplayMode.CLASSIC:
		screen_rig.position = classic_position
		screen_rig.rotation_degrees = classic_rotation_degrees
	elif screen_default_saved:
		screen_rig.position = default_screen_position
		screen_rig.rotation_degrees = default_screen_rotation


# ==================================================
# UNDO BUTTONS
# ==================================================
func _setup_undo_buttons() -> void:
	undo_button_p1 = _find_area3d(screen_model, "UndoBtnP1")
	if undo_button_p1 == null:
		undo_button_p1 = _find_area3d(self, "UndoBtnP1")

	undo_button_p2 = _find_area3d(screen_model, "UndoBtnP2")
	if undo_button_p2 == null:
		undo_button_p2 = _find_area3d(self, "UndoBtnP2")

	if undo_button_p1 != null:
		undo_button_p1.input_ray_pickable = true
		if not undo_button_p1.input_event.is_connected(_on_undo_p1_input_event):
			undo_button_p1.input_event.connect(_on_undo_p1_input_event)
	else:
		push_warning("Screens: UndoBtnP1 не найден.")

	if undo_button_p2 != null:
		undo_button_p2.input_ray_pickable = true
		if not undo_button_p2.input_event.is_connected(_on_undo_p2_input_event):
			undo_button_p2.input_event.connect(_on_undo_p2_input_event)
	else:
		push_warning("Screens: UndoBtnP2 не найден.")

	_apply_button_glow(undo_button_p1)
	_apply_button_glow(undo_button_p2)
	_refresh_undo_buttons()

func _apply_button_glow(root: Node) -> void:
	if root == null:
		return

	for child in root.get_children():
		_apply_button_glow(child)

	if not root is MeshInstance3D:
		return

	var mesh_instance := root as MeshInstance3D
	if mesh_instance.mesh == null:
		return

	for surface in range(mesh_instance.mesh.get_surface_count()):
		var source_material := mesh_instance.get_active_material(surface)
		if not source_material is StandardMaterial3D:
			continue

		var glow_material := source_material.duplicate(true) as StandardMaterial3D
		glow_material.emission_enabled = true
		glow_material.emission = button_glow_color
		glow_material.emission_energy_multiplier = button_glow_energy

		if button_glow_uses_texture:
			glow_material.emission_texture = glow_material.albedo_texture

		mesh_instance.set_surface_override_material(surface, glow_material)

func _refresh_undo_buttons() -> void:
	# В одиночной игре используется только P1.
	# В сетевой каждый клиент может нажимать только кнопку своего поля.
	if is_instance_valid(undo_button_p1):
		undo_button_p1.input_ray_pickable = (
			(not network_session_active)
			or (network_opponent_connected and local_player_slot == 1)
		)

	if is_instance_valid(undo_button_p2):
		undo_button_p2.input_ray_pickable = (
			network_session_active
			and network_opponent_connected
			and local_player_slot == 2
		)


func _on_undo_p1_input_event(
	_camera: Camera3D,
	event: InputEvent,
	_event_position: Vector3,
	_normal: Vector3,
	_shape_idx: int
) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_press_undo_slot(1)
	elif event is InputEventScreenTouch and event.pressed:
		_press_undo_slot(1)


func _on_undo_p2_input_event(
	_camera: Camera3D,
	event: InputEvent,
	_event_position: Vector3,
	_normal: Vector3,
	_shape_idx: int
) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_press_undo_slot(2)
	elif event is InputEventScreenTouch and event.pressed:
		_press_undo_slot(2)


func _press_undo_slot(player_slot: int) -> void:
	if game_manager == null:
		return
	if game_manager.is_dealing or game_manager.game_finished:
		return

	if network_session_active:
		if not network_opponent_connected:
			return
		if player_slot != local_player_slot:
			return

		# ВАЖНО: сетевой Undo пока только отправляет запрос.
		# Сетевой менеджер должен обработать его и отменить ход нужного поля.
		network_undo_requested.emit(player_slot)
		return

	# Одиночная игра: прежнее поведение общей истории.
	if player_slot != 1:
		return

	var available_undos := mini(
		game_manager.history.size(),
		game_manager.undo_charges
	)
	if available_undos <= 0:
		return

	game_manager.undo()




func _find_area3d(root: Node, target_name: String) -> Area3D:
	if root == null:
		return null
	if root is Area3D and root.name == target_name:
		return root as Area3D

	for child in root.get_children():
		var found := _find_area3d(child, target_name)
		if found != null:
			return found
	return null


# ==================================================
# VIEWPORT / UI SCALING
# ==================================================
func _s(value: float) -> float:
	return value * ui_scale


func _si(value: float) -> int:
	return roundi(value * ui_scale)


func _setup_viewport() -> void:
	ui_scale = minf(
		float(viewport_resolution.x) / 1024.0,
		float(viewport_resolution.y) / 512.0
	)

	screen_viewport = SubViewport.new()
	screen_viewport.name = "ScreensViewport"
	screen_viewport.size = viewport_resolution
	screen_viewport.transparent_bg = false
	screen_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(screen_viewport)

	var root := Control.new()
	root.name = "ScreenUI"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = _make_screen_theme()
	screen_viewport.add_child(root)

	var background := ColorRect.new()
	background.color = Color("#0D141D")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(background)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", _si(14))
	margin.add_theme_constant_override("margin_right", _si(14))
	margin.add_theme_constant_override("margin_top", _si(12))
	margin.add_theme_constant_override("margin_bottom", _si(10))
	root.add_child(margin)

	var main := VBoxContainer.new()
	main.add_theme_constant_override("separation", _si(8))
	margin.add_child(main)

	var players_row := HBoxContainer.new()
	players_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	players_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	players_row.add_theme_constant_override("separation", _si(12))
	main.add_child(players_row)

	player_one_ui = _create_player_panel(players_row, "PLAYER 1")
	player_two_ui = _create_player_panel(players_row, "PLAYER 2")

	var separator := HSeparator.new()
	main.add_child(separator)

	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	footer.add_theme_constant_override("separation", _si(32))
	main.add_child(footer)

	var time_label := _make_label("ВРЕМЯ: 00:00", 26, Color("#86E8CF"))
	time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var score_p1 := _make_label("ОЧКИ: 50", 26, Color("#F2C35B"))
	score_p1.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var score_p2 := _make_label("P2: —", 26, Color("#F2C35B"))
	score_p2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	footer.add_child(time_label)
	footer.add_child(score_p1)
	footer.add_child(score_p2)

	player_one_ui["time_label"] = time_label
	player_one_ui["score_label"] = score_p1
	player_two_ui["score_label"] = score_p2

	classic_ui_root = margin
	ring_ui = _create_ring_ui(root)


## Шрифт табло: Nunito (читаемые цифры, кириллица) + системный резерв
## для символов мастей ♠♥♦♣, ▧ и ⚠, которых в Nunito нет.
func _make_screen_theme() -> Theme:
	var theme := Theme.new()
	var symbols := SystemFont.new()
	symbols.font_names = PackedStringArray(["Segoe UI Symbol", "Segoe UI Emoji", "DejaVu Sans", "Noto Sans Symbols2"])
	var base_path := "res://fonts/Nunito-Black.ttf"
	if ResourceLoader.exists(base_path):
		var variation := FontVariation.new()
		variation.base_font = load(base_path) as FontFile
		variation.fallbacks = [symbols]
		theme.default_font = variation
	else:
		theme.default_font = symbols
	return theme


# ==================================================
# CLASSIC / MIRRORED PLAYER PANEL
# ==================================================
func _create_player_panel(parent: HBoxContainer, player_title: String) -> Dictionary:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color("#152131")
	panel_style.border_color = Color("#2B3D55")
	panel_style.set_border_width_all(_si(1))
	panel_style.set_corner_radius_all(_si(7))
	panel.add_theme_stylebox_override("panel", panel_style)
	parent.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, _si(8))
	panel.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", _si(6))
	margin.add_child(content)

	var header := HBoxContainer.new()
	content.add_child(header)

	var title := _make_label(player_title, 22, Color("#F2C35B"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	var status := _make_label("ОЖИДАНИЕ", 12, Color("#86E8CF"))
	header.add_child(status)

	# STOCK + WASTE + STATISTICS
	var resource_row := HBoxContainer.new()
	resource_row.add_theme_constant_override("separation", _si(6))
	content.add_child(resource_row)

	var stock_label := _create_card_tile(resource_row, Vector2(64, 61), 13)
	stock_label.text = "STOCK\n00"

	var waste_column := VBoxContainer.new()
	waste_column.size_flags_horizontal = Control.SIZE_FILL
	waste_column.add_theme_constant_override("separation", _si(2))
	resource_row.add_child(waste_column)

	var waste_title := _make_label("WASTE", 11, Color("#9AAEC4"))
	waste_column.add_child(waste_title)

	var waste_row := HBoxContainer.new()
	waste_row.add_theme_constant_override("separation", _si(3))
	waste_column.add_child(waste_row)

	var waste_labels: Array[Label] = []
	for i in range(3):
		waste_labels.append(_create_card_tile(waste_row, Vector2(48, 48), 13))

	var stats_row := HBoxContainer.new()
	stats_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stats_row.alignment = BoxContainer.ALIGNMENT_CENTER
	stats_row.add_theme_constant_override("separation", _si(9))
	resource_row.add_child(stats_row)

	var moves_label := _make_label("ХОДЫ 000", 12, Color("#86E8CF"))
	var undos_label := _make_label("ОТМЕНЫ 000", 12, Color("#86E8CF"))
	var available_label := _make_label("UNDO 00", 12, Color("#86E8CF"))
	for label in [moves_label, undos_label, available_label]:
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		stats_row.add_child(label)

	var tableau_title := _make_label("TABLEAU", 12, Color("#9AAEC4"))
	tableau_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(tableau_title)

	var tableau_row := GridContainer.new()
	tableau_row.name = "TableauGrid"
	tableau_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	tableau_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tableau_row.columns = 7
	tableau_row.add_theme_constant_override("h_separation", _si(3))
	tableau_row.add_theme_constant_override("v_separation", _si(4))
	content.add_child(tableau_row)

	var foundation_total_label := _make_label(
		"FOUNDATION: 00/52",
		12,
		Color("#9AAEC4")
	)
	content.add_child(foundation_total_label)

	var foundation_rows := VBoxContainer.new()
	foundation_rows.add_theme_constant_override("separation", _si(2))
	content.add_child(foundation_rows)

	var foundation_card_labels: Array = []
	var foundation_count_labels: Array[Label] = []

	for suit_index in range(FOUNDATION_COUNT):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", _si(4))
		foundation_rows.add_child(row)

		var suit_label := _make_label(
			SUIT_SYMBOLS[suit_index],
			15,
			Color("#F2C35B")
		)
		suit_label.custom_minimum_size.x = _s(19)
		suit_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_child(suit_label)

		var cards_row := HBoxContainer.new()
		cards_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cards_row.add_theme_constant_override("separation", _si(1))
		row.add_child(cards_row)

		var suit_cards: Array[Label] = []
		for rank_index in range(FOUNDATION_CARDS):
			var card_label := _create_card_tile(cards_row, Vector2(18, 21), 8)
			var tile := card_label.get_parent() as Control
			tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_set_foundation_cell(card_label, false, suit_index, rank_index)
			suit_cards.append(card_label)
		foundation_card_labels.append(suit_cards)

		var count_label := _make_label("00/13", 10, Color("#86E8CF"))
		count_label.custom_minimum_size.x = _s(38)
		count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(count_label)
		foundation_count_labels.append(count_label)

	var deadend := _create_deadend_overlay(panel)

	return {
		"deadend": deadend,
		"panel": panel,
		"title": title,
		"status": status,
		"stock": stock_label,
		"waste": waste_labels,
		"waste_column": waste_column,
		"tableau_title": tableau_title,
		"tableau_row": tableau_row,
		"tableau_labels": [],
		"tableau_containers": [],
		"tableau_counts": [],
		"foundation_total": foundation_total_label,
		"foundation_rows": foundation_rows,
		"foundation_cards": foundation_card_labels,
		"foundation_counts": foundation_count_labels,
		"stats": {
			"moves": moves_label,
			"undos": undos_label,
			"available": available_label
		}
	}


## Окончательный тупик: затемнение поля игрока, предупреждение и выбор
## «Сдаться» / «Перетасовать». Кнопки нажимаются прямо на экране табло
## (клик по 3D-экрану пересылается в этот SubViewport — см. _forward_screen_click).
func _create_deadend_overlay(panel: PanelContainer) -> Dictionary:
	var overlay := Control.new()
	overlay.name = "DeadEndOverlay"
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.visible = false
	panel.add_child(overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.02, 0.02, 0.82)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(center)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", _si(10))
	center.add_child(box)

	var title := _make_label("⚠ ОКОНЧАТЕЛЬНЫЙ ТУПИК", 24, Color("#FF8A6B"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var hint := _make_label("Продвигающих ходов нет, отмены не помогут.", 13, Color("#F3E6C8"))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", _si(14))
	box.add_child(buttons)
	var surrender := _make_screen_button("СДАТЬСЯ", Color("#6E2A22"))
	var reshuffle := _make_screen_button("ПЕРЕТАСОВАТЬ", Color("#245A4A"))
	buttons.add_child(surrender)
	buttons.add_child(reshuffle)
	return {"root": overlay, "title": title, "hint": hint, "surrender": surrender, "reshuffle": reshuffle, "field": ""}


func _make_screen_button(text_value: String, base: Color) -> Button:
	var button := Button.new()
	button.text = text_value
	button.custom_minimum_size = Vector2(_s(150), _s(40))
	button.add_theme_font_size_override("font_size", _si(15))
	for state in ["normal", "hover", "pressed", "focus"]:
		var style := StyleBoxFlat.new()
		style.bg_color = base.lightened(0.15) if state == "hover" else (base.darkened(0.2) if state == "pressed" else base)
		style.border_color = Color("#F2C35B")
		style.set_border_width_all(_si(2))
		style.set_corner_radius_all(_si(6))
		button.add_theme_stylebox_override(state, style)
	button.add_theme_color_override("font_color", Color("#F3E6C8"))
	return button


## Вердикт предсказателя по полю: показать/спрятать предупреждение о тупике.
func _on_field_verdict_changed(field_id: String, verdict: int, _info: Dictionary) -> void:
	var ui := _ui_for_field(field_id)
	if ui.is_empty():
		return
	var deadend: Dictionary = ui["deadend"]
	var dead_now := verdict == KlondikePredictor.Verdict.DEAD_END and _is_local_field(field_id)
	deadend["field"] = field_id
	(deadend["root"] as Control).visible = dead_now
	(deadend["root"] as Control).mouse_filter = Control.MOUSE_FILTER_STOP if dead_now else Control.MOUSE_FILTER_IGNORE


func _ui_for_field(field_id: String) -> Dictionary:
	if game_manager == null:
		return {}
	if is_instance_valid(player_one_stock) and game_manager.get_field_id(player_one_stock) == field_id:
		return player_one_ui
	if is_instance_valid(player_two_stock) and game_manager.get_field_id(player_two_stock) == field_id:
		return player_two_ui
	return {}


## В сети выбор показывается только на стороне игрока этого поля.
func _is_local_field(field_id: String) -> bool:
	var sync := NetworkMatchSync.find_in(get_tree())
	if sync == null or not network_session_active:
		return true
	return sync.field_of_slot(sync.local_slot) == field_id


func _on_deadend_surrender(ui: Dictionary) -> void:
	var deadend: Dictionary = ui["deadend"]
	(deadend["root"] as Control).visible = false
	if game_manager != null and not str(deadend["field"]).is_empty():
		game_manager.surrender(str(deadend["field"]))


func _on_deadend_reshuffle(ui: Dictionary) -> void:
	var deadend: Dictionary = ui["deadend"]
	(deadend["root"] as Control).visible = false
	if game_manager != null and not str(deadend["field"]).is_empty():
		game_manager.redeal_field(str(deadend["field"]))


# ==================================================
# КЛИКИ ПО 3D-ЭКРАНУ → SubViewport
# ==================================================
var _screen_click_area: Area3D
var _screen_mesh_instance: MeshInstance3D
var _screen_mdt: MeshDataTool

const SCREEN_CLICK_LAYER := 1 << 19


## Делает экран табло кликабельным: коллизия по мешу экрана (отдельный слой,
## карты и стопки её не видят) и данные меша для пересчёта точки в UV.
func _setup_screen_touch() -> void:
	_screen_mesh_instance = _find_screen_mesh(screen_model)
	if _screen_mesh_instance == null or _screen_mesh_instance.mesh == null:
		return
	var mesh := _screen_mesh_instance.mesh
	if not mesh is ArrayMesh or screen_surface_index >= mesh.get_surface_count():
		return
	_screen_mdt = MeshDataTool.new()
	if _screen_mdt.create_from_surface(mesh as ArrayMesh, screen_surface_index) != OK:
		_screen_mdt = null
		return
	_screen_click_area = Area3D.new()
	_screen_click_area.name = "ScreenTouchArea"
	_screen_click_area.collision_layer = SCREEN_CLICK_LAYER
	_screen_click_area.collision_mask = 0
	_screen_click_area.monitoring = false
	var shape := CollisionShape3D.new()
	shape.shape = mesh.create_trimesh_shape()
	_screen_click_area.add_child(shape)
	_screen_mesh_instance.add_child(_screen_click_area)


func _find_screen_mesh(node: Node) -> MeshInstance3D:
	if node == null:
		return null
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null \
			and screen_surface_index < (node as MeshInstance3D).mesh.get_surface_count():
		return node as MeshInstance3D
	for child in node.get_children():
		var found := _find_screen_mesh(child)
		if found != null:
			return found
	return null


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or (event as InputEventMouseButton).button_index != MOUSE_BUTTON_LEFT:
		return
	if not _any_deadend_visible():
		return   # кликабельные элементы на табло есть только в тупике
	var pixel: Variant = _screen_pixel_under_mouse((event as InputEventMouseButton).position)
	if pixel == null:
		return
	var forwarded := (event as InputEventMouseButton).duplicate() as InputEventMouseButton
	forwarded.position = pixel
	forwarded.global_position = pixel
	# Наведение, затем само нажатие — так Button внутри SubViewport его примет.
	var motion := InputEventMouseMotion.new()
	motion.position = pixel
	motion.global_position = pixel
	screen_viewport.push_input(motion, true)
	screen_viewport.push_input(forwarded, true)
	get_viewport().set_input_as_handled()


func _any_deadend_visible() -> bool:
	for ui in [player_one_ui, player_two_ui]:
		if not ui.is_empty() and (ui["deadend"]["root"] as Control).visible:
			return true
	return false


## Экранная точка мыши → пиксель SubViewport табло (null — мимо экрана).
func _screen_pixel_under_mouse(mouse_position: Vector2) -> Variant:
	if _screen_mdt == null or not is_instance_valid(_screen_click_area):
		return null
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return null
	var origin := camera.project_ray_origin(mouse_position)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + camera.project_ray_normal(mouse_position) * 100.0, SCREEN_CLICK_LAYER)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	var local := _screen_mesh_instance.global_transform.affine_inverse() * (hit["position"] as Vector3)
	var uv: Variant = _uv_at(local)
	if uv == null:
		return null
	var screen_uv := _apply_screen_rotation(uv)
	return Vector2(screen_uv.x * viewport_resolution.x, screen_uv.y * viewport_resolution.y)


## UV точки на меше экрана: ищем треугольник, в который попала точка, и
## интерполируем UV по барицентрическим координатам.
func _uv_at(local_point: Vector3) -> Variant:
	var best_distance := INF
	var best_uv: Variant = null
	for face in _screen_mdt.get_face_count():
		var a := _screen_mdt.get_vertex(_screen_mdt.get_face_vertex(face, 0))
		var b := _screen_mdt.get_vertex(_screen_mdt.get_face_vertex(face, 1))
		var c := _screen_mdt.get_vertex(_screen_mdt.get_face_vertex(face, 2))
		var normal := (b - a).cross(c - a)
		if normal.length_squared() < 1e-12:
			continue
		var plane := Plane(normal.normalized(), a)
		var distance := absf(plane.distance_to(local_point))
		if distance > best_distance:
			continue
		var projected := plane.project(local_point)
		var bary := Geometry3D.get_triangle_barycentric_coords(projected, a, b, c)
		if bary.x < -0.001 or bary.y < -0.001 or bary.z < -0.001:
			continue
		best_distance = distance
		best_uv = _screen_mdt.get_vertex_uv(_screen_mdt.get_face_vertex(face, 0)) * bary.x \
			+ _screen_mdt.get_vertex_uv(_screen_mdt.get_face_vertex(face, 1)) * bary.y \
			+ _screen_mdt.get_vertex_uv(_screen_mdt.get_face_vertex(face, 2)) * bary.z
	return best_uv


## Тот же поворот, что в shaders/multiplayer_screen.gdshader (rotation_mode).
func _apply_screen_rotation(uv: Vector2) -> Vector2:
	var mode := 3
	if screen_material != null:
		var value: Variant = screen_material.get_shader_parameter("rotation_mode")
		if value != null:
			mode = int(value)
	match mode:
		1:
			return Vector2(uv.y, 1.0 - uv.x)
		2:
			return Vector2(1.0 - uv.x, 1.0 - uv.y)
		3:
			return Vector2(1.0 - uv.y, uv.x)
	return uv


func _create_classic_tableau_slot(ui: Dictionary, index: int) -> void:
	var grid: GridContainer = ui["tableau_row"]

	var column := VBoxContainer.new()
	column.name = "TableauColumn%d" % (index + 1)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", _si(2))
	grid.add_child(column)

	var stack_container := VBoxContainer.new()
	stack_container.name = "TableauStack%d" % (index + 1)
	stack_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack_container.custom_minimum_size = Vector2(_s(46), _s(135))
	stack_container.clip_contents = true
	stack_container.add_theme_constant_override("separation", _si(1))
	column.add_child(stack_container)

	var cached_labels: Array[Label] = []
	for slot_index in range(16):
		var cached_label := _create_card_tile(stack_container, Vector2(0, 15), 8)
		var tile := cached_label.get_parent() as Control
		tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tile.visible = false
		cached_labels.append(cached_label)

	var count_label := _make_label("00", 11, Color("#86E8CF"))
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(count_label)

	ui["tableau_containers"].append(stack_container)
	ui["tableau_counts"].append(count_label)
	ui["tableau_labels"].append(cached_labels)


func _ensure_classic_tableau_slots(ui: Dictionary, count: int) -> void:
	var grid: GridContainer = ui["tableau_row"]
	var containers: Array = ui["tableau_containers"]
	var counts: Array = ui["tableau_counts"]

	while containers.size() < count:
		_create_classic_tableau_slot(ui, containers.size())

	if count <= 0:
		grid.columns = 1
		return

	# Все вычисления выполняются в логических координатах 1024x512.
	# Не умножаем физическое разрешение на ui_scale повторно.
	var logical_width := float(viewport_resolution.x) / maxf(ui_scale, 0.001)
	var available_width := logical_width - 60.0
	if (display_mode == DisplayMode.MIRRORED or display_mode == DisplayMode.MULTIPLAYER) \
			and player_two_ui.get("panel") != null and player_two_ui["panel"].visible:
		available_width = available_width * 0.5 - 18.0

	var columns := mini(10, count)
	grid.columns = columns

	var gap := 3.0
	var column_width := (available_width - gap * float(columns - 1)) / float(columns)
	# В одиночном Клондайке не растягиваем семь стопок на весь экран.
	# Для 10/20 Tableau сетка использует практически всю доступную ширину.
	column_width = clampf(column_width, 18.0, 120.0)
	var grid_width := column_width * float(columns) + gap * float(columns - 1)

	grid.custom_minimum_size.x = _s(grid_width)
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL

	for i in range(containers.size()):
		var stack: Control = containers[i]
		var column: Control = stack.get_parent()
		column.custom_minimum_size.x = _s(column_width)
		stack.custom_minimum_size.x = _s(column_width)
		column.visible = i < count
		if i < counts.size():
			counts[i].visible = i < count


# ==================================================
# RING UI — HORIZONTAL TABLEAU + BOTTOM FOUNDATION PANEL
# ==================================================
func _create_ring_ui(parent: Control) -> Dictionary:
	var ring_root := Control.new()
	ring_root.name = "RingUI"
	ring_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ring_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ring_root.visible = false
	parent.add_child(ring_root)

	var header := _make_label("КРУГОВОЙ ПАСЬЯНС", 19, Color("#F2C35B"))
	header.position = Vector2(_s(164), _s(7))
	header.size = Vector2(_s(850), _s(27))
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ring_root.add_child(header)

	# Верхняя левая панель: статистика и колоды. Она не занимает место игрового поля.
	var stats_panel := _create_ring_panel(
		ring_root,
		Vector2(10, 42),
		Vector2(145, 250)
	)
	var stats_content := VBoxContainer.new()
	stats_content.add_theme_constant_override("separation", _si(5))
	stats_panel.add_child(stats_content)

	var score_title := _make_label("ОЧКИ", 10, Color("#9AAEC4"))
	stats_content.add_child(score_title)
	var score := _make_label("50", 25, Color("#F2C35B"))
	stats_content.add_child(score)

	var moves := _make_label("ХОДЫ 000", 12, Color("#86E8CF"))
	stats_content.add_child(moves)
	var time_label := _make_label("ВРЕМЯ 00:00", 12, Color("#86E8CF"))
	stats_content.add_child(time_label)
	var undos := _make_label("ОТМЕНЫ 000", 12, Color("#C6A9EE"))
	stats_content.add_child(undos)
	var available := _make_label("UNDO 00", 12, Color("#C6A9EE"))
	stats_content.add_child(available)

	var stats_separator := HSeparator.new()
	stats_content.add_child(stats_separator)

	var resources_row := HBoxContainer.new()
	resources_row.alignment = BoxContainer.ALIGNMENT_CENTER
	resources_row.add_theme_constant_override("separation", _si(10))
	stats_content.add_child(resources_row)

	var stock_column := VBoxContainer.new()
	stock_column.alignment = BoxContainer.ALIGNMENT_CENTER
	stock_column.add_theme_constant_override("separation", _si(2))
	resources_row.add_child(stock_column)
	var stock_title := _make_label("STOCK", 9, Color("#9AAEC4"))
	stock_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stock_column.add_child(stock_title)
	var stock := _create_card_tile(stock_column, Vector2(48, 42), 10)
	stock.text = "▧ 00"
	var stock_style := stock.get_meta("tile_style") as StyleBoxFlat
	if stock_style != null:
		stock_style.bg_color = Color("#2F5D8F")

	var waste_column := VBoxContainer.new()
	waste_column.alignment = BoxContainer.ALIGNMENT_CENTER
	waste_column.add_theme_constant_override("separation", _si(2))
	resources_row.add_child(waste_column)
	var waste_title := _make_label("WASTE", 9, Color("#9AAEC4"))
	waste_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	waste_column.add_child(waste_title)
	var waste := _create_card_tile(waste_column, Vector2(48, 42), 10)

	# Нижняя левая панель Spider: четыре полноразмерных прогресс-бара по мастям.
	var spider_stack_panel := _create_ring_panel(
		ring_root,
		Vector2(10, 304),
		Vector2(145, 198)
	)
	var spider_progress_content := VBoxContainer.new()
	spider_progress_content.add_theme_constant_override("separation", _si(7))
	spider_stack_panel.add_child(spider_progress_content)
	var spider_stack_heading := _make_label("СОБРАННЫЕ РЯДЫ", 10, Color("#F2C35B"))
	spider_stack_heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	spider_progress_content.add_child(spider_stack_heading)

	var spider_stack_rows: Array[Dictionary] = []
	for suit_index in range(FOUNDATION_COUNT):
		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", _si(2))
		spider_progress_content.add_child(row)

		var info_row := HBoxContainer.new()
		info_row.add_theme_constant_override("separation", _si(4))
		row.add_child(info_row)

		var suit_label := _make_label(SUIT_SYMBOLS[suit_index], 13, Color("#F2C35B"))
		suit_label.custom_minimum_size.x = _s(18)
		suit_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		info_row.add_child(suit_label)

		var count_label := _make_label("0/0", 9, Color("#86E8CF"))
		count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		info_row.add_child(count_label)

		var progress := ProgressBar.new()
		progress.min_value = 0.0
		progress.max_value = 1.0
		progress.value = 0.0
		progress.show_percentage = false
		progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		progress.custom_minimum_size = Vector2(0, _s(12))
		var progress_bg := StyleBoxFlat.new()
		progress_bg.bg_color = Color("#1F2D3F")
		progress_bg.border_color = Color("#3A5068")
		progress_bg.set_border_width_all(_si(1))
		progress_bg.set_corner_radius_all(_si(3))
		var progress_fill := StyleBoxFlat.new()
		progress_fill.bg_color = _card_color(suit_index + 1)
		progress_fill.set_corner_radius_all(_si(3))
		progress.add_theme_stylebox_override("background", progress_bg)
		progress.add_theme_stylebox_override("fill", progress_fill)
		row.add_child(progress)

		spider_stack_rows.append({
			"root": row,
			"suit": suit_label,
			"progress": progress,
			"count": count_label
		})

	# Игровая сетка всегда начинается правее левой панели и обрезается своими границами.
	var tableau_grid := GridContainer.new()
	tableau_grid.position = Vector2(_s(164), _s(42))
	tableau_grid.size = Vector2(_s(850), _s(460))
	tableau_grid.custom_minimum_size = tableau_grid.size
	tableau_grid.columns = 10
	tableau_grid.clip_contents = true
	tableau_grid.add_theme_constant_override("h_separation", _si(3))
	tableau_grid.add_theme_constant_override("v_separation", _si(4))
	ring_root.add_child(tableau_grid)

	# Foundation существует только для Ring Klondike.
	var foundation_panel := _create_ring_panel(
		ring_root,
		Vector2(164, 370),
		Vector2(850, 132)
	)
	var foundation_content := VBoxContainer.new()
	foundation_content.add_theme_constant_override("separation", _si(2))
	foundation_panel.add_child(foundation_content)
	var foundation_heading := _make_label("ОСНОВАНИЯ", 11, Color("#F2C35B"))
	foundation_heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	foundation_content.add_child(foundation_heading)

	var foundation_rows: Array[Dictionary] = []
	for suit_index in range(FOUNDATION_COUNT):
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", _si(4))
		foundation_content.add_child(row)

		var suit_label := _make_label(SUIT_SYMBOLS[suit_index], 15, Color("#F2C35B"))
		suit_label.custom_minimum_size.x = _s(20)
		suit_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_child(suit_label)

		var cards_row := HBoxContainer.new()
		cards_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cards_row.add_theme_constant_override("separation", _si(2))
		row.add_child(cards_row)

		var card_labels: Array[Label] = []
		for rank_index in range(FOUNDATION_CARDS):
			var card_label := _create_card_tile(cards_row, Vector2(23, 20), 8)
			var tile := card_label.get_parent() as Control
			tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_set_foundation_cell(card_label, false, suit_index, rank_index)
			card_labels.append(card_label)

		var count_label := _make_label("00/13", 10, Color("#86E8CF"))
		count_label.custom_minimum_size.x = _s(42)
		count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(count_label)
		foundation_rows.append({
			"root": row,
			"suit": suit_label,
			"cards": card_labels,
			"count": count_label
		})

	return {
		"root": ring_root,
		"header": header,
		"score": score,
		"moves": moves,
		"time": time_label,
		"undos": undos,
		"available": available,
		"stock": stock,
		"waste": waste,
		"waste_column": waste_column,
		"spider_stack_panel": spider_stack_panel.get_parent() as Control,
		"spider_stack_heading": spider_stack_heading,
		"spider_stack_rows": spider_stack_rows,
		"tableau_grid": tableau_grid,
		"foundation_panel": foundation_panel.get_parent() as Control,
		"foundation_heading": foundation_heading,
		"foundation_rows": foundation_rows
	}


func _create_ring_panel(
	parent: Control,
	pos: Vector2,
	panel_size: Vector2
) -> MarginContainer:
	var panel := PanelContainer.new()
	panel.position = Vector2(_s(pos.x), _s(pos.y))
	panel.size = Vector2(_s(panel_size.x), _s(panel_size.y))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()
	style.bg_color = Color("#152131")
	style.border_color = Color("#2B3D55")
	style.set_border_width_all(_si(1))
	style.set_corner_radius_all(_si(7))
	panel.add_theme_stylebox_override("panel", style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", _si(7))
	margin.add_theme_constant_override("margin_right", _si(7))
	margin.add_theme_constant_override("margin_top", _si(5))
	margin.add_theme_constant_override("margin_bottom", _si(5))
	panel.add_child(margin)
	parent.add_child(panel)
	return margin


func _create_ring_tableau_slot(
	parent: Control,
	index: int,
	slot_size: Vector2
) -> Dictionary:
	var holder := VBoxContainer.new()
	holder.custom_minimum_size = slot_size
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_theme_constant_override("separation", _si(1))
	parent.add_child(holder)

	var index_label := _make_label(
		"T%02d" % (index + 1),
		9,
		Color("#F2C35B")
	)
	index_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	holder.add_child(index_label)

	var stack := VBoxContainer.new()
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.custom_minimum_size.x = 0.0
	stack.clip_contents = true
	stack.add_theme_constant_override("separation", 0)
	holder.add_child(stack)

	var labels: Array[Label] = []
	for i in range(11):
		var card_label := _create_card_tile(stack, Vector2(0, 7), 8)
		var tile := card_label.get_parent() as Control
		tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tile.visible = false
		labels.append(card_label)

	var count_label := _make_label("00", 9, Color("#86E8CF"))
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	holder.add_child(count_label)

	return {
		"root": holder,
		"index": index_label,
		"stack": stack,
		"labels": labels,
		"count": count_label
	}


func _ensure_ring_tableau_slots(count: int, grid_height: float) -> void:
	var grid: GridContainer = ring_ui["tableau_grid"]
	var columns := mini(10, maxi(1, count))
	var rows := int(ceil(float(count) / float(columns))) if count > 0 else 1
	grid.columns = columns
	grid.clip_contents = true

	var grid_width := 850.0
	var horizontal_gap := 3.0
	var vertical_gap := 4.0
	var slot_width := (grid_width - horizontal_gap * float(columns - 1)) / float(columns)
	var slot_height := (grid_height - vertical_gap * float(maxi(0, rows - 1))) / float(rows)
	var stack_height := maxf(26.0, slot_height - 25.0)
	var slot_size := Vector2(_s(slot_width), _s(slot_height))

	if ring_tableau_slots.size() != count:
		for child in grid.get_children():
			grid.remove_child(child)
			child.queue_free()
		ring_tableau_slots.clear()
		for i in range(count):
			ring_tableau_slots.append(_create_ring_tableau_slot(grid, i, slot_size))

	grid.size = Vector2(_s(grid_width), _s(grid_height))
	grid.custom_minimum_size = grid.size
	for slot in ring_tableau_slots:
		var holder: Control = slot["root"]
		holder.custom_minimum_size = slot_size
		holder.clip_contents = true
		var stack: Control = slot["stack"]
		stack.custom_minimum_size.y = _s(stack_height)
		stack.clip_contents = true


func _draw_ring_tableau(slot: Dictionary, pile: Pile, index: int) -> void:
	var labels: Array = slot["labels"]
	var count_label: Label = slot["count"]
	var index_label: Label = slot["index"]
	index_label.text = "T%02d" % (index + 1)

	for label in labels:
		var tile := label.get_parent() as Control
		tile.visible = false

	if not is_instance_valid(pile) or pile.cards.is_empty():
		count_label.text = "00"
		return

	const MAX_VISIBLE := 10
	var total := pile.cards.size()
	var first_visible := maxi(0, total - MAX_VISIBLE)
	var show_more := first_visible > 0
	var item_count := total - first_visible + (1 if show_more else 0)
	var stack: Control = slot["stack"]
	var available_height := maxf(stack.size.y, stack.custom_minimum_size.y)
	# При 7–10 Tableau стопки получают больше вертикального места;
	# при 20+ колонках высота автоматически уменьшается.
	var bar_height := clampf(
		available_height / float(maxi(1, item_count)),
		_s(4.0),
		_s(20.0)
	)

	var slot_index := 0
	if show_more:
		var more_label: Label = labels[slot_index]
		slot_index += 1
		var more_tile := more_label.get_parent() as Control
		more_tile.visible = true
		more_tile.custom_minimum_size.y = bar_height
		more_label.text = "+%d" % first_visible
		more_label.add_theme_color_override("font_color", Color("#86E8CF"))
		var more_style := more_label.get_meta("tile_style") as StyleBoxFlat
		if more_style != null:
			more_style.bg_color = Color("#1F2D3F")

	for card_index in range(first_visible, total):
		if slot_index >= labels.size():
			break
		var card: Card = pile.cards[card_index]
		var card_label: Label = labels[slot_index]
		slot_index += 1
		var tile := card_label.get_parent() as Control
		tile.visible = true
		tile.custom_minimum_size.y = bar_height
		_set_card_label(card_label, card)
		card_label.add_theme_font_size_override("font_size", _si(8))

	count_label.text = "%02d" % total


# ==================================================
# COMMON UI HELPERS
# ==================================================
func _make_label(text_value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", _si(font_size))
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _create_card_tile(parent: Control, minimum_size: Vector2, font_size: int) -> Label:
	var tile := PanelContainer.new()
	tile.custom_minimum_size = minimum_size * ui_scale
	tile.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()
	style.bg_color = Color("#EFE8D8")
	style.set_corner_radius_all(_si(3))
	tile.add_theme_stylebox_override("panel", style)
	parent.add_child(tile)

	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", _si(font_size))
	label.add_theme_color_override("font_color", Color("#1B2433"))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(label)
	label.set_meta("tile_style", style)
	return label


func _set_card_label(label: Label, card: Card) -> void:
	var style := label.get_meta("tile_style") as StyleBoxFlat

	if not is_instance_valid(card):
		label.text = "—"
		label.add_theme_color_override("font_color", Color("#6B7E95"))
		if style != null:
			style.bg_color = Color("#1F2D3F")
		return

	if not card.face_up:
		label.text = "▧"
		label.add_theme_color_override("font_color", Color.WHITE)
		if style != null:
			style.bg_color = Color("#2F5D8F")
		return

	label.text = _format_card(card)
	label.add_theme_color_override("font_color", _card_color(card.suit))
	if style != null:
		style.bg_color = Color("#EFE8D8")


func _format_card(card: Card) -> String:
	var rank_text := str(card.rank)
	match card.rank:
		1:
			rank_text = "A"
		11:
			rank_text = "J"
		12:
			rank_text = "Q"
		13:
			rank_text = "K"
	var suit_index := clampi(card.suit - 1, 0, 3)
	return rank_text + SUIT_SYMBOLS[suit_index]


func _card_color(suit: int) -> Color:
	if suit == Card.Suit.HEARTS or suit == Card.Suit.DIAMONDS:
		return Color("#C73B3B")
	return Color("#1B2433")


func _set_foundation_cell(label: Label, filled: bool, suit_index: int, rank_index: int) -> void:
	label.text = FOUNDATION_RANKS[rank_index]
	var style := label.get_meta("tile_style") as StyleBoxFlat
	if filled:
		if style != null:
			style.bg_color = Color("#EFE8D8")
			style.border_color = Color("#CFC5B0")
		label.add_theme_color_override("font_color", _card_color(suit_index + 1))
	else:
		if style != null:
			style.bg_color = Color("#1F2D3F")
			style.border_color = Color("#33475F")
		label.add_theme_color_override("font_color", Color("#62758C"))


# ==================================================
# GAME MANAGER SIGNALS / REFRESH
# ==================================================
func _queue_screen_refresh() -> void:
	if screen_refresh_queued:
		return
	screen_refresh_queued = true
	call_deferred("_flush_screen_refresh")


func _flush_screen_refresh() -> void:
	screen_refresh_queued = false
	if not is_inside_tree() or game_manager == null:
		return
	_update_player_one()


func _on_history_changed(_move_count: int) -> void:
	_queue_screen_refresh()


func _connect_game_manager() -> void:
	if game_manager_path != NodePath():
		game_manager = get_node_or_null(game_manager_path) as GameManager
	if game_manager == null:
		game_manager = get_tree().get_first_node_in_group("game_manager") as GameManager
	if game_manager == null:
		push_warning("Screens: GameManager не найден.")
		return

	if not game_manager.board_counts_changed.is_connected(_on_board_counts_changed):
		game_manager.board_counts_changed.connect(_on_board_counts_changed)
	if not game_manager.history_changed.is_connected(_on_history_changed):
		game_manager.history_changed.connect(_on_history_changed)
	if not game_manager.statistics_changed.is_connected(_on_statistics_changed):
		game_manager.statistics_changed.connect(_on_statistics_changed)
	if not game_manager.deal_finished.is_connected(_on_deal_finished):
		game_manager.deal_finished.connect(_on_deal_finished)
	if not game_manager.game_won.is_connected(_on_game_won):
		game_manager.game_won.connect(_on_game_won)
	if not game_manager.field_verdict_changed.is_connected(_on_field_verdict_changed):
		game_manager.field_verdict_changed.connect(_on_field_verdict_changed)

	_connect_network_sync()
	_update_player_one()
	_on_statistics_changed(
		game_manager.moves_count,
		game_manager.undo_count,
		mini(game_manager.history.size(), game_manager.undo_charges),
		game_manager.undo_charges
	)

	if not game_manager.is_dealing and not game_manager.game_finished:
		timer_running = true
	_update_time_label()


## Сетевая партия: табло получает состояние сессии, номер своего игрока
## и статистику соперника от NetworkMatchSync (создаёт GameManager).
func _connect_network_sync() -> void:
	var sync := NetworkMatchSync.find_in(get_tree())
	if sync == null:
		# Одиночная игра: прежнее поведение.
		set_network_session_state(false, false, 1)
		return
	if not sync.session_state_changed.is_connected(set_network_session_state):
		sync.session_state_changed.connect(set_network_session_state)
	if not sync.remote_stats_changed.is_connected(_on_remote_stats_changed):
		sync.remote_stats_changed.connect(_on_remote_stats_changed)
	if not network_undo_requested.is_connected(sync.handle_undo_request):
		network_undo_requested.connect(sync.handle_undo_request)
	set_network_session_state(
		NetworkMatchSync.is_network_match(),
		sync.opponent_connected,
		maxi(1, sync.local_slot)
	)


func _on_remote_stats_changed(_slot: int, _stats: Dictionary) -> void:
	_queue_screen_refresh()


## Статистика конкретного игрока. В сети у каждого своя история ходов:
## свои цифры берём из GameManager, цифры соперника — из его последнего снимка.
func _get_slot_stats(slot: int) -> Dictionary:
	if network_session_active and slot != local_player_slot:
		var sync := NetworkMatchSync.find_in(get_tree())
		var remote: Dictionary = sync.get_remote_stats(slot) if sync != null else {}
		if remote.is_empty():
			return {}
		return {
			"moves": int(remote.get("moves", 0)),
			"undos": int(remote.get("undos", 0)),
			"available": int(remote.get("available", 0)),
		}
	if display_mode == DisplayMode.MIRRORED and not network_session_active:
		# Одиночная игра на двух полях: ходы и отмены считаются по каждому полю.
		var anchor := player_one_stock if slot == 1 else player_two_stock
		var field := game_manager.get_field_stats(game_manager.get_field_id(anchor))
		return {
			"moves": int(field["moves"]),
			"undos": int(field["undos"]),
			"available": mini(game_manager.history.size(), game_manager.undo_charges),
		}
	return {
		"moves": game_manager.moves_count,
		"undos": game_manager.undo_count,
		"available": mini(game_manager.history.size(), game_manager.undo_charges),
	}


func _apply_slot_statistics(ui: Dictionary, slot: int) -> void:
	var stats := _get_slot_stats(slot)
	if stats.is_empty():
		var labels: Dictionary = ui["stats"]
		labels["moves"].text = "ХОДЫ —"
		labels["undos"].text = "ОТМЕНЫ —"
		labels["available"].text = "UNDO —"
		return
	_update_panel_statistics(ui, int(stats["moves"]), int(stats["undos"]), int(stats["available"]))


func _on_board_counts_changed(_deck_count: int, _field_count: int) -> void:
	if game_manager != null and game_manager.is_dealing:
		return
	_queue_screen_refresh()


func _on_statistics_changed(
	new_moves: int,
	new_undos: int,
	new_available_undos: int,
	_new_undo_charges: int
) -> void:
	if network_session_active and display_mode == DisplayMode.MULTIPLAYER:
		# Локальная статистика относится только к своему полю.
		var own_ui := player_one_ui if local_player_slot == 1 else player_two_ui
		if not own_ui.is_empty():
			_update_panel_statistics(own_ui, new_moves, new_undos, new_available_undos)
		_update_ring_statistics(new_moves, new_undos, new_available_undos)
		return
	if display_mode == DisplayMode.MIRRORED:
		# У каждого поля своя статистика — панели перерисует общий refresh.
		_queue_screen_refresh()
		_update_ring_statistics(new_moves, new_undos, new_available_undos)
		return
	if not player_one_ui.is_empty():
		_update_panel_statistics(player_one_ui, new_moves, new_undos, new_available_undos)
	if not player_two_ui.is_empty() and player_two_stock != null and player_two_ui["panel"].visible:
		_update_panel_statistics(player_two_ui, new_moves, new_undos, new_available_undos)
	_update_ring_statistics(new_moves, new_undos, new_available_undos)


func _update_panel_statistics(ui: Dictionary, moves: int, undos: int, available: int) -> void:
	if ui.is_empty():
		return
	var stats: Dictionary = ui["stats"]
	stats["moves"].text = "ХОДЫ %03d" % moves
	stats["undos"].text = "ОТМЕНЫ %03d" % undos
	stats["available"].text = "UNDO %02d" % available


func _on_deal_finished() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree() or game_manager == null:
		return
	_update_player_one()
	elapsed_time = 0.0
	last_displayed_second = -1
	timer_running = not game_manager.game_finished
	_update_time_label()


func _on_game_won() -> void:
	timer_running = false
	if not ring_ui.is_empty():
		ring_ui["header"].text = "ПОБЕДА · КРУГОВОЙ ПАСЬЯНС"
	if not player_one_ui.is_empty():
		player_one_ui["status"].text = "ПОБЕДА"
	if display_mode == DisplayMode.MULTIPLAYER and not player_two_ui.is_empty():
		player_two_ui["status"].text = "ПОБЕДА"
	_update_time_label()


# ==================================================
# PILE LOOKUP / FIELD FILTERING
# ==================================================
func _get_trailing_number(value: String) -> int:
	var regex := RegEx.new()
	regex.compile("([0-9]+)$")
	var result := regex.search(value)
	if result == null:
		return -1
	return int(result.get_string(1))


func _get_tableau_marker_order(pile: Pile) -> int:
	if not is_instance_valid(pile) or not is_instance_valid(pile.owner_marker):
		return -1

	var marker: Node = pile.owner_marker
	var field_root := _get_field_root(pile)
	while marker != null and marker != field_root:
		# Имена T1, T2 ... T20 имеют приоритет над свойствами по умолчанию.
		var number := _get_trailing_number(str(marker.name))
		if number >= 0:
			return number

		# Поддержка маркеров, где индекс задан экспортируемым свойством.
		for property_info in marker.get_property_list():
			var property_name := str(property_info.get("name", ""))
			if property_name in ["tableau_index", "column_index", "pile_index", "marker_index"]:
				var property_value: Variant = marker.get(property_name)
				if property_value is int or property_value is float:
					return int(property_value)
		marker = marker.get_parent()
	return -1


func _sort_tableau_piles(piles: Array[Pile]) -> void:
	piles.sort_custom(
		func(a: Pile, b: Pile) -> bool:
			var order_a := _get_tableau_marker_order(a)
			var order_b := _get_tableau_marker_order(b)
			if order_a >= 0 and order_b >= 0 and order_a != order_b:
				return order_a < order_b
			if order_a >= 0 and order_b < 0:
				return true
			if order_b >= 0 and order_a < 0:
				return false

			# Запасной вариант для маркеров без числового индекса:
			# сначала порядок узлов в одном родителе, затем координаты.
			if is_instance_valid(a.owner_marker) and is_instance_valid(b.owner_marker):
				if a.owner_marker.get_parent() == b.owner_marker.get_parent():
					return a.owner_marker.get_index() < b.owner_marker.get_index()
			if not is_equal_approx(a.global_position.z, b.global_position.z):
				return a.global_position.z < b.global_position.z
			return a.global_position.x < b.global_position.x
	)


func _find_pile(marker_name: String) -> Pile:
	if game_manager == null:
		return null
	for pile in game_manager.piles:
		if not is_instance_valid(pile):
			continue
		if not is_instance_valid(pile.owner_marker):
			continue
		if pile.owner_marker.name == marker_name:
			return pile
	return null


func _get_field_root(pile: Pile) -> Node:
	if pile == null or not is_instance_valid(pile.owner_marker):
		return null

	var root: Node3D = game_manager.markers_root
	if root == null:
		root = game_manager._resolve_markers_root()
	if root == null:
		return null

	var coop_root: Node = root.get_node_or_null("CoopPresets")
	var node: Node = pile.owner_marker
	while node != null and node != root:
		if coop_root != null and node.get_parent() == coop_root:
			return node
		node = node.get_parent()
	return root


func _same_field(a: Pile, b: Pile) -> bool:
	if a == null or b == null:
		return false
	var root_a: Node = _get_field_root(a)
	var root_b: Node = _get_field_root(b)
	return root_a != null and root_a == root_b


func _get_field_piles(source_stock: Pile, target_kind: PileMarker.Kind) -> Array[Pile]:
	var result: Array[Pile] = []
	if game_manager == null or not is_instance_valid(source_stock):
		return result

	for candidate in game_manager.get_piles(target_kind):
		if not is_instance_valid(candidate):
			continue
		if _same_field(source_stock, candidate):
			result.append(candidate)
	return result


func _find_field_pile(source_stock: Pile, target_kind: PileMarker.Kind) -> Pile:
	var found := _get_field_piles(source_stock, target_kind)
	if found.is_empty():
		return null
	return found[0]


func _find_field_pile_vault(source_stock: Pile) -> PileVault:
	if game_manager == null or not is_instance_valid(source_stock):
		return null

	var unassigned_vaults: Array[PileVault] = []
	for pile in game_manager.piles:
		if not is_instance_valid(pile) or not pile is PileVault:
			continue
		var vault := pile as PileVault
		if is_instance_valid(vault.owner_marker):
			if _same_field(source_stock, vault):
				return vault
		else:
			unassigned_vaults.append(vault)

	# Совместимость со старой сценой, где есть только один общий Vault без маркера.
	if unassigned_vaults.size() == 1:
		var all_vaults := 0
		for pile in game_manager.piles:
			if is_instance_valid(pile) and pile is PileVault:
				all_vaults += 1
		if all_vaults == 1:
			return unassigned_vaults[0]
	return null


func _find_pile_vault() -> PileVault:
	if game_manager == null:
		return null
	for pile in game_manager.piles:
		if is_instance_valid(pile) and pile is PileVault:
			return pile as PileVault
	return null


func _resolve_display_mode() -> DisplayMode:
	if game_manager == null:
		return DisplayMode.CLASSIC
	match GameSession.get_board_layout(game_manager.current_mode):
		GameSession.BOARD_LAYOUT_MIRRORED:
			# Сетевая партия: два поля двух разных игроков.
			if network_session_active:
				return DisplayMode.MULTIPLAYER
			return DisplayMode.MIRRORED
		GameSession.BOARD_LAYOUT_RING:
			return DisplayMode.RING
	return DisplayMode.CLASSIC


func _is_mirrored_mode() -> bool:
	return display_mode == DisplayMode.MIRRORED


# ==================================================
# PLAYER PANEL UPDATES — KLONDIKE AND SPIDER
# ==================================================
func _update_player_one() -> void:
	if game_manager == null:
		return

	display_mode = _resolve_display_mode()
	_apply_display_transform()

	var is_klondike := game_manager.current_mode == GameManager.GameMode.KLONDIKE

	# В зеркальном режиме второе поле показывается и в Клондайке, и в Пауке.
	var show_second_panel := (
		display_mode == DisplayMode.MIRRORED
		or display_mode == DisplayMode.MULTIPLAYER
	)
	player_two_ui["panel"].visible = show_second_panel
	player_one_ui["panel"].size_flags_horizontal = Control.SIZE_EXPAND_FILL
	player_two_ui["panel"].size_flags_horizontal = Control.SIZE_EXPAND_FILL

	classic_ui_root.visible = display_mode != DisplayMode.RING
	ring_ui["root"].visible = display_mode == DisplayMode.RING

	# Поля определяются по корню раскладки (Markers / Coop_MIRRORED), а не по колодам:
	# в зеркальном Пауке колода может быть одна на два поля, и раньше второе поле
	# из-за этого не находилось и панель оставалась пустой.
	# player_*_stock — «якорная» стопка поля (по возможности его STOCK).
	player_one_stock = null
	player_two_stock = null
	var anchors := _get_field_anchors()
	if anchors.is_empty():
		player_one_ui["status"].text = "НЕТ КОЛОДЫ"
		if display_mode == DisplayMode.RING and not ring_ui.is_empty():
			ring_ui["header"].text = "НЕТ КОЛОДЫ"
		_update_player_two_placeholder()
		return

	player_one_stock = anchors[0]
	if show_second_panel and anchors.size() > 1:
		player_two_stock = anchors[1]

	if display_mode == DisplayMode.RING:
		_update_ring_display(player_one_stock, is_klondike)
		_update_time_label()
		return

	# Одиночная игра с двумя полями: это поля одного игрока, а не «Игрок 2».
	player_one_ui["title"].text = "ПОЛЕ 1" if display_mode == DisplayMode.MIRRORED else "PLAYER 1"
	_update_field_panel(player_one_ui, player_one_stock)
	if display_mode == DisplayMode.MIRRORED:
		player_one_ui["status"].text = "АКТИВНО · ОДИНОЧНАЯ ИГРА"
	if display_mode == DisplayMode.MULTIPLAYER:
		player_one_ui["title"].text = _network_panel_title(1)
		player_one_ui["status"].text = _network_panel_status(1)
	_update_player_two()
	_highlight_own_panel()
	_update_time_label()


## Своё поле в сети — яркая рамка цвета игрока; у соперника — его цвет, приглушённо.
func _highlight_own_panel() -> void:
	for slot in [1, 2]:
		var ui: Dictionary = player_one_ui if slot == 1 else player_two_ui
		var style := (ui["panel"] as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
		if style == null:
			continue
		if display_mode == DisplayMode.MULTIPLAYER:
			var color := NetworkMatchState.color_of(slot)
			style.border_color = color if slot == local_player_slot else color.darkened(0.55)
			style.set_border_width_all(_si(3) if slot == local_player_slot else _si(1))
		else:
			style.border_color = Color("#2B3D55")
			style.set_border_width_all(_si(1))


## Заголовок сетевой панели: «P1 · Имя (ВЫ)». Номер поля не зависит от того,
## какой клиент смотрит: поле 1 всегда игрока 1, поле 2 — игрока 2.
func _network_panel_title(slot: int) -> String:
	var title := "P%d · %s" % [slot, NetworkMatchState.name_of(slot)]
	if slot == local_player_slot:
		title += " (ВЫ)"
	return title


func _network_panel_status(slot: int) -> String:
	if game_manager != null and game_manager.game_finished:
		return "ПОБЕДА"
	if slot == local_player_slot:
		return "ВАШЕ ПОЛЕ"
	return "СОПЕРНИК В ИГРЕ" if network_opponent_connected else "СОПЕРНИК ОТКЛЮЧЁН"


func _update_player_two() -> void:
	if game_manager == null or not player_two_ui["panel"].visible:
		_update_player_two_placeholder()
		return

	var mode_name := (
		"КЛОНДАЙК"
		if game_manager.current_mode == GameManager.GameMode.KLONDIKE
		else "ПАУК"
	)

	if player_two_stock == null:
		_update_player_two_placeholder(
			"ОЖИДАНИЕ СЕТЕВОГО ПОЛЯ"
			if network_session_active
			else "ЛОББИ СОЗДАЁТСЯ ЧЕРЕЗ МЕНЮ"
		)
		player_two_ui["title"].text = mode_name + " · ПОЛЕ 2"
		return

	_update_field_panel(player_two_ui, player_two_stock)

	if network_session_active:
		player_two_ui["title"].text = _network_panel_title(2)
		player_two_ui["status"].text = _network_panel_status(2)
	else:
		player_two_ui["title"].text = "ПОЛЕ 2 · " + mode_name
		player_two_ui["status"].text = "АКТИВНО · ОДИНОЧНАЯ ИГРА"


## Якорные стопки полей: [поле 1 (Markers), поле 2 (Coop_MIRRORED)].
## Для каждого поля берём его STOCK, а если колоды у поля нет — любую его стопку.
func _get_field_anchors() -> Array[Pile]:
	var result: Array[Pile] = []
	if game_manager == null:
		return result
	var roots: Array[Node] = []
	var by_root := {}
	for pile in game_manager.piles:
		if not is_instance_valid(pile) or pile is PileVault:
			continue
		var root := _get_field_root(pile)
		if root == null:
			continue
		if not by_root.has(root):
			by_root[root] = pile
			roots.append(root)
		elif pile.kind == PileMarker.Kind.STOCK and (by_root[root] as Pile).kind != PileMarker.Kind.STOCK:
			by_root[root] = pile
	# Поле Markers (игрок 1) всегда первое.
	var main_root: Node = game_manager.markers_root
	roots.sort_custom(func(a: Node, b: Node) -> bool: return a == main_root and b != main_root)
	for root in roots:
		result.append(by_root[root])
	return result


func _update_field_panel(ui: Dictionary, stock: Pile) -> void:
	if not is_instance_valid(stock):
		return

	var is_klondike := game_manager.current_mode == GameManager.GameMode.KLONDIKE
	ui["panel"].modulate = Color.WHITE
	ui["status"].text = "АКТИВЕН · " + ("КЛОНДАЙК" if is_klondike else "ПАУК")
	# stock — якорь поля; у поля может не быть своей колоды (общая колода Паука).
	var field_stock := stock if stock.kind == PileMarker.Kind.STOCK else _find_field_pile(stock, PileMarker.Kind.STOCK)
	ui["stock"].text = "STOCK\n%02d" % field_stock.cards.size() if is_instance_valid(field_stock) else "STOCK\n—"

	# Waste и Foundation относятся только к Klondike.
	ui["waste_column"].visible = is_klondike
	ui["foundation_rows"].visible = is_klondike
	var waste: Pile = _find_field_pile(stock, PileMarker.Kind.WASTE)
	var waste_labels: Array = ui["waste"]
	for label in waste_labels:
		_set_card_label(label, null)

	if is_klondike and is_instance_valid(waste):
		var visible_count := mini(3, waste.cards.size())
		var start_index := waste.cards.size() - visible_count
		var first_slot := 3 - visible_count
		for i in range(visible_count):
			var card: Card = waste.cards[start_index + i]
			_set_card_label(waste_labels[first_slot + i], card)

	# Порядок T1..T20 задаётся индексом маркера, а не координатой X.
	var tableau_piles := _get_field_piles(stock, PileMarker.Kind.TABLEAU)
	_sort_tableau_piles(tableau_piles)

	ui["tableau_title"].text = "TABLEAU · %d" % tableau_piles.size()
	_ensure_classic_tableau_slots(ui, tableau_piles.size())

	var containers: Array = ui["tableau_containers"]
	var count_labels: Array = ui["tableau_counts"]
	var cached_labels: Array = ui["tableau_labels"]
	for i in range(tableau_piles.size()):
		_draw_tableau_stack(containers[i], tableau_piles[i], cached_labels[i])
		count_labels[i].text = "%02d" % tableau_piles[i].cards.size()

	var foundation_total: Label = ui["foundation_total"]
	if is_klondike:
		var foundation_piles := _get_field_piles(stock, PileMarker.Kind.FOUNDATION)
		foundation_piles.sort_custom(
			func(a: Pile, b: Pile) -> bool:
				return a.marker_suit < b.marker_suit
		)
		var total_cards := 0
		for i in range(FOUNDATION_COUNT):
			var pile: Pile = foundation_piles[i] if i < foundation_piles.size() else null
			var count := pile.cards.size() if is_instance_valid(pile) else 0
			total_cards += count
			var suit_cards: Array = ui["foundation_cards"][i]
			for rank_index in range(FOUNDATION_CARDS):
				_set_foundation_cell(suit_cards[rank_index], rank_index < count, i, rank_index)
			ui["foundation_counts"][i].text = "%02d/13" % count
		foundation_total.text = "FOUNDATION: %02d/52" % total_cards
	else:
		var sequence_data := _get_spider_sequence_counts(stock)
		var totals: Dictionary = sequence_data["totals"]
		var completed: Dictionary = sequence_data["completed"]
		var completed_total := 0
		var total_sequences := 0
		for suit in range(1, 5):
			completed_total += int(completed[suit])
			total_sequences += int(totals[suit])
		foundation_total.text = "СОБРАНО РЯДОВ: %d / %d" % [completed_total, maxi(1, total_sequences)]

	_apply_slot_statistics(ui, 1 if is_same(ui, player_one_ui) else 2)


func _get_total_spider_sequences(source_stock: Pile) -> int:
	var data := _get_spider_sequence_counts(source_stock)
	var totals: Dictionary = data["totals"]
	var total := 0
	for suit in range(1, 5):
		total += int(totals[suit])
	return maxi(1, total)


func _draw_tableau_stack(container: Control, pile: Pile, labels: Array) -> void:
	for child in container.get_children():
		child.visible = false

	if not is_instance_valid(pile) or pile.cards.is_empty():
		return

	const MAX_VISIBLE_CARDS := 15
	const MAX_BAR_HEIGHT := 15.0
	const MIN_BAR_HEIGHT := 6.0
	const BAR_GAP := 1.0

	var total := pile.cards.size()
	var first_visible := maxi(0, total - MAX_VISIBLE_CARDS)
	var visible_count := total - first_visible
	var show_more := first_visible > 0
	var item_count := visible_count + (1 if show_more else 0)
	var available_height := maxf(container.size.y, container.custom_minimum_size.y)
	var total_gaps := maxf(0.0, float(item_count - 1) * BAR_GAP)
	var bar_height := clampf(
		(available_height - total_gaps) / float(item_count),
		MIN_BAR_HEIGHT,
		MAX_BAR_HEIGHT
	)

	var slot := 0
	if show_more:
		var more_label: Label = labels[slot]
		slot += 1
		var more_tile := more_label.get_parent() as Control
		more_tile.visible = true
		more_tile.custom_minimum_size.y = _s(bar_height)
		more_label.text = "+%d" % first_visible
		more_label.add_theme_color_override("font_color", Color("#86E8CF"))
		var more_style := more_label.get_meta("tile_style") as StyleBoxFlat
		if more_style != null:
			more_style.bg_color = Color("#1F2D3F")

	for i in range(first_visible, total):
		if slot >= labels.size():
			break
		var card: Card = pile.cards[i]
		var card_label: Label = labels[slot]
		slot += 1
		var tile := card_label.get_parent() as Control
		tile.visible = true
		tile.custom_minimum_size.y = _s(bar_height)
		_set_card_label(card_label, card)

		var column_width := maxf(container.size.x, container.custom_minimum_size.x)
		var font_size := 6
		if column_width >= _s(90.0):
			font_size = 10 if bar_height >= 12.0 else 8
		elif column_width >= _s(55.0):
			font_size = 8 if bar_height >= 9.0 else 7
		elif column_width >= _s(34.0):
			font_size = 7
		card_label.add_theme_font_size_override("font_size", _si(font_size))


# ==================================================
# SPIDER PROGRESS — PER-FIELD DATA
# ==================================================
func _get_spider_sequence_counts(source_stock: Pile) -> Dictionary:
	var totals := {1: 0, 2: 0, 3: 0, 4: 0}
	var completed := {1: 0, 2: 0, 3: 0, 4: 0}
	if game_manager == null or not is_instance_valid(source_stock):
		return {"totals": totals, "completed": completed}

	# Считаем только карты текущего поля, иначе в кооперативе каждый игрок
	# увидит общую сумму двух столов.
	var field_vault := _find_field_pile_vault(source_stock)
	for pile in game_manager.piles:
		if not is_instance_valid(pile):
			continue
		if not _same_field(source_stock, pile) and pile != field_vault:
			continue
		for card_variant in pile.cards:
			var card := card_variant as Card
			if is_instance_valid(card):
				var suit := clampi(int(card.suit), 1, 4)
				totals[suit] = int(totals[suit]) + 1

	for suit in range(1, 5):
		totals[suit] = int(int(totals[suit]) / FOUNDATION_CARDS)

	# Vault хранит собранные последовательности блоками по 13 карт.
	if is_instance_valid(field_vault):
		var complete_count := int(field_vault.cards.size() / FOUNDATION_CARDS)
		for sequence_index in range(complete_count):
			var card_index := sequence_index * FOUNDATION_CARDS
			var card: Card = field_vault.cards[card_index]
			if not is_instance_valid(card):
				continue
			var suit := clampi(int(card.suit), 1, 4)
			completed[suit] = int(completed[suit]) + 1

	# Собранные ряды в стопках PileSpiderDone этого поля (по 13 карт на ряд).
	for pile in game_manager.get_piles(PileMarker.Kind.FOUNDATION):
		if not is_instance_valid(pile) or pile is PileVault or not _same_field(source_stock, pile):
			continue
		for sequence_index in range(int(pile.cards.size() / FOUNDATION_CARDS)):
			var done_card: Card = pile.cards[sequence_index * FOUNDATION_CARDS]
			if is_instance_valid(done_card):
				var done_suit := clampi(int(done_card.suit), 1, 4)
				completed[done_suit] = int(completed[done_suit]) + 1

	return {"totals": totals, "completed": completed}


func _update_ring_progress(is_klondike: bool, stock: Pile) -> void:
	var foundation_panel: Control = ring_ui["foundation_panel"]
	var spider_panel: Control = ring_ui["spider_stack_panel"]
	var tableau_grid: Control = ring_ui["tableau_grid"]

	foundation_panel.visible = is_klondike
	spider_panel.visible = not is_klondike

	if is_klondike:
		ring_ui["foundation_heading"].text = "ОСНОВАНИЯ"
		tableau_grid.position = Vector2(_s(164), _s(42))
		tableau_grid.size = Vector2(_s(850), _s(320))
		tableau_grid.custom_minimum_size = tableau_grid.size
		var foundations := _get_field_piles(stock, PileMarker.Kind.FOUNDATION)
		foundations.sort_custom(
			func(a: Pile, b: Pile) -> bool:
				return a.marker_suit < b.marker_suit
		)
		var rows: Array = ring_ui["foundation_rows"]
		for suit_index in range(FOUNDATION_COUNT):
			var row: Dictionary = rows[suit_index]
			var pile: Pile = foundations[suit_index] if suit_index < foundations.size() else null
			var count := pile.cards.size() if is_instance_valid(pile) else 0
			row["root"].visible = true
			row["suit"].text = SUIT_SYMBOLS[suit_index]
			for rank_index in range(FOUNDATION_CARDS):
				_set_foundation_cell(row["cards"][rank_index], rank_index < count, suit_index, rank_index)
			row["count"].text = "%02d/13" % count
		return

	# Spider: отдельная нижняя левая панель, основное поле занимает всю высоту справа.
	tableau_grid.position = Vector2(_s(164), _s(42))
	tableau_grid.size = Vector2(_s(850), _s(460))
	tableau_grid.custom_minimum_size = tableau_grid.size
	var data := _get_spider_sequence_counts(stock)
	var totals: Dictionary = data["totals"]
	var completed: Dictionary = data["completed"]
	var rows: Array = ring_ui["spider_stack_rows"]
	for suit_index in range(FOUNDATION_COUNT):
		var suit := suit_index + 1
		var total := int(totals[suit])
		var done := int(completed[suit])
		var row: Dictionary = rows[suit_index]
		row["root"].visible = total > 0
		row["suit"].text = SUIT_SYMBOLS[suit_index]
		row["count"].text = "%d/%d" % [done, total]
		var progress: ProgressBar = row["progress"]
		progress.max_value = maxf(float(total), 1.0)
		progress.value = clampf(float(done), 0.0, progress.max_value)


func _update_ring_display(stock: Pile, is_klondike: bool) -> void:
	if ring_ui.is_empty() or not is_instance_valid(stock):
		return

	ring_ui["root"].visible = true
	if is_instance_valid(classic_ui_root):
		classic_ui_root.visible = false
	ring_ui["header"].text = "КРУГОВОЙ ПАСЬЯНС · " + ("КЛОНДАЙК" if is_klondike else "ПАУК")

	# Сначала выбираем геометрию режима, затем создаём слоты и рисуем карты.
	_update_ring_progress(is_klondike, stock)
	var tableau_piles := _get_field_piles(stock, PileMarker.Kind.TABLEAU)
	_sort_tableau_piles(tableau_piles)
	var target_grid_height := 320.0 if is_klondike else 460.0
	_ensure_ring_tableau_slots(tableau_piles.size(), target_grid_height)
	for i in range(tableau_piles.size()):
		_draw_ring_tableau(ring_tableau_slots[i], tableau_piles[i], i)

	var stock_label: Label = ring_ui["stock"]
	stock_label.text = "▧ %02d" % stock.cards.size()
	var stock_style := stock_label.get_meta("tile_style") as StyleBoxFlat
	if stock_style != null:
		stock_style.bg_color = Color("#2F5D8F")

	var waste_column: Control = ring_ui["waste_column"]
	waste_column.visible = is_klondike
	var waste_label: Label = ring_ui["waste"]
	var waste := _find_field_pile(stock, PileMarker.Kind.WASTE)
	if is_klondike and is_instance_valid(waste) and not waste.cards.is_empty():
		_set_card_label(waste_label, waste.cards.back())
	else:
		_set_card_label(waste_label, null)

	_update_ring_statistics(
		game_manager.moves_count,
		game_manager.undo_count,
		mini(game_manager.history.size(), game_manager.undo_charges)
	)
	_update_time_label()


func _update_ring_statistics(moves: int, undos: int, available: int) -> void:
	if ring_ui.is_empty():
		return
	ring_ui["moves"].text = "ХОДЫ %03d" % moves
	ring_ui["undos"].text = "ОТМЕНЫ %03d" % undos
	ring_ui["available"].text = "UNDO %02d" % available


# ==================================================
# PLAYER 1 / PLAYER 2 ROUTING
# ==================================================
func _update_player_two_placeholder(
	status_text: String = "НЕ ПОДКЛЮЧЕНО"
) -> void:
	if player_two_ui.is_empty():
		return

	player_two_ui["title"].text = "PLAYER 2"
	player_two_ui["status"].text = status_text
	player_two_ui["panel"].modulate = Color(0.55, 0.60, 0.58, 1.0)
	player_two_stock = null

	player_two_ui["waste_column"].visible = false
	player_two_ui["foundation_rows"].visible = false
	for label in player_two_ui["waste"]:
		_set_card_label(label, null)
	for container in player_two_ui["tableau_containers"]:
		for child in container.get_children():
			child.visible = false
	for label in player_two_ui["tableau_counts"]:
		label.text = "--"
	player_two_ui["tableau_title"].text = "TABLEAU"
	player_two_ui["foundation_total"].text = "ОЖИДАНИЕ ДАННЫХ"

	var card_rows: Array = player_two_ui["foundation_cards"]
	for i in range(FOUNDATION_COUNT):
		var suit_cards: Array = card_rows[i]
		for rank_index in range(FOUNDATION_CARDS):
			_set_foundation_cell(suit_cards[rank_index], false, i, rank_index)
		player_two_ui["foundation_counts"][i].text = "00/13"
	var stats: Dictionary = player_two_ui["stats"]
	stats["moves"].text = "ХОДЫ —"
	stats["undos"].text = "ОТМЕНЫ —"
	stats["available"].text = "UNDO —"
	player_two_ui["score_label"].text = "P2: —"


func _update_time_label() -> void:
	if player_one_ui.is_empty():
		return

	var total_seconds := floori(elapsed_time)
	var minutes := int(total_seconds / 60)
	var seconds := total_seconds % 60
	var time_text := "ВРЕМЯ: %02d:%02d" % [minutes, seconds]
	player_one_ui["time_label"].text = time_text

	var penalty := floori(elapsed_time / maxf(score_loss_interval, 0.1))
	current_score_p1 = maxi(0, STARTING_SCORE - penalty)
	player_one_ui["score_label"].visible = display_mode != DisplayMode.RING
	player_two_ui["score_label"].visible = display_mode == DisplayMode.MULTIPLAYER

	if display_mode == DisplayMode.MULTIPLAYER:
		# Очки зависят только от общего времени партии — у обоих одно правило.
		player_one_ui["score_label"].text = "P1: %02d" % current_score_p1
		player_two_ui["score_label"].text = "P2: %02d" % current_score_p1
	else:
		player_one_ui["score_label"].text = "ОЧКИ: %02d" % current_score_p1

	if not ring_ui.is_empty():
		ring_ui["time"].text = "ВРЕМЯ %02d:%02d" % [minutes, seconds]
		ring_ui["score"].text = "%02d" % current_score_p1


# ==================================================
# SCREEN MATERIAL
# ==================================================
func _setup_screen_material() -> void:
	if screen_model == null:
		push_warning("Screens: не назначена модель экрана.")
		return

	screen_material = ShaderMaterial.new()
	screen_material.shader = SCREEN_SHADER
	screen_material.set_shader_parameter("screen_texture", screen_viewport.get_texture())
	screen_material.set_shader_parameter("emission_energy", emission_energy)
	screen_material.set_shader_parameter("rotate_clockwise", rotate_clockwise)

	var applied := _apply_screen_material(screen_model, screen_surface_index, screen_material)
	if applied == 0:
		push_warning("Screens: не удалось назначить материал. Проверь модель и индекс поверхности.")
	else:
		print("Screens: материал назначен. Мешей: ", applied)


func _apply_screen_material(node: Node, surface_index: int, material: Material) -> int:
	var applied := 0
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh != null and surface_index < mesh_instance.mesh.get_surface_count():
			mesh_instance.set_surface_override_material(surface_index, material)
			applied += 1

	for child in node.get_children():
		applied += _apply_screen_material(child, surface_index, material)
	return applied

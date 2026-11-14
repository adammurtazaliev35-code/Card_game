extends CanvasLayer
class_name NetworkMatchSigns

## Replace the old Node3D/Marker3D setup with a CanvasLayer using this script.
## The compact player list is shown in the top-right corner only during a network match.

const HOST_COLOR := Color("#E8C36A")
const GUEST_COLOR := Color("#63D6C2")
const PANEL_COLOR := Color("#171B1A")
const BORDER_COLOR := Color("#8A7448")
const TEXT_COLOR := Color("#F3E6C8")

var _panel: PanelContainer
var _name_labels: Array[Label] = []
var _role_labels: Array[Label] = []
var _voice_labels: Array[Label] = []
var _voice_active: Array[bool] = [false, false]
var _voice_phase := 0.0


func _ready() -> void:
	layer = 80
	add_to_group("network_match_signs")
	_build_panel()
	_refresh_panel()
	if not GDSync.disconnected.is_connected(_on_disconnected):
		GDSync.disconnected.connect(_on_disconnected)
	if not GDSync.client_left.is_connected(_on_client_left):
		GDSync.client_left.connect(_on_client_left)


func _process(delta: float) -> void:
	var should_show := NetworkMatchState.active and GDSync.is_active()
	if _panel.visible != should_show:
		_panel.visible = should_show
	if not should_show:
		return

	_refresh_panel()
	_voice_phase += delta * 6.0
	for i in range(_voice_labels.size()):
		var label := _voice_labels[i]
		label.visible = _voice_active[i]
		if _voice_active[i]:
			var pulse := 0.5 + 0.5 * sin(_voice_phase)
			label.modulate.a = 0.55 + pulse * 0.45
		else:
			label.modulate.a = 1.0


func _build_panel() -> void:
	var root := Control.new()
	root.name = "NetworkPlayersOverlay"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_panel = PanelContainer.new()
	_panel.name = "PlayersPanel"
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 0.0
	_panel.offset_left = -350.0
	_panel.offset_right = -18.0
	_panel.offset_top = 18.0
	_panel.offset_bottom = 112.0
	_panel.add_theme_stylebox_override("panel", _panel_style())
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	_panel.add_child(margin)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 7)
	margin.add_child(rows)

	var title := Label.new()
	title.text = "ИГРОКИ"
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", Color("#BDAA82"))
	rows.add_child(title)

	for i in range(2):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		rows.add_child(row)
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(8, 8)
		dot.color = HOST_COLOR if i == 0 else GUEST_COLOR
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(dot)
		var name_label := Label.new()
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.add_theme_font_size_override("font_size", 15)
		name_label.add_theme_color_override("font_color", TEXT_COLOR)
		row.add_child(name_label)
		var voice_label := Label.new()
		voice_label.text = "● В ЭФИРЕ"
		voice_label.visible = false
		voice_label.add_theme_font_size_override("font_size", 10)
		voice_label.add_theme_color_override("font_color", Color("#35C991"))
		row.add_child(voice_label)

		var role_label := Label.new()
		role_label.add_theme_font_size_override("font_size", 10)
		role_label.add_theme_color_override("font_color", Color("#BDAA82"))
		row.add_child(role_label)
		_name_labels.append(name_label)
		_voice_labels.append(voice_label)
		_role_labels.append(role_label)

	_panel.visible = false


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_COLOR
	style.bg_color.a = 0.94
	style.border_color = BORDER_COLOR
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	return style


func set_voice_activity(slot: int, speaking: bool) -> void:
	if slot not in [1, 2]:
		return
	var index := slot - 1
	_voice_active[index] = speaking
	if index < _voice_labels.size():
		_voice_labels[index].visible = speaking
		if not speaking:
			_voice_labels[index].modulate.a = 1.0


func _refresh_panel() -> void:
	var names := [NetworkMatchState.player_one_name, NetworkMatchState.player_two_name]
	var ids := [NetworkMatchState.player_one_id, NetworkMatchState.player_two_id]
	var local_id := int(GDSync.get_client_id()) if GDSync.is_active() else -1
	for i in range(2):
		var player_name := str(names[i]).strip_edges()
		if player_name.is_empty():
			player_name = "Игрок %d" % (i + 1)
		_name_labels[i].text = player_name
		_role_labels[i].text = "ВЫ" if int(ids[i]) == local_id else ("ХОСТ" if i == 0 else "ГОСТЬ")


func _on_client_left(client_id: int) -> void:
	if client_id == NetworkMatchState.player_one_id or client_id == NetworkMatchState.player_two_id:
		set_voice_activity(1, false)
		set_voice_activity(2, false)
		NetworkMatchState.active = false
		_panel.visible = false


func _on_disconnected() -> void:
	set_voice_activity(1, false)
	set_voice_activity(2, false)
	NetworkMatchState.active = false
	NetworkMatchState.player_one_name = "Игрок 1"
	NetworkMatchState.player_two_name = "Игрок 2"
	NetworkMatchState.player_one_id = -1
	NetworkMatchState.player_two_id = -1
	_panel.visible = false

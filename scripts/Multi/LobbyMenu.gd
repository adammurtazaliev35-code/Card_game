extends CanvasLayer
class_name LobbyMenu

## Attach this CanvasLayer script to the existing 3D lobby scene.
## The CanvasLayer and this script must have the same NodePath on every client,
## because GD-Sync remote calls resolve Nodes by their scene-tree paths.

const MODE_SPIDER := 1
const MODE_KLONDIKE := 2
const MAX_PLAYERS := 2
const GAME_TAG := "CardSolitaire"

# Все цвета интерфейса берутся из активной палитры GameSettings.

@export_file("*.tscn") var main_menu_scene_path := "res://scenes/MainMenu.tscn"
@export var start_only_with_two_players := true

var _selected_mode: int = MODE_SPIDER
var _selected_layout: int = GameSession.BOARD_LAYOUT_MIRRORED
var _selected_draw_mode: int = GameSession.DRAW_ONE
var _mode_selector: OptionButton
var _layout_selector: OptionButton
var _draw_selector: OptionButton
var _config_hint: Label
## Опции раздачи сетевого зеркального Клондайка (независимые)
var _deal_same_deck := false
var _deal_winnable := true
var _deal_same_layout := false
var _deal_options_box: VBoxContainer
var _same_deck_toggle: CheckButton
var _winnable_toggle: CheckButton
var _same_layout_toggle: CheckButton
var _generating_deal := false

var _root: Control
var _lobby_panel: PanelContainer
var _status_label: Label
var _name_input: LineEdit
var _create_room_input: LineEdit
var _create_password_input: LineEdit
var _public_toggle: CheckButton
var _join_room_input: LineEdit
var _join_password_input: LineEdit
var _lobby_list: VBoxContainer
var _room_panel: PanelContainer
var _room_title: Label
var _room_code_label: Label
var _player_labels: Array[Label] = []
var _start_button: Button
var _leave_button: Button

var _connected := false
var _in_lobby := false
## Подключение: интернет-серверы GD-Sync или локальная сеть (LAN, без серверов).
var _use_lan := false
var _net_mode_selector: OptionButton
var _reconnect_button: Button
var _host_ip_input: LineEdit
## Самый дальний этап подключения, до которого дошли (для понятной причины сбоя).
var _connect_stage := 0
var _auto_retries_left := 2
const AUTO_RETRIES := 2
var _pending_password := ""
var _current_lobby_name := ""
## Имена комнат, созданных этим клиентом в текущем запуске. Не показываем их в поиске,
## даже если сервер ещё некоторое время возвращает устаревшую запись.
var _created_lobby_names: Dictionary = {}
var _local_player_name := "Игрок"
var _local_player_color := GameSettings.get_color("gold")
var _room_players: Dictionary = {} # client_id -> {"name": String, "color": Color}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	GameSettings.ensure_loaded()
	_local_player_color = _host_color()
	_init_lobby_settings()
	_build_interface()
	GameSettings.apply_palette_tree(self)
	call_deferred("_update_panel_geometry")
	_connect_gdsync_signals()

	# Register only the small functions that are needed for lobby roster/config sync.
	GDSync.expose_func(_receive_roster_entry)
	GDSync.expose_func(_receive_lobby_configuration)
	GDSync.expose_func(_apply_network_match_settings)

	# is_active() alone is not enough after returning from a lobby: GD-Sync can
	# still report an active transport while its local client entry is already gone.
	# In that state get_client_id() is -1 and player_set_username() crashes inside
	# SessionController.set_player_data(). Restart the connection instead.
	var local_client_id: int = int(GDSync.get_client_id()) if GDSync.is_active() else -1
	if GDSync.is_active() and local_client_id >= 0:
		_on_gdsync_connected()
	else:
		_start_connection()


func _process(_delta: float) -> void:
	if _connected:
		return
	# Запоминаем, до какого этапа дошло подключение: по нему объясняем причину сбоя.
	var status := int(GDSync._connection_controller.status)
	if status > _connect_stage:
		_connect_stage = status


## Подключение к GD-Sync: интернет или локальная сеть.
func _start_connection() -> void:
	_connected = false
	_connect_stage = 0
	if _reconnect_button != null:
		_reconnect_button.visible = false
	if GDSync.is_active() or int(GDSync._connection_controller.status) != ENUMS.CONNECTION_STATUS.DISABLED:
		GDSync.stop_multiplayer()
	if _use_lan:
		_set_status("Запуск локальной сети (LAN)…")
		GDSync.start_local_multiplayer()
	else:
		_set_status("Подключение к серверам GD-Sync…")
		GDSync.start_multiplayer()


func _on_reconnect_pressed() -> void:
	_auto_retries_left = AUTO_RETRIES
	_start_connection()


func _on_net_mode_selected(index: int) -> void:
	var lan := _net_mode_selector.get_item_id(index) == 1
	if lan == _use_lan:
		return
	if _in_lobby:
		_leave_room()
	_use_lan = lan
	if _host_ip_input != null:
		_host_ip_input.visible = lan
	_auto_retries_left = AUTO_RETRIES
	_start_connection()


func _connect_gdsync_signals() -> void:
	if not GDSync.connected.is_connected(_on_gdsync_connected):
		GDSync.connected.connect(_on_gdsync_connected)
	if not GDSync.connection_failed.is_connected(_on_connection_failed):
		GDSync.connection_failed.connect(_on_connection_failed)
	if not GDSync.disconnected.is_connected(_on_disconnected):
		GDSync.disconnected.connect(_on_disconnected)
	if not GDSync.lobby_created.is_connected(_on_lobby_created):
		GDSync.lobby_created.connect(_on_lobby_created)
	if not GDSync.lobby_creation_failed.is_connected(_on_lobby_creation_failed):
		GDSync.lobby_creation_failed.connect(_on_lobby_creation_failed)
	if not GDSync.lobby_joined.is_connected(_on_lobby_joined):
		GDSync.lobby_joined.connect(_on_lobby_joined)
	if not GDSync.lobby_join_failed.is_connected(_on_lobby_join_failed):
		GDSync.lobby_join_failed.connect(_on_lobby_join_failed)
	if not GDSync.lobbies_received.is_connected(_on_lobbies_received):
		GDSync.lobbies_received.connect(_on_lobbies_received)
	if not GDSync.client_joined.is_connected(_on_client_joined):
		GDSync.client_joined.connect(_on_client_joined)
	if not GDSync.client_left.is_connected(_on_client_left):
		GDSync.client_left.connect(_on_client_left)
	if not GDSync.player_data_changed.is_connected(_on_player_data_changed):
		GDSync.player_data_changed.connect(_on_player_data_changed)
	if not GDSync.kicked.is_connected(_on_kicked):
		GDSync.kicked.connect(_on_kicked)


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "LobbyOverlay"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_lobby_panel = PanelContainer.new()
	_lobby_panel.name = "LobbyPanel"
	_lobby_panel.add_theme_stylebox_override("panel", _style_box(GameSettings.get_color("background"), GameSettings.get_color("border"), 14))
	_lobby_panel.custom_minimum_size.x = 560.0
	_root.add_child(_lobby_panel)
	_root.resized.connect(_update_panel_geometry)
	var panel := _lobby_panel

	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 9)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(content)

	var title := _make_label("СЕТЕВАЯ ИГРА", 22, GameSettings.get_color("gold"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(title)
	_status_label = _make_label("Подключение к GD-Sync…", 12, GameSettings.get_color("muted"))
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.custom_minimum_size.y = 30
	content.add_child(_status_label)

	var net_row := HBoxContainer.new()
	net_row.add_theme_constant_override("separation", 6)
	content.add_child(net_row)
	_net_mode_selector = OptionButton.new()
	_net_mode_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_net_mode_selector.add_item("Интернет (серверы GD-Sync)", 0)
	_net_mode_selector.add_item("Локальная сеть (LAN)", 1)
	_net_mode_selector.tooltip_text = "LAN: оба компьютера в одной сети или в общей виртуальной сети (Radmin VPN, ZeroTier). Серверы GD-Sync не нужны."
	_net_mode_selector.item_selected.connect(_on_net_mode_selected)
	net_row.add_child(_net_mode_selector)
	_reconnect_button = _make_button("Переподключиться")
	_reconnect_button.visible = false
	_reconnect_button.pressed.connect(_on_reconnect_pressed)
	net_row.add_child(_reconnect_button)
	content.add_child(HSeparator.new())

	content.add_child(_make_label("ИМЯ ИГРОКА", 12, GameSettings.get_color("gold")))
	var name_row := HBoxContainer.new()
	content.add_child(name_row)
	_name_input = LineEdit.new()
	_name_input.placeholder_text = "Ваше имя"
	_name_input.text = _default_player_name()
	_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(_name_input)
	var name_apply := _make_button("ОК")
	name_apply.custom_minimum_size.x = 54
	name_apply.pressed.connect(_apply_player_name)
	name_row.add_child(name_apply)

	# Вкладки: «Настройки режима» (открыта по умолчанию) и «Комната».
	var tabs := TabContainer.new()
	tabs.name = "LobbyTabs"
	tabs.custom_minimum_size = Vector2(0, 360)
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_theme_color_override("font_selected_color", GameSettings.get_color("gold"))
	tabs.add_theme_color_override("font_unselected_color", GameSettings.get_color("muted"))
	tabs.add_theme_stylebox_override("tab_selected", _style_box(GameSettings.get_color("panel_alt"), GameSettings.get_color("gold"), 7))
	tabs.add_theme_stylebox_override("tab_unselected", _style_box(GameSettings.get_color("button"), GameSettings.get_color("border_soft"), 7))
	tabs.add_theme_stylebox_override("tab_hovered", _style_box(GameSettings.get_color("accent_hover"), GameSettings.get_color("gold"), 7))
	tabs.add_theme_stylebox_override("tab_disabled", _style_box(GameSettings.get_color("button_disabled"), GameSettings.get_color("border_dim"), 7))
	tabs.tab_alignment = TabBar.ALIGNMENT_CENTER
	content.add_child(tabs)
	var settings_tab := VBoxContainer.new()
	settings_tab.name = "Настройки режима"
	settings_tab.add_theme_constant_override("separation", 7)
	settings_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.add_child(settings_tab)
	var room_tab := VBoxContainer.new()
	room_tab.name = "Комната"
	room_tab.add_theme_constant_override("separation", 7)
	room_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.add_child(room_tab)
	tabs.current_tab = 0

	settings_tab.add_child(HSeparator.new())
	settings_tab.add_child(_make_label("РЕЖИМ ПАРТИИ", 12, GameSettings.get_color("gold")))
	_mode_selector = OptionButton.new()
	_mode_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_selector.add_item("Паук", MODE_SPIDER)
	_mode_selector.add_item("Клондайк", MODE_KLONDIKE)
	_mode_selector.item_selected.connect(_on_mode_selected)
	settings_tab.add_child(_mode_selector)

	settings_tab.add_child(_make_label("РАСКЛАДКА ДЛЯ ДВУХ ИГРОКОВ", 12, GameSettings.get_color("gold")))
	_layout_selector = OptionButton.new()
	_layout_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_layout_selector.add_item("Зеркальная · два поля", GameSession.BOARD_LAYOUT_MIRRORED)
	_layout_selector.add_item("Кольцевая", GameSession.BOARD_LAYOUT_RING)
	_layout_selector.add_item("Классическая · один игрок", GameSession.BOARD_LAYOUT_CLASSIC)
	_layout_selector.set_item_disabled(2, true)
	_layout_selector.item_selected.connect(_on_layout_selected)
	settings_tab.add_child(_layout_selector)

	settings_tab.add_child(_make_label("ДОБОР КАРТ · КЛОНДАЙК", 12, GameSettings.get_color("gold")))
	_draw_selector = OptionButton.new()
	_draw_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_draw_selector.add_item(str(GameSession.DRAW_NAMES[GameSession.DRAW_ONE]), GameSession.DRAW_ONE)
	_draw_selector.add_item(str(GameSession.DRAW_NAMES[GameSession.DRAW_THREE]), GameSession.DRAW_THREE)
	_draw_selector.item_selected.connect(_on_draw_selected)
	settings_tab.add_child(_draw_selector)

	# Условия раздачи (Клондайк, два поля). Опции не связаны между собой.
	_deal_options_box = VBoxContainer.new()
	settings_tab.add_child(_deal_options_box)
	_deal_options_box.add_child(_make_label("РАЗДАЧА · КЛОНДАЙК", 12, GameSettings.get_color("gold")))
	_same_deck_toggle = _make_toggle("Одинаковая колода", _deal_same_deck)
	_winnable_toggle = _make_toggle("Выигрышная колода", _deal_winnable)
	_same_layout_toggle = _make_toggle("Одинаковая раскидка", _deal_same_layout)
	for toggle in [_same_deck_toggle, _winnable_toggle, _same_layout_toggle]:
		toggle.toggled.connect(func(_on: bool): _on_deal_option_changed())
		_deal_options_box.add_child(toggle)
	_config_hint = _make_label("В сетевой партии классическая раскладка недоступна: нужны две игровые стороны.", 11, GameSettings.get_color("muted"))
	settings_tab.add_child(_config_hint)

	room_tab.add_child(HSeparator.new())
	room_tab.add_child(_make_label("СОЗДАТЬ КОМНАТУ", 12, GameSettings.get_color("gold")))
	_create_room_input = LineEdit.new()
	_create_room_input.placeholder_text = "Название / код комнаты"
	_create_room_input.text = _generate_room_code()
	_create_room_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room_tab.add_child(_create_room_input)
	_create_password_input = LineEdit.new()
	_create_password_input.placeholder_text = "Пароль (необязательно)"
	_create_password_input.secret = true
	_create_password_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room_tab.add_child(_create_password_input)
	_public_toggle = CheckButton.new()
	_public_toggle.text = "Показывать комнату в списке"
	_public_toggle.button_pressed = true
	_public_toggle.add_theme_color_override("font_color", GameSettings.get_color("text"))
	room_tab.add_child(_public_toggle)
	var create_button := _make_button("Создать комнату")
	create_button.pressed.connect(_create_room)
	room_tab.add_child(create_button)

	room_tab.add_child(HSeparator.new())
	room_tab.add_child(_make_label("ПРИСОЕДИНИТЬСЯ", 12, GameSettings.get_color("gold")))
	_join_room_input = LineEdit.new()
	_join_room_input.placeholder_text = "Код комнаты"
	_join_room_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room_tab.add_child(_join_room_input)
	_join_password_input = LineEdit.new()
	_join_password_input.placeholder_text = "Пароль комнаты"
	_join_password_input.secret = true
	_join_password_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room_tab.add_child(_join_password_input)
	# LAN через Tailscale/VPN: широковещательный поиск там не работает — подключаемся по IP.
	_host_ip_input = LineEdit.new()
	_host_ip_input.placeholder_text = "IP хоста (LAN через Tailscale/VPN), напр. 100.64.0.5"
	_host_ip_input.visible = false
	room_tab.add_child(_host_ip_input)
	var join_row := HBoxContainer.new()
	room_tab.add_child(join_row)
	var join_button := _make_button("Войти по коду")
	join_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join_button.pressed.connect(_join_room_by_code)
	join_row.add_child(join_button)
	var refresh_button := _make_button("Обновить")
	refresh_button.custom_minimum_size.x = 92
	refresh_button.pressed.connect(_refresh_public_lobbies)
	join_row.add_child(refresh_button)

	room_tab.add_child(_make_label("ОТКРЫТЫЕ КОМНАТЫ", 11, GameSettings.get_color("gold")))
	var list_scroll := ScrollContainer.new()
	list_scroll.custom_minimum_size = Vector2(0, 70)
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	room_tab.add_child(list_scroll)
	_lobby_list = VBoxContainer.new()
	_lobby_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_scroll.add_child(_lobby_list)

	content.add_child(HSeparator.new())
	_room_panel = PanelContainer.new()
	_room_panel.name = "JoinedRoomPanel"
	_room_panel.add_theme_stylebox_override("panel", _style_box(GameSettings.get_color("panel_alt"), GameSettings.get_color("border_soft"), 10))
	_room_panel.visible = false
	_room_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(_room_panel)
	var room_margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		room_margin.add_theme_constant_override("margin_" + side, 9)
	room_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_room_panel.add_child(room_margin)
	var room_content := VBoxContainer.new()
	room_content.add_theme_constant_override("separation", 6)
	room_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room_margin.add_child(room_content)
	_room_title = _make_label("КОМНАТА", 16, GameSettings.get_color("gold"))
	_room_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	room_content.add_child(_room_title)
	_room_code_label = _make_label("Код: —", 12, GameSettings.get_color("text"))
	_room_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	room_content.add_child(_room_code_label)
	var copy_button := _make_button("Скопировать код")
	copy_button.pressed.connect(_copy_room_code)
	room_content.add_child(copy_button)

	var slots := HBoxContainer.new()
	slots.add_theme_constant_override("separation", 6)
	room_content.add_child(slots)
	_player_labels.clear()
	for i in range(MAX_PLAYERS):
		var slot := PanelContainer.new()
		slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slot.add_theme_stylebox_override("panel", _style_box(GameSettings.get_color("panel"), GameSettings.get_color("border_soft"), 7))
		slots.add_child(slot)
		var label := _make_label("Игрок %d\nОжидание…" % (i + 1), 12, GameSettings.get_color("text"))
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.custom_minimum_size = Vector2(0, 42)
		slot.add_child(label)
		_player_labels.append(label)

	var room_buttons := HBoxContainer.new()
	room_content.add_child(room_buttons)
	_start_button = _make_button("НАЧАТЬ")
	_start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start_button.disabled = true
	_start_button.pressed.connect(_start_network_game)
	room_buttons.add_child(_start_button)
	_leave_button = _make_button("Выйти")
	_leave_button.pressed.connect(_leave_room)
	room_buttons.add_child(_leave_button)

	content.add_child(HSeparator.new())
	var back_button := _make_button("← В главное меню")
	back_button.pressed.connect(_return_to_main_menu)
	content.add_child(back_button)
	_update_config_ui()
	for selector in [_net_mode_selector, _mode_selector, _layout_selector, _draw_selector]:
		GameSettings.apply_option_button_palette(selector)
	GameSettings.apply_palette_tree(self)


func _update_panel_geometry() -> void:
	if not is_instance_valid(_root) or not is_instance_valid(_lobby_panel):
		return
	var view_size := get_viewport().get_visible_rect().size
	var max_width := maxf(1.0, view_size.x - 24.0)
	var max_height := maxf(1.0, view_size.y - 24.0)
	# Wider lobby: keep it visually balanced on desktop and let inner controls fill it.
	var width := minf(900.0, minf(max_width, maxf(560.0, view_size.x * 0.82)))
	var height := minf(740.0, minf(max_height, maxf(420.0, view_size.y * 0.90)))
	_lobby_panel.position = Vector2((view_size.x - width) * 0.5, (view_size.y - height) * 0.5)
	_lobby_panel.size = Vector2(width, height)


func _host_color() -> Color:
	return GameSettings.get_color("gold")


func _guest_color() -> Color:
	return GameSettings.get_color("focus")


func _init_lobby_settings() -> void:
	if GameSession.mode == MODE_SPIDER or GameSession.mode == MODE_KLONDIKE:
		_selected_mode = GameSession.mode
	else:
		_selected_mode = MODE_SPIDER
	_selected_layout = int(GameSession.get_board_layout(_selected_mode))
	if _selected_layout == GameSession.BOARD_LAYOUT_CLASSIC:
		_selected_layout = GameSession.BOARD_LAYOUT_MIRRORED
	_selected_draw_mode = int(GameSession.effective_draw_mode())


func _on_mode_selected(index: int) -> void:
	_selected_mode = int(_mode_selector.get_item_id(index))
	GameSession.mode = _selected_mode
	if _selected_mode == MODE_SPIDER:
		_selected_layout = int(GameSession.spider_board_layout)
	else:
		_selected_layout = int(GameSession.klondike_board_layout)
	if _selected_layout == GameSession.BOARD_LAYOUT_CLASSIC:
		_selected_layout = GameSession.BOARD_LAYOUT_MIRRORED
	_apply_selected_layout()
	_update_config_ui()
	_publish_lobby_configuration()


func _on_layout_selected(index: int) -> void:
	_selected_layout = int(_layout_selector.get_item_id(index))
	if _selected_layout == GameSession.BOARD_LAYOUT_CLASSIC:
		_selected_layout = GameSession.BOARD_LAYOUT_MIRRORED
	_apply_selected_layout()
	_update_config_ui()
	_publish_lobby_configuration()


func _on_draw_selected(index: int) -> void:
	_selected_draw_mode = int(_draw_selector.get_item_id(index))
	GameSession.draw_mode = _selected_draw_mode
	_publish_lobby_configuration()


func _apply_selected_layout() -> void:
	GameSession.mode = _selected_mode
	if _selected_mode == MODE_SPIDER:
		GameSession.spider_board_layout = _selected_layout
	else:
		GameSession.klondike_board_layout = _selected_layout


func _update_config_ui() -> void:
	if _mode_selector == null or _layout_selector == null or _draw_selector == null:
		return
	var mode_index := _mode_selector.get_item_index(_selected_mode)
	if mode_index >= 0:
		_mode_selector.select(mode_index)
	var layout_index := _layout_selector.get_item_index(_selected_layout)
	if layout_index < 0 or _selected_layout == GameSession.BOARD_LAYOUT_CLASSIC:
		_selected_layout = GameSession.BOARD_LAYOUT_MIRRORED
		_apply_selected_layout()
		layout_index = _layout_selector.get_item_index(_selected_layout)
	if layout_index >= 0:
		_layout_selector.select(layout_index)
	var draw_index := _draw_selector.get_item_index(_selected_draw_mode)
	if draw_index >= 0:
		_draw_selector.select(draw_index)
	var is_klondike := _selected_mode == MODE_KLONDIKE
	_draw_selector.visible = is_klondike
	if _deal_options_box != null:
		_deal_options_box.visible = is_klondike and _selected_layout == GameSession.BOARD_LAYOUT_MIRRORED
		_same_deck_toggle.set_pressed_no_signal(_deal_same_deck)
		_winnable_toggle.set_pressed_no_signal(_deal_winnable)
		_same_layout_toggle.set_pressed_no_signal(_deal_same_layout)
	if _config_hint != null:
		_config_hint.text = (
			"Клондайк: добор по 1 или 3 карты. Классическая раскладка недоступна для двух игроков."
			if is_klondike
			else "Паук: выбери зеркальную или кольцевую раскладку. Классическая раскладка недоступна для двух игроков."
		)
	var can_edit := not _in_lobby or GDSync.is_host()
	_mode_selector.disabled = not can_edit
	_layout_selector.disabled = not can_edit
	_draw_selector.disabled = not can_edit
	if _deal_options_box != null:
		for toggle in [_same_deck_toggle, _winnable_toggle, _same_layout_toggle]:
			toggle.disabled = not can_edit


func _publish_lobby_configuration() -> void:
	if not _in_lobby or not GDSync.is_host():
		return
	GDSync.lobby_set_data("Mode", _selected_mode)
	GDSync.lobby_set_data("Layout", _selected_layout)
	GDSync.lobby_set_data("DrawMode", _selected_draw_mode)
	GDSync.lobby_set_data("DealOptions", _deal_options_mask())
	GDSync.call_func_all(_receive_lobby_configuration, _selected_mode, _selected_layout, _selected_draw_mode, _deal_options_mask())
	_room_title.text = "КОМНАТА · %s" % _selected_mode_name()


## Опции раздачи одним числом: 1 — одинаковая колода, 2 — выигрышная, 4 — одинаковая раскидка.
func _deal_options_mask() -> int:
	return (1 if _deal_same_deck else 0) | (2 if _deal_winnable else 0) | (4 if _deal_same_layout else 0)


func _receive_lobby_configuration(mode_id: int, layout_id: int, draw_mode: int, deal_options: int = -1) -> void:
	if mode_id not in [MODE_SPIDER, MODE_KLONDIKE]:
		return
	if deal_options >= 0:
		_deal_same_deck = (deal_options & 1) != 0
		_deal_winnable = (deal_options & 2) != 0
		_deal_same_layout = (deal_options & 4) != 0
	if layout_id == GameSession.BOARD_LAYOUT_CLASSIC:
		layout_id = GameSession.BOARD_LAYOUT_MIRRORED
	_selected_mode = mode_id
	_selected_layout = layout_id
	_selected_draw_mode = draw_mode if draw_mode in [GameSession.DRAW_ONE, GameSession.DRAW_THREE] else GameSession.DRAW_ONE
	GameSession.mode = _selected_mode
	GameSession.draw_mode = _selected_draw_mode
	_apply_selected_layout()
	_update_config_ui()
	if is_instance_valid(_room_title):
		_room_title.text = "КОМНАТА · %s" % _selected_mode_name()


func _selected_mode_name() -> String:
	return "КЛОНДАЙК" if _selected_mode == MODE_KLONDIKE else "ПАУК"


func _read_lobby_configuration() -> void:
	var mode_value: Variant = GDSync.lobby_get_data("Mode", _selected_mode)
	var layout_value: Variant = GDSync.lobby_get_data("Layout", _selected_layout)
	var draw_value: Variant = GDSync.lobby_get_data("DrawMode", _selected_draw_mode)
	var deal_value: Variant = GDSync.lobby_get_data("DealOptions", _deal_options_mask())
	_receive_lobby_configuration(int(mode_value), int(layout_value), int(draw_value), int(deal_value))


func _make_subpanel(heading: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style_box(GameSettings.get_color("panel"), GameSettings.get_color("border_soft"), 12))
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	panel.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 9)
	margin.add_child(content)
	var label := _make_label(heading, 17, GameSettings.get_color("gold"))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(label)
	return panel


func _make_label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _make_toggle(value: String, pressed: bool) -> CheckButton:
	var toggle := CheckButton.new()
	toggle.text = value
	toggle.button_pressed = pressed
	toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toggle.add_theme_color_override("font_color", GameSettings.get_color("text"))
	return toggle


func _on_deal_option_changed() -> void:
	_deal_same_deck = _same_deck_toggle.button_pressed
	_deal_winnable = _winnable_toggle.button_pressed
	_deal_same_layout = _same_layout_toggle.button_pressed
	_publish_lobby_configuration()


func _make_button(value: String) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size = Vector2(0, 42)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 16)
	button.add_theme_color_override("font_color", GameSettings.get_color("text"))
	button.add_theme_color_override("font_hover_color", GameSettings.get_color("text"))
	button.add_theme_stylebox_override("normal", _style_box(GameSettings.get_color("button"), GameSettings.get_color("border"), 8))
	button.add_theme_stylebox_override("hover", _style_box(GameSettings.get_color("accent_hover"), GameSettings.get_color("gold"), 8))
	button.add_theme_stylebox_override("pressed", _style_box(GameSettings.get_color("button_pressed"), GameSettings.get_color("gold"), 8))
	button.add_theme_stylebox_override("disabled", _style_box(GameSettings.get_color("button_disabled"), GameSettings.get_color("border_dim"), 8))
	return button


func _style_box(bg: Color, border: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(bg.r, bg.g, bg.b, 1.0)
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	return style


func _default_player_name() -> String:
	var os_name := OS.get_environment("USERNAME").strip_edges()
	if os_name.is_empty():
		os_name = OS.get_environment("USER").strip_edges()
	return os_name if not os_name.is_empty() else "Игрок"


func _generate_room_code() -> String:
	return "Solitaire-%06d" % randi_range(100000, 999999)


func _apply_player_name() -> void:
	_local_player_name = _name_input.text.strip_edges()
	if _local_player_name.is_empty():
		_local_player_name = "Игрок"
		_name_input.text = _local_player_name
	var local_id: int = int(GDSync.get_client_id()) if GDSync.is_active() else -1
	# Never write player data until GD-Sync has assigned a valid client ID.
	if local_id >= 0:
		GDSync.player_set_username(_local_player_name)
		GDSync.player_set_data("PlayerColor", _local_player_color)
	if _in_lobby and local_id >= 0:
		_room_players[local_id] = {"name": _local_player_name, "color": _local_player_color}
		_refresh_room_ui()


func _on_gdsync_connected() -> void:
	# A stale/partially reset GD-Sync state can emit or imitate readiness while
	# the local client is not registered. Do not touch player data in that state.
	if int(GDSync.get_client_id()) < 0:
		_connected = false
		_set_status("GD-Sync подключается… ожидается назначение ID клиента.")
		return
	_connected = true
	_auto_retries_left = AUTO_RETRIES
	if _reconnect_button != null:
		_reconnect_button.visible = false
	_local_player_color = _host_color() if GDSync.is_host() else _guest_color()
	_apply_player_name()
	if _use_lan:
		_set_status("Локальная сеть готова. Создай комнату или нажми «Обновить», чтобы найти комнату в сети.")
	else:
		_set_status("Подключено к GD-Sync. Можно создать комнату или войти по коду.")
		_refresh_public_lobbies()


func _on_connection_failed(error: int) -> void:
	_connected = false
	var reason := _connection_failure_text(error)
	if _auto_retries_left > 0 and error != ENUMS.CONNECTION_FAILED.INVALID_PUBLIC_KEY:
		_auto_retries_left -= 1
		_set_status("%s Повторная попытка через 3 с…" % reason)
		await get_tree().create_timer(3.0).timeout
		if is_inside_tree() and not _connected:
			_start_connection()
		return
	_set_status(reason)
	if _reconnect_button != null:
		_reconnect_button.visible = true


## Понятная причина сбоя по коду GD-Sync и этапу, на котором он случился.
func _connection_failure_text(error: int) -> String:
	match error:
		ENUMS.CONNECTION_FAILED.INVALID_PUBLIC_KEY:
			return "GD-Sync отклонил ключ проекта (неверный публичный ключ в настройках плагина)."
		ENUMS.CONNECTION_FAILED.LOCAL_PORT_ERROR:
			return "Порт локальной сети занят: закрой вторую копию игры на этом компьютере."
	match _connect_stage:
		ENUMS.CONNECTION_STATUS.DISABLED, ENUMS.CONNECTION_STATUS.FINDING_LB:
			return "Нет ответа от серверов GD-Sync (HTTPS). Проверь интернет, VPN/прокси и что игра не заблокирована брандмауэром."
		ENUMS.CONNECTION_STATUS.PINGING_SERVERS:
			return "Игровые серверы GD-Sync не отвечают на пинг (UDP заблокирован сетью или брандмауэром). Попробуй другую сеть или режим «Локальная сеть»."
		_:
			return "Сервер GD-Sync не принял соединение (код %d). Разреши игре доступ в брандмауэре Windows или попробуй «Локальная сеть»." % error


func _on_disconnected() -> void:
	_remove_local_lan_lobby_cache(_current_lobby_name)
	_connected = false
	NetworkMatchState.clear()
	_in_lobby = false
	_current_lobby_name = ""
	_room_players.clear()
	_room_panel.visible = false
	_set_status("Соединение с GD-Sync потеряно.")


func _create_room() -> void:
	if not _connected:
		_set_status("Сначала дождись подключения к GD-Sync.")
		return
	var room_name := _create_room_input.text.strip_edges()
	if room_name.length() < 3 or room_name.length() > 32:
		_set_status("Название комнаты должно содержать от 3 до 32 символов.")
		return
	var password := _create_password_input.text
	if password.length() > 16:
		_set_status("Пароль не должен быть длиннее 16 символов.")
		return
	_pending_password = password
	_set_status("Создание комнаты…")
	GDSync.lobby_create(
		room_name,
		password,
		_public_toggle.button_pressed,
		MAX_PLAYERS,
		{"Game": GAME_TAG, "Mode": str(_selected_mode), "Layout": str(_selected_layout), "Version": "1"}
	)


func _on_lobby_created(lobby_name: String) -> void:
	# GD-Sync does not auto-join a newly created lobby. Join immediately.
	# Remember this name locally: a delayed public-list response must not show
	# our own room as a room we can join.
	_created_lobby_names[lobby_name] = true
	_set_status("Комната создана. Входим…")
	GDSync.lobby_join(lobby_name, _pending_password)


func _on_lobby_creation_failed(lobby_name: String, error: int) -> void:
	_set_status("Не удалось создать '%s' (код %d). Измени название или попробуй позже." % [lobby_name, error])


func _join_room_by_code() -> void:
	_join_named_lobby(_join_room_input.text.strip_edges(), _join_password_input.text)


func _join_named_lobby(lobby_name: String, password: String) -> void:
	if not _connected:
		_set_status("Нет подключения к GD-Sync.")
		return
	if lobby_name.length() < 3 or lobby_name.length() > 32:
		_set_status("Код комнаты должен содержать от 3 до 32 символов.")
		return
	_pending_password = password
	_set_status("Подключение к комнате %s…" % lobby_name)
	if _use_lan and _host_ip_input != null and not _host_ip_input.text.strip_edges().is_empty():
		_register_direct_lan_lobby(lobby_name, _host_ip_input.text.strip_edges())
	GDSync.lobby_join(lobby_name, password)


## Комната хоста по прямому адресу (Tailscale/VPN не пропускают широковещательный
## поиск GD-Sync). Запись без DetectionTime не устаревает при сканировании.
func _register_direct_lan_lobby(lobby_name: String, address: String) -> void:
	var local_server = GDSync._local_server
	var ip := address
	var port := int(local_server.min_game_port)
	if address.count(":") == 1:
		ip = address.get_slice(":", 0)
		port = int(address.get_slice(":", 1))
	local_server.found_lobbies[lobby_name] = {
		"Name": lobby_name, "IP": ip, "Port": port, "Public": true,
		"PlayerCount": 1, "PlayerLimit": MAX_PLAYERS, "Open": true, "Tags": {"Game": GAME_TAG},
	}


## Адреса этого компьютера для подключения по LAN (Tailscale помечается отдельно).
func _lan_addresses_text() -> String:
	var parts: PackedStringArray = []
	for ip in IP.get_local_addresses():
		if ip.contains(":") or ip.begins_with("127.") or ip.begins_with("169.254."):
			continue
		var octets := ip.split(".")
		var is_tailscale := octets.size() == 4 and int(octets[0]) == 100 and int(octets[1]) >= 64 and int(octets[1]) <= 127
		parts.append(ip + (" (Tailscale)" if is_tailscale else ""))
	var port := int(GDSync._local_server.local_lobby_port)
	return "IP для друга: %s · порт %d" % [", ".join(parts), port]


func _on_lobby_joined(lobby_name: String) -> void:
	# GD-Sync 1.0.2 шлёт lobby_joined не только при входе, но и при КАЖДОМ
	# обновлении данных комнаты (RequestProcessor: LOBBY_DATA_RECEIVED).
	# Раньше это сбрасывало список игроков и заново писало данные комнаты —
	# бесконечный цикл, второй игрок «не появлялся», кнопка «НАЧАТЬ» не включалась.
	if _in_lobby and lobby_name == _current_lobby_name:
		if not GDSync.is_host():
			_read_lobby_configuration()
		return

	_in_lobby = true
	_current_lobby_name = lobby_name
	_room_players.clear()
	var local_id := int(GDSync.get_client_id())
	_local_player_color = _host_color() if GDSync.is_host() else _guest_color()
	GDSync.player_set_data("PlayerColor", _local_player_color)
	_room_players[local_id] = {"name": _local_player_name, "color": _local_player_color}
	if GDSync.is_host():
		GDSync.lobby_set_data("Game", GAME_TAG)
		_publish_lobby_configuration()
	else:
		_read_lobby_configuration()
	_room_panel.visible = true
	_room_title.text = "КОМНАТА · %s" % _selected_mode_name()
	_update_config_ui()
	_room_code_label.text = "Код приглашения: %s" % lobby_name
	if _use_lan and GDSync.is_host():
		_room_code_label.text += "\n" + _lan_addresses_text()
	_set_status("Вы в комнате. Ожидаем второго игрока…")
	_refresh_room_ui()


func _on_lobby_join_failed(lobby_name: String, error: int) -> void:
	var reasons := {
		ENUMS.LOBBY_JOIN_ERROR.LOBBY_DOES_NOT_EXIST: "комната не найдена — у создателя она не создалась (нет связи с GD-Sync) или он уже вышел; в режиме LAN оба должны быть в одной сети",
		ENUMS.LOBBY_JOIN_ERROR.LOBBY_IS_CLOSED: "комната закрыта — партия уже началась",
		ENUMS.LOBBY_JOIN_ERROR.LOBBY_IS_FULL: "в комнате уже два игрока",
		ENUMS.LOBBY_JOIN_ERROR.INCORRECT_PASSWORD: "неверный пароль",
		ENUMS.LOBBY_JOIN_ERROR.DUPLICATE_USERNAME: "игрок с таким именем уже в комнате — смени имя и нажми ОК",
	}
	_set_status("Не удалось войти в '%s': %s." % [lobby_name, reasons.get(error, "код %d" % error)])


func _client_name(client_id: int) -> String:
	var value := str(GDSync.player_get_username(client_id, "Игрок %d" % client_id))
	return value if not value.is_empty() else "Игрок %d" % client_id


func _client_color(client_id: int) -> Color:
	if client_id == int(GDSync.get_client_id()):
		return _local_player_color
	var value: Variant = GDSync.player_get_data(client_id, "PlayerColor", _guest_color())
	return value if value is Color else _guest_color()


func _on_client_joined(client_id: int) -> void:
	if not _in_lobby:
		return
	var local_id := int(GDSync.get_client_id())
	if client_id == local_id:
		_room_players[local_id] = {"name": _local_player_name, "color": _local_player_color}
	else:
		# Safety cap for rooms not created by this menu: host rejects a third client.
		if GDSync.is_host() and _room_players.size() >= MAX_PLAYERS:
			GDSync.lobby_kick_client(client_id, "Комната рассчитана максимум на двух игроков.")
			return
		_room_players[client_id] = {"name": _client_name(client_id), "color": _client_color(client_id)}
		# The joining client receives the profiles of clients already in this room.
		GDSync.call_func_on(
			client_id,
			_receive_roster_entry,
			local_id,
			_local_player_name,
			_local_player_color
		)
		if GDSync.is_host():
			GDSync.call_func_on(client_id, _receive_lobby_configuration, _selected_mode, _selected_layout, _selected_draw_mode, _deal_options_mask())
	_refresh_room_ui()


func _receive_roster_entry(client_id: int, player_name: String, player_color: Color) -> void:
	if not _in_lobby:
		return
	if client_id == int(GDSync.get_client_id()):
		return
	_room_players[client_id] = {"name": player_name, "color": player_color}
	_refresh_room_ui()


func _on_client_left(client_id: int) -> void:
	_room_players.erase(client_id)
	_refresh_room_ui()
	if _in_lobby:
		_set_status("Игрок вышел. Можно пригласить другого участника.")


func _on_player_data_changed(client_id: int, key: String, value: Variant) -> void:
	if not _in_lobby or key not in ["Username", "PlayerColor"]:
		return
	if not _room_players.has(client_id):
		_room_players[client_id] = {"name": _client_name(client_id), "color": _guest_color()}
	if key == "Username":
		_room_players[client_id]["name"] = str(value) if value != null else "Игрок %d" % client_id
	elif key == "PlayerColor" and value is Color:
		_room_players[client_id]["color"] = value
	_refresh_room_ui()


func _refresh_room_ui() -> void:
	if not _in_lobby:
		return
	var ids: Array = _room_players.keys()
	ids.sort()
	for slot_index in range(MAX_PLAYERS):
		if slot_index < ids.size():
			var client_id := int(ids[slot_index])
			var entry: Dictionary = _room_players[client_id]
			var player_color: Color = entry.get("color", GameSettings.get_color("text"))
			# Роль не выводим: цвет PlayerColor может пережить смену комнаты/хозяина.
			_player_labels[slot_index].text = str(entry.get("name", "Игрок"))
			_player_labels[slot_index].add_theme_color_override("font_color", player_color)
		else:
			_player_labels[slot_index].text = "Игрок %d\nОжидание…" % (slot_index + 1)
			_player_labels[slot_index].add_theme_color_override("font_color", GameSettings.get_color("muted"))

	var ready_to_start := ids.size() == MAX_PLAYERS
	_start_button.visible = GDSync.is_host()
	_start_button.disabled = not ready_to_start
	_update_config_ui()
	if GDSync.is_host():
		_set_status("Оба игрока подключены. Можно начинать!" if ready_to_start else "Вы хозяин комнаты. Пригласите второго игрока.")
	else:
		_set_status("Ожидаем, пока хозяин комнаты начнёт игру…")


func _copy_room_code() -> void:
	if _current_lobby_name.is_empty():
		return
	DisplayServer.clipboard_set(_current_lobby_name)
	_set_status("Код комнаты скопирован. Отправь его второму игроку.")


func _refresh_public_lobbies() -> void:
	if not _connected:
		_set_status("Нет подключения к GD-Sync.")
		return
	for child in _lobby_list.get_children():
		child.queue_free()
	_set_status("Поиск открытых комнат…")
	GDSync.get_public_lobbies()


func _on_lobbies_received(lobbies: Array) -> void:
	for child in _lobby_list.get_children():
		child.queue_free()
	var found := 0
	for lobby_variant in lobbies:
		if not lobby_variant is Dictionary:
			continue
		var lobby: Dictionary = lobby_variant
		var tags: Dictionary = lobby.get("Tags", {})
		if str(tags.get("Game", "")) != GAME_TAG:
			continue
		var player_count := int(lobby.get("PlayerCount", 0))
		var player_limit := int(lobby.get("PlayerLimit", MAX_PLAYERS))
		var is_open: bool = lobby.get("Open", false) == true
		if not is_open or player_count >= MAX_PLAYERS or player_limit != MAX_PLAYERS:
			continue
		var room_name := str(lobby.get("Name", ""))
		if room_name.is_empty():
			continue
		# Never list the room this client is currently in or created earlier.
		# GD-Sync may briefly return an outdated public-list entry after leaving.
		if room_name == _current_lobby_name or _created_lobby_names.has(room_name):
			continue
		var join_button := _make_button("%s   ·   %d/%d" % [room_name, player_count, MAX_PLAYERS])
		join_button.pressed.connect(_join_lobby_from_list.bind(room_name))
		_lobby_list.add_child(join_button)
		found += 1
	if found == 0:
		var empty_label := _make_label("Подходящих открытых комнат пока нет.", 13, GameSettings.get_color("muted"))
		_lobby_list.add_child(empty_label)
		_set_status("Открытые комнаты не найдены.")
	else:
		_set_status("Найдено комнат: %d. Выбери одну для подключения." % found)


func _join_lobby_from_list(lobby_name: String) -> void:
	_join_named_lobby(lobby_name, _join_password_input.text)


func _start_network_game() -> void:
	if not _in_lobby or not GDSync.is_host():
		return
	if start_only_with_two_players and _room_players.size() != MAX_PLAYERS:
		_set_status("Для запуска нужны оба игрока.")
		return
	if _selected_layout == GameSession.BOARD_LAYOUT_CLASSIC:
		_set_status("Классическая раскладка рассчитана на одного игрока. Выбери зеркальную или кольцевую.")
		return

	var scene_path := str(GameSession.LEVEL_SCENES.get(_selected_mode, ""))
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		_set_status("Не найдена сцена режима %s: %s" % [_selected_mode_name(), scene_path])
		return

	_apply_selected_layout()
	GameSession.draw_mode = _selected_draw_mode
	var roster := _get_match_roster()
	var player_one_name: String = roster[0]["name"]
	var player_two_name: String = roster[1]["name"]
	var player_one_id: int = roster[0]["id"]
	var player_two_id: int = roster[1]["id"]
	if _generating_deal:
		return
	# Общий сид раздачи: оба клиента тасуют колоды одинаково,
	# поэтому поле соперника совпадает с его настоящим полем с первой карты.
	var deal_seed := randi_range(1, 2147483646)

	# Зеркальный Клондайк: хост собирает колоды полей по опциям лобби
	# (решатель для «выигрышной» работает несколько секунд — в отдельном потоке).
	var decks := {}
	if _selected_mode == MODE_KLONDIKE and _selected_layout == GameSession.BOARD_LAYOUT_MIRRORED:
		_generating_deal = true
		_start_button.disabled = true
		_set_status("Готовим раздачу…" + (" (подбираем решаемые колоды)" if _deal_winnable else ""))
		var draw := 3 if _selected_draw_mode == GameSession.DRAW_THREE else 1
		var options := [_deal_same_deck, _deal_same_layout, _deal_winnable]
		var task := WorkerThreadPool.add_task(func():
			var gen := KlondikeDealGenerator.new(draw, deal_seed)
			decks.merge(gen.generate(options[0], options[1], options[2]))
		)
		while not WorkerThreadPool.is_task_completed(task):
			await get_tree().process_frame
		WorkerThreadPool.wait_for_task_completion(task)
		_generating_deal = false
		_start_button.disabled = false
		if not is_inside_tree() or not _in_lobby:
			return
		print("LobbyMenu: раздача — ", decks.get("info", ""))

	GDSync.lobby_set_data("NetworkMatch", true)
	GDSync.call_func_all(
		_apply_network_match_settings,
		_selected_mode,
		_selected_draw_mode,
		_selected_layout,
		player_one_name,
		player_two_name,
		player_one_id,
		player_two_id,
		deal_seed,
		{"Stock": decks.get("field_1", []), "Stock_P2": decks.get("field_2", [])} if not decks.is_empty() else {}
	)
	_set_status("Запускаем сетевую партию: %s…" % _selected_mode_name())
	await get_tree().process_frame
	GDSync.change_scene(scene_path)


func _get_match_roster() -> Array[Dictionary]:
	var ids: Array = _room_players.keys()
	ids.sort()
	var result: Array[Dictionary] = []
	for client_id_variant in ids:
		var client_id := int(client_id_variant)
		var player_name := _client_name(client_id)
		if _room_players.has(client_id):
			player_name = str(_room_players[client_id].get("name", player_name))
		result.append({"id": client_id, "name": player_name})
	while result.size() < MAX_PLAYERS:
		var slot := result.size() + 1
		result.append({"id": -1, "name": "Игрок %d" % slot})
	return result


func _apply_network_match_settings(
	mode_id: int,
	draw_mode: int,
	layout_id: int,
	player_one_name: String,
	player_two_name: String,
	player_one_id: int,
	player_two_id: int,
	deal_seed: int = 0,
	field_decks: Dictionary = {}
) -> void:
	# This function is exposed and called on both clients before the synchronized scene switch.
	GameSession.mode = mode_id
	GameSession.draw_mode = draw_mode
	if mode_id == MODE_SPIDER:
		GameSession.spider_board_layout = layout_id
	else:
		GameSession.klondike_board_layout = layout_id
	NetworkMatchState.active = true
	NetworkMatchState.player_one_name = player_one_name
	NetworkMatchState.player_two_name = player_two_name
	NetworkMatchState.player_one_id = player_one_id
	NetworkMatchState.player_two_id = player_two_id
	NetworkMatchState.deal_seed = deal_seed
	NetworkMatchState.field_decks = field_decks


func _remove_local_lan_lobby_cache(lobby_name: String) -> void:
	if not _use_lan or lobby_name.is_empty() or GDSync._local_server == null:
		return
	# _register_direct_lan_lobby() stores manually resolved LAN entries here.
	# Remove that local discovery record when leaving, so it cannot reappear locally.
	GDSync._local_server.found_lobbies.erase(lobby_name)


func _leave_room() -> void:
	if _in_lobby:
		var leaving_lobby_name := _current_lobby_name
		if not leaving_lobby_name.is_empty():
			_created_lobby_names[leaving_lobby_name] = true
			_remove_local_lan_lobby_cache(leaving_lobby_name)
		# Lobby metadata belongs to the host; guests only clear their own player data.
		if GDSync.is_host():
			GDSync.lobby_erase_data("NetworkMatch")
		GDSync.player_erase_data("NetworkMatchActive")
		GDSync.lobby_leave()
	# Очищаем состояние независимо от флага _in_lobby: он тоже может устареть.
	NetworkMatchState.clear()
	_in_lobby = false
	_current_lobby_name = ""
	_room_players.clear()
	_room_panel.visible = false
	_set_status("Вы покинули комнату.")


func _return_to_main_menu() -> void:
	if _in_lobby:
		_leave_room()
	if main_menu_scene_path.is_empty() or not ResourceLoader.exists(main_menu_scene_path):
		_set_status("Укажи main_menu_scene_path в инспекторе.")
		return
	get_tree().change_scene_to_file(main_menu_scene_path)


func _on_kicked(reason: String) -> void:
	_remove_local_lan_lobby_cache(_current_lobby_name)
	NetworkMatchState.clear()
	_in_lobby = false
	_current_lobby_name = ""
	_room_players.clear()
	_room_panel.visible = false
	_set_status("Вы исключены из комнаты: %s" % reason)


func _set_status(message: String) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = message

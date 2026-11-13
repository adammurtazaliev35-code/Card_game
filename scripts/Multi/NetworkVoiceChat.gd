extends Node
class_name NetworkVoiceChat
## GD-Sync VoiceChat wiring for the two player slots.
## Every peer creates the same two VoiceChat nodes and assigns network ownership
## to the matching lobby client. The local slot alone may open its microphone.

const PTT_ACTION := GameSettings.VOICE_PTT_ACTION

var _voice_nodes: Array[Node] = []
var _output_players: Array[AudioStreamPlayer] = []
var _local_voice: Node
var _talking := false
var _mobile_layer: CanvasLayer
var _last_volume := -1.0
var _last_threshold := -1.0
var _last_quality := -1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred("_setup_voice_nodes")


func _setup_voice_nodes() -> void:
	GameSettings.ensure_loaded()
	var found: Array[Node] = []
	_collect_voice_nodes(get_tree().current_scene, found)
	if found.is_empty():
		push_warning("NetworkVoiceChat: в сцене не найдена GD-Sync VoiceChat-нода.")
		return

	var first: Node = found[0]
	if found.size() == 1:
		first.name = "VoiceChat_P1"
		var second := first.duplicate() as Node
		if second == null and ClassDB.class_exists("VoiceChat"):
			second = ClassDB.instantiate("VoiceChat") as Node
		if second == null:
			push_warning("NetworkVoiceChat: не удалось создать вторую VoiceChat-ноду. Добавь VoiceChat_P2 вручную.")
			return
		second.name = "VoiceChat_P2"
		first.get_parent().add_child(second)
		_voice_nodes = [first, second]
	else:
		_voice_nodes = [found[0], found[1]]
		_voice_nodes[0].name = "VoiceChat_P1"
		_voice_nodes[1].name = "VoiceChat_P2"

	for slot in [1, 2]:
		var voice: Node = _voice_nodes[slot - 1]
		var peer_id := NetworkMatchState.id_of(slot)
		if peer_id < 0:
			push_warning("NetworkVoiceChat: не найден сетевой ID игрока %d." % slot)
			continue
		var output := AudioStreamPlayer.new()
		output.name = "VoiceOutput_P%d" % slot
		add_child(output)
		_output_players.append(output)
		if not _has_property(voice, "_output_player"):
			push_warning("NetworkVoiceChat: у VoiceChat отсутствует свойство _output_player.")
			continue
		voice.set("_output_player", output)
		voice.set("spatial_mode", 0)
		GDSync.set_gdsync_owner(voice, peer_id)
		_configure_input_device(voice)

		# VoiceChat._ready() disables processing when Output Player was None.
		# The scene node is already inside the tree here, so complete the
		# plugin's own setup explicitly after assigning the output player.
		if peer_id == int(GDSync.get_client_id()):
			voice.call("_configure_input")
		else:
			voice.call("_configure_output")
		voice.set_process(true)
		if voice.has_method("mute_microphone"):
			voice.call("mute_microphone")

	var local_slot := NetworkMatchState.slot_of(int(GDSync.get_client_id()))
	if local_slot not in [1, 2]:
		push_warning("NetworkVoiceChat: не удалось определить локального игрока.")
		return
	_local_voice = _voice_nodes[local_slot - 1]
	_apply_voice_settings()
	if OS.has_feature("mobile"):
		_create_mobile_ptt_button()


func _collect_voice_nodes(node: Node, output: Array[Node]) -> void:
	if node == null:
		return
	if node.has_method("get_input_devices") and node.has_method("set_input_device") \
			and node.has_method("mute_microphone") and node.has_method("unmute_microphone"):
		output.append(node)
	for child in node.get_children():
		_collect_voice_nodes(child, output)


func _has_property(object: Object, property_name: String) -> bool:
	for item in object.get_property_list():
		if str(item.get("name", "")) == property_name:
			return true
	return false


func _configure_input_device(voice: Node) -> void:
	var devices: PackedStringArray = voice.call("get_input_devices")
	if devices.is_empty():
		push_warning("NetworkVoiceChat: GD-Sync не обнаружил устройство записи.")
		return
	var selected := AudioServer.input_device
	if not devices.has(selected):
		selected = str(devices[0])
	voice.call("set_input_device", selected)


func _apply_voice_settings() -> void:
	GameSettings.ensure_loaded()
	for voice in _voice_nodes:
		voice.set("audio_quality", GameSettings.voice_quality)
		voice.set("input_volume_threshold", GameSettings.voice_input_threshold)
	for output in _output_players:
		output.volume_linear = GameSettings.voice_volume


func _process(_delta: float) -> void:
	if _voice_nodes.is_empty():
		return
	if GameSettings.voice_volume != _last_volume \
			or GameSettings.voice_input_threshold != _last_threshold \
			or GameSettings.voice_quality != _last_quality:
		_apply_voice_settings()
		_last_volume = GameSettings.voice_volume
		_last_threshold = GameSettings.voice_input_threshold
		_last_quality = GameSettings.voice_quality
	if not OS.has_feature("mobile"):
		_set_talking(InputMap.has_action(PTT_ACTION) and Input.is_action_pressed(PTT_ACTION))


func _create_mobile_ptt_button() -> void:
	_mobile_layer = CanvasLayer.new()
	_mobile_layer.name = "VoicePushToTalk"
	_mobile_layer.layer = 70
	add_child(_mobile_layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mobile_layer.add_child(root)

	var button := Button.new()
	button.text = "🎙\nУДЕРЖИВАЙ"
	button.custom_minimum_size = Vector2(170, 76)
	button.anchor_left = 1.0
	button.anchor_top = 1.0
	button.anchor_right = 1.0
	button.anchor_bottom = 1.0
	button.offset_left = -194.0
	button.offset_top = -104.0
	button.offset_right = -24.0
	button.offset_bottom = -28.0
	button.add_theme_font_size_override("font_size", 18)
	button.add_theme_color_override("font_color", Color("#f3e6c8"))
	button.add_theme_stylebox_override("normal", _button_style(
		GameSettings.get_color("button"), GameSettings.get_color("gold")
	))
	button.add_theme_stylebox_override("pressed", _button_style(
		GameSettings.get_color("accent"), GameSettings.get_color("gold")
	))
	button.button_down.connect(_set_talking.bind(true))
	button.button_up.connect(_set_talking.bind(false))
	root.add_child(button)


func _button_style(background: Color, border_color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border_color
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	return style


func _set_talking(value: bool) -> void:
	if _talking == value or _local_voice == null or not is_instance_valid(_local_voice):
		return
	_talking = value
	if value:
		_local_voice.call("unmute_microphone")
	else:
		_local_voice.call("mute_microphone")


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_set_talking(false)


func _exit_tree() -> void:
	_set_talking(false)

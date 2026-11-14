
extends Node
class_name NetworkVoiceChat
## Настройка GD-Sync VoiceChat для двух игроков.
## В сцене должны присутствовать VoiceChat_P1 и VoiceChat_P2,
## каждому заранее назначается собственный AudioStreamPlayer.

const PTT_ACTION := GameSettings.VOICE_PTT_ACTION

var _voice_nodes: Array[Node] = []
var _local_voice: Node
var _remote_output: AudioStreamPlayer
var _local_slot := 0
var _talking := false
var _mobile_layer: CanvasLayer

var _last_volume := -1.0
var _last_threshold := -1.0
var _last_quality := -1


func _ready() -> void:
	if GDSync.is_active():
		GDSync.expose_func(_receive_voice_state)
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)
	call_deferred("_setup_voice_nodes")


func _setup_voice_nodes() -> void:
	GameSettings.ensure_loaded()

	var voice_p1: Node
	var voice_p2: Node

	var found: Array[Node] = []
	_collect_voice_nodes(get_tree().current_scene, found)

	for voice in found:
		match str(voice.name):
			"VoiceChat_P1":
				voice_p1 = voice
			"VoiceChat_P2":
				voice_p2 = voice

	if voice_p1 == null or voice_p2 == null:
		push_error(
			"NetworkVoiceChat: нужны две ноды VoiceChat_P1 и VoiceChat_P2. "
			+ "Проверь структуру сцены."
		)
		return

	_voice_nodes = [voice_p1, voice_p2]

	var outputs: Array[AudioStreamPlayer] = []

	for voice in _voice_nodes:
		var output := voice.get("_output_player") as AudioStreamPlayer

		if output == null or not is_instance_valid(output):
			push_error(
				"NetworkVoiceChat: у %s не назначен Output Player."
				% voice.name
			)
			_voice_nodes.clear()
			return

		outputs.append(output)
		voice.set("spatial_mode", 0)

	var local_id := int(GDSync.get_client_id())
	var local_slot := NetworkMatchState.slot_of(local_id)

	if local_slot not in [1, 2]:
		push_error("NetworkVoiceChat: не удалось определить локального игрока.")
		_voice_nodes.clear()
		return
	_local_slot = local_slot
	var player_ids: Array[int] = []

	for slot in [1, 2]:
		var peer_id := int(NetworkMatchState.id_of(slot))
		if peer_id < 0:
			push_error(
				"NetworkVoiceChat: не найден сетевой ID игрока %d." % slot
			)
			_voice_nodes.clear()
			return
		player_ids.append(peer_id)

	# Каждый VoiceChat принадлежит своему игроку.
	# GD-Sync сам обработает смену владельца и настройку записи/воспроизведения.
	for index in range(2):
		GDSync.set_gdsync_owner(_voice_nodes[index], player_ids[index])

	_local_voice = _voice_nodes[local_slot - 1]

	var remote_slot := 2 if local_slot == 1 else 1
	_remote_output = outputs[remote_slot - 1]

	_configure_input_device(_local_voice)

	if _local_voice.has_method("mute_microphone"):
		_local_voice.call("mute_microphone")

	_apply_voice_settings()
	_update_settings_cache()

	if OS.has_feature("mobile"):
		_create_mobile_ptt_button()


func _collect_voice_nodes(node: Node, output: Array[Node]) -> void:
	if node == null:
		return

	if node.has_method("get_input_devices") \
			and node.has_method("set_input_device") \
			and node.has_method("mute_microphone") \
			and node.has_method("unmute_microphone"):
		output.append(node)

	for child in node.get_children():
		_collect_voice_nodes(child, output)


func _configure_input_device(voice: Node) -> void:
	var devices: PackedStringArray = voice.call("get_input_devices")

	if devices.is_empty():
		push_warning(
			"NetworkVoiceChat: GD-Sync не обнаружил устройство записи."
		)
		return

	var selected := AudioServer.input_device

	if selected.is_empty() or not devices.has(selected):
		selected = str(devices[0])

	voice.call("set_input_device", selected)


func _apply_voice_settings() -> void:
	GameSettings.ensure_loaded()

	# Качество передачи и порог чувствительности относятся
	# к микрофону локального игрока.
	if is_instance_valid(_local_voice):
		_local_voice.set(
			"audio_quality",
			clampi(GameSettings.voice_quality, 0, 3)
		)
		_local_voice.set(
			"input_volume_threshold",
			clampf(GameSettings.voice_input_threshold, 0.001, 0.1)
		)

	# Громкость регулирует только голос соперника.
	if is_instance_valid(_remote_output):
		_remote_output.volume_linear = clampf(
			GameSettings.voice_volume, 0.0, 1.0
		)


func _update_settings_cache() -> void:
	_last_volume = GameSettings.voice_volume
	_last_threshold = GameSettings.voice_input_threshold
	_last_quality = GameSettings.voice_quality


func _process(_delta: float) -> void:
	if not is_instance_valid(_local_voice):
		return

	if GameSettings.voice_volume != _last_volume \
			or GameSettings.voice_input_threshold != _last_threshold \
			or GameSettings.voice_quality != _last_quality:
		_apply_voice_settings()
		_update_settings_cache()

	if not OS.has_feature("mobile"):
		var pressed := (
			InputMap.has_action(PTT_ACTION)
			and Input.is_action_pressed(PTT_ACTION)
		)
		_set_talking(pressed)


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
	button.focus_mode = Control.FOCUS_NONE

	button.add_theme_font_size_override("font_size", 18)
	button.add_theme_color_override("font_color", Color("#f3e6c8"))

	button.add_theme_stylebox_override(
		"normal",
		_button_style(
			GameSettings.get_color("button"),
			GameSettings.get_color("gold")
		)
	)
	button.add_theme_stylebox_override(
		"pressed",
		_button_style(
			GameSettings.get_color("accent"),
			GameSettings.get_color("gold")
		)
	)

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
	if _talking == value:
		return

	if not is_instance_valid(_local_voice):
		return

	_talking = value
	_update_voice_indicator(_local_slot, value)
	
	if _local_slot in [1, 2] and GDSync.is_active():
		GDSync.call_func(_receive_voice_state, _local_slot, value)
	if value:
		_local_voice.call("unmute_microphone")
	else:
		_local_voice.call("mute_microphone")


func _receive_voice_state(sender_slot: int, speaking: bool) -> void:
	if not GDSync.is_active() or not NetworkMatchState.active:
		return
	if sender_slot not in [1, 2] or sender_slot == _local_slot:
		return

	# Проверяем, что сообщение действительно пришло от указанного игрока.
	if NetworkMatchState.slot_of(int(GDSync.get_sender_id())) != sender_slot:
		return

	_update_voice_indicator(sender_slot, speaking)


func _update_voice_indicator(slot: int, speaking: bool) -> void:
	var signs := get_tree().get_first_node_in_group("network_match_signs")
	if signs != null and signs.has_method("set_voice_activity"):
		signs.call("set_voice_activity", slot, speaking)

	var feedback := get_tree().get_first_node_in_group("network_board_feedback")
	if feedback != null and slot != _local_slot:
		feedback.set_remote_speaking(speaking)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_set_talking(false)


func _exit_tree() -> void:
	_set_talking(false)

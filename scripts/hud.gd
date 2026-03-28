extends CanvasLayer

var hp_label: Label
var money_label: Label
var crosshair: ColorRect
var tower_container: HBoxContainer
var _player: CharacterBody3D

func _ready() -> void:
	# --- Crosshair ---
	crosshair = ColorRect.new()
	crosshair.size = Vector2(4, 4)
	crosshair.color = Color.WHITE
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.grow_horizontal = Control.GROW_DIRECTION_BOTH
	crosshair.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(crosshair)

	# --- HP Label ---
	hp_label = Label.new()
	hp_label.name = "HPLabel"
	hp_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	hp_label.position = Vector2(20, 20)
	hp_label.add_theme_font_size_override("font_size", 32)
	add_child(hp_label)

	# --- Money Label ---
	money_label = Label.new()
	money_label.name = "MoneyLabel"
	money_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	money_label.position = Vector2(-220, 20)
	money_label.add_theme_font_size_override("font_size", 32)
	money_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(money_label)

	# --- Tower Selection UI ---
	tower_container = HBoxContainer.new()
	tower_container.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	tower_container.grow_horizontal = Control.GROW_DIRECTION_BOTH
	tower_container.position.y = -120
	tower_container.add_theme_constant_override("separation", 20)
	add_child(tower_container)

	_setup_tower_buttons()

func _setup_tower_buttons() -> void:
	var towers = [
		{"name": "Standard", "script": "res://scripts/towers/tower.gd", "cost": 50},
		{"name": "Wind", "script": "res://scripts/towers/wind_tower.gd", "cost": 150}
	]
	
	for tower_info in towers:
		_create_tower_button(tower_info)

func _create_tower_button(info: Dictionary) -> void:
	var panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(100, 100)
	tower_container.add_child(panel)
	
	# Viewport for 3D preview
	var viewport_container = SubViewportContainer.new()
	viewport_container.stretch = true
	panel.add_child(viewport_container)
	
	var viewport = SubViewport.new()
	viewport.size = Vector2i(100, 100)
	viewport.transparent_bg = true
	viewport_container.add_child(viewport)
	
	# Separate world for the preview
	viewport.world_3d = World3D.new()
	
	var camera = Camera3D.new()
	camera.position = Vector3(0, 5, 15)
	viewport.add_child(camera)
	camera.look_at(Vector3(0, 5, 0))
	
	var light = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 45, 0)
	viewport.add_child(light)
	
	# The tower model
	var tower_model = StaticBody3D.new()
	tower_model.set_script(load(info.script))
	viewport.add_child(tower_model)
	# Disable processing for the preview tower
	tower_model.set_physics_process(false)
	tower_model.set_process(false)
	
	# Rotation node to spin the model
	var timer = Timer.new()
	timer.wait_time = 0.02
	timer.autostart = true
	timer.timeout.connect(func(): if is_instance_valid(tower_model): tower_model.rotate_y(0.03))
	add_child(timer)

	# Label for cost
	var cost_label = Label.new()
	cost_label.text = "$%d" % info.cost
	cost_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(cost_label)

	# Click to select
	panel.gui_input.connect(func(event):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			if _player and _player.has_method("start_placement"):
				_player.start_placement(info.script)
	)

func initialize(player: CharacterBody3D, objective: Area3D) -> void:
	_player = player
	assert(objective != null)
	_update_hp(objective.current_hp, objective.max_hp)
	objective.hp_changed.connect(_update_hp)
	
	assert(player != null)
	_update_money(player.money)
	player.money_changed.connect(_update_money)

func _update_hp(curr: float, max_hp: float) -> void:
	hp_label.text = "Objective HP: %d / %d" % [curr, max_hp]

func _update_money(amount: float) -> void:
	money_label.text = "Money: $%.2f" % amount

func show_game_over() -> void:
	layer = 100 # Ensure it's on top
	
	var overlay = ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.7)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(overlay)
	
	var center_container = CenterContainer.new()
	center_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center_container)
	
	var v_box = VBoxContainer.new()
	center_container.add_child(v_box)
	
	var label = Label.new()
	label.text = "GAME OVER"
	label.add_theme_font_size_override("font_size", 64)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v_box.add_child(label)
	
	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, 20)
	v_box.add_child(spacer)
	
	var restart_button = Button.new()
	restart_button.text = "RESTART"
	restart_button.custom_minimum_size = Vector2(200, 60)
	restart_button.add_theme_font_size_override("font_size", 32)
	restart_button.pressed.connect(func():
		get_tree().reload_current_scene()
	)
	v_box.add_child(restart_button)
	
	var quit_spacer = Control.new()
	quit_spacer.custom_minimum_size = Vector2(0, 10)
	v_box.add_child(quit_spacer)
	
	var quit_button = Button.new()
	quit_button.text = "QUIT"
	quit_button.custom_minimum_size = Vector2(200, 60)
	quit_button.add_theme_font_size_override("font_size", 32)
	quit_button.pressed.connect(func():
		get_tree().quit()
	)
	v_box.add_child(quit_button)
	
	# Unlock mouse
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

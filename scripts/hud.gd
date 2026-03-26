extends CanvasLayer

var hp_label: Label
var money_label: Label
var crosshair: ColorRect

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

func initialize(player: CharacterBody3D, objective: Area3D) -> void:
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

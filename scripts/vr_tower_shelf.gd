extends Node3D

signal tower_selected(script_path: String, cost: int, source_position: Vector3)

@export var spacing: float = 2.0
@export var vertical_spacing: float = 1.5
@export var shelf_height: float = 1.0

const MAX_COLUMNS = 4

func _ready() -> void:
	_setup_shelf()

func _setup_shelf() -> void:
	var dir = DirAccess.open("res://scripts/towers/")
	if not dir:
		push_error("Failed to open towers directory")
		return

	var towers = []
	dir.list_dir_begin()
	var file_name = dir.get_next()

	while file_name != "":
		if file_name.ends_with(".gd") and file_name != "building.gd":
			var script_path = "res://scripts/towers/" + file_name
			var script_class = load(script_path)
			var tower_name = file_name.trim_suffix(".gd").capitalize()

			towers.append({
				"name": tower_name,
				"script": script_path,
				"cost": script_class.get_cost()
			})

		file_name = dir.get_next()

	# Sort by cost (ascending)
	towers.sort_custom(func(a, b): return a.cost < b.cost)

	var total = towers.size()

	for i in range(total):
		var r := floori(float(i) / float(MAX_COLUMNS))
		var c = i % MAX_COLUMNS

		var x_pos = (c - (MAX_COLUMNS - 1) / 2.0) * spacing
		var y_pos = r * vertical_spacing  # row 0 at bottom, additional rows stack upward

		_create_tower_option(towers[i], Vector3(x_pos, y_pos, 0))

	var max_row := floori(float(max(total - 1, 0)) / float(MAX_COLUMNS))
	_build_controls_label((max_row + 1) * vertical_spacing + 1.0)

func _create_tower_option(info: Dictionary, pos: Vector3) -> void:
	var option_root = Node3D.new()
	option_root.position = pos
	add_child(option_root)

	# 1. The Tower Model (Visual only)
	var tower_preview = StaticBody3D.new()
	tower_preview.set_script(load(info.script))
	# Scale down the preview towers as they are quite large (17m tall!)
	# Scale 0.05 makes a 17m tower about 0.85m tall
	tower_preview.scale = Vector3(0.05, 0.05, 0.05)
	# Prevent placement raycasts from hitting the dummy tower
	tower_preview.collision_layer = 0
	tower_preview.collision_mask = 0
	tower_preview.input_ray_pickable = false
	option_root.add_child(tower_preview)
	
	# Disable logic for the preview
	tower_preview.set_physics_process(false)
	tower_preview.set_process(false)
	
	# 2. Interactable Area for Selection (Works for both XR and Mouse)
	var interactable = XRToolsInteractableArea.new()
	# Use XR/UI-only layer (20) so mouse raycasts for placement ignore the shelf
	# Keep layer 1 removed so placement raycasts (mask 1) don't hit the shelf
	interactable.collision_layer = 1 << 20
	interactable.collision_mask = 0
	interactable.input_ray_pickable = true
	option_root.add_child(interactable)
	
	var col = CollisionShape3D.new()
	var shape = BoxShape3D.new()
	shape.size = Vector3(1.0, 1.5, 1.0) # Adjusted for 0.05 scale
	col.shape = shape
	col.position = Vector3(0, 0.75, 0)
	interactable.add_child(col)
	
	# XR Tools Signal
	interactable.pointer_event.connect(func(event):
		if event is XRToolsPointerEvent:
			if event.event_type == XRToolsPointerEvent.Type.PRESSED:
				tower_selected.emit(info.script, info.cost, tower_preview.global_position)
				get_viewport().set_input_as_handled()
	)

	# Mouse Signal
	interactable.input_event.connect(func(_camera, event, _position, _normal, _shape_idx):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			tower_selected.emit(info.script, info.cost, tower_preview.global_position)
			get_viewport().set_input_as_handled()
	)

	# 3. Label for Name and Cost
	var label = Label3D.new()
	label.text = "%s\n$%d" % [info.name, info.cost]
	label.position = Vector3(0, -0.2, 0)
	label.pixel_size = 0.005
	label.font_size = 48
	option_root.add_child(label)

	# Animation: spin the tower
	var tween = create_tween().set_loops()
	tween.tween_property(tower_preview, "rotation:y", TAU, 4.0).from(0.0)

func _build_controls_label(y: float) -> void:
	var label := Label3D.new()
	label.text = (
		"— CONTROLS —\n\n" +
		"LEFT HAND\n" +
		"X             Recenter\n\n" +
		"RIGHT HAND\n" +
		"Trigger       Place tower / Pick up tower\n" +
		"A             Fire spell / Cancel placement\n" +
		"B             Rotate tower (placing)\n" +
		"Laser         Select tower / Press buttons"
	)
	label.position = Vector3(0.0, y, 0.0)
	label.pixel_size = 0.005
	label.font_size = 32
	label.outline_size = 6
	label.modulate = Color(0.85, 0.95, 1.0)
	label.no_depth_test = true
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.rotation_degrees.y = 180.0
	add_child(label)

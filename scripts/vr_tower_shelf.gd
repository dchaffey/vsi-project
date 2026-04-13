extends Node3D

signal tower_selected(script_path: String, cost: int)

@export var spacing: float = 2.0
@export var vertical_spacing: float = 3.0
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
	var rows = ceili(total / float(MAX_COLUMNS))

	for i in range(total):
		var r = i / MAX_COLUMNS
		var c = i % MAX_COLUMNS
		
		# Number of items in this row to center it
		var items_in_row = min(MAX_COLUMNS, total - r * MAX_COLUMNS)
		
		var x_pos = (c - (items_in_row - 1) / 2.0) * spacing
		# Stack rows vertically (downwards from center)
		var y_pos = -(r - (rows - 1) / 2.0) * vertical_spacing
		
		_create_tower_option(towers[i], Vector3(x_pos, y_pos, 0))

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
	option_root.add_child(tower_preview)
	
	# Disable logic for the preview
	tower_preview.set_physics_process(false)
	tower_preview.set_process(false)
	tower_preview.input_ray_pickable = false
	
	# 2. Interactable Area for Selection (Works for both XR and Mouse)
	var interactable = XRToolsInteractableArea.new()
	# Put it on layer 1 (same as terrain) so mouse raycast hits it easily
	# Also keep layer 21 for XR Tools if needed
	interactable.collision_layer = 1 | (1 << 20)
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
				tower_selected.emit(info.script, info.cost)
	)

	# Mouse Signal
	interactable.input_event.connect(func(_camera, event, _position, _normal, _shape_idx):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			tower_selected.emit(info.script, info.cost)
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

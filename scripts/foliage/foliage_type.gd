# foliage_type.gd
extends Resource
class_name FoliageType

## The visual mesh used in the MultiMesh
@export var mesh: Mesh
## Relative weight for random selection (higher = more common)
@export var spawn_weight: float = 1.0

# Future fields you will add later:
# @export var destroyed_scene: PackedScene
# @export var collision_shape: Shape3D

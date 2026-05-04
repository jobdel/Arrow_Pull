extends ParallaxBackground

@export var scroll_speed: float = 15.0

func _process(delta: float) -> void:
	# Using scroll_base_offset is often more stable for 
	# continuous movement in Godot 4
	scroll_base_offset.x -= scroll_speed * delta

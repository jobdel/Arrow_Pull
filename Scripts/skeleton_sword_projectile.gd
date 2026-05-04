extends Area2D

# =============================================================================
# SKELETON SWORD PROJECTILE
# =============================================================================
# Spinning sword thrown by the skeleton monster. Flies in a direction,
# plays hit animation on contact, then despawns.
# =============================================================================

@export var SPEED := 150.0
@export var LIFETIME := 4.0
@export var damage := 1

var direction: float = 1.0
var is_active: bool = false
var lifetime_timer: float = 0.0

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D


func _ready() -> void:
	animated_sprite.animation_finished.connect(_on_animation_finished)
	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)
	set_meta("damage", damage)
	add_to_group("enemy_attack")


func launch(dir: float) -> void:
	direction = dir
	is_active = true
	lifetime_timer = LIFETIME
	animated_sprite.play(&"SpinningSword")

	if direction < 0.0:
		animated_sprite.flip_h = true


func _physics_process(delta: float) -> void:
	if not is_active:
		return

	position.x += SPEED * direction * delta

	lifetime_timer -= delta
	if lifetime_timer <= 0.0:
		queue_free()


func _on_body_entered(body: Node2D) -> void:
	if not is_active:
		return

	if body is CharacterBody2D and body.has_method("take_damage"):
		body.take_damage(damage, global_position)
		_hit()
	elif body is StaticBody2D or body is TileMapLayer:
		_hit()


func _on_area_entered(area: Area2D) -> void:
	if not is_active:
		return
	# If it hits the player's hurtbox or a shield
	if area.is_in_group("player_hurtbox"):
		if area.get_parent().has_method("take_damage"):
			area.get_parent().take_damage(damage, global_position)
		_hit()


func _hit() -> void:
	is_active = false
	animated_sprite.play(&"SwordHit")


func _on_animation_finished() -> void:
	if animated_sprite.animation == &"SwordHit":
		queue_free()

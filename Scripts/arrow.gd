extends Area2D

# =============================================================================
# UTILITY ARROW — PLATFORM MECHANIC
# =============================================================================
# Flies horizontally. On hitting a wall, stops and becomes a one-way platform
# the player can stand on. Despawns after PLATFORM_DURATION or if MAX_ARROWS
# is exceeded (oldest arrow removed first).
# =============================================================================

@export var SPEED := 500.0
@export var MAX_SPEED := 800.0
@export var LIFETIME := 5.0
@export var PLATFORM_DURATION := 5.0
@export var damage := 1

var direction: float = 1.0
var launch_angle: float = 0.0
var is_active: bool = false
var is_stuck: bool = false
var lifetime_timer: float = 0.0
var platform_timer: float = 0.0
var reparented: bool = false
var is_despawning: bool = false

# Track all stuck arrow platforms globally; oldest removed when over limit
static var active_arrows: Array[Node] = []
const MAX_ARROWS := 3

@onready var arrow_sprite: Sprite2D = $"Arrow sprite"
@onready var hit_anim: AnimatedSprite2D = $"Arrow hit wall"
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var platform_body: StaticBody2D = $PlatformBody
@onready var platform_shape: CollisionShape2D = $PlatformBody/CollisionShape2D


func _ready() -> void:
	hit_anim.visible = false
	hit_anim.animation_finished.connect(_on_hit_animation_finished)
	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)
	set_meta("damage", damage)
	add_to_group("player_attack")
	add_to_group("Arrows")
	platform_body.add_to_group("arrow_platform")
	platform_shape.disabled = true


func launch(dir: float, angle: float = 0.0) -> void:
	direction = dir
	launch_angle = angle
	is_active = true
	lifetime_timer = LIFETIME

	if direction < 0.0:
		arrow_sprite.flip_h = true

	arrow_sprite.rotation = -launch_angle * direction


func _physics_process(delta: float) -> void:
	if is_stuck:
		platform_timer -= delta
		if platform_timer <= 0.0:
			_begin_despawn()
			return
		# If we reparented to a node that was freed, clean up
		if reparented and not is_inside_tree():
			queue_free()
		return

	if not is_active:
		return

	var effective_speed := minf(SPEED, MAX_SPEED)
	position.x += effective_speed * direction * cos(launch_angle) * delta
	position.y += effective_speed * -sin(launch_angle) * delta

	lifetime_timer -= delta
	if lifetime_timer <= 0.0:
		queue_free()


func _on_body_entered(body: Node2D) -> void:
	if not is_active:
		return
	# Arrow passes through the player
	if body.is_in_group("player"):
		return

	# --- Shatter: flying arrow hits a stuck arrow's platform ---
	if body.is_in_group("arrow_platform"):
		var stuck_arrow := body.get_parent()
		if stuck_arrow and stuck_arrow.is_in_group("Arrows"):
			_shatter_with(stuck_arrow)
			return

	# Stick to walls and become a platform
	if body is TileMapLayer or (body is StaticBody2D):
		_become_platform(body)
	elif body is CharacterBody2D:
		# Hit an enemy body — stick to it as a platform
		_stick_to_enemy(body)
	else:
		_play_hit()


func _on_area_entered(area: Area2D) -> void:
	if not is_active:
		return
	if area.is_in_group("enemy_attack"):
		return
	# Stick to enemy if we hit their hurtbox
	var enemy := area.get_parent()
	if enemy is CharacterBody2D and enemy != null:
		_stick_to_enemy(enemy)
	else:
		_play_hit()


func _become_platform(target: Node2D) -> void:
	is_active = false
	is_stuck = true
	platform_timer = PLATFORM_DURATION

	# Disable the Area2D flight hitbox (projectile collision)
	collision_shape.set_deferred("disabled", true)

	# Enable the platform immediately so the player can stand on it during the VFX
	platform_shape.set_deferred("disabled", false)

	# Reparent to the wall/tilemap so the arrow is a child of what it hit
	reparent(target, true)  # true = keep_global_transform
	reparented = true

	# Hide the arrow sprite while the hit VFX plays
	arrow_sprite.visible = false

	# Play hit VFX
	if direction < 0.0:
		hit_anim.scale.x = -abs(hit_anim.scale.x)
	else:
		hit_anim.scale.x = abs(hit_anim.scale.x)
	hit_anim.visible = true
	hit_anim.play(&"arrow hit wall")

	_add_to_tracking()


func _stick_to_enemy(enemy: CharacterBody2D) -> void:
	is_active = false
	is_stuck = true
	platform_timer = PLATFORM_DURATION

	# Disable the Area2D flight hitbox to prevent double-hits
	collision_shape.set_deferred("disabled", true)

	# Enable the platform so the player can stand on the arrow stuck in the enemy
	platform_shape.set_deferred("disabled", false)

	# Reparent to the enemy — the arrow now moves perfectly with them
	reparent(enemy, true)  # true = keep_global_transform
	reparented = true

	# Keep the arrow sprite visible and rotated correctly
	arrow_sprite.visible = true
	arrow_sprite.show()

	_add_to_tracking()


func _shatter_with(stuck_arrow: Node2D) -> void:
	# Pass double damage up to whatever the stuck arrow was parented to (e.g. enemy)
	var host := stuck_arrow.get_parent()
	if host and host.has_method("take_damage"):
		host.take_damage(2, stuck_arrow.global_position)

	# Shatter both arrows
	stuck_arrow._shatter()
	_shatter()


func _shatter() -> void:
	is_active = false
	collision_shape.set_deferred("disabled", true)
	platform_shape.set_deferred("disabled", true)
	arrow_sprite.visible = false

	# Play the hit VFX as a shatter effect, then queue_free when it finishes
	if direction < 0.0:
		hit_anim.scale.x = -abs(hit_anim.scale.x)
	else:
		hit_anim.scale.x = abs(hit_anim.scale.x)
	hit_anim.visible = true
	hit_anim.play(&"arrow hit wall")

	# Override: free after anim regardless of is_stuck state
	is_stuck = false


func _play_hit() -> void:
	is_active = false
	arrow_sprite.visible = false
	collision_shape.set_deferred("disabled", true)
	if direction < 0.0:
		hit_anim.scale.x = -abs(hit_anim.scale.x)
	else:
		hit_anim.scale.x = abs(hit_anim.scale.x)
	hit_anim.visible = true
	hit_anim.play(&"arrow hit wall")


func _begin_despawn() -> void:
	is_despawning = true
	is_stuck = false
	platform_shape.set_deferred("disabled", true)
	arrow_sprite.visible = false
	hit_anim.visible = true
	hit_anim.play_backwards(&"arrow hit wall")


func _on_hit_animation_finished() -> void:
	hit_anim.visible = false

	if is_despawning:
		queue_free()
	elif is_stuck:
		# Arrow is a platform — reveal the static sprite now that VFX is done
		arrow_sprite.visible = true
	else:
		# Non-stickable hit (e.g. bounced off something) — just despawn
		queue_free()


# --- Arrow count management ---

func _add_to_tracking() -> void:
	active_arrows = active_arrows.filter(func(a): return is_instance_valid(a))
	active_arrows.append(self)
	while active_arrows.size() > MAX_ARROWS:
		var oldest = active_arrows.pop_front()
		if is_instance_valid(oldest):
			oldest._begin_despawn()


func _exit_tree() -> void:
	active_arrows.erase(self)

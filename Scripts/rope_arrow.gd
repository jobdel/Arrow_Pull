extends Area2D

# =============================================================================
# ROPE ARROW — GRAPPLING HOOK MECHANIC
# =============================================================================
# Flies in a direction. On hitting a wall, sticks and signals the player to
# enter SWINGING state. On hitting an enemy, yanks the player toward the enemy.
# A Line2D rope is drawn between player and arrow every frame.
# =============================================================================

@export var SPEED := 600.0
@export var MAX_SPEED := 900.0
@export var LIFETIME := 3.0
@export var YANK_IMPULSE := 800.0
@export var MAX_DISTANCE := 400.0
@export var MAX_ROPE_LENGTH := 180.0
@export var RETURN_SPEED := 700.0
@export var damage := 0

var direction: float = 1.0
var launch_angle: float = 0.0
var grapple_mode: String = "swing"  # "swing" or "pull" — locked at launch time
var is_active: bool = false
var is_stuck: bool = false
var is_returning: bool = false
var lifetime_timer: float = 0.0
var launch_position: Vector2 = Vector2.ZERO

## Reference to the player who fired this arrow (set by player before launch)
var owner_player: CharacterBody2D = null

## The point the arrow is stuck to (world space)
var anchor_point: Vector2 = Vector2.ZERO

@onready var arrow_sprite: Sprite2D = $"Arrow sprite"
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var rope_line: Line2D = $RopeLine


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)
	rope_line.width = 2.0
	rope_line.default_color = Color(0.6, 0.45, 0.25)  # Brown rope color
	rope_line.points = PackedVector2Array()


func launch(dir: float, angle: float = 0.0, mode: String = "swing") -> void:
	direction = dir
	launch_angle = angle
	grapple_mode = mode
	is_active = true
	lifetime_timer = LIFETIME
	launch_position = global_position

	if direction < 0.0:
		arrow_sprite.flip_h = true
	arrow_sprite.rotation = -launch_angle * direction


func _physics_process(delta: float) -> void:
	# --- Update rope visual ---
	if owner_player and is_instance_valid(owner_player):
		rope_line.clear_points()
		# Convert both positions to the rope's local space
		rope_line.add_point(rope_line.to_local(owner_player.global_position))
		rope_line.add_point(rope_line.to_local(global_position))
	else:
		rope_line.clear_points()

	if is_stuck:
		return

	# --- Return to player if missed ---
	if is_returning:
		if owner_player and is_instance_valid(owner_player):
			var to_player := owner_player.global_position - global_position
			if to_player.length() <= RETURN_SPEED * delta + 16.0:
				queue_free()
				return
			var return_dir := to_player.normalized()
			global_position += return_dir * RETURN_SPEED * delta
			arrow_sprite.rotation = return_dir.angle()
		else:
			queue_free()
		return

	if not is_active:
		return

	# --- Fly ---
	var effective_speed := minf(SPEED, MAX_SPEED)
	position.x += effective_speed * direction * cos(launch_angle) * delta
	position.y += effective_speed * -sin(launch_angle) * delta

	lifetime_timer -= delta
	if lifetime_timer <= 0.0:
		_start_returning()
		return

	# --- Check rope length ---
	if owner_player and is_instance_valid(owner_player):
		var rope_length := global_position.distance_to(owner_player.global_position)
		if rope_length >= MAX_ROPE_LENGTH:
			_start_returning()
			return


func _on_body_entered(body: Node2D) -> void:
	if not is_active:
		return
	if body.is_in_group("player"):
		return

	if body is TileMapLayer or body is StaticBody2D:
		_stick_to_wall(body)
	elif body is CharacterBody2D:
		_yank_player_toward(body)


func _on_area_entered(area: Area2D) -> void:
	if not is_active:
		return
	var enemy := area.get_parent()
	if enemy is CharacterBody2D and enemy != null and not enemy.is_in_group("player"):
		_yank_player_toward(enemy)


func _stick_to_wall(_body: Node2D) -> void:
	is_active = false
	is_stuck = true
	anchor_point = global_position

	# Disable flight collision
	collision_shape.set_deferred("disabled", true)

	# Tell the player to enter swinging state
	if owner_player and is_instance_valid(owner_player) and owner_player.has_method("_enter_swinging"):
		owner_player._enter_swinging(self)


func _yank_player_toward(enemy: CharacterBody2D) -> void:
	is_active = false

	# Apply impulse to the player in the direction of the enemy
	if owner_player and is_instance_valid(owner_player):
		var yank_dir: Vector2 = (enemy.global_position - owner_player.global_position).normalized()
		owner_player.velocity = yank_dir * YANK_IMPULSE

	rope_line.clear_points()
	queue_free()


## Begin flying back toward the player after missing
func _start_returning() -> void:
	is_active = false
	is_returning = true
	collision_shape.set_deferred("disabled", true)


## Cleanly remove the rope arrow and notify the player
func disconnect_rope() -> void:
	if owner_player and is_instance_valid(owner_player):
		if owner_player.has_method("_exit_swinging"):
			owner_player._exit_swinging()
	rope_line.clear_points()
	queue_free()

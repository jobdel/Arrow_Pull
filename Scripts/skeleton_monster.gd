extends CharacterBody2D

# =============================================================================
# SKELETON MONSTER — HOLLOW KNIGHT-STYLE ENEMY AI
# =============================================================================
# Patrols platforms, detects the player, chases and attacks with melee combos
# and a ranged sword throw. Can shield briefly. Telegraphed attacks with
# recovery windows the player can punish.
#
# BUG FIXES:
# - Areas (AttackArea, Hitbox, WallRay) now flip with facing_direction
# - WallRay used for proper forward wall detection
# - Chase no longer gets stuck in wall→idle→chase loop
# - Attack/combat checks run before edge/wall bailout in chase
# =============================================================================

# --- Stats ---
@export var max_health := 5
@export var contact_damage := 1

# --- Movement ---
@export var PATROL_SPEED := 40.0
@export var CHASE_SPEED := 70.0
@export var GRAVITY := 900.0
@export var MAX_FALL_SPEED := 500.0
@export var JUMP_VELOCITY := -300.0
@export var JUMP_COOLDOWN := 1.2

# --- Combat ---
@export var ATTACK_RANGE := 35.0
@export var DETECTION_RANGE := 120.0
@export var SWORD_THROW_RANGE := 100.0
@export var KNOCKBACK_FORCE := Vector2(120.0, -150.0)
@export var HURT_DURATION := 0.35
@export var ATTACK_COOLDOWN := 1.0
@export var SHIELD_CHANCE := 0.2
@export var SHIELD_DURATION := 0.6
@export var SWORD_THROW_COOLDOWN := 4.0

# --- Patrol ---
@export var IDLE_WAIT_TIME := 1.5
@export var AGGRO_LINGER_TIME := 3.0  # How long to stay aggro after losing sight

# --- State ---
enum State { IDLE, PATROL, CHASE, ATTACK, SWORD_THROW, SHIELD, HURT, DEATH }
var state: State = State.IDLE

var health: int
var facing_direction: float = -1.0
var player: CharacterBody2D = null
var player_in_detection: bool = false
var player_in_attack_range: bool = false

# Timers
var idle_timer: float = 0.0
var attack_cooldown_timer: float = 0.0
var sword_throw_cooldown_timer: float = 0.0
var hurt_timer: float = 0.0
var shield_timer: float = 0.0
var aggro_timer: float = 0.0
var jump_cooldown_timer: float = 0.0

# Wall-stuck prevention: counts consecutive frames stuck at a wall during chase
var wall_stuck_timer: float = 0.0
const WALL_STUCK_PATIENCE := 0.8  # seconds before giving up and waiting

# Patrol safe-flip: when true, the enemy stopped for one frame and will flip next frame
var _patrol_flip_pending: bool = false
const WALL_NUDGE_PIXELS := 5.0  # pixels to push away from wall after flipping

var is_attacking: bool = false
var is_shielding: bool = false
var is_dead: bool = false

# Preload sword projectile
var sword_projectile_scene: PackedScene = preload("res://Scenes/skeleton_sword_projectile.tscn")

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var detection_area: Area2D = $DetectionArea
@onready var attack_area: Area2D = $AttackArea
@onready var hurtbox: Area2D = $Hurtbox
@onready var hitbox: Area2D = $Hitbox
@onready var floor_ray_left: RayCast2D = $FloorRayLeft
@onready var floor_ray_right: RayCast2D = $FloorRayRight
@onready var wall_ray: RayCast2D = $WallRay
@onready var health_bar: ProgressBar = $HealthBar

# Store default offsets for nodes that need to flip with facing_direction.
# These are the RIGHT-facing positions (positive X = forward).
var _attack_shape_offset: Vector2
var _hitbox_shape_offset: Vector2
var _wall_ray_base_pos: Vector2
var _wall_ray_target: Vector2


func _ready() -> void:
	health = max_health
	idle_timer = IDLE_WAIT_TIME * randf_range(0.3, 1.0)
	hitbox.monitoring = false

	# Cache the default (right-facing) offsets
	_attack_shape_offset = $AttackArea/AttackShape.position
	_hitbox_shape_offset = $Hitbox/HitboxShape.position
	_wall_ray_base_pos = wall_ray.position
	_wall_ray_target = wall_ray.target_position

	animated_sprite.animation_finished.connect(_on_animation_finished)
	detection_area.body_entered.connect(_on_detection_entered)
	detection_area.body_exited.connect(_on_detection_exited)
	attack_area.body_entered.connect(_on_attack_range_entered)
	attack_area.body_exited.connect(_on_attack_range_exited)
	hurtbox.area_entered.connect(_on_hurtbox_area_entered)
	hitbox.body_entered.connect(_on_hitbox_body_entered)

	# Apply initial facing
	_flip_nodes()


func _physics_process(delta: float) -> void:
	if is_dead:
		return

	_tick_timers(delta)
	_apply_gravity(delta)

	# --- AGGRO PRIORITY: Chase always interrupts Patrol/Idle ---
	if state in [State.IDLE, State.PATROL] and _should_aggro():
		_patrol_flip_pending = false
		_enter_chase()

	match state:
		State.IDLE:
			_state_idle(delta)
		State.PATROL:
			_state_patrol(delta)
		State.CHASE:
			_state_chase(delta)
		State.ATTACK:
			_state_attack(delta)
		State.SWORD_THROW:
			_state_sword_throw(delta)
		State.SHIELD:
			_state_shield(delta)
		State.HURT:
			_state_hurt(delta)
		State.DEATH:
			pass

	move_and_slide()
	_update_sprite_direction()


# =============================================================================
# TIMERS
# =============================================================================

func _tick_timers(delta: float) -> void:
	attack_cooldown_timer -= delta
	sword_throw_cooldown_timer -= delta
	aggro_timer -= delta
	jump_cooldown_timer -= delta


# =============================================================================
# GRAVITY
# =============================================================================

func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y = minf(velocity.y + GRAVITY * delta, MAX_FALL_SPEED)


# =============================================================================
# STATE HANDLERS
# =============================================================================

func _state_idle(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, 200.0 * delta)
	_play_anim(&"Idle")

	if _should_aggro():
		_enter_chase()
		return

	idle_timer -= delta
	if idle_timer <= 0.0:
		state = State.PATROL


func _state_patrol(_delta: float) -> void:
	if _should_aggro():
		_patrol_flip_pending = false
		_enter_chase()
		return

	# --- Safe Flip (two-frame turn) ---
	# Frame 1: we detected wall/edge last frame → stopped. Now flip + nudge away.
	if _patrol_flip_pending:
		_patrol_flip_pending = false
		facing_direction = -facing_direction
		_flip_nodes()
		# Nudge away from the wall so the ray is no longer colliding
		global_position.x += WALL_NUDGE_PIXELS * facing_direction
		state = State.IDLE
		idle_timer = IDLE_WAIT_TIME * randf_range(0.5, 1.0)
		return

	# --- Detect obstacle: RayCast first (soft stop), is_on_wall() as backup ---
	if _is_at_edge() or _is_at_wall():
		# Frame 0: stop movement immediately, schedule flip for next frame
		velocity.x = 0.0
		_patrol_flip_pending = true
		_play_anim(&"Idle")
		return

	# Clear path — walk forward
	velocity.x = PATROL_SPEED * facing_direction
	_play_anim(&"Walk")


func _state_chase(delta: float) -> void:
	if player == null or not _should_aggro():
		# Lost the player — go back to patrol
		wall_stuck_timer = 0.0
		state = State.IDLE
		idle_timer = IDLE_WAIT_TIME
		return

	var dir_to_player: float = sign(player.global_position.x - global_position.x)
	if dir_to_player != 0.0 and dir_to_player != facing_direction:
		facing_direction = dir_to_player
		_flip_nodes()

	var dist: float = absf(player.global_position.x - global_position.x)

	# --- COMBAT CHECKS FIRST (before movement/obstacle checks) ---

	# Melee attack when close — highest priority
	if player_in_attack_range and attack_cooldown_timer <= 0.0:
		wall_stuck_timer = 0.0
		if randf() < SHIELD_CHANCE:
			_enter_shield()
		else:
			_enter_attack()
		return

	# Try sword throw at medium range
	if dist > ATTACK_RANGE and dist < SWORD_THROW_RANGE and sword_throw_cooldown_timer <= 0.0:
		wall_stuck_timer = 0.0
		_enter_sword_throw()
		return

	# --- MOVEMENT & OBSTACLE HANDLING ---

	# Don't walk off edges — stop and wait (but don't leave chase)
	if _is_at_edge():
		velocity.x = 0.0
		_play_anim(&"Idle")
		return

	# Wall handling: try to jump over it, don't get stuck
	if _is_at_wall():
		if is_on_floor() and jump_cooldown_timer <= 0.0:
			_do_jump()
			wall_stuck_timer = 0.0
		else:
			# Can't jump yet — accumulate stuck time
			wall_stuck_timer += delta
			velocity.x = 0.0
			_play_anim(&"Idle")
			if wall_stuck_timer >= WALL_STUCK_PATIENCE:
				# Give up chasing for a moment, don't leave aggro
				wall_stuck_timer = 0.0
				state = State.IDLE
				idle_timer = IDLE_WAIT_TIME * randf_range(0.3, 0.6)
		return

	# Clear path — chase the player
	wall_stuck_timer = 0.0
	velocity.x = CHASE_SPEED * facing_direction
	_play_anim(&"Walk")

	# Jump up to player if they're above us
	if is_on_floor() and jump_cooldown_timer <= 0.0:
		var player_above := player.global_position.y < global_position.y - 40.0
		if player_above:
			_do_jump()


func _state_attack(_delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, 300.0 * _delta)
	# Animation drives this state — wait for _on_animation_finished


func _state_sword_throw(_delta: float) -> void:
	velocity.x = 0.0
	# Animation drives this state


func _state_shield(_delta: float) -> void:
	velocity.x = 0.0
	shield_timer -= _delta
	if shield_timer <= 0.0:
		is_shielding = false
		state = State.IDLE
		idle_timer = 0.3


func _state_hurt(_delta: float) -> void:
	hurt_timer -= _delta
	if hurt_timer <= 0.0:
		if _should_aggro():
			_enter_chase()
		else:
			state = State.IDLE
			idle_timer = 0.5


# =============================================================================
# STATE TRANSITIONS
# =============================================================================

func _enter_chase() -> void:
	state = State.CHASE
	aggro_timer = AGGRO_LINGER_TIME
	wall_stuck_timer = 0.0


func _enter_attack() -> void:
	state = State.ATTACK
	is_attacking = true
	attack_cooldown_timer = ATTACK_COOLDOWN
	velocity.x = 0.0

	# Face the player before attacking
	if player != null:
		var dir: float = sign(player.global_position.x - global_position.x)
		if dir != 0.0 and dir != facing_direction:
			facing_direction = dir
			_flip_nodes()

	# Randomly pick Attack1 or Attack2
	var attack_anim: StringName = &"Attack1" if randf() > 0.5 else &"Attack2"
	animated_sprite.play(attack_anim)

	# Enable hitbox partway through the attack (frame signal would be ideal,
	# but we use a simple timer approach via _on_animation_finished)
	hitbox.monitoring = true


func _enter_sword_throw() -> void:
	state = State.SWORD_THROW
	is_attacking = true
	sword_throw_cooldown_timer = SWORD_THROW_COOLDOWN
	attack_cooldown_timer = ATTACK_COOLDOWN
	velocity.x = 0.0

	if player != null:
		var dir: float = sign(player.global_position.x - global_position.x)
		if dir != 0.0 and dir != facing_direction:
			facing_direction = dir
			_flip_nodes()

	animated_sprite.play(&"Attack3 SwordThrow")


func _enter_shield() -> void:
	state = State.SHIELD
	is_shielding = true
	shield_timer = SHIELD_DURATION
	attack_cooldown_timer = ATTACK_COOLDOWN * 0.5
	velocity.x = 0.0
	_play_anim(&"Shield")


func _enter_hurt(knockback_dir: float) -> void:
	if is_dead:
		return
	state = State.HURT
	hurt_timer = HURT_DURATION
	is_attacking = false
	hitbox.monitoring = false
	is_shielding = false
	# Reset patrol flip state so we don't resume into a stale pending flip
	_patrol_flip_pending = false
	# After stagger, face away from the knockback source so patrol walks
	# away from the wall we may have been pushed into
	facing_direction = knockback_dir
	_flip_nodes()
	velocity.x = KNOCKBACK_FORCE.x * knockback_dir
	velocity.y = KNOCKBACK_FORCE.y
	animated_sprite.play(&"TakeHit")


func _enter_death() -> void:
	is_dead = true
	state = State.DEATH
	is_attacking = false
	hitbox.monitoring = false
	velocity.x = 0.0
	velocity.y = 0.0

	# Disable all collision so the corpse doesn't block anything
	collision_shape.set_deferred("disabled", true)
	hurtbox.set_deferred("monitoring", false)
	hurtbox.set_deferred("monitorable", false)
	detection_area.set_deferred("monitoring", false)
	attack_area.set_deferred("monitoring", false)

	animated_sprite.play(&"Death")


# =============================================================================
# DAMAGE
# =============================================================================

func take_damage(amount: int, from_position: Vector2) -> void:
	if is_dead:
		return

	# Shield blocks damage from the front
	if is_shielding:
		var attack_dir: float = sign(from_position.x - global_position.x)
		if sign(facing_direction) == sign(attack_dir):
			# Blocked! Small pushback only
			velocity.x = -facing_direction * 30.0
			return

	health -= amount
	health_bar.update_health(health, max_health)
	if health <= 0:
		_enter_death()
	else:
		var knockback_dir: float = sign(global_position.x - from_position.x)
		if knockback_dir == 0.0:
			knockback_dir = 1.0
		_enter_hurt(knockback_dir)


# =============================================================================
# PROJECTILE
# =============================================================================

func _spawn_sword_projectile() -> void:
	var projectile := sword_projectile_scene.instantiate()
	get_parent().add_child(projectile)
	projectile.global_position = global_position + Vector2(facing_direction * 20.0, -26.0)
	if projectile.has_method("launch"):
		projectile.launch(facing_direction)


# =============================================================================
# SIGNALS
# =============================================================================

func _on_animation_finished() -> void:
	match state:
		State.ATTACK:
			hitbox.monitoring = false
			is_attacking = false
			if _should_aggro():
				_enter_chase()
			else:
				state = State.IDLE
				idle_timer = 0.4

		State.SWORD_THROW:
			_spawn_sword_projectile()
			is_attacking = false
			if _should_aggro():
				_enter_chase()
			else:
				state = State.IDLE
				idle_timer = 0.6

		State.DEATH:
			# Fade out and free
			var tween: Tween = create_tween()
			tween.tween_property(animated_sprite, "modulate:a", 0.0, 0.8)
			tween.tween_callback(queue_free)


func _on_detection_entered(body: Node2D) -> void:
	if body is CharacterBody2D and body != self:
		player = body
		player_in_detection = true
		aggro_timer = AGGRO_LINGER_TIME


func _on_detection_exited(body: Node2D) -> void:
	if body == player:
		player_in_detection = false


func _on_attack_range_entered(body: Node2D) -> void:
	if body == player:
		player_in_attack_range = true


func _on_attack_range_exited(body: Node2D) -> void:
	if body == player:
		player_in_attack_range = false


func _on_hurtbox_area_entered(area: Area2D) -> void:
	# Hit by player's arrow or attack
	if area.is_in_group("player_attack"):
		var damage := 1
		if area.has_meta("damage"):
			damage = area.get_meta("damage")
		take_damage(damage, area.global_position)


func _on_hitbox_body_entered(body: Node2D) -> void:
	# Deal contact damage to player
	if body is CharacterBody2D and body != self and body.has_method("take_damage"):
		body.take_damage(contact_damage, global_position)


# =============================================================================
# HELPERS
# =============================================================================

func _should_aggro() -> bool:
	return player_in_detection or aggro_timer > 0.0


func _is_at_edge() -> bool:
	if not is_on_floor():
		return false
	if facing_direction < 0.0:
		return not floor_ray_left.is_colliding()
	else:
		return not floor_ray_right.is_colliding()


func _is_at_wall() -> bool:
	# Use the WallRay for proper forward-facing wall detection.
	# The ray is already flipped by _flip_nodes() to point in facing_direction.
	return wall_ray.is_colliding()


func _do_jump() -> void:
	velocity.y = JUMP_VELOCITY
	jump_cooldown_timer = JUMP_COOLDOWN


func _play_anim(anim_name: StringName) -> void:
	if animated_sprite.animation != anim_name:
		animated_sprite.play(anim_name)


## Flip directional child nodes (AttackShape, HitboxShape, WallRay) to match
## the current facing_direction. Call this whenever facing_direction changes.
func _flip_nodes() -> void:
	var sign_f := signf(facing_direction) if facing_direction != 0.0 else 1.0

	# Flip the attack area shape offset (e.g. +15 → -15 when facing left)
	$AttackArea/AttackShape.position.x = _attack_shape_offset.x * sign_f

	# Flip the hitbox shape offset
	$Hitbox/HitboxShape.position.x = _hitbox_shape_offset.x * sign_f

	# Flip the wall ray: mirror both its position and target
	wall_ray.position.x = _wall_ray_base_pos.x * sign_f
	wall_ray.target_position.x = _wall_ray_target.x * sign_f


func _update_sprite_direction() -> void:
	if facing_direction < 0.0:
		animated_sprite.flip_h = true
	else:
		animated_sprite.flip_h = false

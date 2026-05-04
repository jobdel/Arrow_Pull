extends CharacterBody2D

# =============================================================================
# PRECISION PLATFORMER PLAYER CONTROLLER
# =============================================================================
# Inspired by the game feel of Hollow Knight and Celeste. Core philosophy:
# instant response, no floaty movement, generous input windows.
#
# Animation System: State-driven with three-part attack sequencing
# (Start → Loop → End) using await for smooth transitions.
# =============================================================================

# --- Movement ---
@export var SPEED := 240.0
@export var ACCELERATION := 2000.0
@export var FRICTION := 2000.0

# --- Jump ---
@export var JUMP_VELOCITY := -320.0
@export var JUMP_CUT_MULTIPLIER := 0.4

# --- Gravity (asymmetric: floaty rise, snappy fall) ---
@export var GRAVITY_UP := 900.0
@export var GRAVITY_DOWN := 1200.0
@export var MAX_FALL_SPEED := 500.0

# --- Coyote Time & Jump Buffer ---
@export var COYOTE_TIME := 0.1
@export var JUMP_BUFFER_TIME := 0.1

# --- Dash ---
@export var DASH_SPEED := 600.0
@export var DASH_DURATION := 0.18
@export var DASH_COOLDOWN := 0.3

# --- Wall Slide & Wall Jump ---
@export var WALL_SLIDE_SPEED := 120.0
@export var WALL_JUMP_VELOCITY := Vector2(200.0, -300.0)
@export var WALL_JUMP_LOCK_TIME := 0.15

# --- Double Jump ---
@export var MAX_AIR_JUMPS := 1
@export var AIR_JUMP_VELOCITY := -290.0

# --- Shooting ---
@export var SHOOT_COOLDOWN := 0.2
@export var ARROW_MUZZLE_OFFSET := Vector2(14.0, -6.0)

# --- Corner Cutting (Apex Correction) ---
@export var CORNER_CORRECTION_AMOUNT := 6.0

# --- Health ---
@export var MAX_HEALTH := 5
@export var INVINCIBILITY_TIME := 1.0

# --- Attack ---
@export var ATTACK_LOOP_DURATION := 0.3  # How long the attack loop plays if button isn't held
@export var ATTACK_HOLD_TO_EXTEND := true  # If true, holding attack extends the loop

# --- Melee Attack ---
@export var MELEE_DAMAGE := 2
@export var MELEE_COMBO_WINDOW := 0.4  # Seconds after first swing to input follow-up

# --- Rope Arrow / Swinging ---
@export var SWING_INPUT_FORCE := 600.0
@export var GRAPPLE_JUMP_BOOST := -280.0
@export var ROPE_SHOOT_COOLDOWN := 0.5
# --- Rope Arrow / Pull Mode ---
@export var PULL_SPEED := 400.0         # px/s — constant winch velocity toward anchor
@export var PULL_ARRIVAL_DIST := 28.0   # px  — distance at which pull auto-cancels

# =============================================================================
# STATE ENUMS
# =============================================================================

enum State { IDLE, RUN, JUMP, FALL, DASH, WALL_SLIDE, CROUCH, ATTACK, DEATH, SWINGING, PULLING, MELEE_ATTACK, BALL_THROW }
enum AttackType { NORMAL, HIGH, LOW }
enum AttackPhase { START, LOOP, END }

# Animation name mapping for the three-part attack system.
const ATTACK_ANIMS := {
	AttackType.NORMAL: { "start": &"StartNormalAttack", "loop": &"NormalAttackLoop", "end": &"EndNormalAttack" },
	AttackType.HIGH:   { "start": &"StartHighAttack",   "loop": &"HighAttackLoop",   "end": &"EndHighAttack" },
	AttackType.LOW:    { "start": &"StartCrouchAttack",  "loop": &"CrouchAttackLoop",  "end": &"EndCrouchAttack" },
}

# Animations that must NOT loop (played once for transitions)
const NON_LOOPING_ANIMS: Array[StringName] = [
	&"Dash", &"Death", &"StartCrouch", &"ResumeStanding",
	&"StartNormalAttack", &"StartHighAttack", &"StartCrouchAttack",
	&"EndNormalAttack", &"EndHighAttack", &"EndCrouchAttack",
	&"MeleeAttack", &"MeleeAttackFollowUp",
]

# =============================================================================
# STATE VARIABLES
# =============================================================================

var state: State = State.IDLE
var attack_type: AttackType = AttackType.NORMAL
var attack_phase: AttackPhase = AttackPhase.START

# Timers (manual for frame-precise control — no Timer nodes)
var coyote_timer: float = 0.0
var jump_buffer_timer: float = 0.0
var dash_timer: float = 0.0
var dash_cooldown_timer: float = 0.0
var wall_jump_lock_timer: float = 0.0
var shoot_cooldown_timer: float = 0.0
var attack_loop_timer: float = 0.0

var facing_direction: float = 1.0  # 1.0 = right, -1.0 = left
var has_dash: bool = true
var was_on_floor: bool = false
var air_jumps_left: int = 0
var is_dead: bool = false
var health: int
var invincibility_timer: float = 0.0

# Flags for async animation sequencing
var _in_attack_sequence: bool = false
var _in_crouch_transition: bool = false
var _in_dash_start: bool = false
var _in_melee_sequence: bool = false
var _melee_combo_queued: bool = false
var _melee_combo_timer: float = 0.0

## Mirrors TetherSystem.is_spinning — true while the player holds "spin_ball".
## Read by animation, VFX, and any system that needs to know the ball is winding up.
var is_spinning: bool = false

# --- Rope Arrow State ---
var rope_arrow: Node2D = null           # Active rope arrow instance
var rope_length: float = 0.0            # Tether radius when swinging
var rope_shoot_cooldown_timer: float = 0.0

var arrow_scene: PackedScene = preload("res://Scenes/arrow.tscn")
var rope_arrow_scene: PackedScene = preload("res://Scenes/rope_arrow.tscn")
var health_bar_scene: PackedScene = preload("res://Scenes/custom_health_bar.tscn")

# --- Tether System ---
var tether_system: Node2D  # TetherSystem.gd instance (child node)

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision_shape: CollisionShape2D = $CollisionShapePlayer
@onready var wall_ray_left: RayCast2D = $WallRayLeft
@onready var wall_ray_right: RayCast2D = $WallRayRight
@onready var head_ray_left: RayCast2D = $HeadRayLeft
@onready var head_ray_right: RayCast2D = $HeadRayRight
@onready var melee_hitbox: Area2D = $MeleeHitbox

var health_bar: ProgressBar


func _ready() -> void:
	add_to_group("player")
	_setup_animation_loops()
	_register_crouch_input()

	health = MAX_HEALTH
	health_bar = health_bar_scene.instantiate()
	add_child(health_bar)
	health_bar.update_health(health, MAX_HEALTH)

	# Setup melee hitbox
	melee_hitbox.add_to_group("player_attack")
	melee_hitbox.set_meta("damage", MELEE_DAMAGE)
	melee_hitbox.monitoring = false
	melee_hitbox.monitorable = true
	animated_sprite.frame_changed.connect(_on_frame_changed)

	# Setup tether system (expects a TetherSystem child node)
	tether_system = get_node_or_null("TetherSystem")
	if not tether_system:
		# Auto-create if not placed in scene tree
		var ts := preload("res://Scripts/TetherSystem.gd")
		tether_system = Node2D.new()
		tether_system.set_script(ts)
		tether_system.name = "TetherSystem"
		add_child(tether_system)

	# Wire camera shake — fires whenever the ball lands a Hard Smash.
	# Uses call_deferred so TetherSystem._ready() has run before we connect.
	tether_system.call_deferred("connect", "hard_smash_hit", _on_hard_smash_hit)


func _physics_process(delta: float) -> void:
	if is_dead:
		# During death, only apply gravity so the body settles
		_apply_gravity(delta)
		move_and_slide()
		return

	_tick_timers(delta)

	var input_dir := Input.get_axis("move_left", "move_right")

	# Lock facing direction during attack Start/End phases and dash start
	var movement_locked := _is_movement_locked()
	if not movement_locked and input_dir != 0.0:
		facing_direction = sign(input_dir)

	_update_coyote_time()
	_update_jump_buffer()

	# --- State machine ---
	match state:
		State.IDLE:
			_state_idle(delta, input_dir)
		State.RUN:
			_state_run(delta, input_dir)
		State.JUMP:
			_state_jump(delta, input_dir)
		State.FALL:
			_state_fall(delta, input_dir)
		State.DASH:
			_state_dash(delta, input_dir)
		State.WALL_SLIDE:
			_state_wall_slide(delta, input_dir)
		State.CROUCH:
			_state_crouch(delta, input_dir)
		State.ATTACK:
			_state_attack(delta, input_dir)
		State.MELEE_ATTACK:
			_state_melee_attack(delta, input_dir)
		State.SWINGING:
			_state_swinging(delta, input_dir)
		State.PULLING:
			_state_pulling(delta, input_dir)
		State.BALL_THROW:
			_state_ball_throw(delta, input_dir)

	# --- Rope Arrow Input (available from any non-locked state) ---
	var _rope_blocked := state == State.SWINGING or state == State.PULLING or state == State.MELEE_ATTACK or state == State.DEATH or state == State.BALL_THROW
	if not _rope_blocked and (state != State.ATTACK or attack_type == AttackType.LOW):
		if Input.is_action_just_pressed("Shoot Rope"):
			_try_shoot_rope()

	# --- Ball Throw Input (Action button) ---
	if state != State.BALL_THROW and state != State.DEATH and state != State.SWINGING and state != State.PULLING:
		if Input.is_action_just_pressed("Shoot Ball") and tether_system:
			_do_ball_throw()

	# --- Ball & Chain Visibility Toggle ---
	if Input.is_action_just_pressed("show ball") and tether_system:
		tether_system.chain_visible = not tether_system.chain_visible

	# --- Sync is_spinning from TetherSystem ---
	is_spinning = tether_system != null and tether_system.is_spinning

	# --- Tether tension is handled inside TetherSystem._enforce_tether() ---
	# It applies dynamic weight only when the chain is taut AND the player is
	# moving away from the ball. When slack, the player moves at full speed.

	move_and_slide()

	# Corner correction runs AFTER move_and_slide so we can detect the ceiling hit
	if state == State.JUMP and is_on_ceiling():
		_try_corner_correction()

	_update_animation(input_dir)


# =============================================================================
# SETUP
# =============================================================================

## Ensures transition animations play once instead of looping.
## Call this in _ready() so you don't have to manually fix each one in the editor.
func _setup_animation_loops() -> void:
	for anim_name in NON_LOOPING_ANIMS:
		if animated_sprite.sprite_frames.has_animation(anim_name):
			animated_sprite.sprite_frames.set_animation_loop(anim_name, false)


## Registers "crouch" input action at runtime if it doesn't exist.
## Mapped to S and Down Arrow. You can also add this in Project → Input Map.
func _register_crouch_input() -> void:
	if not InputMap.has_action("crouch"):
		InputMap.add_action("crouch")
		# S key
		var s_key := InputEventKey.new()
		s_key.physical_keycode = KEY_S
		InputMap.action_add_event("crouch", s_key)
		# Down arrow
		var down_key := InputEventKey.new()
		down_key.physical_keycode = KEY_DOWN
		InputMap.action_add_event("crouch", down_key)


# =============================================================================
# TIMERS & INPUT BOOKKEEPING
# =============================================================================

func _tick_timers(delta: float) -> void:
	coyote_timer -= delta
	jump_buffer_timer -= delta
	dash_timer -= delta
	dash_cooldown_timer -= delta
	wall_jump_lock_timer -= delta
	shoot_cooldown_timer -= delta
	rope_shoot_cooldown_timer -= delta
	if attack_loop_timer > 0.0:
		attack_loop_timer -= delta
	if _melee_combo_timer > 0.0:
		_melee_combo_timer -= delta
	if invincibility_timer > 0.0:
		invincibility_timer -= delta
		# Flash the sprite during invincibility
		animated_sprite.modulate.a = 0.4 if fmod(invincibility_timer, 0.16) < 0.08 else 1.0
		if invincibility_timer <= 0.0:
			animated_sprite.modulate.a = 1.0


func _update_coyote_time() -> void:
	if was_on_floor and not is_on_floor():
		if state != State.JUMP and state != State.DASH:
			coyote_timer = COYOTE_TIME
	was_on_floor = is_on_floor()


func _update_jump_buffer() -> void:
	if Input.is_action_just_pressed("jump"):
		jump_buffer_timer = JUMP_BUFFER_TIME


## Returns true when the player should not move or flip direction.
## This gives attack start/end animations and dash startup their "weight".
func _is_movement_locked() -> bool:
	if _in_dash_start:
		return true
	if _in_crouch_transition:
		return true
	return false


# =============================================================================
# STATE HANDLERS
# =============================================================================

func _state_idle(delta: float, input_dir: float) -> void:
	_apply_gravity(delta)
	_apply_horizontal_movement(delta, input_dir)

	if _try_melee():
		return
	if _try_attack():
		return
	if _try_crouch():
		return
	if _try_jump():
		return
	if _try_dash():
		return

	if not is_on_floor():
		state = State.FALL
	elif input_dir != 0.0:
		state = State.RUN


func _state_run(delta: float, input_dir: float) -> void:
	_apply_gravity(delta)
	_apply_horizontal_movement(delta, input_dir)

	if _try_melee():
		return
	if _try_attack():
		return
	if _try_crouch():
		return
	if _try_jump():
		return
	if _try_dash():
		return

	if not is_on_floor():
		state = State.FALL
	elif input_dir == 0.0:
		state = State.IDLE


func _state_jump(delta: float, input_dir: float) -> void:
	_apply_gravity(delta)
	_apply_horizontal_movement(delta, input_dir)

	# Variable jump height: release early = short hop
	if Input.is_action_just_released("jump") and velocity.y < 0.0:
		velocity.y *= JUMP_CUT_MULTIPLIER

	if _try_melee():
		return
	if _try_attack():
		return
	if _try_wall_jump():
		return
	if _try_air_jump():
		return
	if _try_dash():
		return

	if velocity.y >= 0.0:
		if _is_on_wall_and_holding_toward_it(input_dir):
			state = State.WALL_SLIDE
			return
		state = State.FALL
	elif _is_on_wall_and_holding_toward_it(input_dir) and velocity.y >= 0.0:
		state = State.WALL_SLIDE


func _state_fall(delta: float, input_dir: float) -> void:
	_apply_gravity(delta)
	_apply_horizontal_movement(delta, input_dir)

	if _try_melee():
		return
	if _try_attack():
		return
	if _try_jump():
		return
	if _try_wall_jump():
		return
	if _try_air_jump():
		return
	if _try_dash():
		return

	if _is_on_wall_and_holding_toward_it(input_dir):
		state = State.WALL_SLIDE
		return

	if is_on_floor():
		if jump_buffer_timer > 0.0:
			_do_jump()
			return
		has_dash = true
		air_jumps_left = MAX_AIR_JUMPS
		state = State.IDLE if input_dir == 0.0 else State.RUN


func _state_dash(_delta: float, _input_dir: float) -> void:
	if dash_timer > 0.0:
		velocity.x = DASH_SPEED * facing_direction
		velocity.y = 0.0
	else:
		velocity.x = SPEED * facing_direction * 0.5
		if is_on_floor():
			has_dash = true
			air_jumps_left = MAX_AIR_JUMPS
			state = State.IDLE
		else:
			state = State.FALL


func _state_wall_slide(delta: float, input_dir: float) -> void:
	velocity.y = minf(velocity.y + GRAVITY_DOWN * delta, WALL_SLIDE_SPEED)

	if Input.is_action_just_pressed("jump"):
		var wall_dir := _get_wall_direction()
		velocity.x = WALL_JUMP_VELOCITY.x * -wall_dir
		velocity.y = WALL_JUMP_VELOCITY.y
		wall_jump_lock_timer = WALL_JUMP_LOCK_TIME
		facing_direction = -wall_dir
		air_jumps_left = MAX_AIR_JUMPS
		state = State.JUMP
		return

	if _try_dash():
		return

	if not _is_on_wall_and_holding_toward_it(input_dir):
		state = State.FALL

	if is_on_floor():
		has_dash = true
		air_jumps_left = MAX_AIR_JUMPS
		state = State.IDLE if input_dir == 0.0 else State.RUN


func _state_crouch(_delta: float, _input_dir: float) -> void:
	# Crouch keeps the player still on the ground
	_apply_gravity(_delta)
	velocity.x = move_toward(velocity.x, 0.0, FRICTION * _delta)

	if not is_on_floor():
		state = State.FALL
		return

	# Attack from crouch = Low attack
	if Input.is_action_just_pressed("Shoot Arrow") and not _in_crouch_transition:
		_start_attack(AttackType.LOW)
		return

	# Release crouch → play ResumeStanding then return to Idle
	if not Input.is_action_pressed("crouch") and not _in_crouch_transition:
		_resume_standing()


func _state_attack(delta: float, _input_dir: float) -> void:
	_apply_gravity(delta)
	if attack_type == AttackType.LOW:
		# Crouch shooting: can move but slower than walking
		var crouch_speed := SPEED * 0.4
		if _input_dir != 0.0:
			velocity.x = move_toward(velocity.x, _input_dir * crouch_speed, ACCELERATION * delta)
		else:
			velocity.x = move_toward(velocity.x, 0.0, FRICTION * delta)
	else:
		_apply_horizontal_movement(delta, _input_dir)


func _state_melee_attack(delta: float, _input_dir: float) -> void:
	_apply_gravity(delta)
	# Slow movement during melee — player can drift but not run
	velocity.x = move_toward(velocity.x, 0.0, FRICTION * 0.5 * delta)
	# Queue combo if player presses melee during the first swing
	if Input.is_action_just_pressed("MeleeAttack") and _melee_combo_timer > 0.0:
		_melee_combo_queued = true


# =============================================================================
# ATTACK SYSTEM (Three-Part: Start → Loop → End)
# =============================================================================

func _try_attack() -> bool:
	if not Input.is_action_just_pressed("Shoot Arrow"):
		return false
	if _in_attack_sequence:
		return false

	# Determine attack type based on held direction
	if Input.is_action_pressed("Look Up"):
		_start_attack(AttackType.HIGH)
	elif state == State.CROUCH:
		_start_attack(AttackType.LOW)
	else:
		_start_attack(AttackType.NORMAL)
	return true


func _start_attack(type: AttackType) -> void:
	state = State.ATTACK
	attack_type = type
	attack_phase = AttackPhase.START
	_in_attack_sequence = true
	attack_loop_timer = ATTACK_LOOP_DURATION

	var anims: Dictionary = ATTACK_ANIMS[type]

	# --- START phase: play once, lock movement ---
	animated_sprite.speed_scale = 2.0
	animated_sprite.play(anims["start"])
	await animated_sprite.animation_finished

	# Guard: if we died or state changed during await, bail out
	if is_dead or state != State.ATTACK:
		_in_attack_sequence = false
		animated_sprite.speed_scale = 1.0
		return

	# --- LOOP phase: play while held or until timer expires ---
	attack_phase = AttackPhase.LOOP
	animated_sprite.play(anims["loop"])

	# Spawn arrow during ranged attack loops
	_spawn_attack_arrow()

	# Wait for either the button to be released or the timer to expire
	while state == State.ATTACK and attack_phase == AttackPhase.LOOP:
		if ATTACK_HOLD_TO_EXTEND:
			# Hold "Shoot Arrow" to keep looping; release to end
			if not Input.is_action_pressed("Shoot Arrow"):
				break
		else:
			# Timer-based: loop for ATTACK_LOOP_DURATION then end
			if attack_loop_timer <= 0.0:
				break
		await get_tree().process_frame

	# Guard again
	if is_dead or state != State.ATTACK:
		_in_attack_sequence = false
		animated_sprite.speed_scale = 1.0
		return

	# --- END phase: play once, lock movement ---
	attack_phase = AttackPhase.END
	var end_anim: StringName = anims["end"]
	if animated_sprite.sprite_frames.has_animation(end_anim):
		animated_sprite.play(end_anim)
		await animated_sprite.animation_finished
	else:
		# Fallback: replay the start animation as the "end" wind-down
		animated_sprite.play(anims["start"])
		await animated_sprite.animation_finished

	_in_attack_sequence = false
	animated_sprite.speed_scale = 1.0

	# Guard once more
	if is_dead:
		return

	# Return to appropriate state
	if state == State.ATTACK:
		if not is_on_floor():
			state = State.FALL
		else:
			state = State.IDLE


## Spawns an arrow during the attack loop animation.
## Called for Normal and High attacks to integrate the archer mechanic.
func _spawn_attack_arrow() -> void:
	if shoot_cooldown_timer > 0.0:
		return

	shoot_cooldown_timer = SHOOT_COOLDOWN

	var arrow := arrow_scene.instantiate()
	get_parent().add_child(arrow)

	var offset := ARROW_MUZZLE_OFFSET
	offset.x *= facing_direction

	# High attacks shoot slightly upward, low attacks shoot lower
	if attack_type == AttackType.HIGH:
		offset.y -= 8.0
	elif attack_type == AttackType.LOW:
		offset.y += 10.0

	arrow.global_position = global_position + offset

	if arrow.has_method("launch"):
		var angle := 0.0
		if attack_type == AttackType.HIGH:
			angle = deg_to_rad(45.0)
		elif attack_type == AttackType.LOW:
			angle = deg_to_rad(-45.0)
		arrow.launch(facing_direction, angle)


# =============================================================================
# MELEE ATTACK SYSTEM
# =============================================================================

func _try_melee() -> bool:
	if not Input.is_action_just_pressed("MeleeAttack"):
		return false
	if _in_melee_sequence or _in_attack_sequence:
		return false
	_start_melee()
	return true


func _start_melee() -> void:
	state = State.MELEE_ATTACK
	_in_melee_sequence = true
	_melee_combo_queued = false
	_melee_combo_timer = 0.0

	# --- First swing ---
	animated_sprite.play(&"MeleeAttack")
	await animated_sprite.animation_finished

	if is_dead or state != State.MELEE_ATTACK:
		_end_melee()
		return

	# --- Combo window: allow follow-up ---
	_melee_combo_timer = MELEE_COMBO_WINDOW

	# Wait for combo input or timer expiry
	while state == State.MELEE_ATTACK and _melee_combo_timer > 0.0:
		if _melee_combo_queued:
			break
		await get_tree().process_frame

	if is_dead or state != State.MELEE_ATTACK:
		_end_melee()
		return

	# --- Follow-up swing if queued ---
	if _melee_combo_queued:
		_melee_combo_queued = false
		animated_sprite.play(&"MeleeAttackFollowUp")
		await animated_sprite.animation_finished

	_end_melee()

	if is_dead:
		return

	# Return to appropriate state
	if state == State.MELEE_ATTACK:
		if not is_on_floor():
			state = State.FALL
		else:
			state = State.IDLE


func _end_melee() -> void:
	_in_melee_sequence = false
	_melee_combo_queued = false
	_melee_combo_timer = 0.0
	melee_hitbox.monitoring = false
	melee_hitbox.monitorable = false


## Enable/disable the melee hitbox based on animation frames.
## Active during the "swing" frames of MeleeAttack and MeleeAttackFollowUp.
func _on_frame_changed() -> void:
	if state != State.MELEE_ATTACK:
		melee_hitbox.monitoring = false
		melee_hitbox.monitorable = false
		return

	var anim := animated_sprite.animation
	var frame := animated_sprite.frame

	# MeleeAttack: 11 frames at 12fps — hitbox active on frames 4-7 (the swing)
	# MeleeAttackFollowUp: 11 frames at 12fps — hitbox active on frames 4-7
	if anim == &"MeleeAttack" or anim == &"MeleeAttackFollowUp":
		var active := frame >= 4 and frame <= 7
		melee_hitbox.monitoring = active
		melee_hitbox.monitorable = active
	else:
		melee_hitbox.monitoring = false
		melee_hitbox.monitorable = false


# =============================================================================
# CROUCH SYSTEM
# =============================================================================

func _try_crouch() -> bool:
	if not Input.is_action_just_pressed("crouch"):
		return false
	if not is_on_floor():
		return false

	_enter_crouch()
	return true


func _enter_crouch() -> void:
	state = State.CROUCH
	_in_crouch_transition = true

	animated_sprite.play(&"StartCrouch")
	await animated_sprite.animation_finished

	_in_crouch_transition = false

	# If player released crouch during the transition, stand back up
	if state == State.CROUCH and not Input.is_action_pressed("crouch"):
		_resume_standing()


func _resume_standing() -> void:
	_in_crouch_transition = true

	animated_sprite.play(&"ResumeStanding")
	await animated_sprite.animation_finished

	_in_crouch_transition = false

	if is_dead:
		return

	if state == State.CROUCH:
		state = State.IDLE


# =============================================================================
# DASH SYSTEM (Two-Part: Dash → DashLoop)
# =============================================================================

func _try_dash() -> bool:
	if Input.is_action_just_pressed("dash") and has_dash and dash_cooldown_timer <= 0.0:
		_do_dash()
		return true
	return false


func _do_dash() -> void:
	state = State.DASH
	dash_timer = DASH_DURATION
	dash_cooldown_timer = DASH_COOLDOWN
	has_dash = false
	velocity.y = 0.0
	velocity.x = DASH_SPEED * facing_direction

	# Scale the Dash animation speed so it fills the entire dash duration
	var frames := animated_sprite.sprite_frames
	var frame_count := frames.get_frame_count(&"Dash")
	var base_fps := frames.get_animation_speed(&"Dash")
	if base_fps > 0.0 and frame_count > 0:
		var natural_duration := float(frame_count) / base_fps
		animated_sprite.speed_scale = natural_duration / DASH_DURATION

	_in_dash_start = true
	animated_sprite.play(&"Dash")
	await animated_sprite.animation_finished

	animated_sprite.speed_scale = 1.0
	_in_dash_start = false


# =============================================================================
# DEATH
# =============================================================================

func take_damage(amount: int, _from_position: Vector2 = Vector2.ZERO) -> void:
	if is_dead or invincibility_timer > 0.0:
		return

	health -= amount
	health = maxi(health, 0)
	health_bar.update_health(health, MAX_HEALTH)

	if health <= 0:
		die()
		return

	# Brief invincibility after being hit
	invincibility_timer = INVINCIBILITY_TIME


## Call this from external scripts (e.g., when taking lethal damage).
func die() -> void:
	if is_dead:
		return

	is_dead = true
	state = State.DEATH
	_in_attack_sequence = false
	_in_crouch_transition = false
	_in_dash_start = false
	_in_melee_sequence = false
	melee_hitbox.monitoring = false
	melee_hitbox.monitorable = false
	velocity = Vector2.ZERO

	animated_sprite.play(&"Death")
	# Optionally await and then emit a signal, respawn, etc.
	# await animated_sprite.animation_finished
	# queue_free()  # or respawn logic


# =============================================================================
# BALL THROW (Prisoner Mechanic — Ball Dash)
# =============================================================================

func _do_ball_throw() -> void:
	if not tether_system:
		return
	var throw_dir := Vector2(facing_direction, 0.0)
	# If the player is holding a direction, use that instead.
	var input_vec := Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_up", "move_down")
	)
	if input_vec.length() > 0.1:
		throw_dir = input_vec.normalized()

	# Shoot ball + apply mini-dash. Player keeps full movement control.
	tether_system.shoot_ball(throw_dir)


func _state_ball_throw(_delta: float, _input_dir: float) -> void:
	# Player is never locked into BALL_THROW — transition immediately to normal state.
	state = State.FALL if not is_on_floor() else State.IDLE


# =============================================================================
# ROPE ARROW / SWINGING SYSTEM
# =============================================================================

func _try_shoot_rope() -> void:
	if rope_shoot_cooldown_timer > 0.0:
		return
	# If there's already a rope arrow out, disconnect it first
	if rope_arrow and is_instance_valid(rope_arrow):
		rope_arrow.disconnect_rope()
		rope_arrow = null

	rope_shoot_cooldown_timer = ROPE_SHOOT_COOLDOWN

	var arrow := rope_arrow_scene.instantiate()
	get_parent().add_child(arrow)

	var offset := ARROW_MUZZLE_OFFSET
	offset.x *= facing_direction
	arrow.global_position = global_position + offset
	arrow.owner_player = self

	if arrow.has_method("launch"):
		var angle := 0.0
		var mode := "pull"  # Default: horizontal or S → pull toward point
		if Input.is_action_pressed("Look Up"):
			angle = deg_to_rad(45.0)
			mode = "swing"  # W held → swing/pendulum
		elif Input.is_action_pressed("crouch"):
			angle = deg_to_rad(-45.0)
		arrow.launch(facing_direction, angle, mode)

	rope_arrow = arrow


## Called by RopeArrow when it sticks to a wall. Branches on the mode locked at launch.
func _enter_swinging(arrow: Node2D) -> void:
	rope_arrow = arrow
	air_jumps_left = MAX_AIR_JUMPS
	has_dash = true
	if arrow.grapple_mode == "pull":
		_enter_pulling()
		return
	rope_length = arrow.MAX_ROPE_LENGTH
	state = State.SWINGING


## Called by RopeArrow when the rope is disconnected, or by the player on jump
func _exit_swinging() -> void:
	if state == State.SWINGING or state == State.PULLING:
		state = State.FALL
	rope_arrow = null
	rope_length = 0.0


## Transitions into pull mode. Called from _enter_swinging() when mode == "pull".
func _enter_pulling() -> void:
	state = State.PULLING
	# Apply an immediate impulse toward the anchor so the pull feels snappy.
	var anchor: Vector2 = rope_arrow.anchor_point
	velocity = (anchor - global_position).normalized() * PULL_SPEED


## Swinging state: pendulum physics with tether constraint.
##
## HOW THE TETHER WORKS (prevents floor clipping):
## 1. Gravity and horizontal input are applied to velocity normally.
## 2. Before move_and_slide(), we check if the velocity would push the player
##    AWAY from the anchor (beyond rope_length).
## 3. If so, we remove the outward radial component of velocity — the player
##    can only move tangentially along the circle.
## 4. move_and_slide() then runs with the corrected velocity, handling floor
##    and wall collisions as usual.
##
## This means the floor still blocks the player (Godot's built-in collision),
## while the rope prevents them from swinging too far from the anchor.
## The player hangs naturally and swings like a pendulum.
func _state_swinging(delta: float, input_dir: float) -> void:
	if not rope_arrow or not is_instance_valid(rope_arrow):
		_exit_swinging()
		return

	var anchor: Vector2 = rope_arrow.anchor_point

	# --- Apply gravity ---
	var gravity := GRAVITY_UP if velocity.y < 0.0 else GRAVITY_DOWN
	velocity.y = minf(velocity.y + gravity * delta, MAX_FALL_SPEED)

	# --- Apply horizontal swing input ---
	velocity.x += input_dir * SWING_INPUT_FORCE * delta

	# --- Tether constraint ---
	# Predict where the player will be after this frame
	var predicted_pos: Vector2 = global_position + velocity * delta
	var to_predicted: Vector2 = predicted_pos - anchor
	var predicted_dist: float = to_predicted.length()

	if predicted_dist > rope_length and predicted_dist > 0.0:
		# Player would exceed rope length — constrain velocity
		# Get the radial direction (from anchor toward player)
		var radial_dir: Vector2 = (global_position - anchor).normalized()

		# Project velocity onto the radial direction
		var radial_speed: float = velocity.dot(radial_dir)

		# Only remove the outward component (positive = moving away from anchor)
		if radial_speed > 0.0:
			velocity -= radial_dir * radial_speed

	# --- Also snap position if already beyond rope_length (safety net) ---
	var current_offset: Vector2 = global_position - anchor
	if current_offset.length() > rope_length:
		global_position = anchor + current_offset.normalized() * rope_length

	# --- Jump to disconnect ---
	if Input.is_action_just_pressed("jump"):
		var swing_velocity := velocity  # Preserve swing momentum
		if rope_arrow and is_instance_valid(rope_arrow):
			rope_arrow.disconnect_rope()
		rope_arrow = null
		rope_length = 0.0
		state = State.JUMP
		velocity = swing_velocity
		velocity.y = minf(velocity.y, GRAPPLE_JUMP_BOOST)  # Upward boost
		return


## Pull mode: acts as a winch — locks velocity toward the anchor every frame.
## Gravity is suppressed so the player flies in a straight line to the point.
## Break conditions: arriving within PULL_ARRIVAL_DIST, or pressing jump.
func _state_pulling(_delta: float, _input_dir: float) -> void:
	if not rope_arrow or not is_instance_valid(rope_arrow):
		_exit_swinging()
		return

	var anchor: Vector2 = rope_arrow.anchor_point
	var to_anchor: Vector2 = anchor - global_position

	# --- Arrived — auto-cancel and land into normal air state ---
	if to_anchor.length() <= PULL_ARRIVAL_DIST:
		rope_arrow.disconnect_rope()
		return

	# --- Re-orient velocity each frame (handles curved geometry) ---
	velocity = to_anchor.normalized() * PULL_SPEED

	# --- Jump to cancel — eject with current momentum ---
	if Input.is_action_just_pressed("jump"):
		var eject_velocity := velocity
		rope_arrow.disconnect_rope()
		state = State.JUMP
		velocity = eject_velocity
		velocity.y = minf(velocity.y, GRAPPLE_JUMP_BOOST)


# =============================================================================
# SHARED MECHANICS
# =============================================================================

func _apply_gravity(delta: float) -> void:
	if is_on_floor():
		return
	var gravity := GRAVITY_UP if velocity.y < 0.0 else GRAVITY_DOWN
	velocity.y = minf(velocity.y + gravity * delta, MAX_FALL_SPEED)


func _apply_horizontal_movement(delta: float, input_dir: float) -> void:
	if wall_jump_lock_timer > 0.0:
		return
	if _is_movement_locked():
		velocity.x = move_toward(velocity.x, 0.0, FRICTION * delta)
		return

	if input_dir != 0.0:
		velocity.x = move_toward(velocity.x, input_dir * SPEED, ACCELERATION * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, FRICTION * delta)


func _try_jump() -> bool:
	var can_jump := is_on_floor() or coyote_timer > 0.0
	var wants_jump := Input.is_action_just_pressed("jump") or jump_buffer_timer > 0.0

	if can_jump and wants_jump:
		_do_jump()
		return true
	return false


func _do_jump() -> void:
	velocity.y = JUMP_VELOCITY
	coyote_timer = 0.0
	jump_buffer_timer = 0.0
	air_jumps_left = MAX_AIR_JUMPS
	state = State.JUMP
	# Slingshot effect: if the ball is swinging fast, its momentum pulls the player
	# higher / further in the direction the ball was travelling.
	if tether_system and tether_system.has_method("get_slingshot_velocity"):
		velocity += tether_system.get_slingshot_velocity()


func _try_air_jump() -> bool:
	if not Input.is_action_just_pressed("jump"):
		return false
	if is_on_floor() or coyote_timer > 0.0:
		return false
	if _get_wall_direction() != 0.0:
		return false
	if air_jumps_left <= 0:
		return false

	air_jumps_left -= 1
	velocity.y = AIR_JUMP_VELOCITY
	jump_buffer_timer = 0.0
	state = State.JUMP
	return true


func _try_wall_jump() -> bool:
	if not Input.is_action_just_pressed("jump"):
		return false
	var wall_dir := _get_wall_direction()
	if wall_dir == 0.0:
		return false

	velocity.x = WALL_JUMP_VELOCITY.x * -wall_dir
	velocity.y = WALL_JUMP_VELOCITY.y
	wall_jump_lock_timer = WALL_JUMP_LOCK_TIME
	facing_direction = -wall_dir
	jump_buffer_timer = 0.0
	air_jumps_left = MAX_AIR_JUMPS
	state = State.JUMP
	return true


# =============================================================================
# CORNER CUTTING (APEX CORRECTION)
# =============================================================================

func _try_corner_correction() -> void:
	var left_blocked := head_ray_left.is_colliding()
	var right_blocked := head_ray_right.is_colliding()

	if left_blocked == right_blocked:
		return

	if left_blocked:
		position.x += CORNER_CORRECTION_AMOUNT
	else:
		position.x -= CORNER_CORRECTION_AMOUNT

	velocity.y = minf(velocity.y, 0.0)


# =============================================================================
# WALL DETECTION
# =============================================================================

func _is_on_wall_and_holding_toward_it(input_dir: float) -> bool:
	if input_dir == 0.0:
		return false
	var wall_dir := _get_wall_direction()
	return wall_dir != 0.0 and sign(input_dir) == wall_dir


func _get_wall_direction() -> float:
	if wall_ray_left.is_colliding():
		return -1.0
	if wall_ray_right.is_colliding():
		return 1.0
	return 0.0


# =============================================================================
# ANIMATION
# =============================================================================

func _update_animation(input_dir: float) -> void:
	# --- Sprite flipping ---
	if facing_direction < 0.0:
		animated_sprite.flip_h = true
		collision_shape.position.x = -abs(collision_shape.position.x)
		melee_hitbox.position.x = -abs(melee_hitbox.position.x)
	else:
		animated_sprite.flip_h = false
		collision_shape.position.x = abs(collision_shape.position.x)
		melee_hitbox.position.x = abs(melee_hitbox.position.x)

	# States that manage their own animations via await — don't override them
	if state == State.DEATH:
		return
	if _in_attack_sequence:
		return
	if _in_melee_sequence:
		return
	if _in_crouch_transition:
		return
	if _in_dash_start:
		return

	var anim: StringName
	match state:
		State.DASH:
			anim = &"Dash"
		State.WALL_SLIDE:
			anim = &"Idle"
		State.SWINGING, State.PULLING:
			anim = &"Jump"  # Reuse jump/fall sprite while swinging or being pulled
		State.BALL_THROW:
			anim = &"Dash"  # Reuse dash sprite during ball throw tug-along
		State.JUMP, State.FALL:
			anim = &"Jump" if velocity.y < 0.0 else &"Jump"
			# If you add a "Fall" animation to your SpriteFrames, uncomment:
			# anim = &"Jump" if velocity.y < 0.0 else &"Fall"
		State.RUN:
			anim = &"Run"
		State.CROUCH:
			# After StartCrouch finishes, hold on the last frame (it's non-looping)
			# so the character stays crouched. No need to change animation.
			return
		_:
			anim = &"Idle"

	if animated_sprite.sprite_frames.has_animation(anim):
		if animated_sprite.animation != anim:
			animated_sprite.play(anim)
	else:
		if animated_sprite.animation != &"Idle":
			animated_sprite.play(&"Idle")


# =============================================================================
# CAMERA SHAKE (Hard Smash feedback)
# =============================================================================

## Receives the TetherSystem.hard_smash_hit signal and converts ball speed into
## a trauma value on the Camera2D (which must have CameraShake.gd attached).
##
## trauma formula: clamp(speed / 2000, 0.35, 1.0)
##   • A 700 px/s threshold-speed smash → 0.35 trauma  (light rumble)
##   • A 1400 px/s screamer             → 0.70 trauma  (big shake)
##   • 2000+ px/s cap                   → 1.00 trauma  (max shake)
func _on_hard_smash_hit(_enemy: Node, ball_speed: float, _approach_dot: float) -> void:
	var camera := get_node_or_null("Camera2D") as Camera2D
	if camera and camera.has_method("add_trauma"):
		camera.add_trauma(clampf(ball_speed / 2000.0, 0.35, 1.0))

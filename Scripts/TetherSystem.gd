extends Node2D
## Verlet-integration chain that connects the Player to a heavy Ball.
## Attach as a child of the Player (CharacterBody2D).
## NO PinJoint2D nodes — purely positional constraints + visual segments.

# --- Scenes ---
@export var segment_scene: PackedScene = preload("res://Scenes/chainsegment.tscn")
@export var ball_scene: PackedScene = preload("res://Scenes/ball.tscn")

# --- Chain Config ---
@export var SEGMENT_REST_DISTANCE: float = 9.0      # Exact pixel distance between each link
@export var constraint_iterations: int = 12         # 10-15 keeps chain rigid even at high player speed
@export var CHAIN_GRAVITY: float = 900.0            # Downward pull for slack droop (px/s²)

# --- Attachment Offset ---
## Offset from player.global_position where the chain visually attaches.
## Tweak X/Y in the Inspector to line up with your player sprite's hand/belt/shoulder.
@export var ATTACHMENT_OFFSET: Vector2 = Vector2(0, 16)

# Fixed segment count: always MAX_ROPE_LENGTH / SEGMENT_REST_DISTANCE
var _fixed_segment_count: int  # calculated in _ready

# --- Ball Config ---
@export var ball_mass: float = 10.0
@export var ball_linear_damp: float = 0.5           # Gentle settling damp when idle
@export var ball_damp_during_throw: float = 0.1    # Minimal drag while thrown

# --- Tether Config ---
@export var MAX_ROPE_LENGTH: float = 100.0
@export var MINI_DASH_POWER: float = 200.0          # Impulse added to player velocity on shoot

# --- Ball Dash Config ---
@export var THROW_IMPULSE: float = 2500.0
@export var THROW_COOLDOWN: float = 0.6
@export var HIGH_VELOCITY_THRESHOLD: float = 300.0  # Ball speed above which it deals damage
@export var BALL_DAMAGE: int = 3
@export var BALL_KNOCKBACK: float = 600.0

# --- Spin (Wind-up) ---
## Tangential force applied to the ball each physics frame while Spin is held.
@export var SPIN_FORCE: float = 3500.0
## Minimum speed the ball must reach before the tether auto-releases spin (optional feel tweak).
@export var SPIN_MAX_SPEED: float = 1200.0

# --- Centrifugal Force (Player Movement → Ball Momentum) ---
## Fraction of the player's per-frame velocity change transferred to the ball as an impulse.
## Higher = ball reacts more dramatically when the player runs/jumps/reverses direction.
@export var CENTRIFUGAL_FACTOR: float = 0.3

# --- Hard Smash Detection ---
## Ball speed above which a hit is classified as a Hard Smash (vs. Soft Touch).
@export var HARD_SMASH_THRESHOLD: float = 700.0
@export var HARD_SMASH_DAMAGE: int = 8
@export var HARD_SMASH_KNOCKBACK: float = 1200.0
## Seconds to freeze time on a Hard Smash (HitStop).
@export var HITSTOP_DURATION: float = 0.12

# --- Slingshot (Ball momentum → Player jump boost) ---
## Ball must be at least this fast for the slingshot to fire on jump.
@export var SLINGSHOT_MIN_SPEED: float = 400.0
## Fraction of ball velocity added to the player when they jump during a fast swing.
@export var SLINGSHOT_FRACTION: float = 0.45

# --- Chain Tightness Visual ---
## Ball speed above which the chain enforces exact segment distance (tight/taut look).
## Below this the chain is allowed to sag and go slack.
@export var CHAIN_TIGHT_SPEED: float = 150.0

# --- Runtime ---
## Emitted on every Hard Smash hit.
## approach_dot: 1.0 = perfectly head-on, 0.5 = minimum threshold.
signal hard_smash_hit(enemy: Node, ball_speed: float, approach_dot: float)

var player: CharacterBody2D
var ball: RigidBody2D

# Verlet points: index 0 = player anchor, last = ball anchor
# Each point: { pos: Vector2, old_pos: Vector2 }
var points: Array[Dictionary] = []
var segment_nodes: Array[Node2D] = []

var _throw_cooldown_timer: float = 0.0
var _ball_thrown: bool = false

## True while the player holds the "spin_ball" action — drives _apply_spin_force().
var is_spinning: bool = false

## Toggle to show/hide the ball and chain visuals (bound to "show ball" / B key).
var chain_visible: bool = true

# Previous player velocity — used to compute the per-frame velocity delta for centrifugal force.
var _prev_player_velocity: Vector2 = Vector2.ZERO

# HitStop state — tracked with real wall-clock time via Time.get_ticks_msec()
# so it fires correctly even when Engine.time_scale = 0.
var _hitstop_active: bool = false
var _hitstop_end_ms: int = 0

# Cached ray query — reused every frame to avoid per-frame allocation
var _ray_params: PhysicsRayQueryParameters2D


func _ready() -> void:
	player = get_parent() as CharacterBody2D
	assert(player != null, "TetherSystem must be a child of a CharacterBody2D")
	_fixed_segment_count = int(ceil(MAX_ROPE_LENGTH / SEGMENT_REST_DISTANCE))  # e.g. 500/8 = 63
	_spawn_ball()
	_build_chain_points()
	_spawn_segment_visuals()
	_ray_params = PhysicsRayQueryParameters2D.new()
	_ray_params.collision_mask = (1 << 0) | (1 << 1)  # layers 1-2: World geometry

	# Register "spin_ball" input action if not already in the project Input Map.
	# Default: Q key. Add a gamepad button in Project → Input Map if needed.
	if not InputMap.has_action("spin_ball"):
		InputMap.add_action("spin_ball")
		var q_key := InputEventKey.new()
		q_key.physical_keycode = KEY_Q
		InputMap.action_add_event("spin_ball", q_key)

	# HitStop is tracked with real-time via Time.get_ticks_msec() in _process.
	# Set PROCESS_MODE_ALWAYS so _process still runs while Engine.time_scale = 0.
	process_mode = Node.PROCESS_MODE_ALWAYS


# =============================================================================
# BALL CREATION
# =============================================================================

func _spawn_ball() -> void:
	var ball_instance := ball_scene.instantiate()

	# The ball.tscn root is Area2D — we need a RigidBody2D.
	ball = RigidBody2D.new()
	ball.name = "TetheredBall"
	ball.mass = ball_mass
	ball.linear_damp = ball_linear_damp   # 0.5 — ball settles without bouncing forever
	ball.gravity_scale = 1.0              # Full gravity: ball falls when chain is slack
	ball.freeze = false                   # FREEZE_MODE_OFF: engine owns physics

	# Attach Ball.gd so _integrate_forces can handle tether-aware gravity.
	ball.set_script(preload("res://Scripts/Ball.gd"))

	# Steal children from the Area2D instance
	var children_to_move: Array[Node] = []
	for child in ball_instance.get_children():
		children_to_move.append(child)
	for child in children_to_move:
		ball_instance.remove_child(child)
		ball.add_child(child)
	ball_instance.queue_free()

	# Ball collides with the World layer so it lands on floors, walls, etc.
	# Adjust the mask bits to match your project's Physics Layers panel.
	#   bit 0 (layer 1) = World / walls / floor geometry
	#   bit 1 (layer 2) = additional world geometry if split across two layers
	ball.collision_layer = 1 << 4                  # bit 5: "ball" layer
	ball.collision_mask  = (1 << 0) | (1 << 1)    # layers 1-2: World (floor + walls)
	ball.contact_monitor = true
	ball.max_contacts_reported = 4

	# Pass tether parameters to Ball.gd so _integrate_forces has what it needs.
	ball.player_ref        = player
	ball.tether_max_length = MAX_ROPE_LENGTH
	ball.anchor_offset     = ATTACHMENT_OFFSET

	# Place ball to the side of the player initially
	ball.global_position = player.global_position + Vector2(50, 0)

	# Add to the scene tree at the same level as the player so it moves independently
	player.get_parent().call_deferred("add_child", ball)

	# Connect body_entered for combat
	ball.body_entered.connect(_on_ball_body_entered)


# =============================================================================
# VERLET CHAIN SETUP
# =============================================================================

func _build_chain_points() -> void:
	points.clear()
	var start := player.global_position
	var end := ball.global_position if ball else start + Vector2(50, 0)

	# Always use a fixed number of segments to cover MAX_ROPE_LENGTH
	var count := _fixed_segment_count + 2  # +2 for player anchor and ball anchor

	for i in count:
		var t := float(i) / float(count - 1)
		var pos := start.lerp(end, t)
		points.append({ "pos": pos, "old_pos": pos })


func _spawn_segment_visuals() -> void:
	# Clear old segments
	for seg in segment_nodes:
		if is_instance_valid(seg):
			seg.queue_free()
	segment_nodes.clear()

	# Spawn one visual segment per internal point (skip first and last — those are anchors)
	for i in range(1, points.size() - 1):
		var seg := segment_scene.instantiate() as Node2D
		seg.name = "ChainSeg_%d" % i
		# Disable any collision on chain segments
		_disable_collision_recursive(seg)
		add_child(seg)
		segment_nodes.append(seg)


func _disable_collision_recursive(node: Node) -> void:
	if node is CollisionShape2D:
		(node as CollisionShape2D).disabled = true
	elif node is CollisionPolygon2D:
		(node as CollisionPolygon2D).disabled = true
	for child in node.get_children():
		_disable_collision_recursive(child)


# =============================================================================
# PHYSICS PROCESS
# =============================================================================

func _physics_process(delta: float) -> void:
	_throw_cooldown_timer -= delta

	# --- Spin input (held action) ---
	is_spinning = Input.is_action_pressed("spin_ball") and not _ball_thrown

	# --- Centrifugal force: player acceleration → ball momentum ---
	_apply_centrifugal_force()

	# --- Active spin: apply tangential force to whip ball in a circle ---
	_apply_spin_force(delta)

	# --- Pin endpoints (use attachment offset for player anchor) ---
	points[0]["pos"] = player.global_position + ATTACHMENT_OFFSET
	if ball and is_instance_valid(ball):
		points[-1]["pos"] = ball.global_position

	# --- Verlet integration for internal points ---
	_verlet_integrate(delta)

	# --- Distance constraints (tight when ball is fast, slack when slow) ---
	for _iter in constraint_iterations:
		_apply_constraints()

	# --- Update ball position from constraint (soft — apply as force) ---
	_apply_ball_constraint_force(delta)

	# --- Update segment visuals ---
	_update_segment_visuals()

	# --- Tether enforcement: snap ball if over max length (passive mode only) ---
	_enforce_tether()

	# --- End shot state when ball slows down ---
	_check_shot_end()

	# --- Ball damping management ---
	_update_ball_damp()


## Idle process — only active role is ending HitStop using real wall-clock time.
## Runs even at Engine.time_scale = 0 because process_mode = PROCESS_MODE_ALWAYS.
func _process(_delta: float) -> void:
	if _hitstop_active and Time.get_ticks_msec() >= _hitstop_end_ms:
		_hitstop_active = false
		Engine.time_scale = 1.0


# =============================================================================
# VERLET INTEGRATION
# =============================================================================

func _verlet_integrate(delta: float) -> void:
	var gravity := Vector2(0, CHAIN_GRAVITY)
	var space := get_world_2d().direct_space_state
	_ray_params.exclude = [ball.get_rid()]

	# Skip first (player) and last (ball) — they are pinned
	for i in range(1, points.size() - 1):
		var p := points[i]
		var current: Vector2 = p["pos"]
		var old: Vector2 = p["old_pos"]
		var vel := (current - old) * 0.98  # damping
		p["old_pos"] = current
		var next_pos := current + vel + gravity * delta * delta

		# Floor push: ray from current position to projected next position.
		# If the segment would pass through the floor, clamp it to the surface.
		_ray_params.from = current
		_ray_params.to = next_pos + Vector2(0, 2.0)  # 2px margin catches grazing hits
		var hit := space.intersect_ray(_ray_params)
		if hit:
			next_pos.y = (hit.position as Vector2).y
			# Reset old_pos Y so Verlet velocity doesn't pull the point back through
			p["old_pos"].y = next_pos.y

		p["pos"] = next_pos


func _apply_constraints() -> void:
	var last_idx := points.size() - 1
	# Chain is tight (enforce exact length) when ball is fast or actively spinning.
	# Chain is slack (only prevent over-extension, allow sag) when ball is slow.
	var tight := _is_chain_tight()

	for i in range(last_idx):
		var p1 := points[i]
		var p2 := points[i + 1]
		var pos1: Vector2 = p1["pos"]
		var pos2: Vector2 = p2["pos"]

		var diff := pos2 - pos1
		var dist := diff.length()
		if dist < 0.001:
			continue

		var error := dist - SEGMENT_REST_DISTANCE

		# Slack chain: skip the compression correction so gravity can create natural sag.
		# Segments are only pushed apart when too close on a TIGHT chain.
		if not tight and error < 0.0:
			continue

		var correction := diff.normalized() * error * 0.5

		# First and last points are pinned (player / ball)
		if i == 0:
			p2["pos"] = pos2 - correction * 2.0  # pin absorbs nothing
		elif i + 1 == last_idx:
			p1["pos"] = pos1 + correction * 2.0  # pin absorbs nothing
		else:
			p1["pos"] = pos1 + correction
			p2["pos"] = pos2 - correction


## True when the chain should be held taut: ball is moving fast OR player is spinning.
func _is_chain_tight() -> bool:
	if is_spinning:
		return true
	if not ball or not is_instance_valid(ball):
		return false
	return ball.linear_velocity.length() > CHAIN_TIGHT_SPEED


func _apply_ball_constraint_force(_delta: float) -> void:
	if not ball or not is_instance_valid(ball):
		return
	# While the ball is shot, let it fly free — no Verlet constraint.
	if _ball_thrown:
		return

	# The last verlet point may have shifted from constraints — nudge ball toward it
	var constrained_pos: Vector2 = points[-1]["pos"]
	var ball_pos := ball.global_position
	var diff := constrained_pos - ball_pos
	var dist := diff.length()

	# Strong force keeps the ball anchored to the chain endpoint
	if dist > 1.0:
		ball.apply_central_force(diff * 60.0 * ball.mass)
	# For large deviations, also snap the ball closer to prevent runaway
	if dist > SEGMENT_REST_DISTANCE * 3.0:
		ball.global_position = ball_pos + diff * 0.5


# =============================================================================
# TETHER ENFORCEMENT
# =============================================================================

func _enforce_tether() -> void:
	if not ball or not is_instance_valid(ball):
		return
	# While the ball is shot, don't clamp it — let it fly freely.
	if _ball_thrown:
		return

	var anchor := player.global_position + ATTACHMENT_OFFSET
	var to_ball := ball.global_position - anchor
	var dist := to_ball.length()

	# Chain is slack: nothing to do.
	if dist <= MAX_ROPE_LENGTH:
		return

	# Snap the ball back to max length — player velocity is never touched.
	var dir_to_ball := to_ball / dist
	var overshoot := dist - MAX_ROPE_LENGTH
	ball.global_position = anchor + dir_to_ball * MAX_ROPE_LENGTH
	ball.apply_central_impulse(-dir_to_ball * overshoot * ball.mass * 2.0)


## Returns the current tug force vector on the player.
## Always zero — the ball never pulls the player.
func get_drag_on_player() -> Vector2:
	return Vector2.ZERO


## Returns 0.0–1.0 tension ratio (used for UI/animation).
func get_tension_ratio() -> float:
	if not ball or not is_instance_valid(ball):
		return 0.0
	var dist := player.global_position.distance_to(ball.global_position)
	return clampf(dist / MAX_ROPE_LENGTH, 0.0, 1.0)


## Returns true when the chain is taut (distance > max length).
func is_chain_taut() -> bool:
	if not ball or not is_instance_valid(ball):
		return false
	return player.global_position.distance_to(ball.global_position) > MAX_ROPE_LENGTH


## Returns true when the player is moving away from the ball (pulling it).
func is_pulling_ball() -> bool:
	if not ball or not is_instance_valid(ball):
		return false
	if not is_chain_taut():
		return false
	var dir_to_ball := (ball.global_position - player.global_position).normalized()
	return player.velocity.dot(-dir_to_ball) > 0.0


# =============================================================================
# BALL DASH / THROW
# =============================================================================

## Call this from the player when the Shoot Ball button is pressed.
## Launches the ball in direction and gives the player a snappy mini-dash.
func shoot_ball(direction: Vector2) -> void:
	if _throw_cooldown_timer > 0.0:
		return
	if not ball or not is_instance_valid(ball):
		return

	var dir := direction.normalized()
	_throw_cooldown_timer = THROW_COOLDOWN
	_ball_thrown = true

	# Launch ball with high impulse.
	ball.linear_damp = ball_damp_during_throw
	ball.apply_central_impulse(dir * THROW_IMPULSE)

	# Mini-dash: snappy impulse to the player in the same direction.
	player.velocity += dir * MINI_DASH_POWER


## Ends the shot state once the ball slows to a stop.
func _check_shot_end() -> void:
	if not _ball_thrown:
		return
	if not ball or not is_instance_valid(ball):
		_ball_thrown = false
		return
	if ball.linear_velocity.length() < 50.0:
		_ball_thrown = false


## Always false — the player is never forcibly pulled toward the ball.
func is_tug_along_active() -> bool:
	return false


## Returns true if the ball is mid-throw.
func is_ball_thrown() -> bool:
	return _ball_thrown


func _update_ball_damp() -> void:
	if not ball or not is_instance_valid(ball):
		return
	if _ball_thrown:
		ball.linear_damp = ball_damp_during_throw
	else:
		ball.linear_damp = ball_linear_damp


# =============================================================================
# COMBAT — BALL HITS ENEMIES
# =============================================================================

func _on_ball_body_entered(body: Node) -> void:
	# Deal damage when actively thrown OR spinning (a mid-spin hit is valid).
	if not _ball_thrown and not is_spinning:
		return
	if not ball or not is_instance_valid(ball):
		return
	if not body.is_in_group("Enemies"):
		return

	var speed := ball.linear_velocity.length()
	if speed < HIGH_VELOCITY_THRESHOLD:
		# Soft Touch — not fast enough to deal damage.
		return

	# --- Classify the hit using velocity magnitude + dot product ---
	#
	# approach_dot = how directly the ball was flying toward the enemy centre.
	#   1.0  → perfectly head-on (maximum damage)
	#   0.5  → 60° glancing threshold (minimum for Hard Smash)
	#   0.0  → ball moving perpendicular to the enemy
	#  -1.0  → ball moving away (shouldn't happen, but possible with bounce)
	#
	# A Hard Smash requires BOTH: speed >= HARD_SMASH_THRESHOLD AND approach_dot >= 0.5.
	# A Normal Hit is anything above HIGH_VELOCITY_THRESHOLD that isn't a Hard Smash.
	var to_enemy: Vector2 = ((body as Node2D).global_position - ball.global_position).normalized()
	var ball_dir := ball.linear_velocity.normalized()
	var approach_dot: float = ball_dir.dot(to_enemy)

	var is_hard_smash := speed >= HARD_SMASH_THRESHOLD and approach_dot >= 0.5

	var damage  := HARD_SMASH_DAMAGE   if is_hard_smash else BALL_DAMAGE
	var knockback := HARD_SMASH_KNOCKBACK if is_hard_smash else BALL_KNOCKBACK

	# Deal damage
	if body.has_method("take_damage"):
		body.take_damage(damage, ball.global_position)

	# Knockback — push enemy away from the ball's impact point
	var kb_dir: Vector2 = to_enemy
	if body is RigidBody2D:
		body.apply_central_impulse(kb_dir * knockback)
	elif body is CharacterBody2D:
		body.velocity += kb_dir * knockback

	# HitStop on Hard Smash — freeze time briefly for impact feel
	if is_hard_smash:
		emit_signal("hard_smash_hit", body, speed, approach_dot)
		_do_hitstop()


# =============================================================================
# VISUAL SEGMENT UPDATES
# =============================================================================

func _update_segment_visuals() -> void:
	if ball and is_instance_valid(ball):
		ball.visible = chain_visible

	var seg_count := segment_nodes.size()
	if seg_count == 0:
		return

	for i in range(seg_count):
		var seg := segment_nodes[i]
		if not is_instance_valid(seg):
			continue

		# Each visual segment maps 1:1 to a Verlet point (offset by 1 to skip player anchor)
		var point_idx := i + 1
		if point_idx >= points.size():
			seg.visible = false
			continue

		seg.visible = chain_visible

		# Position: directly from the Verlet point — no overrides
		seg.global_position = points[point_idx]["pos"]

		# Rotation: point toward the NEXT Verlet point in the chain
		var next_idx := point_idx + 1
		if next_idx < points.size():
			var target: Vector2 = points[next_idx]["pos"]
			# Sprite points upward (local -Y), so subtract 90° from the angle
			seg.global_rotation = seg.global_position.angle_to_point(target) - PI / 2.0
		elif point_idx - 1 >= 0:
			# Last segment: face back toward previous point (reversed)
			var prev: Vector2 = points[point_idx - 1]["pos"]
			seg.global_rotation = prev.angle_to_point(seg.global_position) - PI / 2.0


# =============================================================================
# CENTRIFUGAL FORCE — Player acceleration transfers momentum to the ball
# =============================================================================

## Called every physics frame. When the player changes velocity significantly
## (running in a new direction, jumping, reversing), the velocity delta is applied
## to the ball as a scaled impulse — simulating the pseudo-force felt in the
## player's accelerating reference frame.
func _apply_centrifugal_force() -> void:
	if not ball or not is_instance_valid(ball):
		_prev_player_velocity = player.velocity
		return

	var velocity_delta := player.velocity - _prev_player_velocity
	_prev_player_velocity = player.velocity

	# Only react to meaningful velocity changes (filters out micro-jitter).
	if velocity_delta.length() > 40.0:
		ball.apply_central_impulse(velocity_delta * ball.mass * CENTRIFUGAL_FACTOR)


# =============================================================================
# SPIN FORCE — Manual wind-up whips the ball in a circle
# =============================================================================

## Applies a tangential force to the ball while the "spin_ball" action is held.
## This pushes the ball perpendicular to the radius (anchor → ball), accelerating
## it around the player without directly setting its position.
##
## The additional small outward (radial) component keeps the chain taut during
## spin so the Verlet constraints see a tight chain and maintain a clean circle.
func _apply_spin_force(_delta: float) -> void:
	if not is_spinning or not ball or not is_instance_valid(ball):
		return

	var anchor := player.global_position + ATTACHMENT_OFFSET
	var to_ball := ball.global_position - anchor
	var dist := to_ball.length()
	if dist < 1.0:
		return

	var radial := to_ball / dist
	# Tangential direction: 90° counterclockwise from the radial = (-y, x).
	# Change sign to clockwise if you want the default spin reversed.
	var tangent := Vector2(-radial.y, radial.x)

	# Tangential push (spins the ball) + slight outward nudge (keeps chain taut).
	ball.apply_central_force(tangent * SPIN_FORCE + radial * SPIN_FORCE * 0.15)


# =============================================================================
# SLINGSHOT — Ball momentum boosts a player jump
# =============================================================================

## Call this from player._do_jump() to add a momentum bonus when the ball is
## already swinging fast. Returns Vector2.ZERO if the ball is too slow.
##
## Physics note: this is a simplified momentum transfer. A rigorously correct
## version would also reduce the ball's velocity by the same amount, but the
## slight "free energy" feels better in gameplay and is standard in action games.
func get_slingshot_velocity() -> Vector2:
	if not ball or not is_instance_valid(ball):
		return Vector2.ZERO
	var speed := ball.linear_velocity.length()
	if speed < SLINGSHOT_MIN_SPEED:
		return Vector2.ZERO
	return ball.linear_velocity * SLINGSHOT_FRACTION


# =============================================================================
# HITSTOP — Momentary time freeze on a Hard Smash
# =============================================================================

## Freezes Engine.time_scale to 0 for HITSTOP_DURATION real-time seconds.
## Expiry is checked in _process using Time.get_ticks_msec() (wall-clock time),
## so it fires correctly even while the engine is frozen at time_scale = 0.
func _do_hitstop() -> void:
	Engine.time_scale = 0.0
	_hitstop_active = true
	_hitstop_end_ms = Time.get_ticks_msec() + int(HITSTOP_DURATION * 1000.0)

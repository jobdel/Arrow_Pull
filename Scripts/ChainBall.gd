extends Node2D
## Attach this to a Node2D child of your Player.
## Instances the chainsegment.tscn and ball.tscn scenes, wraps them in
## RigidBody2D nodes, and connects everything with PinJoint2D.

# --- Scenes ---
@export var segment_scene: PackedScene = preload("res://Scenes/chainsegment.tscn")
@export var ball_scene: PackedScene = preload("res://Scenes/ball.tscn")

# --- Configuration ---
@export var segment_count: int = 10
@export var segment_spacing: float = 9.0         # matches capsule height from chainsegment.tscn (halved)
@export var segment_mass: float = 0.2
@export var ball_mass: float = 8.0
@export var max_chain_length: float = 180.0       # max distance before player is hindered
@export var pull_force: float = 600.0             # force pulling ball inward during wind-up
@export var orbit_speed: float = 12.0             # tangential speed during wind-up
@export var shoot_impulse: float = 1200.0

# --- Runtime refs ---
var segments: Array[RigidBody2D] = []
var joints: Array[PinJoint2D] = []
var ball: RigidBody2D
var anchor_joint: PinJoint2D

# Owner player body — set by Player_BallController
var player_body: CharacterBody2D


func _ready() -> void:
	_build_chain()


## ---- Programmatic chain construction ----
func _build_chain() -> void:
	assert(player_body != null, "ChainBall: player_body must be set before _ready")

	# --- Create segments from scene ---
	for i in segment_count:
		var seg := _wrap_scene_in_rigidbody(segment_scene, "ChainSeg_%d" % i, segment_mass)

		# Segments should not collide with anything — purely visual chain links.
		seg.collision_layer = 0
		seg.collision_mask = 0

		# Position segments in a horizontal line behind the player (rest pose).
		var t := float(i + 1) / float(segment_count + 1)
		seg.position = Vector2(-64.0 * t, 0)

		add_child(seg)
		segments.append(seg)

		# --- Joint to previous body ---
		var joint := PinJoint2D.new()
		joint.name = "Joint_%d" % i
		joint.disable_collision = true

		if i == 0:
			joint.position = Vector2.ZERO
			joint.node_a = player_body.get_path()
			joint.node_b = seg.get_path()
			anchor_joint = joint
		else:
			var prev_seg := segments[i - 1]
			joint.position = (prev_seg.position + seg.position) * 0.5
			joint.node_a = prev_seg.get_path()
			joint.node_b = seg.get_path()

		add_child(joint)
		joints.append(joint)

	# --- Create ball from scene ---
	ball = _wrap_scene_in_rigidbody(ball_scene, "Ball", ball_mass)

	# Ball collides with enemies and walls. Adjust bits to match your project.
	ball.collision_layer = 1 << 4   # bit 5 — "ball" layer
	ball.collision_mask = (1 << 0) | (1 << 2)  # bits 1 & 3 — walls & enemies

	ball.position = Vector2(-64.0, 0)
	add_child(ball)

	# Joint connecting last segment to the ball.
	var ball_joint := PinJoint2D.new()
	ball_joint.name = "Joint_Ball"
	ball_joint.disable_collision = true
	ball_joint.position = (segments[-1].position + ball.position) * 0.5
	ball_joint.node_a = segments[-1].get_path()
	ball_joint.node_b = ball.get_path()
	add_child(ball_joint)
	joints.append(ball_joint)


## Instances a scene (Area2D root), steals its children (Sprite2D, CollisionShape2D),
## and parents them under a new RigidBody2D so PinJoint2D works.
func _wrap_scene_in_rigidbody(scene: PackedScene, body_name: String, mass: float) -> RigidBody2D:
	var instance := scene.instantiate()

	var body := RigidBody2D.new()
	body.mass = mass
	body.gravity_scale = 1.0
	body.name = body_name

	# Move all children (Sprite2D, CollisionShape2D, etc.) from the scene
	# instance into the RigidBody2D, preserving their transforms.
	var children_to_move: Array[Node] = []
	for child in instance.get_children():
		children_to_move.append(child)

	for child in children_to_move:
		instance.remove_child(child)
		body.add_child(child)

	# The scene instance (Area2D) is no longer needed.
	instance.queue_free()

	return body


## ---- Public helpers called by Player_BallController ----

func get_chain_stretch() -> float:
	return ball.global_position.distance_to(player_body.global_position)


func get_tension_ratio() -> float:
	return clampf(get_chain_stretch() / max_chain_length, 0.0, 1.0)


func wind_ball(delta: float) -> void:
	var to_player := (player_body.global_position - ball.global_position)
	var dist := to_player.length()
	if dist < 1.0:
		return

	var dir := to_player / dist

	# Radial pull — stronger the further away the ball is
	ball.apply_central_force(dir * pull_force * clampf(dist / 60.0, 0.5, 3.0))

	# Tangential force for orbiting (perpendicular to radial direction)
	var tangent := Vector2(-dir.y, dir.x)
	ball.apply_central_force(tangent * orbit_speed * ball.mass * 60.0 * delta)


func shoot(direction: Vector2) -> void:
	ball.apply_central_impulse(direction.normalized() * shoot_impulse)


func get_drag_on_player() -> Vector2:
	var stretch := get_chain_stretch()
	if stretch <= max_chain_length:
		return Vector2.ZERO

	var overshoot := stretch - max_chain_length
	var dir_to_ball := (ball.global_position - player_body.global_position).normalized()
	return dir_to_ball * clampf(overshoot * 0.4, 0.0, 120.0)

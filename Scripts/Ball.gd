extends RigidBody2D
## Attached at runtime by TetherSystem._spawn_ball().
## Handles tether-aware gravity via _integrate_forces:
##   - Chain SLACK  (dist < tether_max_length): full gravity, ball falls freely.
##   - Chain TAUT   (dist >= tether_max_length): cancel the outward component of
##     gravity so the ball cannot stretch the chain further, but can still swing
##     laterally or travel inward.

## Assigned by TetherSystem immediately after the script is set.
var player_ref: CharacterBody2D = null
## Must match TetherSystem.MAX_ROPE_LENGTH.  Set by TetherSystem.
var tether_max_length: float = 200.0
## Attachment offset on the player (mirrors TetherSystem.ATTACHMENT_OFFSET).
var anchor_offset: Vector2 = Vector2.ZERO

# Cached gravity strength (px/s²) — read once in _ready so it works even if
# the project setting is customised.
var _gravity_strength: float = 980.0


func _ready() -> void:
	_gravity_strength = ProjectSettings.get_setting(
		"physics/2d/default_gravity", 980.0)


func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	if not player_ref or not is_instance_valid(player_ref):
		return

	var ball_pos  := state.transform.origin
	var anchor    := player_ref.global_position + anchor_offset
	var to_ball   := ball_pos - anchor
	var dist      := to_ball.length()

	# ── Slack chain: physics engine gravity acts unimpeded. ──────────────────
	if dist < tether_max_length:
		return

	# ── Taut chain: cancel the fraction of gravity that would extend the chain.
	# dir_from_anchor points from the player anchor outward toward the ball.
	var dir_from_anchor := to_ball / dist

	# Total downward gravity force acting on this body this step.
	var gravity_vec := Vector2(0.0, _gravity_strength * gravity_scale * mass)

	# Project gravity onto the outward direction.
	# A positive value means gravity is pulling the ball away from the player.
	var outward_component := gravity_vec.dot(dir_from_anchor)

	if outward_component > 0.0:
		# Apply an equal-and-opposite force along the tether only — lateral
		# movement and inward movement remain completely unaffected.
		state.apply_central_force(-dir_from_anchor * outward_component)

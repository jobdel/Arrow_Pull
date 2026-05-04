extends CharacterBody2D
## Attach this to your Player (CharacterBody2D).
## Manages input, state machine, and communication with ChainBall.

# --- Movement tuning ---
@export var move_speed: float = 200.0
@export var time_slow_scale: float = 0.25  # Engine.time_scale during aiming

# --- Input action names (configure in Project > Input Map) ---
# "move_left", "move_right", "move_up", "move_down"
# "wind_ball"   — hold to start winding
# "shoot_ball"  — press while winding to aim, release to fire

# --- State machine ---
enum State { IDLE, MOVING, WINDING, AIMING }
var state: State = State.IDLE

var aim_direction: Vector2 = Vector2.RIGHT

# --- Chain reference ---
var chain_ball: Node  # ChainBall.gd instance

@onready var chain_ball_node: Node2D = $ChainBall  # adjust path if needed


func _ready() -> void:
	chain_ball = chain_ball_node
	# ChainBall needs a reference to our body BEFORE its _ready builds the chain.
	# Because child _ready fires before parent _ready in Godot 4, we use
	# _enter_tree or set it from the scene.  Safest: assign in _enter_tree.
	# See _enter_tree below.


func _enter_tree() -> void:
	# Ensure ChainBall has our body ref before it builds the chain.
	var cb := get_node_or_null("ChainBall")
	if cb:
		cb.player_body = self


func _physics_process(delta: float) -> void:
	var input_vec := _get_input_vector()

	match state:
		State.IDLE:
			_state_idle(input_vec, delta)
		State.MOVING:
			_state_moving(input_vec, delta)
		State.WINDING:
			_state_winding(input_vec, delta)
		State.AIMING:
			_state_aiming(input_vec, delta)

	# Apply chain drag regardless of state.
	var drag: Vector2 = chain_ball.get_drag_on_player()
	velocity += drag
	move_and_slide()


# ---------- State handlers ----------

func _state_idle(input_vec: Vector2, _delta: float) -> void:
	velocity = velocity.move_toward(Vector2.ZERO, 600.0 * _delta)

	if Input.is_action_pressed("wind_ball"):
		_enter_state(State.WINDING)
		return
	if input_vec.length() > 0.1:
		_enter_state(State.MOVING)


func _state_moving(input_vec: Vector2, _delta: float) -> void:
	velocity = input_vec * move_speed

	if Input.is_action_pressed("wind_ball"):
		_enter_state(State.WINDING)
		return
	if input_vec.length() < 0.1:
		_enter_state(State.IDLE)


func _state_winding(input_vec: Vector2, delta: float) -> void:
	# Player can still move (slower) while winding.
	velocity = input_vec * move_speed * 0.4

	chain_ball.wind_ball(delta)

	if not Input.is_action_pressed("wind_ball"):
		_enter_state(State.IDLE if input_vec.length() < 0.1 else State.MOVING)
		return

	if Input.is_action_just_pressed("shoot_ball"):
		_enter_state(State.AIMING)


func _state_aiming(input_vec: Vector2, _delta: float) -> void:
	# Movement is frozen while aiming.
	velocity = Vector2.ZERO

	# Update aim direction from input (keep last direction if no input).
	if input_vec.length() > 0.1:
		aim_direction = input_vec.normalized()

	if Input.is_action_just_released("shoot_ball"):
		# Fire!
		chain_ball.shoot(aim_direction)
		# Restore time
		Engine.time_scale = 1.0
		_enter_state(State.IDLE)
		return

	if not Input.is_action_pressed("wind_ball"):
		# Cancelled — released wind without shooting.
		Engine.time_scale = 1.0
		_enter_state(State.IDLE)


# ---------- State transitions ----------

func _enter_state(new_state: State) -> void:
	# Exit logic for old state
	match state:
		State.AIMING:
			Engine.time_scale = 1.0  # safety reset

	state = new_state

	# Enter logic for new state
	match new_state:
		State.AIMING:
			Engine.time_scale = time_slow_scale
			# Default aim to current facing / velocity direction
			if velocity.length() > 10.0:
				aim_direction = velocity.normalized()


# ---------- Utility ----------

func _get_input_vector() -> Vector2:
	return Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_up", "move_down")
	).limit_length(1.0)

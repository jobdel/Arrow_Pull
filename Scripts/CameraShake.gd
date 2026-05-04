extends Camera2D
## Trauma-based procedural camera shake.
## Attach this script to the Camera2D that is a child of the Player.
##
## Usage — from any script that has a reference to this node:
##   camera.add_trauma(0.6)   # 0.0 = no shake, 1.0 = maximum shake
##
## trauma decays automatically; squaring it gives finer low-end control.

@export var decay_rate: float = 2.5           # Trauma lost per second
@export var max_offset: Vector2 = Vector2(18.0, 12.0)  # Max pixel offset at trauma=1
@export var max_roll: float = 0.04            # Max rotation in radians at trauma=1

# --- Speed-based zoom ---
@export var zoom_at_rest: float = 1.3         # Zoom when stationary (zoomed in)
@export var zoom_at_max_speed: float = 1.0    # Zoom at max speed (most zoomed out)
@export var max_speed_reference: float = 600.0 # Speed (px/s) that counts as "max"
@export var zoom_lerp_speed: float = 3.0      # How fast zoom transitions

var trauma: float = 0.0

var _noise := FastNoiseLite.new()
var _noise_t: float = 0.0   # Noise "time" cursor — advanced every frame


func _ready() -> void:
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.seed = randi()


func _process(delta: float) -> void:
	# --- Speed-based zoom ---
	var parent := get_parent()
	if parent is CharacterBody2D:
		var speed := (parent as CharacterBody2D).velocity.length()
		var t := clampf(speed / max_speed_reference, 0.0, 1.0)
		var target_zoom := lerpf(zoom_at_rest, zoom_at_max_speed, t)
		zoom = zoom.lerp(Vector2(target_zoom, target_zoom), zoom_lerp_speed * delta)

	# Decay first so a single-frame trauma still produces one frame of shake.
	trauma = maxf(trauma - decay_rate * delta, 0.0)

	if trauma < 0.001:
		offset = Vector2.ZERO
		rotation = 0.0
		return

	_noise_t += delta * 55.0          # Speed of noise scroll (frames/sec equivalent)

	# Square trauma: perceived shake ≈ linear but control range is much nicer.
	var shake := trauma * trauma

	offset = Vector2(
		_noise.get_noise_2d(_noise_t,        0.0) * max_offset.x * shake,
		_noise.get_noise_2d(0.0,             _noise_t) * max_offset.y * shake,
	)
	rotation = _noise.get_noise_2d(_noise_t * 0.4, 99.9) * max_roll * shake


## Add trauma to the camera. Values above 1.0 are clamped.
## Call this on every hard hit — multiple hits stack but cap at 1.0.
func add_trauma(amount: float) -> void:
	trauma = minf(trauma + amount, 1.0)

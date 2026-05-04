extends ProgressBar

## Health bar with a trailing "damage ghost" effect.
## The white bar behind the red bar drains slowly to show recent damage.

@onready var damage_bar: ProgressBar = $ProgressBar
@onready var reset_timer: Timer = $ProgressBar/ResetVisibility

## How fast the damage ghost bar catches up (per second, in % of max).
@export var ghost_drain_speed := 80.0
## Delay before the ghost bar starts draining.
@export var ghost_delay := 0.4

var _ghost_draining := false


func _ready() -> void:
	# Sync both bars to full
	damage_bar.max_value = max_value
	damage_bar.value = max_value
	value = max_value

	reset_timer.wait_time = ghost_delay
	reset_timer.timeout.connect(_on_ghost_delay_finished)

	# Hide when full
	visible = false


func _process(delta: float) -> void:
	if _ghost_draining and damage_bar.value > value:
		damage_bar.value -= ghost_drain_speed * delta
		damage_bar.value = maxf(damage_bar.value, value)
		if damage_bar.value <= value:
			_ghost_draining = false


## Call this to update the health bar. Pass current and max health.
func update_health(current: float, maximum: float) -> void:
	max_value = maximum
	damage_bar.max_value = maximum

	# Show the bar once damage is taken
	if current < maximum:
		visible = true

	value = current

	# Reset ghost drain and start delay timer
	_ghost_draining = false
	reset_timer.start()

	# Hide if health is zero (death handles visuals)
	if current <= 0.0:
		visible = false


func _on_ghost_delay_finished() -> void:
	_ghost_draining = true

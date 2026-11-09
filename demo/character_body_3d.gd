extends CharacterBody3D

enum Mode {
	WALK,
	RUN,
	FLY,
}

const JUMP_VELOCITY := 4.5
const MAX_HP := 100.0
const MODE_SPEED := { Mode.WALK: 6.0, Mode.RUN: 12.0, Mode.FLY: 16.0 }

@export var camera_rig: CameraRig
@export var hp_bar: ProgressBar
## Children that are Marker3D become warp targets, keyed by node name.
@export var marker_root: Node3D
## How fast the body turns toward its movement direction.
@export var turn_speed: float = 12.0

var hp := MAX_HP:
	set(value):
		hp = clampf(value, 0.0, MAX_HP)
		if hp_bar:
			hp_bar.value = hp

var _mode: Mode = Mode.WALK
var _speed_scale := 1.0
var _registered: Array[String] = []
var _markers: Dictionary = { } # name → Marker3D (what unmark/markers see)
var _targets: Dictionary = { } # name → Callable → Vector3 (live; what warp sees)


func _ready() -> void:
	if hp_bar:
		hp_bar.max_value = MAX_HP
		hp_bar.value = hp
	if marker_root:
		for child in marker_root.get_children():
			if child is Marker3D:
				_track_marker(child)
	_targets["random"] = _random_point
	_warp_to_marker("Origin")
	_register_commands()


func _exit_tree() -> void:
	for cmd in _registered:
		DCKit.unregister(cmd)

func _warp_to_marker(marker_name: String) -> void:
	if _targets.has(marker_name):
		warp(_targets[marker_name].call())

#region Console commands
func _reg(cmd: String, fn: Callable, desc := "") -> void:
	if DCKit.register(cmd, fn, desc):
		_registered.append(cmd)


func _register_commands() -> void:
	_reg("player.mode", set_mode, "Switch movement mode.")
	DCKit.set_param("player.mode", 0, "mode", Mode)

	_reg("player.heal", heal, "Restore HP. Defaults to 10.")
	DCKit.set_param("player.heal", 0, "amount", [5, 10, 25])
	DCKit.add_alias("player.heal", "heal")

	_reg("player.damage", damage, "Remove HP.")
	DCKit.set_aliases("player.damage", PackedStringArray(["hurt", "dmg"]))

	_reg("player.speed", set_speed_scale, "Movement speed multiplier.")
	DCKit.set_param("player.speed", 0, "factor", [0.5, 1, 2])

	_reg("player.hpbar", set_hp_bar, "Show or hide the HP bar.")
	DCKit.set_param("player.hpbar", 0, "visible", ["true", "false"])

	# Same Dictionary instance, mutated later by mark/unmark, so suggestions stay current.
	_reg("player.warp", warp, "Teleport to a marker, 'random', or a Vector3.")
	DCKit.set_param("player.warp", 0, "target", _targets)

	_reg("player.mark", mark, "Drop a named marker at the player's position.")
	DCKit.set_param("player.mark", 0, "name")

	_reg("player.unmark", unmark, "Remove a marker.")
	DCKit.set_param("player.unmark", 0, "name", _marker_names)

	_reg("player.markers", list_markers, "List markers.")
#endregion


#region Command targets
func set_mode(mode: Mode) -> String:
	_mode = mode
	return "Mode: %s" % Mode.keys()[mode]


func heal(amount: float = 10.0) -> float:
	hp += amount
	return hp


func damage(amount: float) -> Variant:
	if hp <= 0.0:
		return DCResult.fail("Already dead.")
	hp -= amount
	return hp


func set_speed_scale(factor: float) -> Variant:
	if factor <= 0.0:
		return DCResult.fail("Factor must be greater than 0.")
	_speed_scale = factor
	return factor


func set_hp_bar(on: bool) -> Variant:
	if hp_bar == null:
		return DCResult.fail("No HP bar assigned.")
	hp_bar.visible = on
	return "HP bar %s." % ("shown" if on else "hidden")


func warp(to: Vector3) -> String:
	global_position = to
	velocity = Vector3.ZERO
	return "Warped to %s" % to


func mark(marker_name: String) -> Variant:
	if marker_root == null:
		return DCResult.fail("No marker root assigned.")
	if _find_key(_targets, marker_name) != null:
		return DCResult.fail("'%s' already exists." % marker_name)
	var m := Marker3D.new()
	m.name = marker_name
	marker_root.add_child(m)
	m.global_position = global_position
	var label := Label3D.new()
	label.text = marker_name
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position.y = 1.0
	m.add_child(label)
	_track_marker(m)
	return "Marker '%s' at %s" % [marker_name, m.global_position]


func unmark(marker_name: String) -> Variant:
	var key = _find_key(_markers, marker_name)
	if key == null:
		return DCResult.fail("No marker '%s'." % marker_name)
	_markers[key].queue_free()
	_markers.erase(key)
	_targets.erase(key)
	return "Removed '%s'." % key


func list_markers() -> String:
	return "No markers." if _markers.is_empty() else ", ".join(PackedStringArray(_markers.keys()))
#endregion


#region Helpers
func _track_marker(m: Marker3D) -> void:
	var key := String(m.name)
	_markers[key] = m
	_targets[key] = func() -> Vector3:
		return m.global_position if is_instance_valid(m) else global_position


func _marker_names() -> Array[String]:
	var out: Array[String] = []
	out.assign(_markers.keys())
	return out


func _find_key(dict: Dictionary, query: String) -> Variant:
	for k in dict:
		if String(k).nocasecmp_to(query) == 0:
			return k
	return null


func _random_point() -> Vector3:
	return Vector3(randf_range(-50.0, 50.0), 2.0, randf_range(-50.0, 50.0))
#endregion


func _physics_process(delta: float) -> void:
	var controlled := not camera_rig.free_cam
	var speed: float = MODE_SPEED[_mode] * _speed_scale

	if _mode == Mode.FLY:
		velocity.y = JUMP_VELOCITY if controlled and Input.is_action_pressed("ui_accept") else 0.0
	elif not is_on_floor():
		velocity += get_gravity() * delta
	elif controlled and Input.is_action_just_pressed("ui_accept"):
		velocity.y = JUMP_VELOCITY

	var input_dir := Vector2.ZERO
	if controlled:
		input_dir = Input.get_vector("left", "right", "up", "down")
	var direction := (camera_rig.yaw_basis() * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
		var target_yaw := atan2(-direction.x, -direction.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, 1.0 - exp(-turn_speed * delta))
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)

	move_and_slide()

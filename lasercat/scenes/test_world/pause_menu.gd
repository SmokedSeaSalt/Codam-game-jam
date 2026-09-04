extends CanvasLayer
## Web builds can only hide the cursor through the browser's Pointer Lock API, and
## the browser drops that lock the instant the player presses Esc (or tabs away)
## WITHOUT sending the game any event. This layer polls for the lock being gone,
## freezes the scene tree, and shows a click-to-resume prompt — the click is what
## re-grabs the pointer, since a browser only allows that from inside a user
## gesture. Disabled on desktop, where the cursor stays captured the whole session
## and becomes the laser outright.

@export var enabled: bool = OS.has_feature("web")

var _paused: bool = false
var _grace: float = 0.0  # seconds after a resume to let the browser (re)grant the lock before we re-check

var _panel: ColorRect
var _button: Button

func _ready() -> void:
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS  # keep polling / accept the resume click while the tree is paused
	_build_ui()
	_panel.visible = false
	if not enabled:
		set_process(false)
		set_process_unhandled_input(false)

func _process(delta: float) -> void:
	if _grace > 0.0:
		_grace -= delta
		return
	# Lock gone but we didn't put up the menu -> the browser handed the cursor
	# back (Esc / lost focus). Pause and show the prompt.
	if not _paused and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_pause()

func _unhandled_input(event: InputEvent) -> void:
	# Any key press (Esc included, on the browsers that still forward it) resumes.
	if _paused and event is InputEventKey and event.pressed and not event.echo:
		_resume()
		get_viewport().set_input_as_handled()

func _pause() -> void:
	_paused = true
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_panel.visible = true
	_button.grab_focus()

func _resume() -> void:
	if not _paused:
		return
	_paused = false
	_panel.visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED  # pointer-lock request, riding this click's gesture
	_grace = 0.3

func _build_ui() -> void:
	_panel = ColorRect.new()
	_panel.color = Color(0.04, 0.04, 0.06, 0.72)
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP  # swallow clicks so they don't toggle the laser underneath
	add_child(_panel)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	center.add_child(box)

	var title := Label.new()
	title.text = "Paused"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 40)
	box.add_child(title)

	_button = Button.new()
	_button.text = "Click to play"
	_button.custom_minimum_size = Vector2(220, 48)
	_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_button.pressed.connect(_resume)
	box.add_child(_button)

	var hint := Label.new()
	hint.text = "The cursor is yours while paused — press Esc to pause"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.modulate = Color(1, 1, 1, 0.55)
	box.add_child(hint)

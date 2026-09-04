extends Area3D

# Sits over the lasagna prop at the end of the road. The cat reaching it wins the
# level: flag it in GameState (read by the main menu to reveal its own lasagna)
# and send the player back there.

@export var cat: CharacterBody3D
@export_file("*.tscn") var main_menu_scene: String = "res://scenes/Main_Menu/Main_Menu.tscn"

var _triggered: bool = false

func _ready() -> void:
	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node3D) -> void:
	if _triggered or body != cat:
		return
	_triggered = true  # guard against a second overlap firing before the scene swaps
	GameState.lasagna_unlocked = true
	if cat.has_method("play_win_fanfare"):
		cat.play_win_fanfare()
	SoundLibrary.play_global("ui/win_jingle", -4.0, 0.15)
	# body_entered fires during the physics step — freeing nodes for a scene swap
	# right now is unsafe, so defer it to the next idle frame.
	get_tree().change_scene_to_file.call_deferred(main_menu_scene)

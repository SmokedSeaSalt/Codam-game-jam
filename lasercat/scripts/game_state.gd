extends Node

# Tiny cross-scene save: autoloaded (see project.godot [autoload]) so it survives
# get_tree().change_scene_to_*() calls. Add flags here as more of the game needs
# to remember something between scenes.

# Set once the cat reaches the lasagna at the end of Crossy Road. The main menu
# reads this to decide whether its own lasagna prop should be shown.
var lasagna_unlocked: bool = false

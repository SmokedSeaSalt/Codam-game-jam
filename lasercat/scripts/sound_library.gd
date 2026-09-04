extends Node

## Autoloaded (see project.godot [autoload]) sound bank. On startup it scans
## assets/audio/<category>/ folders and caches every clip found there, keyed by
## the category path relative to assets/audio (e.g. "cat/meow", "vehicle/car").
## Callers ask for a random clip from a category instead of preloading a
## hardcoded file list — dropping a new take into the right folder is all that's
## needed to add it to the rotation.

const ROOT := "res://assets/audio"

var _cache: Dictionary = {}  # category (String) -> Array[AudioStream]

func _ready() -> void:
	_scan_dir(ROOT, "")

func _scan_dir(path: String, category: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	var streams: Array[AudioStream] = []
	while entry != "":
		if not entry.begins_with("."):
			var full := path + "/" + entry
			if dir.current_is_dir():
				_scan_dir(full, entry if category == "" else category + "/" + entry)
			elif entry.get_extension().to_lower() in ["ogg", "wav", "mp3"]:
				var stream := load(full) as AudioStream
				if stream:
					streams.append(stream)
		entry = dir.get_next()
	dir.list_dir_end()
	if category != "" and not streams.is_empty():
		_cache[category] = streams

## A random clip from `category` (e.g. "cat/meow"), or null if the category is
## empty or unknown.
func random(category: String) -> AudioStream:
	var streams: Array = _cache.get(category, [])
	if streams.is_empty():
		return null
	return streams[randi() % streams.size()]

## Fire-and-forget playback that survives a scene change — the player is parented
## to this autoload (which change_scene_to_* never frees), not to the caller's
## own tree. Used for stings that must finish playing across a scene swap, like
## the lasagna win jingle.
func play_global(category: String, volume_db: float = 0.0, delay: float = 0.0) -> void:
	var stream := random(category)
	if stream == null:
		return
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = volume_db
	add_child(player)
	player.finished.connect(player.queue_free)
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
	player.play()

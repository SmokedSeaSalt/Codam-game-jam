class_name AmbientAudio
extends Node

## Background environmental audio bed: a soft looping wind track plus occasional
## random bird chirps, and — when enabled — occasional distant train rumbles for
## the road level. Self-contained: instantiate and add_child() it from a level's
## _ready(), the same way the laser builds its dot/spark rig procedurally.

@export var wind_volume_db: float = -18.0
@export var bird_interval: Vector2 = Vector2(6.0, 18.0)
@export var bird_volume_db: float = -12.0
@export var train_enabled: bool = false
@export var train_interval: Vector2 = Vector2(25.0, 55.0)
@export var train_volume_db: float = -14.0

var _bird_timer: float = 0.0
var _train_timer: float = 0.0
var _bird_player: AudioStreamPlayer
var _train_player: AudioStreamPlayer

func _ready() -> void:
	var wind_stream := SoundLibrary.random("ambient/wind")
	if wind_stream:
		if wind_stream is AudioStreamOggVorbis:
			(wind_stream as AudioStreamOggVorbis).loop = true
		var wind_player := AudioStreamPlayer.new()
		wind_player.name = "Wind"
		wind_player.stream = wind_stream
		wind_player.volume_db = wind_volume_db
		add_child(wind_player)
		wind_player.play()

	_bird_player = AudioStreamPlayer.new()
	_bird_player.name = "Birds"
	_bird_player.volume_db = bird_volume_db
	add_child(_bird_player)
	_bird_timer = randf_range(bird_interval.x, bird_interval.y)

	if train_enabled:
		_train_player = AudioStreamPlayer.new()
		_train_player.name = "Train"
		_train_player.volume_db = train_volume_db
		add_child(_train_player)
		_train_timer = randf_range(train_interval.x, train_interval.y)

func _process(delta: float) -> void:
	_bird_timer -= delta
	if _bird_timer <= 0.0:
		_bird_timer = randf_range(bird_interval.x, bird_interval.y)
		var stream := SoundLibrary.random("ambient/bird")
		if stream:
			_bird_player.stream = stream
			_bird_player.pitch_scale = randf_range(0.92, 1.1)
			_bird_player.play()

	if train_enabled and _train_player:
		_train_timer -= delta
		if _train_timer <= 0.0:
			_train_timer = randf_range(train_interval.x, train_interval.y)
			var stream := SoundLibrary.random("ambient/train")
			if stream:
				_train_player.stream = stream
				_train_player.play()

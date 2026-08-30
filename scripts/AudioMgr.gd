# Sound and music, following game.c's wiring exactly.
#
# The simulation raises pending_sfx (fn_03c2: one voice, a new effect replaces
# the current one); the shell owns the speaker. Music is a want_song request:
# song 0 on the main menu and intro, song 1 on road select, and a random song
# 2..13 per road start that never repeats the one already playing
# (game.c start_road, main 0x29f). SETMENU and HELP keep whatever is playing.
#
# The sound_off setting gates everything, and turning it off also stops the
# current song immediately (audio_misc.md §5: [0xbc2] = 0xFFFF).
#
# Songs are offline OPL2 renders (tools/render_music.c) of the retail MUZAX
# streams, encoded to Ogg Vorbis q4 — 125 MB of wav became 17 MB with no
# change to what is played. Each file is intro + one loop body, and
# music_meta.json carries the sample where the loop body starts;
# AudioStreamOggVorbis loops from there itself, so the original's
# intro-then-loop structure needs no OPL emulator in the game and no
# end-of-stream handling here.
class_name AudioMgr
extends Node

const SFX_FILES := [
	"sfx_0_explosion", "sfx_1_bounce_thud", "sfx_2_bump_scrape",
	"sfx_3_warning_beep", "sfx_4_supplies_refill",
]

var cfg: Config

var _sfx_player: AudioStreamPlayer
var _music_player: AudioStreamPlayer
var _voice_player: AudioStreamPlayer
var _sfx: Array = []
var _song := -1                 ## the current want_song, -1 = none
var _loop_begin := {}           ## song index -> loop start in seconds
var _rng := 0                   ## game.c's song LCG
var _warn_on := false
var _was_off := false


func _ready() -> void:
	_sfx_player = AudioStreamPlayer.new()
	_music_player = AudioStreamPlayer.new()
	_voice_player = AudioStreamPlayer.new()
	add_child(_sfx_player)
	add_child(_music_player)
	add_child(_voice_player)
	for f in SFX_FILES:
		var path := "res://data/audio/%s.wav" % f
		_sfx.append(load(path) if ResourceLoader.exists(path) else null)
	var mf := FileAccess.open("res://data/music/music_meta.json", FileAccess.READ)
	if mf != null:
		var meta = JSON.parse_string(mf.get_as_text())
		if meta is Array:
			for e in meta:
				_loop_begin[int(e["index"])] = \
					float(e["loop_begin_sample"]) / float(e["mix_rate"])
	_was_off = _off()


func _off() -> bool:
	return cfg != null and cfg.sound_off != 0


## Called every rendered frame; reacts when the settings screen flips sound.
func _process(_delta: float) -> void:
	var off := _off()
	if off == _was_off:
		return
	_was_off = off
	if off:
		# the original also silences the current song at once, not at the
		# next transition
		_music_player.stop()
		_sfx_player.stop()
		_voice_player.stop()
	else:
		_apply_song()


## Play one effect by id 0..4. Single voice: a new effect replaces the
## current one (audio.c sb_stop-then-play).
func sfx(id: int) -> void:
	if _off() or id < 0 or id >= _sfx.size() or _sfx[id] == null:
		return
	_sfx_player.stop()
	_sfx_player.stream = _sfx[id]
	_sfx_player.play()


## The INTRO.SND voice sample, fired 24 ticks into the intro.
func voice() -> void:
	if _off():
		return
	var path := "res://data/audio/intro_voice.wav"
	if not ResourceLoader.exists(path):
		return
	_voice_player.stream = load(path)
	_voice_player.play()


func want_song(n: int) -> void:
	if n == _song:
		return
	_song = n
	_apply_song()


## Random gameplay song per road start, game.c start_road: advance the LCG,
## pick 2..13, and dodge an immediate repeat.
##
## The choice is separated from playing it so it can be tested without an
## audio device — test_audio.gd diffs this against a sequence taken from the
## C engine's own state machine.
func choose_song(entry: int) -> int:
	_rng = int((_rng * 1103515245 + 12345 + entry) & 0xFFFFFFFF)
	var song := 2 + ((_rng >> 16) % 12)
	if song == _song:
		song = 2 + ((song - 1) % 12)
	return song


func gameplay_song(entry: int) -> void:
	want_song(choose_song(entry))


## What the shell last asked for, whether or not sound is on.
func wanted_song() -> int:
	return _song


func is_playing_music() -> bool:
	return _music_player != null and _music_player.playing


func stop_music() -> void:
	_song = -1
	_music_player.stop()


func _apply_song() -> void:
	_music_player.stop()
	if _off() or _song < 0:
		return
	var path := "res://data/music/song_%02d.ogg" % _song
	if not ResourceLoader.exists(path):
		return
	var stream: AudioStream = load(path)
	if stream is AudioStreamOggVorbis:
		# the intro plays once, then the body repeats from the loop point —
		# the stream does this itself, sample-accurately, where reacting to
		# `finished` left a gap at the seam
		var ogg := stream as AudioStreamOggVorbis
		ogg.loop = true
		ogg.loop_offset = _loop_begin.get(_song, 0.0)
	_music_player.stream = stream
	_music_player.play()


## The empty-tank warning beep: the EXE fires sfx 3 once per lamp on-phase
## while end_state is 4 or 5 (gameloop.md §11, 0x13eb). The C port's hud.c
## never implemented it; this follows the EXE.
func warn_tick(play: SkyRoadsPlay) -> void:
	var on: bool = (play.end_state == SkyRoadsPlay.NO_FUEL
		or play.end_state == SkyRoadsPlay.NO_OXYGEN) \
		and (play.tick % SkyRoads.WARN_BLINK_PERIOD) > 4
	if on and not _warn_on:
		sfx(3)
	_warn_on = on

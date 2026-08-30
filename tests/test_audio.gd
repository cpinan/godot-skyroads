# Sound and music: the assets are there, they are audible, and the shell
# picks the same songs the original does.
#
# The music had no coverage at all, which is why "is the background music
# even implemented?" was an open question rather than something the suite
# could answer. It is implemented — these assert it stays that way.
#
# The song choice is diffed against tests/fixtures/song_sequence.txt, which
# was produced by driving the C reference engine's own state machine into
# GAME for each road (tools/menu_trace.c "songs"). Comparing against a second
# copy of the LCG here would prove nothing.
extends SceneTree

const SONGS := 14
const SFX := [
	"sfx_0_explosion", "sfx_1_bounce_thud", "sfx_2_bump_scrape",
	"sfx_3_warning_beep", "sfx_4_supplies_refill",
]
## A render that loads but is silence sounds exactly like no music at all,
## and only a level check tells them apart. The songs measure 85-107 kbps;
## Vorbis codes true silence in under 5.
const MIN_KBPS := 40.0
const MIN_PEAK := 0.05

var _failures := 0
var _checks := 0


func check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL  %s" % label)


func _init() -> void:
	_assets()
	_loop_points()
	await _song_choice()
	await _sound_off_gates()
	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## Bits per second the file actually spends. Vorbis codes silence in almost
## nothing, so this separates a real render from an empty one just as a peak
## measurement does for a WAV — and unlike a peak, it needs no decoder.
func _kbps(path: String, stream: AudioStream) -> float:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or stream == null or stream.get_length() <= 0.0:
		return 0.0
	return float(f.get_length()) * 8.0 / 1000.0 / stream.get_length()


## Peak absolute sample of a stream, 0..1.
func _peak(stream: AudioStream) -> float:
	if stream is AudioStreamWAV:
		var w := stream as AudioStreamWAV
		var d := w.data
		if d.is_empty():
			return 0.0
		var hi := 0
		# 16-bit little-endian; step over the buffer rather than every sample
		var step := maxi(2, (d.size() / 2000) * 2)
		var i := 0
		while i + 1 < d.size():
			var v := d[i] | (d[i + 1] << 8)
			if v >= 32768:
				v -= 65536
			hi = maxi(hi, absi(v))
			i += step
		return float(hi) / 32768.0
	return 1.0        # not a WAV: cannot inspect, do not fail on it


func _assets() -> void:
	for i in SONGS:
		var p := "res://data/music/song_%02d.ogg" % i
		check(ResourceLoader.exists(p), "song %d exists" % i)
		if not ResourceLoader.exists(p):
			continue
		var s: AudioStream = load(p)
		check(s != null, "song %d loads" % i)
		if s == null:
			continue
		check(s is AudioStreamOggVorbis,
			"song %d is Ogg Vorbis, which loops itself" % i)
		check(s.get_length() > 5.0,
			"song %d is a real render, not a stub (%.1fs)" % [i, s.get_length()])
		var kb := _kbps(p, s)
		check(kb > MIN_KBPS,
			"song %d carries audio, not silence (%.0f kbps)" % [i, kb])
	for f in SFX:
		var p := "res://data/audio/%s.wav" % f
		check(ResourceLoader.exists(p), "%s exists" % f)
		if ResourceLoader.exists(p):
			check(_peak(load(p)) > MIN_PEAK, "%s is audible" % f)
	check(ResourceLoader.exists("res://data/audio/intro_voice.wav"),
		"the intro voice sample exists")


## Each song is intro + one loop body, and playback restarts at the loop
## point rather than the beginning. A loop point past the end of the render
## would silently turn the music into one-shot playback, and the stream now
## does the looping itself, so nothing else would notice.
func _loop_points() -> void:
	var f := FileAccess.open("res://data/music/music_meta.json", FileAccess.READ)
	check(f != null, "music_meta.json exists")
	if f == null:
		return
	var meta = JSON.parse_string(f.get_as_text())
	check(meta is Array and (meta as Array).size() == SONGS,
		"music_meta.json covers all %d songs" % SONGS)
	if not (meta is Array):
		return
	for e in meta:
		var i := int(e["index"])
		var secs := float(e["loop_begin_sample"]) / float(e["mix_rate"])
		var p := "res://data/music/song_%02d.ogg" % i
		if not ResourceLoader.exists(p):
			continue
		var s: AudioStream = load(p)
		check(secs >= 0.0 and secs < s.get_length(),
			"song %d's loop point is inside the render (%.1fs of %.1fs)"
			% [i, secs, s.get_length()])


func _song_choice() -> void:
	var f := FileAccess.open("res://tests/fixtures/song_sequence.txt",
		FileAccess.READ)
	check(f != null, "song_sequence.txt fixture exists")
	if f == null:
		return
	f.get_line()                                   # header
	var mgr := AudioMgr.new()
	mgr.cfg = Config.new()
	# sound off: this test is about which song is CHOSEN, and a headless run
	# has no device to play it on
	mgr.cfg.sound_off = 1
	get_root().add_child(mgr)
	await process_frame            # _ready builds the players
	var mismatch := ""
	var n := 0
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.is_empty():
			continue
		var row := line.split(",")
		var entry := int(row[1])
		var want := int(row[2])
		# drive the real entry point: the no-immediate-repeat rule reads the
		# song already playing, so calling the chooser alone would never
		# exercise it
		mgr.gameplay_song(entry)
		var got := mgr.wanted_song()
		n += 1
		if got != want and mismatch.is_empty():
			mismatch = "road %d: got song %d, the C engine picks %d" \
				% [entry, got, want]
	check(n >= 30, "the fixture covers every road (%d)" % n)
	check(mismatch.is_empty(), "the song sequence matches the C engine — %s"
		% mismatch)
	mgr.free()


func _sound_off_gates() -> void:
	var mgr := AudioMgr.new()
	var cfg := Config.new()
	cfg.sound_off = 1
	mgr.cfg = cfg
	get_root().add_child(mgr)
	await process_frame
	mgr.want_song(2)
	check(not mgr.is_playing_music(),
		"sound off means no music, whatever the shell asks for")
	cfg.sound_off = 0
	mgr.cfg = cfg
	check(mgr.wanted_song() == 2,
		"and the request is remembered, so turning sound back on resumes it")
	mgr.free()

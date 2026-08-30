# skyroads.cfg — the original's save file, byte for byte.
#
# 66 bytes: a checksum word, the control device, the sound flag, then 30
# completion counters. The checksum is sum over i=1..32 of (word[i] XOR i);
# a mismatch zeroes everything, exactly as the original does.
#
# Keeping the real format means a save from the DOS game can be dropped in and
# the road-select screen lights up with the right ticks.
class_name Config
extends RefCounted

const PATH := "user://skyroads.cfg"
const WORDS := 33
const BYTES := 66

var control := 0        ## 0 keyboard, 1 joystick, 2 mouse
var sound_off := 0
var completions := PackedInt32Array()


func _init() -> void:
	completions.resize(30)


static func _checksum(w: PackedInt32Array) -> int:
	var sum := 0
	for i in range(1, 33):
		sum = (sum + (w[i] ^ i)) & 0xFFFF
	return sum


func load_file() -> bool:
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null or f.get_length() < BYTES:
		return false
	var w := PackedInt32Array()
	w.resize(WORDS)
	for i in WORDS:
		w[i] = f.get_16()
	if _checksum(w) != w[0]:
		return false                     # corrupt: fall back to defaults
	control = w[1]
	sound_off = w[2]
	for i in 30:
		completions[i] = w[3 + i]
	return true


func save_file() -> void:
	var w := PackedInt32Array()
	w.resize(WORDS)
	w[1] = control
	w[2] = sound_off
	for i in 30:
		w[3 + i] = completions[i]
	w[0] = _checksum(w)
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		return
	for i in WORDS:
		f.store_16(w[i])


func completed_count() -> int:
	var n := 0
	for c in completions:
		if c > 0:
			n += 1
	return n

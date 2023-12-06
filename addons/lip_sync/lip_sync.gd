extends MarginContainer
class_name LipSync

enum Vowel {
	A,
	I,
	U,
	E,
	O
}

const VOWELS: Array = ["A", "I", "U", "E", "O"]

# Getting the recording stream again at a rate of 4 frames or less caused error.
const UPDATE_FRAME: int = 5
# Needs 2^n.
const FFT_SAMPLES: int = 1024

const GRAPH_LENGTH: float = 256.0
const GRAPH_SCALE: float = 128.0

# Assuming the min value of db.
const DYNAMIC_RANGE: float = 100.0
# For reducing calculation.
const INV_DYNAMIC_RANGE: float = 1.0 / DYNAMIC_RANGE

const INV_255: float = 1.0 / 255.0
const INV_32767: float = 1.0 / 32767.0


var effect: AudioEffectRecord
var audio_sample: AudioStreamWAV
var is_recording: bool = false
var buffer: int = UPDATE_FRAME

var before_sample_array: Array = []
var peaks3_log: Array = []
var peaks4_log: Array = []
var vowel_log: Array = [-1, -1, -1]
var estimate_log: Array = [-1, -1, -1]

var is_playing: bool = false
var audio_playing_time = 0
const SAMPLE_INTERVAL = 0.1
var last_time_updated = 0

var precision_threshold = 0.7
@export var stream: AudioStream

signal vowel_estimated

#########
# debug #
#########
# get and print max value in array
func print_max(sample_array: Array):
	var vmax: float = 0.0;
	for i in range(sample_array.size()):
		vmax = max(vmax, abs(sample_array[i]))
	print(vmax)
	return
func print_min(sample_array: Array):
	var vmin: float = 1.0;
	for i in range(sample_array.size()):
		vmin = min(vmin, abs(sample_array[i]))
	print(vmin)
	return

# (Caution!) plotting many points cause unstable.
func draw_graph(sample_array: Array) -> void:
	%Line2D.clear_points()
	
	if not sample_array.size() > 1:
		return
	
	for i in range(sample_array.size()):
		var px = float(GRAPH_LENGTH) / float(sample_array.size() - 1) * float(i)
		var py = float(-sample_array[i]) * float(GRAPH_SCALE)
		%Line2D.add_point(Vector2(px, py))
	
	return


func draw_vowel(vowel: int, amount: float) -> void:
	var text: String = ""
	match vowel:
		Vowel.A:
			text = "A"
		Vowel.I:
			text = "I"
		Vowel.U:
			text = "U"
		Vowel.E:
			text = "E"
		Vowel.O:
			text = "O"
		_:
			text = "_"
	
	$VBoxContainer/Label.text = "%s: %.2f" % [text, amount]
	return

#####################
# general functions #
#####################

# read mic input sample
# reference (https://godotengine.org/qa/67091/how-to-read-audio-samples-as-1-1-floats) 
static func read_16bit_samples(stream: AudioStreamWAV) -> Array:
	assert(stream.format == AudioStreamWAV.FORMAT_16_BITS)
	var channel_count = 2 if stream.is_stereo() else 1
	
	var bytes = stream.data
	var samples: Array[float] = []
	var i = 0
	# Read by packs of 2 bytes
	while (i + 1) < len(bytes):
		var b0 = bytes[i]
		var b1 = bytes[i + 1]
		# Combine low bits and high bits to obtain 16-bit value
		var u = b0 | (b1 << 8)
		# Emulate signed to unsigned 16-bit conversion
		u = (u + 32768) & 0xffff
		# Convert to -1..1 range
		var s = float(u - 32768) / 32768.0
		samples.append(s)
		i += 2 * channel_count
	return samples

##########################
# functions for Lip Sync #
##########################

func get_peaks(sample_array: Array[float], threshold: float) -> Array[Vector2]:
	var n: int = sample_array.size() - 1
	var i: int = 1
	var tmp: Vector2 = Vector2.ZERO
	var out: Array[Vector2] = []
	var div: float = 1.0
	while i < n:
		if (
			(sample_array[i] > threshold) &&
			(sample_array[i] > sample_array[i - 1]) &&
			(sample_array[i] > sample_array[i + 1])
		):
			if out.size() > 0:
				out.append(Vector2(i, sample_array[i] * div))
			else:
				out.append(Vector2(i, 1.0))
				div = 1.0 / sample_array[i]
		i += 1
	return out

func get_peaks_average(size: int) -> Array[Vector2]:
	var out: Array = []
	var i: int = 1
	var j: int = 0
	var div: float = 1.0
	match size:
		3:
			out = peaks3_log[0]
			while i < peaks3_log.size():
				j = 0
				while j < out.size():
					out[j].x += peaks3_log[i][j].x
					out[j].y += peaks3_log[i][j].y
					j += 1
				i += 1
			div = 1.0 / peaks3_log.size()
		4:
			out = peaks4_log[0]
			while i < peaks4_log.size():
				j = 0
				while j < out.size():
					out[j].x += peaks4_log[i][j].x
					out[j].y += peaks4_log[i][j].y
					j += 1
				i += 1
			div = 1.0 / peaks4_log.size()
			
	for k in range(out.size()):
		out[k] *= div
		
	return out

func get_distance_from_db(peaks: Array[Vector2]) -> Array[float]:
	var out: Array[float] = []
	
	var dist: float = 0.0
	
	var peak_estm: Dictionary = {}
	
	match(peaks.size()):
		3:
			peak_estm = Model.ESTIMATE_DB["peak3"]
		4:
			peak_estm = Model.ESTIMATE_DB["peak4"]
		_:
			return out
	
	for v in VOWELS:
		dist = 0.0
		for j in range(peaks.size()):
			var est = peak_estm[v][j]
			dist += abs(est.x - peaks[j].x) * INV_255 + abs(est.y - peaks[j].y)
		out.append(dist)
		
	return out

# Estimate vowel by peak.
func estimate_vowel(sample_array: Array) -> int:
	var peaks: Array = get_peaks(sample_array, 0.1)

	if peaks.size() != 3 && peaks.size() != 4:
		return -1
		
	push_peaks(peaks)
	
	var peaks_ave: Array = get_peaks_average(peaks.size())
	#print(peaks_ave)
	
	var distance_vowel: Array = get_distance_from_db(peaks_ave)
	#print(distance_vowel)

	var i: int = 1
	var min_distance: float = distance_vowel[0]
	var min_idx = 0
	while i < 5:
		if distance_vowel[i] < min_distance:
			min_distance = distance_vowel[i]
			min_idx = i
		i += 1

	return min_idx

# estimate and complement (wrap estimate_vowel()
func get_vowel(sample_array: Array, amount: float) -> Dictionary:
	var current: int = estimate_vowel(sample_array)

	var f_vowel: int = vowel_log[0]

	# Input begin and end.
	if f_vowel != -1:
		if amount < 0.5:
			return {"estimate": current, "vowel": f_vowel}

	# Stabilize.
	# now if (current == estimate_log[0]) will stabilize while 1 frame
	# so if (current == estimate_log[0] && current == estimate_log[1]) will stabilize while 2 frame
	if vowel_log.size() > 2:
		if current == estimate_log[0]:
			if current != -1:
				return {"estimate": current, "vowel": current}
		else:
			if f_vowel != -1:
				return {"estimate": current, "vowel": f_vowel}
	
	return {"estimate": current, "vowel": randi() % 5}

# log
func push_peaks(peaks: Array) -> void:
	if peaks.size() >= 4:
		if peaks4_log.size() < 3:
			peaks4_log.append(peaks)
		else:
			peaks4_log.push_front(peaks)
			peaks4_log.pop_back()
	elif peaks.size() >= 3:
		if peaks3_log.size() < 3:
			peaks3_log.append(peaks)
		else:
			peaks3_log.push_front(peaks)
			peaks3_log.pop_back()
	return
	
	
func push_vowel(vowel: int) -> void:
	if vowel_log.size() < 3:
		vowel_log.append(vowel)
	else:
		vowel_log.push_front(vowel)
		vowel_log.pop_back()
	return
	
	
func push_estimate(vowel: int) -> void:
	if estimate_log.size() < 3:
		estimate_log.append(vowel)
	else:
		estimate_log.push_front(vowel)
		estimate_log.pop_back()
	return

###########
# process #
###########

func _ready():
	var idx: int = AudioServer.get_bus_index("Record")
	effect = AudioServer.get_bus_effect(idx, 0)
	$AudioStreamWav.stream = stream


func _process(delta):
	$VBoxContainer/Fps.text = "FPS: %d" % Engine.get_frames_per_second()
	
	if is_recording:
		if buffer <= 0 and effect:
			if effect.is_recording_active():
				effect.set_recording_active(false)
				audio_sample = effect.get_recording()
				audio_sample.set_format(AudioStreamWAV.FORMAT_16_BITS)
				if audio_sample:
					var src_array: PackedByteArray = effect.get_recording().get_data()
					var sample_array: Array[float] = read_16bit_samples(audio_sample)
					_execute(sample_array)
					
			effect.set_format(AudioStreamWAV.FORMAT_16_BITS)
			effect.set_recording_active(true)
			buffer = UPDATE_FRAME
		else:
			buffer -= 1
	else:
		if effect:
			effect.set_recording_active(false)
	
	if is_playing:
		audio_playing_time += delta
		
		if (audio_playing_time - last_time_updated) > SAMPLE_INTERVAL:
			last_time_updated = audio_playing_time
			
			var sample_array = read_16bit_samples_stream($AudioStreamWav.stream, audio_playing_time, SAMPLE_INTERVAL)
			
			_execute(sample_array)
	else:
		last_time_updated = 0
		audio_playing_time = 0
		
	return

func _execute(sample_array: Array[float]):
	var rms: float = Algorithm.calc_rms(sample_array)

	if sample_array.size() < FFT_SAMPLES:
		print("Audio data size is too small, skipped!")
		return
		
	sample_array = sample_array.slice(0, FFT_SAMPLES)
	
	# Hamming
	Algorithm.hamming(sample_array)
	
	# To spectrum by FFT
	Algorithm.rfft(sample_array, false, true)
	
	sample_array = sample_array.slice(0, int(FFT_SAMPLES * 0.5) + 1)
	
	# Smoothing
	if !before_sample_array.is_empty():
		Algorithm.smoothing(sample_array, before_sample_array)
	
	before_sample_array = sample_array.duplicate()
	
	# Adjust for formant count.
	Algorithm.filter(sample_array, 10, 95)
	
	# Log power scale.
	for i in range(sample_array.size()):
		sample_array[i] = log(pow(sample_array[i], 2)) * Algorithm.INV_LOG10
	
	Algorithm.array_normalize(sample_array)
	
	# To cepstrum by IFFT.
	Algorithm.rfft(sample_array, true, false)
	
	# Adjust for formant count.
	Algorithm.lifter(sample_array, 26)
	
	# To spectrum by FFT again
	Algorithm.rfft(sample_array, false, false)
	
	sample_array = sample_array.slice(0, int(FFT_SAMPLES * 0.25) + 1)
	
	# Normalize.
	Algorithm.array_normalize(sample_array)
	
	# Emphasis peak.
	for i in range(sample_array.size()):
		sample_array[i] = pow(sample_array[i], 2)
	
	# Normalize again and multiply RMS.
	Algorithm.array_normalize(sample_array)
	
	var nrm_rms = min(DYNAMIC_RANGE, max(rms + DYNAMIC_RANGE, 0))
	for i in range(sample_array.size()):
		sample_array[i] = (sample_array[i] * nrm_rms * INV_DYNAMIC_RANGE)
	
	# Estimate vowel.
	var amount = clamp(inverse_lerp(-DYNAMIC_RANGE, 0.0, rms), 0.0, 1.0)
	var current_vowel: Dictionary = get_vowel(sample_array, amount)
	
	push_estimate(current_vowel["estimate"])
	push_vowel(current_vowel["vowel"])
	
	emit_signal("vowel_estimated", current_vowel["vowel"], amount)
	
	# Visualize.
	draw_vowel(current_vowel["vowel"], amount)
	draw_graph(sample_array)

# reference (https://godotengine.org/qa/67091/how-to-read-audio-samples-as-1-1-floats) 
static func read_16bit_samples_stream(stream: AudioStreamWAV, time: float, duration: float) -> Array:
	assert(stream.format == AudioStreamWAV.FORMAT_16_BITS)
	var bytes = stream.data
	var samples: Array[float] = []
	
	var is_stereo = stream.is_stereo()
	var channel_count = 2 if is_stereo else 1
	
	var sampling_start: int = round(time * stream.mix_rate * 2 * channel_count)
	var sampling_end: int = sampling_start + round(duration * stream.mix_rate * 2 * channel_count)
	
	var i = sampling_start
	
	# Read by packs of 2 + 2 bytes
	while (i + 1) < len(bytes) and i < sampling_end:
		var b0 = bytes[i]
		var b1 = bytes[i + 1]
		# Combine low bits and high bits to obtain 16-bit value
		var u = b0 | (b1 << 8)
		# Emulate signed to unsigned 16-bit conversion
		u = (u + 32768) & 0xffff
		# Convert to -1..1 range
		var s = float(u - 32768) / 32768.0
		samples.append(s)
		# 16-bit and stereo
		i += 2 * channel_count

	return samples


func _on_audio_stream_wav_finished():
	_stop_playing()


func _start_recording():
	is_recording = true
	%Play.hide()
	%Record.hide()
	%Stop.show()


func _stop_recording():
	is_recording = false
	%Play.show()
	%Record.show()
	%Stop.hide()
	
	
func start_playing():
	_start_playing()
	
	
func _start_playing():
	is_playing = true
	$AudioStreamWav.play()
	%Play.hide()
	%Record.hide()
	%Stop.show()


func _stop_playing():
	is_playing = false
	$AudioStreamWav.stop()
	%Play.show()
	%Record.show()
	%Stop.hide()


func _on_stop_pressed():
	if is_recording:
		_stop_recording()
	elif is_playing:
		_stop_playing()


func _on_play_button_pressed():
	_start_playing()


func _on_record_pressed():
	_start_recording()

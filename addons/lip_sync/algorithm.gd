class_name Algorithm

const PI2: float = 2.0 * PI
const INV_LOG10: float = 1.0 / log(10)

#####################
# Functions for FFT #
#####################

static func calc_rms(sample_array: Array[float]) -> float:
	var rms: float = 0.0
	
	for i in range(sample_array.size()):
		rms += sample_array[i] * sample_array[i]
	
	rms = sqrt(rms / sample_array.size())
	rms = 20 * (log(rms) * INV_LOG10)
	
	return rms

static func array_normalize(sample_array: Array[float]):
	var n: int = sample_array.size()
	
	var vmax: float = 0.0;
	var vmin: float = 0.0;
	
	for i in range(n):
		vmax = max(vmax, sample_array[i])
		vmin = min(vmin, sample_array[i])
	
	var diff: float = vmax - vmin
	var d: float = 1.0 / diff if diff != 0.0 else 1.0
	
	for i in range(n):
		sample_array[i] = (sample_array[i] - vmin) * d
	
	return

static func smoothing(sample_array: Array[float], before_sample_array: Array[float]):
	var n = sample_array.size();
	for i in range(n):
		sample_array[i] = (sample_array[i] + before_sample_array[i]) * 0.5
	return

static func hamming(sample_array: Array[float]):
	var n = sample_array.size();
	for i in range(n):
		var h = 0.54 - 0.46 * cos(PI2 * i / float(n - 1));
		sample_array[i] = sample_array[i] * h;
	sample_array[0] = 0
	sample_array[n - 1] = 0
	return;

static func rfft(sample_array: Array[float], reverse: bool = false, positive: bool = true):
	var N: int = sample_array.size()
	
	var cmp_array: Array[Vector2] = []
	cmp_array.resize(N)
	
	for i in range(N):
		cmp_array[i] = Vector2(sample_array[i], 0.0)
	
	fft(cmp_array, reverse)
	
	if positive:
		for i in range(N):
			sample_array[i] = abs(cmp_array[i].x)
	else:
		for i in range(N):
			sample_array[i] = cmp_array[i].x
	if reverse:
		var inv_n: float = 1.0 / float(N)
		for i in range(N):
			sample_array[i] *= inv_n
			
	return

# Reference (https://caddi.tech/archives/836) 
static func fft(a: Array, reverse: bool):
	var N: int = a.size()
	if N == 1:
		return
	
	var b: Array[Vector2] = []
	b.resize(int(ceil(N * 0.5)))
	
	var c: Array[Vector2] = []
	c.resize(int(N * 0.5))
	
	var b_idx: int = 0
	var c_idx: int = 0
	
	for i in range(N):
		if i % 2 == 0:
			b[b_idx] = a[i]
			b_idx += 1
		elif i % 2 == 1:
			c[c_idx] = a[i]
			c_idx += 1

	fft(b, reverse)
	fft(c, reverse)
	
	var circle: float = -PI2 if reverse else PI2
	for i in range(N):
		var mod = i % (N / 2)
		a[i] = b[mod] + ComplexCalc.cmlt(c[mod], ComplexCalc.cexp(Vector2(0, circle * float(i) / float(N))));
	
	return

static func lifter(sample_array: Array[float], level: int):
	var i_min: int = level
	var i_max: int = sample_array.size() - 1 - level
	for i in range(sample_array.size()):
		if i > i_min && i <= i_max:
			sample_array[i] = 0.0
	return

static func filter(sample_array: Array[float], lowcut: int, highcut: int):
	var minimum = sample_array[0]
	for i in range(sample_array.size()):
		minimum = min(minimum, sample_array[i])
	
	# Avoid log(0)
	if minimum == 0.0:
		minimum == 0.000001
		
	for i in range(sample_array.size()):
		if sample_array[i] <= lowcut || sample_array[i] >= highcut:
			sample_array[i] = minimum

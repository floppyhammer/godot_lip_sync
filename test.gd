extends Control


# Called when the node enters the scene tree for the first time.
func _ready():
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass


func _on_lip_sync_vowel_estimated(vowel: int, amount: float):
	print("%d: %.2f" % [vowel, amount])

class_name VisualBaseline
extends RefCounted

const BASELINE_PATH := "res://tests/visual_baselines.json"


static func metric_in_range(test_name: String, metric_name: String, value: float) -> bool:
	var range := _read_range(test_name, metric_name)
	if range.is_empty():
		return false
	return value >= float(range[0]) and value <= float(range[1])


static func describe_failure(test_name: String, metric_name: String, value: float) -> String:
	var range := _read_range(test_name, metric_name)
	if range.is_empty():
		return "%s.%s has no visual baseline" % [test_name, metric_name]
	return "%s.%s=%.3f outside baseline [%.3f, %.3f]" % [
		test_name,
		metric_name,
		value,
		float(range[0]),
		float(range[1]),
	]


static func _read_range(test_name: String, metric_name: String) -> Array:
	var file := FileAccess.open(BASELINE_PATH, FileAccess.READ)
	if file == null:
		return []

	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return []

	var root := parsed as Dictionary
	if not root.has(test_name):
		return []

	var test_entry = root[test_name]
	if not test_entry is Dictionary:
		return []

	var metrics := test_entry as Dictionary
	if not metrics.has(metric_name):
		return []

	var range = metrics[metric_name]
	if not range is Array or range.size() != 2:
		return []

	return range

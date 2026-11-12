class_name StageData extends RefCounted
## 关卡表：每关的显示名、类型、图块地图、音乐、波次。想调关卡内容改这里。
##
## 字段：
##   name     显示名（英文，字体没有中文字形）
##   type     "waves" 按波次打；"boss" Boss 关（阶段 E 实现，目前未启用）
##   enabled  false 的关卡会被跳过
##   tilemap  图块地图场景路径（切关时实例化，替换旧地图节点）
##   music    背景音乐路径
##   waves    波次数组，每波 { "enemies": { 类型名: 数量 }, "interval": 生成间隔秒 }
##            类型名见 WaveSpawner.REGISTRY

const STAGES : Array[Dictionary] = [
	{
		"name": "DUNGEON",
		"type": "waves",
		"enabled": true,
		"tilemap": "res://tile_maps/survival_dungeon.tscn",
		"music": "res://levels/survival/dungeon.mp3",
		"waves": [
			{ "enemies": { "slime": 5 }, "interval": 1.3 },
			{ "enemies": { "slime": 7, "goblin": 2 }, "interval": 1.1 },
			{ "enemies": { "slime": 8, "goblin": 4 }, "interval": 1.0 },
		],
	},
	{
		"name": "GRASSLAND",
		"type": "waves",
		"enabled": true,
		# 占位：阶段 C 会换成草地图块（Grass-01）和 grass.mp3
		"tilemap": "res://tile_maps/survival_dungeon.tscn",
		"music": "res://levels/survival/dungeon.mp3",
		"waves": [
			{ "enemies": { "slime": 8, "goblin": 4 }, "interval": 1.0 },
			{ "enemies": { "slime": 8, "goblin": 6 }, "interval": 0.9 },
			{ "enemies": { "slime": 10, "goblin": 7 }, "interval": 0.8 },
		],
	},
	{
		"name": "WIZARD HALL",
		"type": "boss",
		# 阶段 E 做完 Boss 后改为 true
		"enabled": false,
		"tilemap": "res://tile_maps/survival_dungeon.tscn",
		"music": "res://levels/survival/dungeon.mp3",
		"waves": [],
	},
]


## 所有启用的关卡在 STAGES 里的下标（按顺序）
static func enabled_indices() -> Array[int]:
	var result : Array[int] = []
	for i in STAGES.size():
		if STAGES[i]["enabled"]:
			result.append( i )
	return result


## 第 n 个启用的关卡（n 从 0 开始），返回它的数据
static func get_stage( n : int ) -> Dictionary:
	return STAGES[ enabled_indices()[n] ]


static func stage_count() -> int:
	return enabled_indices().size()

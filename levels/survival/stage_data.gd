class_name StageData extends RefCounted
## 关卡表：每关的显示名、类型、图块地图、音乐、波次。想调关卡内容改这里。
##
## 字段：
##   name     显示名（英文，字体没有中文字形）
##   type     "waves" 按波次打；"boss" Boss 关（没有波次，SurvivalArena 切到该关后放巫师，见 WizardBoss）
##   enabled  false 的关卡会被跳过
##   tilemap  图块地图场景路径（切关时实例化，替换旧地图节点）
##   music    背景音乐路径
##   waves    波次数组，每波 { "enemies": { 类型名: 数量 }, "interval": 生成间隔秒 }
##            类型名见 WaveSpawner.REGISTRY
##            可选 "upgrade": true：这一波清完（宝箱收走后）出现强化三选一；全局最后一波清完直接胜利，不出
##   archer_spots  （可选）弓手站位（世界坐标）：在高台上，每块高台一个；生成弓手时优先站到空闲站位上不动，
##            站位都被占着就按普通方式生成。站位要和图块地图里的高台对上（草地：GrasslandMap.LEDGE_TILES，
##            站位在高台中间一列、离上边界 40 像素处，在 HandController.CURSOR_RECT 之内镖才够得着）

const LEGACY_VERSION := 1
const CURRENT_VERSION := 2
const LEGACY_RULESET := "survival_v1"
const CURRENT_RULESET := "survival_v2"

const STAGES : Array[Dictionary] = [
	{
		"name": "DUNGEON",
		"type": "waves",
		"enabled": true,
		"tilemap": "res://tile_maps/survival_dungeon.tscn",
		"music": "res://levels/survival/dungeon.mp3",
		"waves": [
			{ "enemies": { "slime": 5 }, "interval": 1.3 },
			{ "enemies": { "slime": 6, "goblin": 2, "bomb_slime": 2 }, "interval": 1.1, "upgrade": true },
			{ "enemies": { "slime": 6, "goblin": 3, "bomb_slime": 3, "big_slime": 1 }, "interval": 1.0, "upgrade": true },
		],
	},
	{
		"name": "GRASSLAND",
		"type": "waves",
		"enabled": true,
		"tilemap": "res://tile_maps/survival_grassland.tscn",
		"music": "res://levels/survival/grass.mp3",
		"archer_spots": [ Vector2( 176, 40 ), Vector2( 336, 40 ) ],
		"waves": [
			{ "enemies": { "slime": 6, "goblin": 3, "shield_goblin": 1, "archer_goblin": 1 }, "interval": 1.0 },
			{ "enemies": { "slime": 6, "goblin": 4, "bomb_slime": 2, "shield_goblin": 2, "archer_goblin": 2 }, "interval": 0.9, "upgrade": true },
			{ "enemies": { "slime": 6, "goblin": 5, "bomb_slime": 3, "shield_goblin": 3, "archer_goblin": 2, "big_slime": 2 }, "interval": 0.8, "upgrade": true },
		],
	},
	{
		"name": "WIZARD HALL",
		"type": "boss",
		"enabled": true,
		"tilemap": "res://tile_maps/survival_dungeon.tscn",
		"music": "res://levels/survival/boss.ogg",
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
static func get_stage( n : int, version: int = LEGACY_VERSION ) -> Dictionary:
	if version == CURRENT_VERSION:
		return CampaignPreviewData.STAGES[n]
	return STAGES[ enabled_indices()[n] ]


static func stage_count(version: int = LEGACY_VERSION) -> int:
	return CampaignPreviewData.STAGES.size() if version == CURRENT_VERSION else enabled_indices().size()


static func checkpoint_version(checkpoint: Dictionary) -> int:
	var version: Variant = checkpoint.get("campaign_version", LEGACY_VERSION)
	if (version is int or version is float) and (float(version) == LEGACY_VERSION or float(version) == CURRENT_VERSION):
		return int(version)
	return 0


static func ruleset(version: int) -> String:
	return CURRENT_RULESET if version == CURRENT_VERSION else LEGACY_RULESET


static func milestones_for_ruleset(id: Variant) -> int:
	match id:
		LEGACY_RULESET:
			return milestones_before(stage_count(LEGACY_VERSION), LEGACY_VERSION) + 3
		CURRENT_RULESET:
			return milestones_before(stage_count(CURRENT_VERSION), CURRENT_VERSION) + 3
	return 0


static func milestones_before(index: int, version: int) -> int:
	var completed := 0
	for i in index:
		completed += get_stage(i, version)["waves"].size()
	return completed

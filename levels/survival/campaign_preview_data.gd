class_name CampaignPreviewData extends RefCounted
## 新版正式战役和本地试玩共用的地图、波次及入场点。

const ZONES := {
	"west": [ Vector2( 40, 105 ), Vector2( 40, 117 ), Vector2( 40, 129 ) ],
	"west_wide": [ Vector2( 40, 70 ), Vector2( 40, 182 ), Vector2( 40, 212 ) ],
	"northwest": [ Vector2( 88, 54 ), Vector2( 106, 54 ), Vector2( 124, 54 ) ],
	"northwest_wide": [ Vector2( 57, 54 ), Vector2( 155, 54 ) ],
	"southwest": [ Vector2( 48, 216 ), Vector2( 64, 231 ), Vector2( 90, 233 ) ],
	"east": [ Vector2( 472, 91 ), Vector2( 472, 105 ), Vector2( 472, 126 ) ],
	"east_wide": [ Vector2( 472, 70 ), Vector2( 472, 189 ), Vector2( 472, 219 ) ],
	"northeast": [ Vector2( 372, 96 ), Vector2( 388, 98 ), Vector2( 404, 96 ) ],
	"northeast_wide": [ Vector2( 353, 74 ), Vector2( 408, 102 ) ],
	"north": [ Vector2( 318, 45 ), Vector2( 336, 44 ), Vector2( 352, 49 ) ],
	"south": [ Vector2( 88, 231 ), Vector2( 128, 229 ), Vector2( 157, 233 ) ],
	"fallback": [ Vector2( 107, 212 ), Vector2( 405, 219 ), Vector2( 104, 54 ), Vector2( 405, 54 ) ],
}
const DUNGEON_W2 := [
	{ "time": 0.0, "zone": "west", "enemies": { "slime": 4 } },
	{ "time": 4.0, "zone": "northwest", "enemies": { "bomb_slime": 1 } },
	{ "time": 8.0, "zone": "east", "enemies": { "goblin": 2 } },
	{ "time": 12.0, "zone": "west", "enemies": { "slime": 2 } },
]
const RUINS_W2 := [
	{ "time": 0.0, "zone": "west", "enemies": { "slime": 3, "bomb_slime": 1 } },
	{ "time": 5.0, "zone": "east", "enemies": { "goblin": 2 } },
	{ "time": 9.0, "zone": "northeast", "enemies": { "archer_goblin": 1 } },
	{ "time": 14.0, "zone": "west", "enemies": { "bomb_slime": 1, "slime": 2 } },
]
const STAGES: Array[Dictionary] = [
	{
		"name": "DUNGEON", "type": "waves",
		"tilemap": "res://tile_maps/campaign_dungeon.tscn", "music": "res://levels/survival/dungeon.mp3",
		"waves": [
			{ "batches": [
				{ "time": 0.0, "zone": "west", "enemies": { "slime": 2 } },
				{ "time": 5.0, "zone": "southwest", "enemies": { "slime": 3 } },
			] },
			{ "batches": DUNGEON_W2, "upgrade": true },
			{ "upgrade": true, "batches": [
				{ "time": 0.0, "zone": "west", "enemies": { "big_slime": 1, "slime": 3 } },
				{ "time": 5.0, "zone": "east", "enemies": { "goblin": 3 } },
				{ "time": 10.0, "zone": "northwest", "enemies": { "bomb_slime": 1, "slime": 2 } },
			] },
		],
	},
	{
		"name": "GRASSLAND", "type": "waves",
		"tilemap": "res://tile_maps/campaign_grassland.tscn", "music": "res://levels/survival/grass.mp3",
		"archer_anchors": { "left_platform": Vector2( 176, 44 ), "right_platform": Vector2( 400, 194 ) },
		"waves": [
			{ "batches": [
				{ "time": 0.0, "anchor": "left_platform", "enemies": { "archer_goblin": 1 } },
				{ "time": 0.0, "zone": "west", "enemies": { "slime": 2 } },
				{ "time": 4.0, "zone": "east", "enemies": { "shield_goblin": 1 } },
				{ "time": 8.0, "zone": "east", "enemies": { "goblin": 3 } },
				{ "time": 12.0, "zone": "west", "enemies": { "slime": 2 } },
			] },
			{ "upgrade": true, "batches": [
				{ "time": 0.0, "anchor": "left_platform", "enemies": { "archer_goblin": 1 } },
				{ "time": 0.0, "zone": "west", "enemies": { "slime": 3 } },
				{ "time": 4.0, "zone": "east", "enemies": { "shield_goblin": 1 } },
				{ "time": 9.0, "anchor": "right_platform", "enemies": { "archer_goblin": 1 } },
				{ "time": 13.0, "interval": 1.6, "zone": "north", "enemies": { "goblin": 3 } },
				{ "time": 13.8, "interval": 1.6, "zone": "south", "enemies": { "slime": 3 } },
			] },
			{ "batches": [
				{ "time": 0.0, "zone": "west", "enemies": { "big_slime": 1, "slime": 3, "goblin": 2 } },
				{ "time": 5.0, "zone": "east", "enemies": { "shield_goblin": 1 } },
				{ "time": 5.0, "anchor": "left_platform", "enemies": { "archer_goblin": 1 } },
				{ "time": 10.0, "interval": 1.6, "zone": "east", "enemies": { "bomb_slime": 2 } },
				{ "time": 10.8, "interval": 1.6, "zone": "east", "enemies": { "goblin": 2 } },
			] },
		],
	},
	{
		"name": "RUINS", "type": "waves",
		"tilemap": "res://tile_maps/campaign_ruins.tscn", "music": "res://levels/survival/dungeon.mp3",
		"waves": [
			{ "batches": [
				{ "time": 0.0, "zone": "west", "enemies": { "slime": 3, "goblin": 2 } },
				{ "time": 6.0, "zone": "east", "enemies": { "slime": 2, "goblin": 1 } },
			] },
			{ "batches": RUINS_W2, "upgrade": true },
		],
	},
	{
		"name": "WIZARD HALL", "type": "boss",
		"tilemap": "res://tile_maps/campaign_wizard_hall.tscn", "music": "res://levels/survival/boss.ogg",
		"waves": [],
	},
]

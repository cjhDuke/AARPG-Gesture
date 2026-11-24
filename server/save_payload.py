"""Strict, side-effect-free validation and canonicalization for game save v2."""

from __future__ import annotations

import hashlib
import json
import math
import re
from datetime import datetime
from typing import Any


class InvalidSave(ValueError):
    """Raised when a save record is malformed or outside game limits."""


_ID_RE = re.compile(r"^[0-9a-f]{32}$")
_UPGRADES = {
    "blast": 3, "pierce": 3, "magnet": 3, "frost": 3,
    "pool": 3, "wide_spin": 3, "parry": 3, "heart": 3,
}
_LEGACY_STAGES = (("DUNGEON", "waves", 3), ("GRASSLAND", "waves", 3), ("WIZARD HALL", "boss", 1))
_STAGES = {1: _LEGACY_STAGES, 2: (*_LEGACY_STAGES[:2], ("RUINS", "waves", 2), _LEGACY_STAGES[-1])}
_RECORD_KEYS = {"version", "id", "name", "created_at", "saved_at", "saved_unix", "checkpoint", "save_kind"}
_CHECKPOINT_KEYS = {"stage", "stage_name", "kind", "wave", "hp", "psi", "upgrades", "kills", "loot", "campaign_version"}
_LOOT_KEYS = {"bag_apples", "picked", "kills_since_apple", "eat_timer", "bag_potions"}


def _fail(message: str) -> None:
    raise InvalidSave(message)


def _object(value: Any, keys: set[str], label: str, optional: set[str] = frozenset()) -> dict:
    if not isinstance(value, dict):
        _fail(f"{label} must be an object")
    actual = set(value)
    if not keys - optional <= actual or actual - keys:
        _fail(f"{label} has missing or unknown fields")
    if any(not isinstance(k, str) for k in value):
        _fail(f"{label} keys must be strings")
    return value


def _number(value: Any, label: str, low: float, high: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        _fail(f"{label} must be numeric")
    try:
        result = float(value)
    except OverflowError:
        _fail(f"{label} is out of range")
    if not math.isfinite(result) or not low <= result <= high:
        _fail(f"{label} is out of range")
    return result


def _integer(value: Any, label: str, low: int, high: int) -> int:
    result = _number(value, label, low, high)
    if not result.is_integer():
        _fail(f"{label} must be an integer")
    return int(result)


def _timestamp(value: Any, label: str) -> str:
    if not isinstance(value, str) or len(value) > 32:
        _fail(f"{label} must be a timestamp string of at most 32 characters")
    # Godot Time.get_datetime_string_from_system(false, true): ISO date/time, no zone.
    try:
        parsed = datetime.strptime(value.replace("T", " "), "%Y-%m-%d %H:%M:%S")
    except ValueError:
        _fail(f"{label} must use the client's ISO timestamp format")
    if parsed.strftime("%Y-%m-%d %H:%M:%S") != value.replace("T", " "):
        _fail(f"{label} must use the client's ISO timestamp format")
    return value


def _validate_checkpoint(value: Any) -> dict:
    data = _object(value, _CHECKPOINT_KEYS, "checkpoint", optional={"campaign_version"})
    campaign = _integer(data.get("campaign_version", 1), "checkpoint.campaign_version", 1, 2)
    stages = _STAGES[campaign]
    stage = _integer(data.get("stage"), "checkpoint.stage", 0, len(stages) - 1)
    stage_name, kind, wave_max = stages[stage]
    if data.get("stage_name") != stage_name or data.get("kind") != kind:
        _fail("checkpoint stage identity does not match stage table")
    wave = _integer(data.get("wave"), "checkpoint.wave", 1, wave_max)
    kills = _integer(data.get("kills"), "checkpoint.kills", 0, 1_000_000_000)
    levels = _object(data.get("upgrades"), set(_UPGRADES), "checkpoint.upgrades", optional=set(_UPGRADES))
    normalized_levels = {}
    for key, value in levels.items():
        if key not in _UPGRADES:
            _fail("unknown upgrade")
        normalized_levels[key] = _integer(value, f"upgrade.{key}", 1, _UPGRADES[key])
    max_hp = 6 + 2 * normalized_levels.get("heart", 0)
    hp = _integer(data.get("hp"), "checkpoint.hp", 1, max_hp)
    psi = _number(data.get("psi"), "checkpoint.psi", 0.0, 1.0)
    loot = _object(data.get("loot"), _LOOT_KEYS, "checkpoint.loot", optional={"bag_potions"})
    apples = _integer(loot.get("bag_apples"), "loot.bag_apples", 0, 3)
    potions = _integer(loot.get("bag_potions", 0), "loot.bag_potions", 0, 3)
    pity = _integer(loot.get("kills_since_apple"), "loot.kills_since_apple", 0, 9)
    eat_timer = _number(loot.get("eat_timer"), "loot.eat_timer", 0.0, 0.6)
    picked = loot.get("picked")
    if not isinstance(picked, list) or len(picked) != 3:
        _fail("loot.picked must contain exactly three counts")
    picked = [_integer(item, "loot.picked item", 0, 1_000_000_000) for item in picked]
    normalized_loot = {"bag_apples": apples, "picked": picked, "kills_since_apple": pity, "eat_timer": eat_timer}
    # Preserve omission in legacy v2 records; do not rewrite their content.
    if "bag_potions" in loot:
        normalized_loot["bag_potions"] = potions
    result = {"stage": stage, "stage_name": stage_name, "kind": kind, "wave": wave,
              "hp": hp, "psi": psi, "upgrades": normalized_levels, "kills": kills, "loot": normalized_loot}
    if "campaign_version" in data:
        result["campaign_version"] = campaign
    return result


def canonical_save(record: object, save_id: str) -> tuple[str, str]:
    """Validate a v2 save and return its canonical JSON and UTF-8 SHA-256 hex digest."""
    if not isinstance(save_id, str) or not _ID_RE.fullmatch(save_id):
        _fail("save_id must be 32 lowercase hexadecimal characters")
    data = _object(record, _RECORD_KEYS, "record", optional={"save_kind"})
    if data.get("save_kind", "manual") not in ("manual", "auto"):
        _fail("unsupported save kind")
    if _integer(data.get("version"), "version", 2, 2) != 2:
        _fail("unsupported save version")
    if data.get("id") != save_id:
        _fail("record id does not match path id")
    name = data.get("name")
    if not isinstance(name, str) or not name.strip() or not 1 <= len(name) <= 24 or any(ord(ch) < 32 or 0x7F <= ord(ch) <= 0x9F for ch in name):
        _fail("name must contain 1 to 24 characters without control characters")
    created_at = _timestamp(data.get("created_at"), "created_at")
    saved_at = _timestamp(data.get("saved_at"), "saved_at")
    saved_unix = _number(data.get("saved_unix"), "saved_unix", 0.0, 100000000000.0)
    checkpoint = _validate_checkpoint(data.get("checkpoint"))
    normalized = {"version": 2, "id": save_id, "name": name, "created_at": created_at,
                  "saved_at": saved_at, "saved_unix": saved_unix, "checkpoint": checkpoint}
    if "save_kind" in data:
        normalized["save_kind"] = data["save_kind"]
    try:
        def integral_numbers(value):
            if isinstance(value, dict):
                return {key: integral_numbers(item) for key, item in value.items()}
            if isinstance(value, list):
                return [integral_numbers(item) for item in value]
            if isinstance(value, float) and value.is_integer():
                return int(value)
            return value
        payload = json.dumps(integral_numbers(normalized), sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
        encoded = payload.encode("utf-8")
    except (UnicodeEncodeError, ValueError, TypeError) as exc:
        raise InvalidSave("record cannot be encoded as canonical JSON") from exc
    if len(encoded) > 65536:
        _fail("save payload exceeds 65536 UTF-8 bytes")
    return payload, hashlib.sha256(encoded).hexdigest()

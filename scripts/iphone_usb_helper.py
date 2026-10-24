#!/usr/bin/env python3
"""USB-only, read-only iPhone archive transport. JSON lines are the only stdout.

Runtime dependency: pymobiledevice3==11.32.0. No device is opened on import.
The internal Photos schema is deliberately gated; unsupported assets fail closed.
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import datetime as dt
import hashlib
import importlib.metadata
import json
import logging
import math
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import signal
import sqlite3
import struct
import sys
import tempfile
import unicodedata
import uuid
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

DEPENDENCY_VERSION = "11.32.0"
COCOA_EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
MAX_CHUNK = 4 * 1024 * 1024
MAX_DATABASE = 1024 * 1024 * 1024
MAX_REQUEST = 8 * 1024 * 1024
MAX_LOCAL_PLACE_BLOB = 4 * 1024 * 1024
MAX_LOCAL_PLACE_OBJECTS = 20000
MAX_LOCAL_PLACE_DEPTH = 64
MAX_LOCAL_PLACE_INFOS = 1000
METADATA_PATHS = (
    "/PhotoData/Caches/search/leo.sqlite",
    "/PhotoData/Caches/search/leo.sqlite-wal",
    "/PhotoData/Photos.sqlite",
    "/PhotoData/Photos.sqlite-wal",
)
PHOTO_EXTENSIONS = {".heic", ".heif", ".jpg", ".jpeg", ".png", ".dng", ".tif", ".tiff"}
VIDEO_EXTENSIONS = {".mov", ".mp4", ".m4v"}
SAFE_OPERATIONS = {0x0A, 0x0D, 0x0F, 0x11, 0x14}


class UserError(Exception):
    """Only these deliberately authored messages may cross the IPC boundary."""


class SnapshotChangedError(UserError):
    """A transient index snapshot race, never a semantic mismatch."""


class _LocalPlaceShapeError(ValueError):
    """Unusable optional city data; never becomes a user-visible archive error."""


def _preflight_local_place_plist(blob):
    """Bound native plist allocation and recursion before plistlib decodes it."""
    if type(blob) is not bytes or not 40 <= len(blob) <= MAX_LOCAL_PLACE_BLOB or not blob.startswith(b"bplist00"):
        raise _LocalPlaceShapeError()
    offset_size, ref_size, object_count, top_object, offsets = struct.unpack(">6xBBQQQ", blob[-32:])
    if (offset_size not in (1, 2, 4, 8) or ref_size not in (1, 2, 4, 8)
            or not 0 < object_count <= MAX_LOCAL_PLACE_OBJECTS
            or top_object >= object_count or not 8 <= offsets < len(blob) - 32
            or offsets + object_count * offset_size > len(blob) - 32):
        raise _LocalPlaceShapeError()
    positions = [int.from_bytes(blob[index:index + offset_size], "big")
                 for index in range(offsets, offsets + object_count * offset_size, offset_size)]
    if len(set(positions)) != object_count or any(not 8 <= position < offsets for position in positions):
        raise _LocalPlaceShapeError()
    edges, spans, total_refs = {}, [], 0
    for index, position in enumerate(positions):
        token = blob[position]
        kind, size, cursor = token & 0xF0, token & 0x0F, position + 1
        if kind in (0x40, 0x50, 0x60, 0xA0, 0xD0) and size == 15:
            if cursor >= offsets or blob[cursor] & 0xF0 != 0x10 or blob[cursor] & 0x0F > 3:
                raise _LocalPlaceShapeError()
            width = 1 << (blob[cursor] & 0x0F)
            cursor += 1
            if cursor + width > offsets:
                raise _LocalPlaceShapeError()
            size = int.from_bytes(blob[cursor:cursor + width], "big")
            cursor += width
        if token in (0x00, 0x08, 0x09, 0x0F):
            length = 0
        elif kind == 0x10:
            length = 1 << size
        elif token in (0x22, 0x23, 0x33):
            length = 4 if token == 0x22 else 8
        elif kind in (0x40, 0x50, 0x60):
            length = size * (2 if kind == 0x60 else 1)
        elif kind == 0x80 and size < 8:
            length = size + 1
        elif kind in (0xA0, 0xD0):
            if size > MAX_LOCAL_PLACE_OBJECTS:
                raise _LocalPlaceShapeError()
            count = size * (2 if kind == 0xD0 else 1)
            total_refs += count
            length = count * ref_size
            if total_refs > MAX_LOCAL_PLACE_OBJECTS * 8 or cursor + length > offsets:
                raise _LocalPlaceShapeError()
            refs = [int.from_bytes(blob[start:start + ref_size], "big")
                    for start in range(cursor, cursor + length, ref_size)]
            if any(ref >= object_count for ref in refs):
                raise _LocalPlaceShapeError()
            edges[index] = refs
        else:
            raise _LocalPlaceShapeError()
        if cursor + length > offsets:
            raise _LocalPlaceShapeError()
        spans.append((position, cursor + length))
    spans.sort()
    if any(previous[1] > current[0] for previous, current in zip(spans, spans[1:])):
        raise _LocalPlaceShapeError()
    # UID references are numbers in this graph; the separate keyed-archive
    # resolver checks those. Reject cycles/deep nesting in native containers.
    heights, visiting, stack = {}, {top_object}, [(top_object, 0)]
    while stack:
        node, next_index = stack[-1]
        children = edges.get(node, [])
        if next_index < len(children):
            child = children[next_index]
            stack[-1] = (node, next_index + 1)
            if child in visiting:
                raise _LocalPlaceShapeError()
            if child not in heights:
                visiting.add(child)
                stack.append((child, 0))
                if len(stack) > MAX_LOCAL_PLACE_DEPTH:
                    raise _LocalPlaceShapeError()
        else:
            height = 1 + max((heights[child] for child in children), default=0)
            if height > MAX_LOCAL_PLACE_DEPTH:
                raise _LocalPlaceShapeError()
            heights[node] = height
            visiting.remove(node)
            stack.pop()


class _LocalPlaceArchive:
    """Read a bounded keyed plist as data, without instantiating archived classes."""
    def __init__(self, blob):
        _preflight_local_place_plist(blob)
        archive = plistlib.loads(blob)
        if (not isinstance(archive, dict) or archive.get("$archiver") != "NSKeyedArchiver"
                or type(archive.get("$version")) is not int or archive["$version"] != 100000):
            raise _LocalPlaceShapeError()
        self.objects = archive.get("$objects")
        if not isinstance(self.objects, list) or not 0 < len(self.objects) <= MAX_LOCAL_PLACE_OBJECTS:
            raise _LocalPlaceShapeError()
        top = archive.get("$top")
        if not isinstance(top, dict) or not isinstance(top.get("root"), plistlib.UID):
            raise _LocalPlaceShapeError()
        self.root = self.resolve(top["root"])

    def resolve(self, value):
        seen = set()
        for _ in range(MAX_LOCAL_PLACE_DEPTH):
            if not isinstance(value, plistlib.UID):
                return None if value == "$null" else value
            index = value.data
            if index in seen or not 0 <= index < len(self.objects):
                raise _LocalPlaceShapeError()
            seen.add(index)
            value = self.objects[index]
        raise _LocalPlaceShapeError()

    def object(self, value, expected_class):
        value = self.resolve(value)
        if not isinstance(value, dict):
            raise _LocalPlaceShapeError()
        descriptor = self.resolve(value.get("$class"))
        if not isinstance(descriptor, dict) or descriptor.get("$classname") != expected_class:
            raise _LocalPlaceShapeError()
        classes = descriptor.get("$classes")
        if not isinstance(classes, list) or not classes or classes[0] != expected_class or any(type(name) is not str for name in classes):
            raise _LocalPlaceShapeError()
        return value

    def text(self, value):
        value = self.resolve(value)
        if value is None:
            return None
        if (not isinstance(value, str) or len(value) > 256
                or any(unicodedata.category(char).startswith("C") or char in "\u2028\u2029" for char in value)):
            raise _LocalPlaceShapeError()
        return unicodedata.normalize("NFC", value).strip() or None

    def array(self, value):
        value = self.resolve(value)
        if isinstance(value, dict):
            descriptor = self.resolve(value.get("$class"))
            if not isinstance(descriptor, dict) or descriptor.get("$classname") not in ("NSArray", "NSMutableArray"):
                raise _LocalPlaceShapeError()
            self.object(value, descriptor["$classname"])
            value = self.resolve(value.get("NS.objects"))
        if not isinstance(value, list) or len(value) > MAX_LOCAL_PLACE_INFOS:
            raise _LocalPlaceShapeError()
        return value


def parse_local_place(blob):
    """Return a trustworthy country/province/city label, or let the app fall back.

    Only the observed reverse-location structure is understood. Display names,
    full addresses, POIs and nearby coordinates never stand in for a city.
    """
    try:
        archive = _LocalPlaceArchive(blob)
        root = archive.object(archive.root, "PLRevGeoLocationInfo")
        postal = archive.object(root.get("postalAddress"), "CNPostalAddress")
        country = archive.text(postal.get("_country"))
        province = archive.text(postal.get("_state"))
        city = archive.text(postal.get("_city"))
        if not country or not city:
            return None
        codes = [archive.text(postal.get("_ISOCountryCode")), archive.text(root.get("countryCode"))]
        if any(code is not None and not re.fullmatch(r"[A-Z]{2}", code) for code in codes):
            return None
        if codes[0] is not None and codes[1] is not None and codes[0] != codes[1]:
            return None
        map_item = archive.object(root.get("mapItem"), "PLRevGeoMapItem")
        names = {1: set(), 2: set(), 4: set()}
        for value in archive.array(map_item.get("sortedPlaceInfos")):
            place = archive.object(value, "PLRevGeoMapItemAdditionalPlaceInfo")
            place_type = archive.resolve(place.get("placeType"))
            if type(place_type) is not int or place_type < 0:
                return None
            if place_type in names:
                name = archive.text(place.get("name"))
                if not name:
                    return None
                names[place_type].add(name)
        if names[4] != {city} or (names[1] and names[1] != {country}):
            return None
        if names[2] and (not province or names[2] != {province}):
            return None
        parts = []
        for part in (country, province, city):
            if part and (not parts or part != parts[-1]):
                parts.append(part)
        return " · ".join(parts)
    except (ValueError, TypeError, KeyError, IndexError, OverflowError, RecursionError, struct.error):
        return None


def _has_coordinate(row):
    latitude, longitude = row["ZLATITUDE"], row["ZLONGITUDE"]
    return (type(latitude) in (int, float) and type(longitude) in (int, float)
            and math.isfinite(latitude) and math.isfinite(longitude)
            and -90 <= latitude <= 90 and -180 <= longitude <= 180)


def local_place_names(db, metadata, lower, upper):
    """Read optional cities only for date-filtered candidates with unique links.

    The identity query is batched. BLOBs are read one at a time, after checking
    their type/length and both sides of the relationship. Unsupported optional
    fields do not make otherwise valid media unarchivable.
    """
    required = {"Z_PK", "ZASSET", "ZREVERSELOCATIONDATA", "ZREVERSELOCATIONDATAISVALID"}
    try:
        columns = {row[1].upper() for row in db.execute('PRAGMA table_info("ZADDITIONALASSETATTRIBUTES")')}
        if not required <= columns:
            return {}
        candidates = [(identifier, row) for identifier, row in metadata.items()
                      if lower <= row["ZDATECREATED"] < upper and not row["ZHIDDEN"] and not row["ZTRASHEDSTATE"]
                      and type(row["Z_PK"]) is int and row["Z_PK"] > 0
                      and type(row["ZADDITIONALATTRIBUTES"]) is int and row["ZADDITIONALATTRIBUTES"] > 0
                      and _has_coordinate(row)]
        result = {}
        for start in range(0, len(candidates), 200):
            batch = candidates[start:start + 200]
            asset_ids = [row["Z_PK"] for _, row in batch]
            attribute_ids = [row["ZADDITIONALATTRIBUTES"] for _, row in batch]
            placeholders = ",".join("?" for _ in batch)
            # Either direction is included, so duplicate or misdirected rows
            # cannot be hidden by an inner join or picking the first result.
            headers = db.execute("SELECT Z_PK,ZASSET,ZREVERSELOCATIONDATAISVALID,"
                                 "typeof(ZREVERSELOCATIONDATA) AS blob_type,length(ZREVERSELOCATIONDATA) AS blob_size "
                                 "FROM ZADDITIONALASSETATTRIBUTES WHERE ZASSET IN (" + placeholders + ") "
                                 "OR Z_PK IN (" + placeholders + ") LIMIT ?",
                                 (*asset_ids, *attribute_ids, len(batch) * 4 + 1)).fetchall()
            if len(headers) > len(batch) * 4:
                continue
            by_asset, by_attribute = {}, {}
            for header in headers:
                # Keep numeric aliases (for example REAL 1.0) in the groups:
                # SQLite matches them to INTEGER 1, so discarding their type
                # would conceal duplicate links in an unsupported schema.
                by_asset.setdefault(header["ZASSET"], []).append(header)
                by_attribute.setdefault(header["Z_PK"], []).append(header)
            references = dict(db.execute("SELECT ZADDITIONALATTRIBUTES,COUNT(*) FROM ZASSET "
                                         "WHERE ZADDITIONALATTRIBUTES IN (" + placeholders + ") "
                                         "GROUP BY ZADDITIONALATTRIBUTES", attribute_ids))
            identities = dict(db.execute("SELECT Z_PK,COUNT(*) FROM ZASSET WHERE Z_PK IN (" + placeholders + ") GROUP BY Z_PK", asset_ids))
            for identifier, asset in batch:
                asset_id, attribute_id = asset["Z_PK"], asset["ZADDITIONALATTRIBUTES"]
                owner = by_asset.get(asset_id, [])
                if (len(owner) != 1 or len(by_attribute.get(attribute_id, [])) != 1
                        or owner[0]["Z_PK"] != attribute_id or references.get(attribute_id) != 1
                        or identities.get(asset_id) != 1):
                    continue
                header = owner[0]
                if (type(header["Z_PK"]) is not int or type(header["ZASSET"]) is not int
                        or type(header["ZREVERSELOCATIONDATAISVALID"]) is not int or header["ZREVERSELOCATIONDATAISVALID"] != 1
                        or header["blob_type"] != "blob" or type(header["blob_size"]) is not int
                        or not 0 < header["blob_size"] <= MAX_LOCAL_PLACE_BLOB):
                    continue
                values = db.execute("SELECT ZREVERSELOCATIONDATA FROM ZADDITIONALASSETATTRIBUTES "
                                    "WHERE Z_PK=? AND ZASSET=? LIMIT 2", (attribute_id, asset_id)).fetchall()
                if len(values) == 1:
                    name = parse_local_place(values[0][0])
                    if name is not None:
                        result[identifier] = name
        return result
    except (sqlite3.Error, KeyError, IndexError, TypeError, ValueError, OverflowError):
        return {}


def safe_path(path: str, *, metadata: bool = False) -> str:
    if not isinstance(path, str) or not path.startswith("/"):
        raise UserError("手机文件路径格式不支持，已停止读取。")
    parts = path.split("/")[1:]
    if not parts or any(not part or part in {".", ".."} for part in parts):
        raise UserError("手机文件路径格式不支持，已停止读取。")
    if any(ord(char) < 32 or char == "\\" for char in path):
        raise UserError("手机文件路径格式不支持，已停止读取。")
    if metadata:
        if path not in METADATA_PATHS:
            raise UserError("请求读取的索引不在允许范围内。")
    elif len(parts) < 3 or parts[0] != "DCIM":
        raise UserError("原片路径不在手机 DCIM 目录内，无法确认原片。")
    return path


def primary_path(directory: object, filename: object) -> str:
    if not isinstance(directory, str) or not isinstance(filename, str):
        raise UserError("照片索引没有提供完整原片路径。")
    if "/" in filename or "\\" in filename or not filename:
        raise UserError("照片索引中的文件名格式不支持。")
    return safe_path("/" + directory.removeprefix("/") + "/" + filename)


def date_bounds(start: str, end: str, timezone: str):
    try:
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", start) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", end):
            raise ValueError()
        first, last, zone = dt.date.fromisoformat(start), dt.date.fromisoformat(end), ZoneInfo(timezone)
        if first > last:
            raise ValueError()
        begin = dt.datetime.combine(first, dt.time(), zone)
        finish = dt.datetime.combine(last + dt.timedelta(days=1), dt.time(), zone)
        return (begin.astimezone(dt.timezone.utc) - COCOA_EPOCH).total_seconds(), (finish.astimezone(dt.timezone.utc) - COCOA_EPOCH).total_seconds(), zone
    except (ValueError, TypeError, OverflowError, ZoneInfoNotFoundError):
        raise UserError("旅行日期或时区无效，请重新选择。") from None


def fingerprint(info):
    if info.get("st_ifmt") != "S_IFREG" or "LinkTarget" in info:
        raise UserError("手机原片不是普通文件，已停止读取。")
    size = info.get("st_size")
    if not isinstance(size, int) or size < 0 or "st_mtime" not in info:
        raise UserError("无法确认手机原片的大小或修改时间。")
    return size, str(info["st_mtime"]), str(info.get("st_birthtime", ""))


def require_columns(db, table, columns):
    actual = {row[1].upper() for row in db.execute('PRAGMA table_info("' + table + '")')}
    if not set(column.upper() for column in columns) <= actual:
        raise UserError("此 iPhone 照片索引的结构尚不支持，无法可靠读取“由我拍摄”。")


def open_database(path):
    try:
        db = sqlite3.connect(Path(path).resolve().as_uri() + "?mode=ro", uri=True)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA query_only=ON")
        db.execute("PRAGMA trusted_schema=OFF")
        if [row[0] for row in db.execute("PRAGMA quick_check")] != ["ok"]:
            db.close()
            raise UserError("照片索引校验未通过，请稍后重新扫描。")
        return db
    except sqlite3.Error:
        raise UserError("无法完整读取照片索引，请稍后重新扫描。") from None


def normalized_uuid(value):
    try:
        return str(uuid.UUID(value)).upper()
    except (ValueError, TypeError, AttributeError):
        raise UserError("照片索引包含无法识别的素材标识，已停止扫描。") from None


def read_classification(db, selected_asset_ids=None):
    require_columns(db, "lexicon", {"lexeme_id", "type", "category", "content"})
    require_columns(db, "items", {"identifier", "type", "lexeme_ids"})
    mine_ids, live_ids = set(), set()
    for row in db.execute("SELECT lexeme_id, type, category, content FROM lexicon WHERE category IN (8170, 5060)"):
        if row["type"] == 1:
            # Live-photo search categories can also contain empty placeholder terms.
            # They provide no positive classification and must not invalidate 8170.
            if row["category"] == 5060 and isinstance(row["content"], str) and not row["content"].strip("\0 "):
                continue
            if not isinstance(row["lexeme_id"], int) or not isinstance(row["content"], str) or not row["content"].strip("\0 "):
                raise UserError("照片分类索引不完整，无法确认“由我拍摄”。")
            (mine_ids if row["category"] == 8170 else live_ids).add(row["lexeme_id"])
    if not mine_ids:
        raise UserError("手机尚未提供可识别的“由我拍摄”分类，请先在手机照片 App 中确认分类已生成。")
    indexed, mine, live = set(), set(), set()
    for row in db.execute("SELECT identifier, lexeme_ids FROM items WHERE type=1"):
        try:
            identifier = normalized_uuid(row["identifier"])
        except UserError:
            if selected_asset_ids is None:
                raise
            continue
        if selected_asset_ids is not None and identifier not in selected_asset_ids:
            continue
        blob = row["lexeme_ids"]
        if identifier in indexed or not isinstance(blob, bytes) or len(blob) % 4:
            raise UserError("照片分类索引重复或不完整，请稍后重新扫描。")
        indexed.add(identifier)
        ids = set(struct.unpack("<" + "I" * (len(blob) // 4), blob))
        if ids & mine_ids:
            mine.add(identifier)
        if ids & live_ids:
            live.add(identifier)
    return indexed, mine, live


def issue(asset_id, name, message, blocking=True):
    result = {"id": str(uuid.uuid4()), "name": name, "message": message, "isBlocking": blocking}
    if asset_id is not None:
        result["assetID"] = asset_id
    return result


def live_resources(db, asset_row):
    """Return strictly gated candidates, not proof of Live Photo pairing.

    iLEAPP Ph050AssetIntResouData documents internal resource types 0/3.
    PLPrimaryResourceDataStoreUniformFileKey's iOS 17 runtime header describes
    strategy 3's bit fields; the two exact binary keys below encode original,
    non-derivative, uppercase HEIC/MOV resources. The same-stem DCIM candidate
    rule was checked against 82 resource pairs on one iPhone, including lengths.
    It is NOT a proven general private path-decoding rule. Unknown encodings
    remain blocked. Scan must check both lengths; the archive layer MUST verify
    matching embedded Live Photo content identifiers before committing a group.

    Sources: github.com/abrignoni/iLEAPP/blob/main/scripts/artifacts/Ph050AssetIntResouData.py
    github.com/MTACS/iOS-17-Runtime-Headers/blob/main/PrivateFrameworks/
    PhotoLibraryServices.framework/PLPrimaryResourceDataStoreUniformFileKey.h
    """
    message = "此项为实况照片，尚未可靠确认照片与配对视频的完整关联，已阻止导入，避免只保存静态照片。"
    try:
        require_columns(db, "ZINTERNALRESOURCE", {"ZASSET", "ZRESOURCETYPE", "ZDATASTORESUBTYPE", "ZDATASTORECLASSID", "ZVERSION", "ZRECIPEID", "ZLOCALAVAILABILITY", "ZDATALENGTH"})
    except UserError:
        raise UserError(message) from None
    columns = {row[1].upper() for row in db.execute('PRAGMA table_info("ZINTERNALRESOURCE")')}
    # Ignore derived versions and non-photo/video sidecars, but never discard a
    # conflicting original media row merely because its subtype/key is unknown.
    media = list(db.execute("SELECT * FROM ZINTERNALRESOURCE WHERE ZASSET=? AND ZRESOURCETYPE IN (0,3)", (asset_row["Z_PK"],)))
    if any(type(row["ZVERSION"]) is not int or row["ZVERSION"] not in (0, 1, 2, 3) or type(row["ZRECIPEID"]) is not int or row["ZRECIPEID"] < 0 for row in media):
        raise UserError(message)
    resources = [row for row in media if row["ZVERSION"] == 0 and row["ZRECIPEID"] == 0]
    if len(resources) != 2 or {row["ZRESOURCETYPE"] for row in resources} != {0, 3}:
        raise UserError(message)
    binary = "ZDATASTOREKEYDATA" in columns and any(row["ZDATASTOREKEYDATA"] is not None for row in resources)
    if binary:
        if not {"ZCOMPACTUTI", "ZTRASHEDSTATE", "ZPTPTRASHEDSTATE"} <= columns:
            raise UserError(message)
        photo_path = primary_path(asset_row["ZDIRECTORY"], asset_row["ZFILENAME"])
        if PurePosixPath(photo_path).suffix != ".HEIC":
            raise UserError(message)
        candidate_paths = {0: photo_path, 3: str(PurePosixPath(photo_path).with_suffix(".MOV"))}
        known = {0: (bytes.fromhex("03000000c001"), 1, "3"), 3: (bytes.fromhex("03300000c00b"), 18, "23")}
    elif "ZDATASTOREKEY" not in columns:
        raise UserError(message)
    paths = {}
    sizes = {}
    for resource in resources:
        if resource["ZLOCALAVAILABILITY"] != 1 or resource["ZDATASTORECLASSID"] != 0:
            raise UserError("实况照片的完整原件不在本地，或资源路径格式尚不支持；已阻止整项导入，不会从 iCloud 下载。")
        resource_kind = resource["ZRESOURCETYPE"]
        for flag in ("ZTRASHEDSTATE", "ZPTPTRASHEDSTATE"):
            if flag in columns and resource[flag] != 0:
                raise UserError(message)
        if binary:
            expected_key, subtype, compact_uti = known[resource_kind]
            if resource["ZDATASTOREKEYDATA"] != expected_key or resource["ZDATASTORESUBTYPE"] != subtype or resource["ZCOMPACTUTI"] != compact_uti:
                raise UserError(message)
            # Two path representations would require an independently checked
            # consistency rule; do not silently prefer one over the other.
            if "ZDATASTOREKEY" in columns and resource["ZDATASTOREKEY"] is not None:
                raise UserError(message)
            path = safe_path(candidate_paths[resource_kind])
        else:
            key = resource["ZDATASTOREKEY"]
            if not isinstance(key, str) or resource["ZDATASTORESUBTYPE"] != 1:
                raise UserError(message)
            path = safe_path("/" + key.removeprefix("/"))
        allowed = PHOTO_EXTENSIONS if resource_kind == 0 else VIDEO_EXTENSIONS
        size = resource["ZDATALENGTH"]
        if PurePosixPath(path).suffix.lower() not in allowed or type(size) is not int or size <= 0:
            raise UserError(message)
        paths[resource_kind] = path
        sizes[path] = size
    if paths[0] != primary_path(asset_row["ZDIRECTORY"], asset_row["ZFILENAME"]) or paths[0] == paths[3]:
        raise UserError(message)
    return [paths[0], paths[3]], sizes


def semantic_value(value):
    """Keep raw SQLite values, including unknown coordinates, stable in memory.

    Type tags and exact float representations avoid losing same-day timestamp
    changes or normalizing different invalid/missing coordinates to one value.
    These signatures never cross the JSON protocol or reach persistent storage.
    """
    if isinstance(value, bytes):
        return ("bytes", value.hex())
    if isinstance(value, float):
        return ("float", value.hex())
    return (type(value).__name__, value)


def original_resource_semantics(db, asset_row):
    """Track original resources, not derived previews or database row numbers."""
    columns = {row[1].upper() for row in db.execute('PRAGMA table_info("ZINTERNALRESOURCE")')}
    if not columns:
        return None  # Ordinary originals historically do not require this table.
    require_columns(db, "ZINTERNALRESOURCE", {"ZASSET", "ZRESOURCETYPE", "ZVERSION", "ZRECIPEID", "ZLOCALAVAILABILITY", "ZDATALENGTH"})
    relevant = ("ZRESOURCETYPE", "ZDATASTORESUBTYPE", "ZDATASTORECLASSID", "ZVERSION", "ZRECIPEID",
                "ZLOCALAVAILABILITY", "ZDATALENGTH", "ZDATASTOREKEY", "ZDATASTOREKEYDATA",
                "ZCOMPACTUTI", "ZTRASHEDSTATE", "ZPTPTRASHEDSTATE", "ZUUID", "ZRESOURCEUUID")
    fields = tuple(name for name in relevant if name in columns)
    rows = db.execute("SELECT * FROM ZINTERNALRESOURCE WHERE ZASSET=? AND ZRESOURCETYPE IN (0,3) AND ZVERSION=0 AND ZRECIPEID=0", (asset_row["Z_PK"],))
    descriptors = [tuple((name, semantic_value(row[name])) for name in fields) for row in rows]
    # Sort the typed descriptors rather than using the internal Z_PK; duplicate
    # original rows remain visible in the tuple and cannot silently disappear.
    return (fields, tuple(sorted(descriptors, key=repr)))


def asset_semantics(db, row, identifier, indexed, mine, live, paths, expected_sizes, local_place_name=None):
    fields = ("ZKIND", "ZKINDSUBTYPE", "ZDATECREATED", "ZDIRECTORY", "ZFILENAME",
              "ZLATITUDE", "ZLONGITUDE", "ZHIDDEN", "ZTRASHEDSTATE")
    return (identifier, identifier in indexed, identifier in mine, identifier in live,
            tuple((field, semantic_value(row[field])) for field in fields),
            original_resource_semantics(db, row), tuple(paths), tuple(sorted(expected_sizes.items())), local_place_name)


def parse_catalog(leo_path, photos_path, start, end, timezone, selected_asset_ids=None):
    """Parse only a local snapshot; returns candidates without opening any original."""
    lower, upper, zone = date_bounds(start, end, timezone)
    with contextlib.closing(open_database(leo_path)) as leo, contextlib.closing(open_database(photos_path)) as photos:
        if selected_asset_ids is not None:
            selected_asset_ids = {normalized_uuid(value) for value in selected_asset_ids}
            if not selected_asset_ids:
                raise UserError("没有可复核的已选素材，请重新扫描。")
        indexed, mine, live = read_classification(leo, selected_asset_ids)
        if selected_asset_ids is not None and mine != selected_asset_ids:
            raise UserError("所选素材的“由我拍摄”分类已变化或缺失，请重新扫描并确认选择。")
        columns = {"Z_PK", "ZUUID", "ZKIND", "ZKINDSUBTYPE", "ZDATECREATED", "ZDIRECTORY", "ZFILENAME", "ZLATITUDE", "ZLONGITUDE", "ZHIDDEN", "ZTRASHEDSTATE"}
        require_columns(photos, "ZASSET", columns)
        # Reconcile identities before filtering, so a stale cross-database join is visible.
        metadata = {}
        available = {row[1].upper() for row in photos.execute('PRAGMA table_info("ZASSET")')}
        additional = "ZADDITIONALATTRIBUTES" if "ZADDITIONALATTRIBUTES" in available else "NULL AS ZADDITIONALATTRIBUTES"
        for row in photos.execute("SELECT Z_PK,ZUUID,ZDATECREATED,ZHIDDEN,ZTRASHEDSTATE,ZLATITUDE,ZLONGITUDE," + additional + " FROM ZASSET"):
            try:
                identifier = normalized_uuid(row["ZUUID"])
            except UserError:
                continue  # Non-asset/internal rows are irrelevant unless index references them.
            if identifier in mine:
                if identifier in metadata:
                    raise UserError("照片数据库中存在重复素材标识，无法安全归档。")
                metadata[identifier] = row
        if mine - metadata.keys():
            raise UserError("“由我拍摄”分类与照片数据库尚未同步完整，请稍后重新扫描。")
        outside, ignored = 0, 0
        for row in metadata.values():
            value = row["ZDATECREATED"]
            if not isinstance(value, (int, float)) or not math.isfinite(value):
                raise UserError("部分“由我拍摄”素材缺少可靠拍摄日期，无法确认旅行范围。")
            if row["ZHIDDEN"] not in (0, 1) or not isinstance(row["ZTRASHEDSTATE"], int):
                raise UserError("无法确认照片隐藏或删除状态，已停止扫描。")
            if row["ZHIDDEN"] or row["ZTRASHEDSTATE"]:
                ignored += 1
            elif not lower <= value < upper:
                outside += 1
        places = local_place_names(photos, metadata, lower, upper)
        candidates, issues = [], []
        # Date predicate precedes filesystem checks. Never enumerate DCIM.
        rows = photos.execute("SELECT * FROM ZASSET WHERE ZDATECREATED>=? AND ZDATECREATED<? AND ZHIDDEN=0 AND ZTRASHEDSTATE=0 ORDER BY ZDATECREATED,Z_PK", (lower, upper))
        indexed_unconfirmed, missing_index = 0, 0
        for row in rows:
            try:
                identifier = normalized_uuid(row["ZUUID"])
            except UserError:
                if selected_asset_ids is None:
                    raise
                continue
            if selected_asset_ids is not None and identifier not in selected_asset_ids:
                continue
            if identifier not in mine:
                if identifier in indexed:
                    indexed_unconfirmed += 1
                else:
                    missing_index += 1
                continue
            kind = {0: "photo", 1: "video"}.get(row["ZKIND"])
            name = row["ZFILENAME"] if isinstance(row["ZFILENAME"], str) else "未命名素材"
            day = (COCOA_EPOCH + dt.timedelta(seconds=row["ZDATECREATED"])).astimezone(zone).date().isoformat()
            asset = {"id": identifier, "name": name, "kind": kind or "photo", "captureDay": day, "fileIDs": []}
            local_place_name = places.get(identifier)
            if local_place_name is not None:
                asset["localPlaceName"] = local_place_name
            lat, lon = row["ZLATITUDE"], row["ZLONGITUDE"]
            if all(isinstance(v, (int, float)) and math.isfinite(v) for v in (lat, lon)) and -90 <= lat <= 90 and -180 <= lon <= 180:
                asset.update(latitude=lat, longitude=lon)
            paths, expected_sizes = [], {}
            problem = None
            if kind is None:
                problem = "此素材类型尚不支持，已阻止导入。"
            elif row["ZKINDSUBTYPE"] == 2 or identifier in live:
                try:
                    if kind != "photo":
                        raise UserError("实况照片分类与素材类型冲突，已阻止导入。")
                    paths, expected_sizes = live_resources(photos, row)
                except UserError as exc:
                    problem = str(exc)
            elif row["ZKINDSUBTYPE"] in (10, 103):
                problem = "此素材同时标记为截屏或录屏，与“由我拍摄”分类冲突，已阻止导入。"
            elif row["ZKINDSUBTYPE"] not in (0, 1, 100, 101, 102):
                problem = "此素材的组成类型尚不支持，无法确认原片完整性。"
            else:
                try:
                    path = primary_path(row["ZDIRECTORY"], row["ZFILENAME"])
                    suffix = PurePosixPath(path).suffix.lower()
                    if suffix not in (PHOTO_EXTENSIONS if kind == "photo" else VIDEO_EXTENSIONS):
                        raise UserError("原片扩展名与照片类型不一致或尚不支持。")
                    paths = [path]
                except UserError as exc:
                    problem = str(exc)
            semantic = None
            if problem is None:
                try:
                    semantic = asset_semantics(photos, row, identifier, indexed, mine, live, paths, expected_sizes, local_place_name)
                except UserError as exc:
                    problem = str(exc)
                    paths, expected_sizes = [], {}
            if problem:
                issues.append(issue(identifier, name, problem))
            candidates.append({"asset": asset, "paths": paths, "expectedSizes": expected_sizes, "semantic": semantic})
        if indexed_unconfirmed or missing_index:
            issues.append(issue(None, "分类范围说明", f"日期范围内另有 {indexed_unconfirmed} 项已有索引但未标记为“由我拍摄”，{missing_index} 项缺少搜索索引，均未加入导入列表；这不代表它们一定不是本人拍摄，搜索索引可能有延迟。", False))
        return {"candidates": candidates, "issues": issues, "outsideRangeCount": outside, "ignoredCount": ignored}


def dependency():
    try:
        if importlib.metadata.version("pymobiledevice3") != DEPENDENCY_VERSION:
            raise UserError("USB 组件版本不匹配，请重新安装此版本软件。")
        from pymobiledevice3.usbmux import list_devices
        from pymobiledevice3.lockdown import create_using_usbmux
        from pymobiledevice3.services.afc import AfcService
        from pymobiledevice3.exceptions import AfcFileNotFoundError
    except (ImportError, importlib.metadata.PackageNotFoundError):
        raise UserError("USB 读取组件未安装完整，请重新安装软件。") from None

    class ReadOnlyAFC(AfcService):
        async def _dispatch_packet(self, operation, data, this_length=0):
            if int(operation) not in SAFE_OPERATIONS:
                raise UserError("USB 组件拒绝了非只读文件操作。")
            return await super()._dispatch_packet(operation, data, this_length)

        async def fopen(self, filename, mode="r"):
            if mode != "r":
                raise UserError("USB 组件只允许只读打开。")
            return await super().fopen(filename, "r")

    return list_devices, create_using_usbmux, ReadOnlyAFC, AfcFileNotFoundError


class USBSession:
    def __init__(self, device_id):
        self.device_id = device_id
        self.phone = self.afc = None
        self.mux_id = None
        self.name = "iPhone"
        self.parents = set()

    async def open(self):
        listing, create, afc_class, self.missing_exception = dependency()
        matches = [dev for dev in await listing() if dev.connection_type == "USB" and dev.serial == self.device_id]
        if len(matches) != 1:
            raise UserError("未找到所选 iPhone 的 USB 连接，请连接数据线并解锁手机。")
        self.mux_id = matches[0].devid
        try:
            self.phone = await create(serial=self.device_id, connection_type="USB", autopair=False, label="TravelArchiveUSBReadOnly")
            if not self.phone.paired:
                raise UserError("请先解锁 iPhone，并通过 Finder 完成“信任此电脑”，然后重新扫描。")
            if self.phone.identifier != self.device_id:
                raise UserError("USB 设备已发生变化，请重新扫描。")
            self.name = self.phone.all_values.get("DeviceName", "iPhone")
            self.afc = afc_class(self.phone)
            await self.afc.__aenter__()
        except BaseException:
            await self.close()
            raise
        return self

    async def connected(self):
        listing, *_ = dependency()
        if not any(dev.connection_type == "USB" and dev.serial == self.device_id and dev.devid == self.mux_id for dev in await listing()):
            raise UserError("iPhone 已断开或重新连接，请重新扫描后再导入。")

    async def close(self):
        if self.afc is not None:
            with contextlib.suppress(Exception):
                await asyncio.wait_for(self.afc.aclose(), 3)
            self.afc = None
        if self.phone is not None:
            if getattr(self.phone, "session_id", None):
                with contextlib.suppress(Exception):
                    await asyncio.wait_for(self.phone.stop_session(), 3)
            with contextlib.suppress(Exception):
                await asyncio.wait_for(self.phone.close(), 3)
            self.phone = None
        self.parents.clear()

    async def stat(self, path, *, metadata=False):
        safe_path(path, metadata=metadata)
        for parent in reversed(PurePosixPath(path).parents):
            parent = str(parent)
            if parent == "/" or parent in self.parents:
                continue
            info = await self.afc.stat(parent)
            if info.get("st_ifmt") != "S_IFDIR" or "LinkTarget" in info:
                raise UserError("手机目录不是普通目录，已停止读取。")
            self.parents.add(parent)
        return await self.afc.stat(path)

    async def read_bytes(self, path, offset, length):
        handle = await self.afc.fopen(path, "r")
        try:
            if offset:
                await self.afc.fseek(handle, offset)
            return await self.afc.fread(handle, length)
        finally:
            await self.afc.fclose(handle)


async def metadata_state(session, paths=METADATA_PATHS):
    state = {}
    for path in paths:
        try:
            state[path] = fingerprint(await session.stat(path, metadata=True))
        except session.missing_exception:
            state[path] = None
    return state


async def snapshot(session, destination, progress):
    # The four files are one logical snapshot. Per-file double reads alone do
    # not detect an earlier file changing while a later database is copied.
    baseline = await metadata_state(session)
    if any(baseline[path] is None for path in METADATA_PATHS if not path.endswith("-wal")):
        raise UserError("手机没有提供需要的照片索引，此系统版本暂不支持。")
    first = {}
    for round_number in range(2):
        for index, path in enumerate(METADATA_PATHS):
            await progress("正在读取并核对手机本地照片索引。", round_number * 4 + index)
            try:
                before = fingerprint(await session.stat(path, metadata=True))
            except session.missing_exception:
                before = None
            if before != baseline[path]:
                raise SnapshotChangedError("照片索引正在变化，请稍后重新扫描。")
            if before is None:
                first[path] = None
                continue
            if before[0] > MAX_DATABASE or (not path.endswith("-wal") and before[0] == 0):
                raise UserError("照片索引大小超出当前支持范围或为空，已停止扫描。")
            local = destination / PurePosixPath(path).name
            digest, consumed = hashlib.sha256(), 0
            handle = await session.afc.fopen(path, "r")
            output = local.open("wb") if round_number == 0 else contextlib.nullcontext()
            try:
                with output as file:
                    while consumed < before[0]:
                        data = await session.afc.fread(handle, min(MAX_CHUNK, before[0] - consumed))
                        if not data or len(data) > before[0] - consumed:
                            raise UserError("照片索引读取不完整，请检查数据线后重新扫描。")
                        digest.update(data)
                        consumed += len(data)
                        if file is not None:
                            file.write(data)
            finally:
                await session.afc.fclose(handle)
            try:
                after = fingerprint(await session.stat(path, metadata=True))
            except session.missing_exception:
                after = None
            value = (before, digest.digest())
            if before != after or (round_number and first.get(path) != value):
                raise SnapshotChangedError("照片索引正在变化，请稍后重新扫描。")
            first[path] = value
        if await metadata_state(session) != baseline:
            raise SnapshotChangedError("照片索引正在变化，请稍后重新扫描。")
    await session.connected()
    return baseline


class Server:
    def __init__(self, session_factory=USBSession):
        self.session_factory = session_factory
        self.manifests = {}
        self.session = None
        self.active_token = None

    async def close(self):
        if self.session is not None:
            await self.session.close()
        self.session = None
        self.active_token = None

    async def check_originals(self, manifest, selected):
        if not selected or not selected <= manifest["files"].keys():
            raise UserError("没有可复核的已选原片，请重新扫描。")
        for item_id in selected:
            entry = manifest["files"][item_id]
            try:
                current = fingerprint(await self.session.stat(entry["path"]))
            except self.session.missing_exception:
                current = None
            if current != entry["fingerprint"]:
                raise UserError("所选手机原片在扫描后发生变化，请重新扫描。")

    async def check_metadata(self, manifest, selected_ids=None, progress=None):
        # Only preparation consults the mutable Photos indexes. Once prepared,
        # this archive keeps its confirmed membership/date/place/resource plan;
        # later provider validation checks those original files, not the library.
        selected = set(manifest["selected"] if selected_ids is None else selected_ids)
        if await metadata_state(self.session, manifest["metadata"]) == manifest["metadata"]:
            # An unchanged library index cannot excuse an original's identity
            # changing between the preview and preparation.
            await self.check_originals(manifest, selected)
            if await metadata_state(self.session, manifest["metadata"]) == manifest["metadata"]:
                return
            # The indexes may have changed while originals were being stat'ed.
            # Fall through to semantic verification rather than accepting an
            # index version that was observed only before those awaited calls.
        # A whole-library database update does not establish that the chosen
        # originals changed. Revalidate their semantics against a new stable
        # snapshot without admitting new files or resetting original identities.
        request, semantics = manifest.get("request"), manifest.get("semantics")
        if not selected or not selected <= manifest["files"].keys() or not request or not semantics:
            raise UserError("手机照片索引在扫描后发生变化，请重新扫描以确认分类、日期和位置。")
        asset_ids = {manifest["files"][item_id].get("assetID") for item_id in selected}
        if None in asset_ids or any(semantics.get(asset_id) is None for asset_id in asset_ids):
            raise UserError("所选素材的索引复核依据不完整，请重新扫描。")

        async def notify(message, visited):
            if progress is not None:
                await progress(message, visited)

        for attempt in range(2):
            try:
                # Each attempt gets an independent directory; stale WAL files
                # from a failed attempt must never contaminate a later parse.
                with tempfile.TemporaryDirectory(prefix="travel-iphone-refresh-") as temporary:
                    destination = Path(temporary)
                    refreshed = await snapshot(self.session, destination, notify)
                    result = parse_catalog(destination / "leo.sqlite", destination / "Photos.sqlite",
                                           request["start"], request["end"], request["timeZoneIdentifier"],
                                           selected_asset_ids=asset_ids)
                candidates = result["candidates"]
                current = {candidate["asset"]["id"]: candidate["semantic"] for candidate in candidates}
                if len(current) != len(candidates) or set(current) != asset_ids or any(
                    current[asset_id] != semantics[asset_id] for asset_id in asset_ids
                ) or any(problem["isBlocking"] for problem in result["issues"]):
                    raise UserError("所选素材的分类、拍摄日期、位置或原始资源已变化，已停止导入；请重新扫描并确认选择。")
                await self.check_originals(manifest, selected)
                await self.session.connected()
                if await metadata_state(self.session) != refreshed:
                    raise SnapshotChangedError("照片索引在复核期间仍在变化，请稍后重新扫描。")
                # This is the only mutation: the selected set, raw semantics,
                # paths and original file fingerprints all retain their origin.
                manifest["metadata"] = refreshed
                return
            except SnapshotChangedError:
                if attempt == 1:
                    raise UserError("导入前的照片索引仍在变化，尚未开始复制；请稍后重新扫描。") from None

    async def handle(self, request, progress):
        command = request.get("command")
        if command == "selfcheck":
            dependency()  # Import/package check only; never enumerates devices.
            ZoneInfo("Asia/Shanghai")
            return {"version": DEPENDENCY_VERSION}
        if command == "list":
            listing, *_ = dependency()
            devices = await listing()
            return {"devices": [{"id": d.serial, "name": "iPhone"} for d in devices if d.connection_type == "USB"]}
        if command == "scan":
            await self.close()
            self.manifests.clear()
            date_bounds(request.get("start"), request.get("end"), request.get("timeZoneIdentifier"))
            device_id = request.get("deviceID")
            if not isinstance(device_id, str) or not re.fullmatch(r"[A-Za-z0-9-]{8,64}", device_id):
                raise UserError("请选择需要导入的 iPhone。")
            session = self.session_factory(device_id)
            try:
                await session.open()
                with tempfile.TemporaryDirectory(prefix="travel-iphone-") as temporary:
                    destination = Path(temporary)
                    metadata = await snapshot(session, destination, progress)
                    result = parse_catalog(destination / "leo.sqlite", destination / "Photos.sqlite", request["start"], request["end"], request["timeZoneIdentifier"])
                items, assets, files, semantics = [], [], {}, {}
                for candidate in result.pop("candidates"):
                    asset, paths = candidate["asset"], candidate["paths"]
                    semantics[asset["id"]] = candidate["semantic"]
                    new_files = []
                    try:
                        for path in paths:
                            info = fingerprint(await session.stat(path))
                            if info[0] <= 0:
                                raise UserError("原片为空，无法归档。")
                            if path in candidate["expectedSizes"] and info[0] != candidate["expectedSizes"][path]:
                                raise UserError("实况照片的本地资源大小与数据库不一致，无法确认完整性，已阻止整项导入。")
                            item_id = hashlib.sha256((asset["id"] + "\0" + path).encode()).hexdigest()
                            new_files.append((item_id, path, info))
                    except session.missing_exception:
                        result["issues"].append(issue(asset["id"], asset["name"], "原片不在 iPhone 本地，无法通过数据线复制；软件不会从 iCloud 下载。"))
                        new_files = []
                    except UserError as exc:
                        result["issues"].append(issue(asset["id"], asset["name"], str(exc)))
                        new_files = []
                    ids = [entry[0] for entry in new_files]
                    for item_id, path, info in new_files:
                        item_kind = "video" if PurePosixPath(path).suffix.lower() in VIDEO_EXTENSIONS else "photo"
                        files[item_id] = {"path": path, "fingerprint": info, "kind": item_kind, "assetID": asset["id"]}
                        items.append({"id": item_id, "name": PurePosixPath(path).name, "kind": item_kind, "size": info[0], "captureDay": asset["captureDay"], "dateBasis": "iPhone 拍摄日期", "companionIDs": [other for other in ids if other != item_id]})
                    asset["fileIDs"] = ids
                    assets.append(asset)
                    await progress("正在检查所选日期内素材的本地可用性。", len(assets))
                await session.connected()
                token = str(uuid.uuid4())
                groups = {asset["id"]: set(asset["fileIDs"]) for asset in assets if asset["fileIDs"]}
                self.manifests[token] = {"deviceID": device_id, "muxID": session.mux_id, "files": files,
                                         "metadata": metadata, "groups": groups, "semantics": semantics,
                                         "request": {key: request[key] for key in ("start", "end", "timeZoneIdentifier")},
                                         "prepared": False, "selected": set()}
                return {"token": token, "deviceID": device_id, "deviceName": session.name, "items": items, "assets": assets, **result}
            finally:
                await session.close()
        if command == "shutdown":
            await self.close()
            self.manifests.clear()
            return {}
        token = request.get("token")
        if not isinstance(token, str) or token not in self.manifests:
            if command == "end":
                return {}
            raise UserError("扫描结果已过期，请重新扫描 iPhone。")
        if command == "end":
            if self.active_token == token:
                await self.close()
            del self.manifests[token]
            return {}
        if command not in {"prepare", "validate", "read"}:
            raise UserError("USB 组件收到不支持的请求。")
        manifest = self.manifests[token]
        try:
            if command == "prepare":
                if manifest["prepared"]:
                    raise UserError("此导入已开始，请完成或结束后重新扫描。")
                live_mode = request.get("livePhotoImportMode", "complete")
                if not isinstance(live_mode, str) or live_mode not in {"complete", "stillOnly"}:
                    raise UserError("实况照片导入方式无效，请重新选择。")
                item_ids = request.get("itemIDs")
                if not isinstance(item_ids, list) or not item_ids or any(not isinstance(value, str) for value in item_ids):
                    raise UserError("请先选择要导入的素材。")
                selected = set(item_ids)
                if len(selected) != len(item_ids) or not selected <= manifest["files"].keys():
                    raise UserError("所选素材不属于本次扫描结果，请重新选择。")
                for group in manifest["groups"].values():
                    chosen = group & selected
                    if not chosen:
                        continue
                    if live_mode == "complete":
                        if not group <= selected:
                            raise UserError("完整实况照片必须同时包含照片和配对视频，无法只复制部分组件。")
                    elif len(group) != 1:
                        # Membership comes from the scanned asset index, never
                        # from similar filenames. Preserve the full group while
                        # authorizing only its original photo in still-only mode.
                        photos = {item_id for item_id in group if manifest["files"][item_id].get("kind") == "photo"}
                        videos = {item_id for item_id in group if manifest["files"][item_id].get("kind") == "video"}
                        if len(group) != 2 or len(photos) != 1 or len(videos) != 1 or chosen != photos:
                            raise UserError("仅静态照片模式只能选择已确认实况照片的静态原片，不能包含配对视频。")
                await self.close()
                self.session = self.session_factory(manifest["deviceID"])
                await self.session.open()
                self.active_token = token
                # Preview may have been completed with the USB cable removed.
                # Only preparation can bind a new USB instance, after revalidation.
                await self.session.connected()
                await self.check_metadata(manifest, selected_ids=selected, progress=progress)
                manifest["selected"] = selected
                manifest["prepared"] = True
                manifest["livePhotoImportMode"] = live_mode
                manifest["muxID"] = self.session.mux_id
                return {}
            if not manifest["prepared"]:
                raise UserError("请先确认本次导入选择，再读取手机原片。")
            if self.session is None or self.active_token != token or self.session.mux_id != manifest["muxID"]:
                raise UserError("导入期间 USB 连接已释放或变化，请重新扫描；不会自动继续读取。")
            await self.session.connected()
            if command == "validate":
                # The user confirmed this plan when preparation succeeded.
                # Photos may continue indexing in the background while bytes
                # are copied. Do not re-open/rebase its whole-library indexes;
                # still reject changed/missing originals in the fixed selection.
                await self.check_originals(manifest, set(manifest["selected"]))
                await self.session.connected()
                return {}
            item_id, offset, length = request.get("itemID"), request.get("offset"), request.get("length")
            if item_id not in manifest["selected"]:
                raise UserError("请求读取的素材不在已确认的扫描列表中。")
            entry = manifest["files"][item_id]
            if type(offset) is not int or type(length) is not int or offset < 0 or length < 1 or length > MAX_CHUNK or offset > entry["fingerprint"][0]:
                raise UserError("原片读取范围无效。")
            length = min(length, entry["fingerprint"][0] - offset)
            if fingerprint(await self.session.stat(entry["path"])) != entry["fingerprint"]:
                raise UserError("手机原片在扫描后发生变化，请重新扫描。")
            data = await self.session.read_bytes(entry["path"], offset, length) if length else b""
            if len(data) != length or fingerprint(await self.session.stat(entry["path"])) != entry["fingerprint"]:
                raise UserError("原片读取不完整或已发生变化，请重新扫描。")
            return {"data": base64.b64encode(data).decode("ascii")}
        except BaseException:
            await self.close()
            self.manifests.pop(token, None)
            raise


def public_error(exc):
    if isinstance(exc, UserError):
        return str(exc)
    if isinstance(exc, (asyncio.TimeoutError, TimeoutError)):
        return "USB 读取超时，连接已释放。请确认手机已解锁后重新扫描。"
    name = type(exc).__name__
    if name in {"PasswordRequiredError", "DeviceLockedError", "GetProhibitedError"}:
        return "iPhone 当前不允许读取，请解锁手机并确认已信任此 Mac 后重新扫描。"
    if isinstance(exc, sqlite3.Error):
        return "照片索引结构或内容不支持，已停止读取；请稍后重新扫描。"
    return "USB 读取未能完成，连接已释放。请检查数据线、解锁和信任状态后重新扫描。"


async def serve():
    logging.disable(logging.CRITICAL)
    server = Server()
    reader = asyncio.StreamReader(limit=MAX_REQUEST)
    protocol = asyncio.StreamReaderProtocol(reader)
    await asyncio.get_running_loop().connect_read_pipe(lambda: protocol, sys.stdin)
    current = asyncio.current_task()
    for sig in (signal.SIGTERM, signal.SIGINT):
        asyncio.get_running_loop().add_signal_handler(sig, current.cancel)

    def emit(data):
        sys.stdout.write(json.dumps(data, ensure_ascii=False, allow_nan=False) + "\n")
        sys.stdout.flush()

    try:
        while True:
            try:
                line = await asyncio.wait_for(reader.readline(), 45)
            except asyncio.TimeoutError:
                # Local SHA-256 verification of a large video can legitimately
                # take longer than 45 seconds without requesting USB data.
                # Prepared imports are released by end/cancel/EOF, not idleness.
                if server.active_token is None:
                    await server.close()
                continue
            except ValueError:
                emit({"id": None, "ok": False, "error": "单次归档清单过大，请缩小日期或地点范围。"})
                break
            if not line:
                break
            request_id = None
            try:
                request = json.loads(line)
                if not isinstance(request, dict) or not isinstance(request.get("id"), (str, int)):
                    raise UserError("USB 请求格式无效。")
                request_id = request["id"]

                async def progress(message, visited):
                    emit({"id": request_id, "event": "progress", "message": message, "visitedFiles": visited})

                timeout = 600 if request.get("command") == "scan" else 60
                result = await asyncio.wait_for(server.handle(request, progress), timeout)
                emit({"id": request_id, "ok": True, "result": result})
                if request.get("command") == "shutdown":
                    break
            except Exception as exc:
                await server.close()
                emit({"id": request_id, "ok": False, "error": public_error(exc)})
    finally:
        await server.close()


if __name__ == "__main__":
    try:
        asyncio.run(serve())
    except (KeyboardInterrupt, asyncio.CancelledError, BrokenPipeError):
        pass
    except Exception:
        # Do not let tracebacks reveal identifiers, paths, or transport payloads.
        with contextlib.suppress(Exception):
            sys.stdout.write(json.dumps({"id": None, "ok": False, "error": "USB 组件意外结束，连接已释放，请重新扫描。"}, ensure_ascii=False) + "\n")
            sys.stdout.flush()

"""Synthetic database/transport tests. No Apple device services are imported."""

import asyncio
import base64
import datetime as dt
import importlib.util
import io
import json
from pathlib import Path
import sqlite3
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, patch
import uuid

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("iphone_usb_helper", ROOT / "scripts/iphone_usb_helper.py")
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)


def cocoa(text):
    return (dt.datetime.fromisoformat(text).astimezone(dt.timezone.utc) - helper.COCOA_EPOCH).total_seconds()


class Fixture:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.leo = sqlite3.connect(self.directory / "leo.sqlite")
        self.photos = sqlite3.connect(self.directory / "Photos.sqlite")
        self.leo.executescript("CREATE TABLE lexicon(lexeme_id INTEGER,type INTEGER,category INTEGER,content TEXT); CREATE TABLE items(identifier TEXT,type INTEGER,lexeme_ids BLOB); INSERT INTO lexicon VALUES(7,1,8170,'由我拍摄'),(8,1,5060,'实况照片');")
        self.photos.execute("CREATE TABLE ZASSET(Z_PK INTEGER PRIMARY KEY,ZUUID TEXT,ZKIND INTEGER,ZKINDSUBTYPE INTEGER,ZDATECREATED REAL,ZDIRECTORY TEXT,ZFILENAME TEXT,ZLATITUDE REAL,ZLONGITUDE REAL,ZHIDDEN INTEGER,ZTRASHEDSTATE INTEGER)")
        self.photos.execute("CREATE TABLE ZINTERNALRESOURCE(ZASSET INTEGER,ZRESOURCETYPE INTEGER,ZDATASTOREKEY TEXT,ZDATASTORESUBTYPE INTEGER,ZDATASTORECLASSID INTEGER,ZVERSION INTEGER,ZRECIPEID INTEGER,ZLOCALAVAILABILITY INTEGER,ZDATALENGTH INTEGER)")
        self.number = 0

    def add(self, name="IMG_0001.HEIC", date="2026-10-13T12:00:00+08:00", kind=0, subtype=0, mine=True, live=False, lat=31.2, lon=121.5, hidden=0, trash=0, directory="DCIM/100APPLE"):
        self.number += 1
        identifier = str(uuid.uuid4()).upper()
        ids = ([7] if mine else []) + ([8] if live else [])
        self.leo.execute("INSERT INTO items VALUES(?,1,?)", (identifier, struct.pack("<" + "I" * len(ids), *ids)))
        self.photos.execute("INSERT INTO ZASSET VALUES(?,?,?,?,?,?,?,?,?,?,?)", (self.number, identifier, kind, subtype, cocoa(date), directory, name, lat, lon, hidden, trash))
        self.commit()
        return identifier

    def live_pair(self, name="IMG_0001.HEIC", movie="DIFFERENT.MOV"):
        identifier = self.add(name=name, subtype=2, live=True)
        self.photos.executemany("INSERT INTO ZINTERNALRESOURCE VALUES(?,?,?,?,?,?,?,?,?)", [(self.number, 0, "DCIM/100APPLE/" + name, 1, 0, 0, 0, 1, 5), (self.number, 3, "DCIM/100APPLE/" + movie, 1, 0, 0, 0, 1, 7)])
        self.commit()
        return identifier

    def binary_live_pair(self, name="IMG_0001.HEIC"):
        columns = {row[1] for row in self.photos.execute("PRAGMA table_info(ZINTERNALRESOURCE)")}
        if "ZDATASTOREKEYDATA" not in columns:
            self.photos.execute("DROP TABLE ZINTERNALRESOURCE")
            self.photos.execute("CREATE TABLE ZINTERNALRESOURCE(ZASSET INTEGER,ZRESOURCETYPE INTEGER,ZDATASTOREKEYDATA BLOB,ZDATASTORESUBTYPE INTEGER,ZDATASTORECLASSID INTEGER,ZVERSION INTEGER,ZRECIPEID INTEGER,ZLOCALAVAILABILITY INTEGER,ZDATALENGTH INTEGER,ZCOMPACTUTI TEXT,ZTRASHEDSTATE INTEGER,ZPTPTRASHEDSTATE INTEGER)")
        identifier = self.add(name=name, subtype=2, live=True)
        self.photos.executemany("INSERT INTO ZINTERNALRESOURCE VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", [(self.number, 0, bytes.fromhex("03000000c001"), 1, 0, 0, 0, 1, 5, "3", 0, 0), (self.number, 3, bytes.fromhex("03300000c00b"), 18, 0, 0, 0, 1, 7, "23", 0, 0)])
        self.commit()
        return identifier

    def commit(self):
        self.leo.commit()
        self.photos.commit()

    def parse(self, start="2026-10-13", end="2026-10-15", timezone="Asia/Shanghai"):
        return helper.parse_catalog(self.directory / "leo.sqlite", self.directory / "Photos.sqlite", start, end, timezone)

    def close(self):
        self.leo.close()
        self.photos.close()


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.fixture = Fixture(self.temp.name)

    def tearDown(self):
        self.fixture.close()
        self.temp.cleanup()

    def test_date_selection_is_inclusive_in_requested_timezone(self):
        self.fixture.add(date="2026-10-12T23:59:59+08:00")
        first = self.fixture.add(date="2026-10-13T00:00:00+08:00")
        last = self.fixture.add(date="2026-10-15T23:59:59+08:00")
        self.fixture.add(date="2026-10-16T00:00:00+08:00")
        result = self.fixture.parse()
        self.assertEqual([c["asset"]["id"] for c in result["candidates"]], [first, last])
        self.assertEqual(result["outsideRangeCount"], 2)

    def test_daylight_saving_uses_calendar_midnights(self):
        start, end, _ = helper.date_bounds("2026-03-08", "2026-03-08", "America/New_York")
        self.assertEqual(end - start, 23 * 3600)

    def test_unconfirmed_is_not_declared_not_mine(self):
        self.fixture.add(mine=False)
        result = self.fixture.parse()
        self.assertEqual(result["candidates"], [])
        self.assertEqual(result["ignoredCount"], 0)
        self.assertIn("不代表", result["issues"][0]["message"])
        self.assertFalse(result["issues"][0]["isBlocking"])

    def test_hidden_and_deleted_are_excluded(self):
        self.fixture.add(hidden=1)
        self.fixture.add(trash=1)
        result = self.fixture.parse()
        self.assertEqual(result["candidates"], [])
        self.assertEqual(result["ignoredCount"], 2)

    def test_invalid_location_becomes_unknown(self):
        self.fixture.add(lat=999, lon=999)
        asset = self.fixture.parse()["candidates"][0]["asset"]
        self.assertNotIn("latitude", asset)
        self.assertNotIn("longitude", asset)

    def test_malformed_index_fails_closed(self):
        self.fixture.add()
        self.fixture.leo.execute("UPDATE items SET lexeme_ids=?", (b"\0",))
        self.fixture.commit()
        with self.assertRaises(helper.UserError):
            self.fixture.parse()

    def test_duplicate_index_fails_closed(self):
        self.fixture.add()
        self.fixture.leo.execute("INSERT INTO items SELECT * FROM items")
        self.fixture.commit()
        with self.assertRaises(helper.UserError):
            self.fixture.parse()

    def test_missing_classification_fails_closed(self):
        self.fixture.leo.execute("DELETE FROM lexicon WHERE category=8170")
        self.fixture.commit()
        with self.assertRaises(helper.UserError):
            self.fixture.parse()

    def test_empty_live_search_placeholder_does_not_invalidate_captured_by_me(self):
        identifier = self.fixture.add()
        self.fixture.leo.execute("INSERT INTO lexicon VALUES(9,1,5060,'')")
        self.fixture.commit()
        result = self.fixture.parse()
        self.assertEqual(result["candidates"][0]["asset"]["id"], identifier)
        self.assertEqual(result["issues"], [])

    def test_empty_captured_by_me_term_still_fails_closed(self):
        self.fixture.add()
        self.fixture.leo.execute("UPDATE lexicon SET content='' WHERE category=8170")
        self.fixture.commit()
        with self.assertRaises(helper.UserError):
            self.fixture.parse()

    def test_cross_database_mismatch_fails_closed(self):
        self.fixture.add()
        self.fixture.photos.execute("DELETE FROM ZASSET")
        self.fixture.commit()
        with self.assertRaises(helper.UserError):
            self.fixture.parse()

    def test_missing_capture_date_does_not_use_mtime(self):
        self.fixture.add()
        self.fixture.photos.execute("UPDATE ZASSET SET ZDATECREATED=NULL")
        self.fixture.commit()
        with self.assertRaises(helper.UserError):
            self.fixture.parse()

    def test_unsupported_schema_fails_closed(self):
        self.fixture.photos.execute("ALTER TABLE ZASSET RENAME COLUMN ZKINDSUBTYPE TO UNKNOWN")
        self.fixture.commit()
        with self.assertRaises(helper.UserError):
            self.fixture.parse()

    def test_live_photo_without_explicit_resources_remains_visible_and_blocked(self):
        identifier = self.fixture.add(subtype=2)
        result = self.fixture.parse()
        self.assertEqual(result["candidates"][0]["paths"], [])
        self.assertEqual(result["issues"][0]["assetID"], identifier)
        self.assertTrue(result["issues"][0]["isBlocking"])

    def test_explicit_live_resource_link_does_not_require_same_basename(self):
        self.fixture.live_pair(movie="RESOURCE_VIDEO.MOV")
        result = self.fixture.parse()
        self.assertEqual(result["issues"], [])
        self.assertEqual(result["candidates"][0]["paths"], ["/DCIM/100APPLE/IMG_0001.HEIC", "/DCIM/100APPLE/RESOURCE_VIDEO.MOV"])

    def test_other_asset_video_never_used_as_companion(self):
        self.fixture.live_pair()
        self.fixture.photos.execute("UPDATE ZINTERNALRESOURCE SET ZASSET=999 WHERE ZRESOURCETYPE=3")
        self.fixture.commit()
        self.assertEqual(self.fixture.parse()["candidates"][0]["paths"], [])

    def test_unconfirmed_text_key_video_subtype_is_blocked(self):
        self.fixture.live_pair()
        self.fixture.photos.execute("UPDATE ZINTERNALRESOURCE SET ZDATASTORESUBTYPE=18 WHERE ZRESOURCETYPE=3")
        self.fixture.commit()
        self.assertTrue(self.fixture.parse()["issues"][0]["isBlocking"])

    def test_missing_local_live_resource_blocks_whole_asset(self):
        self.fixture.live_pair()
        self.fixture.photos.execute("UPDATE ZINTERNALRESOURCE SET ZLOCALAVAILABILITY=-1 WHERE ZRESOURCETYPE=3")
        self.fixture.commit()
        self.assertEqual(self.fixture.parse()["candidates"][0]["paths"], [])

    def test_exact_binary_keys_return_candidates_with_both_database_lengths(self):
        self.fixture.binary_live_pair()
        result = self.fixture.parse()
        self.assertEqual(result["issues"], [])
        self.assertEqual(result["candidates"][0]["paths"], ["/DCIM/100APPLE/IMG_0001.HEIC", "/DCIM/100APPLE/IMG_0001.MOV"])
        self.assertEqual(result["candidates"][0]["expectedSizes"], {"/DCIM/100APPLE/IMG_0001.HEIC": 5, "/DCIM/100APPLE/IMG_0001.MOV": 7})

    def test_binary_live_originals_ignore_derivatives_and_adjustment_sidecars(self):
        self.fixture.binary_live_pair()
        self.fixture.photos.executemany("INSERT INTO ZINTERNALRESOURCE VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", [(1, 0, bytes.fromhex("0300c20c5001"), 4, 0, 0, 65741, 1, 3, "2", 0, 0), (1, 3, bytes.fromhex("0330a40cd00b"), 6, 0, 0, 131275, 1, 3, "23", 0, 0), (1, 5, bytes.fromhex("03500000c012"), 22, 0, 0, 0, 1, 1024, "37", 0, 0)])
        self.fixture.commit()
        result = self.fixture.parse()
        self.assertEqual(result["issues"], [])
        self.assertEqual(len(result["candidates"][0]["paths"]), 2)

    def test_binary_live_duplicate_or_conflicting_original_role_blocks_whole_asset(self):
        identifier = self.fixture.binary_live_pair()
        self.fixture.photos.execute("INSERT INTO ZINTERNALRESOURCE SELECT * FROM ZINTERNALRESOURCE WHERE ZRESOURCETYPE=3")
        self.fixture.commit()
        result = self.fixture.parse()
        self.assertEqual(result["candidates"][0]["paths"], [])
        self.assertEqual(result["issues"][0]["assetID"], identifier)
        self.assertTrue(result["issues"][0]["isBlocking"])

    def test_binary_live_missing_or_wrong_foreign_key_cannot_supply_companion(self):
        self.fixture.binary_live_pair()
        self.fixture.photos.execute("UPDATE ZINTERNALRESOURCE SET ZASSET=999 WHERE ZRESOURCETYPE=3")
        self.fixture.commit()
        self.assertEqual(self.fixture.parse()["candidates"][0]["paths"], [])

    def test_binary_live_unknown_key_and_mismatched_flags_fail_closed(self):
        self.fixture.binary_live_pair()
        mutations = [
            ("ZDATASTOREKEYDATA", bytes.fromhex("03300000c00a")),
            ("ZDATASTOREKEYDATA", bytes.fromhex("03300000c00b00")),
            ("ZDATASTOREKEYDATA", "03300000c00b"),
            ("ZDATASTOREKEYDATA", None),
            ("ZDATASTORESUBTYPE", 1), ("ZDATASTORECLASSID", 1),
            ("ZVERSION", 1), ("ZRECIPEID", 1), ("ZLOCALAVAILABILITY", -1),
            ("ZCOMPACTUTI", "3"), ("ZTRASHEDSTATE", 1), ("ZPTPTRASHEDSTATE", 1),
            ("ZTRASHEDSTATE", None), ("ZPTPTRASHEDSTATE", None),
            ("ZDATALENGTH", 0), ("ZDATALENGTH", -1),
        ]
        for column, value in mutations:
            with self.subTest(column=column, value=value):
                baseline = self.fixture.photos.execute(f"SELECT {column} FROM ZINTERNALRESOURCE WHERE ZRESOURCETYPE=3").fetchone()[0]
                self.fixture.photos.execute(f"UPDATE ZINTERNALRESOURCE SET {column}=? WHERE ZRESOURCETYPE=3", (value,))
                self.fixture.commit()
                result = self.fixture.parse()
                self.assertEqual(result["candidates"][0]["paths"], [])
                self.assertTrue(result["issues"][0]["isBlocking"])
                self.fixture.photos.execute(f"UPDATE ZINTERNALRESOURCE SET {column}=? WHERE ZRESOURCETYPE=3", (baseline,))
                self.fixture.commit()

    def test_binary_live_requires_uppercase_heic_primary_and_trash_schema(self):
        self.fixture.binary_live_pair(name="IMG_0001.heic")
        self.assertEqual(self.fixture.parse()["candidates"][0]["paths"], [])
        self.fixture.photos.execute("UPDATE ZASSET SET ZFILENAME='IMG_0001.HEIC'")
        self.fixture.photos.execute("ALTER TABLE ZINTERNALRESOURCE RENAME COLUMN ZPTPTRASHEDSTATE TO UNKNOWN")
        self.fixture.commit()
        self.assertEqual(self.fixture.parse()["candidates"][0]["paths"], [])

    def test_binary_live_conflicting_path_representations_fail_closed(self):
        self.fixture.binary_live_pair()
        self.fixture.photos.execute("ALTER TABLE ZINTERNALRESOURCE ADD COLUMN ZDATASTOREKEY TEXT")
        self.fixture.photos.execute("UPDATE ZINTERNALRESOURCE SET ZDATASTOREKEY='DCIM/100APPLE/OTHER.MOV' WHERE ZRESOURCETYPE=3")
        self.fixture.commit()
        self.assertEqual(self.fixture.parse()["candidates"][0]["paths"], [])

    def test_snapshot_reader_honors_wal(self):
        self.fixture.leo.execute("PRAGMA journal_mode=WAL")
        self.fixture.photos.execute("PRAGMA journal_mode=WAL")
        identifier = self.fixture.add()
        result = self.fixture.parse()
        self.assertEqual(result["candidates"][0]["asset"]["id"], identifier)


class PathTests(unittest.TestCase):
    def test_rejects_escaping_paths(self):
        for path in ["/DCIM/../PhotoData/Photos.sqlite", "/DCIM//IMG.JPG", "/DCIM/100APPLE/../IMG.JPG", "/DCIM/100APPLE/IMG\0.JPG", "/DCIM/100APPLE\\x/IMG.JPG", "DCIM/100APPLE/IMG.JPG", "/PhotoData/Photos.sqlite"]:
            with self.subTest(path=path), self.assertRaises(helper.UserError):
                helper.safe_path(path)

    def test_rejects_symlink_stat(self):
        with self.assertRaises(helper.UserError):
            helper.fingerprint({"st_ifmt": "S_IFLNK", "st_size": 12, "st_mtime": 0})

    def test_errors_do_not_expose_raw_exception_details(self):
        self.assertNotIn("SECRET", helper.public_error(RuntimeError("SECRET /personal/path")))


class FakeMissing(Exception):
    pass


class FakeSession:
    def __init__(self, device_id, files=None):
        self.device_id = device_id
        self.files = files or {}
        self.afc = self
        self.missing_exception = FakeMissing
        self.name = "Test iPhone"
        self.mux_id = 42
        self.reads = []
        self.stats = []
        self.closed = False
        self.handles = {}
        self.opened = self.closed_handles = 0
        self.changed = False

    async def open(self):
        return self

    async def close(self):
        self.closed = True

    async def connected(self):
        if self.changed:
            raise helper.UserError("设备已断开")

    async def stat(self, path, metadata=False):
        self.stats.append(path)
        if path not in self.files:
            raise FakeMissing()
        return {"st_ifmt": "S_IFREG", "st_size": len(self.files[path]), "st_mtime": 1}

    async def fopen(self, path, mode):
        assert mode == "r"
        self.opened += 1
        self.handles[self.opened] = [path, 0]
        return self.opened

    async def fread(self, handle, length):
        path, offset = self.handles[handle]
        self.reads.append(path)
        self.handles[handle][1] += length
        return self.files[path][offset:offset + length]

    async def fclose(self, handle):
        self.closed_handles += 1
        del self.handles[handle]

    async def read_bytes(self, path, offset, length):
        self.reads.append(path)
        return self.files[path][offset:offset + length]


async def progress(*args):
    pass


def manifest(files, groups=None):
    return {"deviceID": "TEST1234", "muxID": 41, "files": files, "metadata": {}, "groups": groups or {key: {key} for key in files}, "prepared": False, "selected": set()}


class TransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_stable_metadata_double_read_and_handles_closed(self):
        session = FakeSession("TEST1234", {path: b"metadata" for path in helper.METADATA_PATHS})
        with tempfile.TemporaryDirectory() as directory:
            await helper.snapshot(session, Path(directory), progress)
        self.assertEqual(session.opened, 8)
        self.assertEqual(session.closed_handles, 8)
        self.assertFalse(any(path.startswith("/DCIM") for path in session.reads))

    async def test_changed_snapshot_is_rejected(self):
        session = FakeSession("TEST1234", {path: b"metadata" for path in helper.METADATA_PATHS})
        original = session.fread

        async def changing(handle, length):
            result = await original(handle, length)
            if session.opened == 5:
                return b"changed!"
            return result

        session.fread = changing
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(helper.UserError):
            await helper.snapshot(session, Path(directory), progress)
        self.assertEqual(session.opened, session.closed_handles)

    async def test_scan_only_stats_selected_original_and_reads_no_media(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            fixture.add(name="IN.HEIC")
            fixture.add(name="OUT.HEIC", date="2026-10-12T12:00:00+08:00")
            fixture.close()
            files = {"/PhotoData/Caches/search/leo.sqlite": (Path(directory) / "leo.sqlite").read_bytes(), "/PhotoData/Photos.sqlite": (Path(directory) / "Photos.sqlite").read_bytes(), "/DCIM/100APPLE/IN.HEIC": b"image"}
        session = FakeSession("TEST1234", files)
        server = helper.Server(lambda _: session)
        result = await server.handle({"command": "scan", "deviceID": "TEST1234", "start": "2026-10-13", "end": "2026-10-15", "timeZoneIdentifier": "Asia/Shanghai"}, progress)
        self.assertEqual(len(result["items"]), 1)
        self.assertEqual(result["outsideRangeCount"], 1)
        self.assertNotIn("/DCIM/100APPLE/OUT.HEIC", session.stats)
        self.assertFalse(any(path.startswith("/DCIM") for path in session.reads))
        self.assertTrue(session.closed)

    async def test_read_only_manifest_file_and_offset(self):
        session = FakeSession("TEST1234", {"/DCIM/100APPLE/IN.HEIC": b"0123456789"})
        server = helper.Server(lambda _: session)
        server.manifests["token"] = manifest({"item": {"path": "/DCIM/100APPLE/IN.HEIC", "fingerprint": (10, "1", "")}})
        await server.handle({"command": "prepare", "token": "token", "itemIDs": ["item"]}, progress)
        result = await server.handle({"command": "read", "token": "token", "itemID": "item", "offset": 2, "length": 3}, progress)
        self.assertEqual(base64.b64decode(result["data"]), b"234")
        await server.handle({"command": "end", "token": "token"}, progress)
        self.assertTrue(session.closed)
        self.assertEqual(server.manifests, {})

    async def test_scan_live_photo_outputs_atomic_companion_group(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            fixture.live_pair()
            fixture.close()
            files = {"/PhotoData/Caches/search/leo.sqlite": (Path(directory) / "leo.sqlite").read_bytes(), "/PhotoData/Photos.sqlite": (Path(directory) / "Photos.sqlite").read_bytes(), "/DCIM/100APPLE/IMG_0001.HEIC": b"image", "/DCIM/100APPLE/DIFFERENT.MOV": b"movie!!"}
        session = FakeSession("TEST1234", files)
        server = helper.Server(lambda _: session)
        result = await server.handle({"command": "scan", "deviceID": "TEST1234", "start": "2026-10-13", "end": "2026-10-15", "timeZoneIdentifier": "Asia/Shanghai"}, progress)
        self.assertEqual({item["kind"] for item in result["items"]}, {"photo", "video"})
        ids = set(result["assets"][0]["fileIDs"])
        for item in result["items"]:
            self.assertEqual(set(item["companionIDs"]), ids - {item["id"]})
        self.assertEqual(result["issues"], [])

    async def test_binary_live_scan_checks_both_lengths_without_reading_originals(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            identifier = fixture.binary_live_pair()
            fixture.close()
            metadata = {"/PhotoData/Caches/search/leo.sqlite": (Path(directory) / "leo.sqlite").read_bytes(), "/PhotoData/Photos.sqlite": (Path(directory) / "Photos.sqlite").read_bytes()}
        for photo, video, accepted in [(b"image", b"movie!!", True), (b"wrongsize", b"movie!!", False), (b"image", b"short", False), (b"image", None, False)]:
            with self.subTest(photo_size=len(photo), video_size=len(video) if video else None):
                files = {**metadata, "/DCIM/100APPLE/IMG_0001.HEIC": photo}
                if video is not None:
                    files["/DCIM/100APPLE/IMG_0001.MOV"] = video
                session = FakeSession("TEST1234", files)
                server = helper.Server(lambda _: session)
                result = await server.handle({"command": "scan", "deviceID": "TEST1234", "start": "2026-10-13", "end": "2026-10-15", "timeZoneIdentifier": "Asia/Shanghai"}, progress)
                self.assertFalse(any(path.startswith("/DCIM") for path in session.reads))
                self.assertTrue(session.closed)
                self.assertEqual(len(result["items"]), 2 if accepted else 0)
                self.assertEqual(len(result["assets"][0]["fileIDs"]), 2 if accepted else 0)
                if accepted:
                    self.assertEqual(result["issues"], [])
                    ids = set(result["assets"][0]["fileIDs"])
                    for item in result["items"]:
                        self.assertEqual(set(item["companionIDs"]), ids - {item["id"]})
                else:
                    self.assertEqual(result["issues"][0]["assetID"], identifier)
                    self.assertTrue(result["issues"][0]["isBlocking"])

    async def test_scan_missing_live_video_excludes_both_files_keeps_asset_issue(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            identifier = fixture.live_pair()
            fixture.close()
            files = {"/PhotoData/Caches/search/leo.sqlite": (Path(directory) / "leo.sqlite").read_bytes(), "/PhotoData/Photos.sqlite": (Path(directory) / "Photos.sqlite").read_bytes(), "/DCIM/100APPLE/IMG_0001.HEIC": b"image"}
        session = FakeSession("TEST1234", files)
        server = helper.Server(lambda _: session)
        result = await server.handle({"command": "scan", "deviceID": "TEST1234", "start": "2026-10-13", "end": "2026-10-15", "timeZoneIdentifier": "Asia/Shanghai"}, progress)
        self.assertEqual(result["items"], [])
        self.assertEqual(result["assets"][0]["fileIDs"], [])
        self.assertEqual(result["issues"][0]["assetID"], identifier)

    async def test_unknown_item_never_reads(self):
        session = FakeSession("TEST1234")
        server = helper.Server(lambda _: session)
        server.manifests["token"] = manifest({})
        with self.assertRaises(helper.UserError):
            await server.handle({"command": "read", "token": "token", "itemID": "/PhotoData/Photos.sqlite", "offset": 0, "length": 1}, progress)
        self.assertEqual(session.reads, [])
        self.assertIsNone(server.session)

    async def test_disconnect_invalidates_manifest(self):
        session = FakeSession("TEST1234")
        session.changed = True
        server = helper.Server(lambda _: session)
        server.manifests["token"] = manifest({"item": {"path": "/DCIM/100APPLE/IN.HEIC", "fingerprint": (10, "1", "")}})
        with self.assertRaises(helper.UserError):
            await server.handle({"command": "prepare", "token": "token", "itemIDs": ["item"]}, progress)
        self.assertNotIn("token", server.manifests)

    async def test_prepare_allows_reconnect_and_only_stats_selected_files(self):
        session = FakeSession("TEST1234", {"/DCIM/100APPLE/IN.HEIC": b"image"})
        server = helper.Server(lambda _: session)
        server.manifests["token"] = manifest({"item": {"path": "/DCIM/100APPLE/IN.HEIC", "fingerprint": (5, "1", "")}, "unselected": {"path": "/DCIM/100APPLE/OTHER.HEIC", "fingerprint": (9, "1", "")}})
        await server.handle({"command": "prepare", "token": "token", "itemIDs": ["item"]}, progress)
        self.assertEqual(server.manifests["token"]["muxID"], 42)
        self.assertNotIn("/DCIM/100APPLE/OTHER.HEIC", session.stats)
        session.stats.clear()
        await server.handle({"command": "validate", "token": "token"}, progress)
        self.assertEqual(session.stats, ["/DCIM/100APPLE/IN.HEIC"])
        await server.close()
        with self.assertRaises(helper.UserError):
            await server.handle({"command": "read", "token": "token", "itemID": "item", "offset": 0, "length": 1}, progress)

    async def test_prepare_rejects_metadata_changes(self):
        path = helper.METADATA_PATHS[0]
        session = FakeSession("TEST1234", {path: b"newmetadata"})
        server = helper.Server(lambda _: session)
        saved = manifest({"item": {"path": "/DCIM/100APPLE/IN.HEIC", "fingerprint": (5, "1", "")}})
        saved["metadata"] = {path: (2, "1", "")}
        server.manifests["token"] = saved
        with self.assertRaises(helper.UserError):
            await server.handle({"command": "prepare", "token": "token", "itemIDs": ["item"]}, progress)
        self.assertNotIn("token", server.manifests)
        self.assertTrue(session.closed)

    async def test_partial_live_group_cannot_be_prepared(self):
        for mode in ({}, {"livePhotoImportMode": "complete"}):
            with self.subTest(mode=mode):
                factory = AsyncMock()
                server = helper.Server(factory)
                server.manifests["token"] = manifest({"photo": {"kind": "photo"}, "video": {"kind": "video"}}, {"asset": {"photo", "video"}})
                with self.assertRaises(helper.UserError):
                    await server.handle({"command": "prepare", "token": "token", "itemIDs": ["photo"], **mode}, progress)
                factory.assert_not_called()

    async def test_complete_mode_prepares_and_reads_both_live_components(self):
        files = {"/DCIM/100APPLE/PHOTO.HEIC": b"image", "/DCIM/100APPLE/MOTION.MOV": b"movie!!"}
        entries = {"photo": {"kind": "photo", "path": "/DCIM/100APPLE/PHOTO.HEIC", "fingerprint": (5, "1", "")},
                   "video": {"kind": "video", "path": "/DCIM/100APPLE/MOTION.MOV", "fingerprint": (7, "1", "")}}
        for mode in ({}, {"livePhotoImportMode": "complete"}):
            with self.subTest(mode=mode):
                session = FakeSession("TEST1234", files)
                server = helper.Server(lambda _: session)
                server.manifests["token"] = manifest(entries, {"asset": {"photo", "video"}})
                await server.handle({"command": "prepare", "token": "token", "itemIDs": ["photo", "video"], **mode}, progress)
                self.assertEqual(server.manifests["token"]["livePhotoImportMode"], "complete")
                for item_id, entry in entries.items():
                    result = await server.handle({"command": "read", "token": "token", "itemID": item_id, "offset": 0, "length": 100}, progress)
                    self.assertEqual(base64.b64decode(result["data"]), files[entry["path"]])
                await server.handle({"command": "end", "token": "token"}, progress)

    async def test_still_only_from_scan_reads_photo_and_standalone_video_without_live_movie(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            fixture.live_pair(name="PHOTO.HEIC", movie="MOTION.MOV")
            fixture.add(name="STANDALONE.MOV", kind=1)
            fixture.add(name="ORDINARY.HEIC")
            fixture.close()
            files = {"/PhotoData/Caches/search/leo.sqlite": (Path(directory) / "leo.sqlite").read_bytes(),
                     "/PhotoData/Photos.sqlite": (Path(directory) / "Photos.sqlite").read_bytes(),
                     "/DCIM/100APPLE/PHOTO.HEIC": b"image", "/DCIM/100APPLE/MOTION.MOV": b"movie!!",
                     "/DCIM/100APPLE/STANDALONE.MOV": b"independent video", "/DCIM/100APPLE/ORDINARY.HEIC": b"ordinary photo"}
        session = FakeSession("TEST1234", files)
        server = helper.Server(lambda _: session)
        result = await server.handle({"command": "scan", "deviceID": "TEST1234", "start": "2026-10-13", "end": "2026-10-15", "timeZoneIdentifier": "Asia/Shanghai"}, progress)
        self.assertFalse(any(path.startswith("/DCIM") for path in session.reads))
        by_name = {item["name"]: item for item in result["items"]}
        self.assertEqual(by_name["PHOTO.HEIC"]["companionIDs"], [by_name["MOTION.MOV"]["id"]])
        selected = [by_name[name]["id"] for name in ("PHOTO.HEIC", "STANDALONE.MOV", "ORDINARY.HEIC")]
        session.stats.clear()
        session.reads.clear()
        await server.handle({"command": "prepare", "token": result["token"], "itemIDs": selected, "livePhotoImportMode": "stillOnly"}, progress)
        self.assertNotIn("/DCIM/100APPLE/MOTION.MOV", session.stats)
        for name in ("PHOTO.HEIC", "STANDALONE.MOV", "ORDINARY.HEIC"):
            copied = await server.handle({"command": "read", "token": result["token"], "itemID": by_name[name]["id"], "offset": 0, "length": 100}, progress)
            self.assertEqual(base64.b64decode(copied["data"]), files["/DCIM/100APPLE/" + name])
        with self.assertRaises(helper.UserError):
            await server.handle({"command": "read", "token": result["token"], "itemID": by_name["MOTION.MOV"]["id"], "offset": 0, "length": 100}, progress)
        self.assertNotIn("/DCIM/100APPLE/MOTION.MOV", session.stats)
        self.assertNotIn("/DCIM/100APPLE/MOTION.MOV", session.reads)
        self.assertEqual(set(session.reads), {"/DCIM/100APPLE/PHOTO.HEIC", "/DCIM/100APPLE/STANDALONE.MOV", "/DCIM/100APPLE/ORDINARY.HEIC"})
        self.assertTrue(session.closed)

    async def test_still_only_rejects_live_movie_alone_or_complete_pair(self):
        for selected in (["video"], ["photo", "video"]):
            with self.subTest(selected=selected):
                factory = AsyncMock()
                server = helper.Server(factory)
                server.manifests["token"] = manifest({"photo": {"kind": "photo"}, "video": {"kind": "video"}}, {"asset": {"photo", "video"}})
                with self.assertRaises(helper.UserError):
                    await server.handle({"command": "prepare", "token": "token", "itemIDs": selected, "livePhotoImportMode": "stillOnly"}, progress)
                factory.assert_not_called()

    async def test_still_only_rejects_unconfirmed_group_roles(self):
        for entries in ({"photo": {"kind": "photo"}, "video": {}},
                        {"photo": {"kind": "photo"}, "video": {"kind": "photo"}},
                        {"photo": {"kind": "photo"}, "video": {"kind": "video"}, "extra": {"kind": "video"}}):
            with self.subTest(entries=entries):
                factory = AsyncMock()
                server = helper.Server(factory)
                server.manifests["token"] = manifest(entries, {"asset": set(entries)})
                with self.assertRaises(helper.UserError):
                    await server.handle({"command": "prepare", "token": "token", "itemIDs": ["photo"], "livePhotoImportMode": "stillOnly"}, progress)
                factory.assert_not_called()

    async def test_unknown_or_malformed_live_mode_is_rejected_before_opening_usb(self):
        for mode in (None, "", "Complete", "photoOnly", "stillOnly ", 0, True, [], {}):
            with self.subTest(mode=mode):
                factory = AsyncMock()
                server = helper.Server(factory)
                server.manifests["token"] = manifest({"photo": {"kind": "photo"}})
                with self.assertRaisesRegex(helper.UserError, "实况照片导入方式无效"):
                    await server.handle({"command": "prepare", "token": "token", "itemIDs": ["photo"], "livePhotoImportMode": mode}, progress)
                factory.assert_not_called()

    async def test_read_without_prepare_never_opens_connection(self):
        factory = AsyncMock()
        server = helper.Server(factory)
        server.manifests["token"] = manifest({"item": {}})
        with self.assertRaises(helper.UserError):
            await server.handle({"command": "read", "token": "token", "itemID": "item", "offset": 0, "length": 1}, progress)
        factory.assert_not_called()

    async def test_explicit_stop_session_precedes_close(self):
        calls = []
        session = helper.USBSession("TEST1234")
        class Phone:
            session_id = "session"
            async def stop_session(self):
                calls.append("stop")
            async def close(self):
                calls.append("close")
        session.phone = Phone()
        await session.close()
        self.assertEqual(calls, ["stop", "close"])


class ProtocolTests(unittest.TestCase):
    def test_prepare_larger_than_64_kib_keeps_protocol_alive(self):
        # An unknown token fails before any USB dependency is imported. Sending
        # shutdown afterwards proves the persistent JSON-lines server survived.
        request = {"id": "large-prepare", "command": "prepare", "token": "synthetic-missing-token",
                   "itemIDs": [format(index, "064x") for index in range(1000)]}
        line = json.dumps(request, separators=(",", ":")) + "\n"
        self.assertGreater(len(line.encode()), 65536)
        shutdown = json.dumps({"id": "shutdown", "command": "shutdown"}) + "\n"
        result = subprocess.run([sys.executable, str(ROOT / "scripts/iphone_usb_helper.py")],
                                input=line + shutdown, text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        responses = [json.loads(value) for value in result.stdout.splitlines()]
        self.assertEqual(len(responses), 2)
        self.assertEqual(responses[0]["id"], "large-prepare")
        self.assertFalse(responses[0]["ok"])
        self.assertIn("扫描结果已过期", responses[0]["error"])
        self.assertEqual(responses[1], {"id": "shutdown", "ok": True, "result": {}})


class ProtocolIdleTests(unittest.IsolatedAsyncioTestCase):
    async def test_local_verification_idle_keeps_prepared_session_until_shutdown(self):
        session = FakeSession("TEST1234")
        server = helper.Server(lambda _: session)
        saved = manifest({"item": {}})
        saved["prepared"] = True
        saved["selected"] = {"item"}
        server.manifests["token"] = saved
        server.session = session
        server.active_token = "token"
        reader = AsyncMock()
        reader.readline.return_value = b'{"id":"shutdown","command":"shutdown"}\n'
        idle_expired = False

        async def controlled_wait(awaitable, timeout):
            nonlocal idle_expired
            if timeout == 45 and not idle_expired:
                idle_expired = True
                awaitable.close()
                raise asyncio.TimeoutError()
            result = await awaitable
            if timeout == 45:
                # Check before shutdown is dispatched: time spent hashing the
                # local copy must not retire the prepared USB session.
                self.assertIs(server.session, session)
                self.assertEqual(server.active_token, "token")
                self.assertFalse(session.closed)
            return result

        loop = asyncio.get_running_loop()
        output = io.StringIO()
        with patch.object(helper, "Server", return_value=server), \
             patch.object(helper.asyncio, "StreamReader", return_value=reader), \
             patch.object(helper.asyncio, "wait_for", side_effect=controlled_wait), \
             patch.object(loop, "connect_read_pipe", new=AsyncMock()), \
             patch.object(loop, "add_signal_handler"), \
             patch.object(helper.logging, "disable"), \
             patch.object(helper.sys, "stdout", output), \
             patch.object(helper, "dependency", side_effect=AssertionError("No real device access")):
            await helper.serve()
        self.assertTrue(idle_expired)
        self.assertTrue(session.closed)
        self.assertIsNone(server.session)
        self.assertEqual(server.manifests, {})
        self.assertEqual(json.loads(output.getvalue()), {"id": "shutdown", "ok": True, "result": {}})


if __name__ == "__main__":
    unittest.main()

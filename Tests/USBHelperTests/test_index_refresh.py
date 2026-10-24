"""Semantic index refresh checks using real SQLite bytes and a fake transport.

These tests never load Apple device services or connect to a phone.
"""

import base64
import copy
from pathlib import Path
import sqlite3
import struct
import tempfile
import unittest
from unittest import mock

from test_iphone_usb_helper import Fixture, FakeSession, helper, progress


LEO, LEO_WAL, PHOTOS, PHOTOS_WAL = helper.METADATA_PATHS
STILL = "/DCIM/100APPLE/PHOTO.HEIC"
MOTION = "/DCIM/100APPLE/MOTION.MOV"
VIDEO = "/DCIM/100APPLE/STANDALONE.MOV"
OTHER = "/DCIM/100APPLE/OTHER.HEIC"


class MutableSession(FakeSession):
    """AFC-like immutable read results, with controllable stat generations."""

    def __init__(self):
        super().__init__("TEST1234")
        self.generations = {}
        self.births = {}
        self.stat_overrides = {}
        self.after_stat = None
        self.after_close = None

    async def open(self):
        self.closed = False
        return self

    def put(self, path, content, *, touch=False):
        if touch or self.files.get(path) != content:
            self.generations[path] = self.generations.get(path, 0) + 1
        self.files[path] = content
        self.births.setdefault(path, 1)

    def touch(self, path):
        self.put(path, self.files[path], touch=True)

    def publish(self, fixture):
        fixture.commit()
        for path in helper.METADATA_PATHS:
            local = fixture.directory / Path(path).name
            if local.exists():
                self.put(path, local.read_bytes())
            else:
                self.files.pop(path, None)

    async def stat(self, path, metadata=False):
        result = await super().stat(path, metadata=metadata)
        result.update(st_mtime=self.generations[path], st_birthtime=self.births[path])
        result.update(self.stat_overrides.get(path, {}))
        if self.after_stat:
            self.after_stat(path)
        return result

    async def fclose(self, handle):
        path = self.handles[handle][0]
        await super().fclose(handle)
        if self.after_close:
            self.after_close(path)


class IndexRefreshTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.fixture = Fixture(self.temporary.name)
        self.live = self.fixture.live_pair(name="PHOTO.HEIC", movie="MOTION.MOV")
        self.video = self.fixture.add(name="STANDALONE.MOV", kind=1)
        self.other = self.fixture.add(name="OTHER.HEIC")
        self.session = MutableSession()
        for path, data in ((STILL, b"image"), (MOTION, b"movie!!"),
                           (VIDEO, b"independent video"), (OTHER, b"other image")):
            self.session.put(path, data)
        self.session.publish(self.fixture)
        self.server = helper.Server(lambda _: self.session)

    async def asyncTearDown(self):
        await self.server.close()
        self.fixture.close()
        self.temporary.cleanup()

    async def scan(self):
        self.result = await self.server.handle({
            "command": "scan", "deviceID": "TEST1234", "start": "2026-10-13",
            "end": "2026-10-15", "timeZoneIdentifier": "Asia/Shanghai"
        }, progress)
        self.token = self.result["token"]
        self.by_name = {item["name"]: item for item in self.result["items"]}
        self.saved = self.server.manifests[self.token]
        self.baseline = copy.deepcopy(self.saved["metadata"])
        self.session.reads.clear()
        self.session.stats.clear()
        return self.result

    async def prepare(self, *, complete=False):
        names = ("PHOTO.HEIC", "MOTION.MOV", "STANDALONE.MOV") if complete else ("PHOTO.HEIC", "STANDALONE.MOV")
        return await self.server.handle({
            "command": "prepare", "token": self.token,
            "itemIDs": [self.by_name[name]["id"] for name in names],
            "livePhotoImportMode": "complete" if complete else "stillOnly"
        }, progress)

    async def validate(self):
        return await self.server.handle({"command": "validate", "token": self.token}, progress)

    async def read(self, name):
        response = await self.server.handle({
            "command": "read", "token": self.token, "itemID": self.by_name[name]["id"],
            "offset": 0, "length": 100
        }, progress)
        return base64.b64decode(response["data"])

    def changed(self):
        self.session.publish(self.fixture)
        # Some SQL no-ops can leave bytes unchanged; still exercise refresh.
        self.session.touch(PHOTOS)

    def assert_stopped_without_rebasing(self):
        self.assertEqual(self.saved["metadata"], self.baseline)
        self.assertNotIn(self.token, self.server.manifests)
        self.assertIsNone(self.server.session)
        self.assertTrue(self.session.closed)
        self.assertEqual(self.session.opened, self.session.closed_handles)

    async def test_unchanged_metadata_fast_path_does_not_reopen_index_contents(self):
        await self.scan()
        opened = self.session.opened
        await self.prepare()
        await self.validate()
        self.assertEqual(self.session.opened, opened)
        self.assertFalse(self.session.reads)
        self.assertEqual(self.saved["metadata"], self.baseline)

    async def test_unselected_asset_change_addition_and_deletion_allow_prepare(self):
        await self.scan()
        self.fixture.photos.execute("UPDATE ZASSET SET ZDATECREATED=ZDATECREATED+1,ZLATITUDE=40 WHERE ZUUID=?", (self.other,))
        added = self.fixture.add(name="NEW.HEIC")
        self.fixture.photos.execute("DELETE FROM ZASSET WHERE ZUUID=?", (self.other,))
        self.fixture.leo.execute("DELETE FROM items WHERE identifier=?", (self.other,))
        self.changed()
        await self.prepare()
        self.assertNotEqual(self.saved["metadata"], self.baseline)
        self.assertEqual(self.saved["selected"], {self.by_name[n]["id"] for n in ("PHOTO.HEIC", "STANDALONE.MOV")})
        self.assertNotIn("/DCIM/100APPLE/NEW.HEIC", self.session.stats)
        self.assertNotIn(OTHER, self.session.stats)
        self.assertFalse(any(p.startswith("/DCIM/") for p in self.session.reads))
        self.assertNotIn(added, {a["id"] for a in self.result["assets"]})

    async def test_unselected_inconsistent_join_does_not_invalidate_selected_records(self):
        await self.scan()
        # Only the unrelated record disappears; its search row temporarily lags.
        self.fixture.photos.execute("DELETE FROM ZASSET WHERE ZUUID=?", (self.other,))
        self.changed()
        await self.prepare()
        self.assertTrue(self.saved["prepared"])

    async def test_database_reorganization_before_prepare_preserves_unchanged_selection(self):
        await self.scan()
        self.fixture.photos.execute("VACUUM")
        self.changed()
        await self.prepare()
        self.assertNotEqual(self.saved["metadata"], self.baseline)
        self.assertEqual(await self.read("PHOTO.HEIC"), b"image")
        self.assertEqual(await self.read("STANDALONE.MOV"), b"independent video")
        self.assertNotIn(MOTION, self.session.reads)
        self.assertNotIn(MOTION, self.session.stats)

    async def test_lexeme_identifiers_can_be_renumbered_without_changing_membership(self):
        await self.scan()
        self.fixture.leo.execute("UPDATE lexicon SET lexeme_id=lexeme_id+100")
        rows = list(self.fixture.leo.execute("SELECT rowid,lexeme_ids FROM items"))
        for rowid, blob in rows:
            values = struct.unpack("<" + "I" * (len(blob) // 4), blob)
            rewritten = struct.pack("<" + "I" * len(values), *(value + 100 for value in values))
            self.fixture.leo.execute("UPDATE items SET lexeme_ids=? WHERE rowid=?", (rewritten, rowid))
        self.changed()
        await self.prepare()
        self.assertTrue(self.saved["prepared"])
        self.assertNotEqual(self.saved["metadata"], self.baseline)

    async def test_asset_primary_keys_can_change_when_resource_join_is_preserved(self):
        await self.scan()
        self.fixture.photos.execute("UPDATE ZASSET SET Z_PK=Z_PK+100")
        self.fixture.photos.execute("UPDATE ZINTERNALRESOURCE SET ZASSET=ZASSET+100")
        self.changed()
        await self.prepare()
        self.assertTrue(self.saved["prepared"])
        self.assertNotEqual(self.saved["metadata"], self.baseline)

    async def test_real_wal_updates_and_checkpoint_preserve_unchanged_selection(self):
        # SQLite emits a real WAL; a checkpoint removes its frames and moves the
        # unrelated change into the database without modifying chosen assets.
        self.fixture.photos.execute("PRAGMA journal_mode=WAL")
        self.fixture.photos.execute("UPDATE ZASSET SET ZLATITUDE=32 WHERE ZUUID=?", (self.other,))
        self.changed()
        self.assertIn(PHOTOS_WAL, self.session.files)
        await self.scan()
        self.fixture.photos.execute("UPDATE ZASSET SET ZLATITUDE=33 WHERE ZUUID=?", (self.other,))
        self.changed()
        await self.prepare()
        self.assertNotEqual(self.saved["metadata"], self.baseline)
        await self.scan()
        self.fixture.photos.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        self.changed()
        await self.prepare()
        self.assertNotEqual(self.saved["metadata"], self.baseline)
        self.assertEqual(await self.read("PHOTO.HEIC"), b"image")
        self.assertNotIn(MOTION, self.session.reads)

    async def test_selected_original_time_change_within_same_day_stops(self):
        await self.scan()
        self.fixture.photos.execute("UPDATE ZASSET SET ZDATECREATED=ZDATECREATED+1 WHERE ZUUID=?", (self.live,))
        self.changed()
        with self.assertRaises(helper.UserError):
            await self.prepare()
        self.assert_stopped_without_rebasing()
        self.assertFalse(any(p.startswith("/DCIM/") for p in self.session.reads))

    async def test_selected_coordinates_hidden_deleted_type_subtype_and_name_changes_stop(self):
        mutations = (("ZLATITUDE", 31.25), ("ZLONGITUDE", 121.55), ("ZHIDDEN", 1),
                     ("ZTRASHEDSTATE", 1), ("ZKIND", 1), ("ZKINDSUBTYPE", 0),
                     ("ZDIRECTORY", "DCIM/101APPLE"), ("ZFILENAME", "RENAMED.HEIC"))
        for field, value in mutations:
            with self.subTest(field=field):
                await self.scan()
                previous = self.fixture.photos.execute(f"SELECT {field} FROM ZASSET WHERE ZUUID=?", (self.live,)).fetchone()[0]
                self.fixture.photos.execute(f"UPDATE ZASSET SET {field}=? WHERE ZUUID=?", (value, self.live))
                self.changed()
                with self.assertRaises(helper.UserError):
                    await self.prepare()
                self.assert_stopped_without_rebasing()
                self.fixture.photos.execute(f"UPDATE ZASSET SET {field}=? WHERE ZUUID=?", (previous, self.live))
                self.changed()

    async def test_selected_classification_changes_stop_even_when_asset_subtype_stays_live(self):
        for ids in ([8], [7], []):
            with self.subTest(classification=ids):
                await self.scan()
                self.fixture.leo.execute("UPDATE items SET lexeme_ids=? WHERE identifier=?", (struct.pack("<" + "I" * len(ids), *ids), self.live))
                self.changed()
                with self.assertRaises(helper.UserError):
                    await self.prepare()
                self.assert_stopped_without_rebasing()
                self.fixture.leo.execute("UPDATE items SET lexeme_ids=? WHERE identifier=?", (struct.pack("<II", 7, 8), self.live))
                self.changed()

    async def test_missing_selected_record_and_duplicate_selected_identity_stop(self):
        await self.scan()
        original = self.fixture.photos.execute("SELECT * FROM ZASSET WHERE ZUUID=?", (self.live,)).fetchone()
        self.fixture.photos.execute("DELETE FROM ZASSET WHERE ZUUID=?", (self.live,))
        self.changed()
        with self.assertRaises(helper.UserError):
            await self.prepare()
        self.assert_stopped_without_rebasing()
        self.fixture.photos.execute("INSERT INTO ZASSET VALUES(?,?,?,?,?,?,?,?,?,?,?)", original)
        self.changed()
        await self.scan()
        duplicate = (999,) + original[1:]
        self.fixture.photos.execute("INSERT INTO ZASSET VALUES(?,?,?,?,?,?,?,?,?,?,?)", duplicate)
        self.changed()
        with self.assertRaises(helper.UserError):
            await self.prepare()
        self.assert_stopped_without_rebasing()

    async def test_selected_resource_version_availability_size_key_and_relation_changes_stop(self):
        mutations = (("ZVERSION", 1), ("ZRECIPEID", 1), ("ZLOCALAVAILABILITY", 0),
                     ("ZDATALENGTH", 8), ("ZDATASTOREKEY", "DCIM/100APPLE/OTHER.MOV"),
                     ("ZASSET", 999), ("ZRESOURCETYPE", 0), ("ZDATASTORECLASSID", 1))
        for field, value in mutations:
            with self.subTest(field=field):
                await self.scan()
                rowid, old = self.fixture.photos.execute(f"SELECT rowid,{field} FROM ZINTERNALRESOURCE WHERE ZRESOURCETYPE=3").fetchone()
                self.fixture.photos.execute(f"UPDATE ZINTERNALRESOURCE SET {field}=? WHERE rowid=?", (value, rowid))
                self.changed()
                with self.assertRaises(helper.UserError):
                    await self.prepare()
                self.assert_stopped_without_rebasing()
                self.assertNotIn(MOTION, self.session.reads)
                self.fixture.photos.execute(f"UPDATE ZINTERNALRESOURCE SET {field}=? WHERE rowid=?", (old, rowid))
                self.changed()

    async def test_binary_resource_keys_uti_and_trash_changes_stop_refresh(self):
        for name, kind in (("ZDATASTOREKEYDATA", "BLOB"), ("ZCOMPACTUTI", "TEXT"),
                           ("ZTRASHEDSTATE", "INTEGER"), ("ZPTPTRASHEDSTATE", "INTEGER")):
            self.fixture.photos.execute(f"ALTER TABLE ZINTERNALRESOURCE ADD COLUMN {name} {kind}")
        self.fixture.photos.execute("UPDATE ZINTERNALRESOURCE SET ZDATASTOREKEY=NULL,ZTRASHEDSTATE=0,ZPTPTRASHEDSTATE=0")
        self.fixture.photos.execute("UPDATE ZINTERNALRESOURCE SET ZDATASTOREKEYDATA=?,ZCOMPACTUTI='3' WHERE ZRESOURCETYPE=0", (bytes.fromhex("03000000c001"),))
        self.fixture.photos.execute("UPDATE ZINTERNALRESOURCE SET ZDATASTOREKEYDATA=?,ZCOMPACTUTI='23',ZDATASTORESUBTYPE=18 WHERE ZRESOURCETYPE=3", (bytes.fromhex("03300000c00b"),))
        self.session.put("/DCIM/100APPLE/PHOTO.MOV", b"movie!!")
        self.changed()
        for field, value in (("ZDATASTOREKEYDATA", bytes.fromhex("03300000c00c")),
                             ("ZCOMPACTUTI", "99"), ("ZTRASHEDSTATE", 1),
                             ("ZPTPTRASHEDSTATE", 1), ("ZDATASTORESUBTYPE", 19)):
            with self.subTest(field=field):
                await self.scan()
                rowid, old = self.fixture.photos.execute(f"SELECT rowid,{field} FROM ZINTERNALRESOURCE WHERE ZRESOURCETYPE=3").fetchone()
                self.fixture.photos.execute(f"UPDATE ZINTERNALRESOURCE SET {field}=? WHERE rowid=?", (value, rowid))
                self.changed()
                with self.assertRaises(helper.UserError):
                    await self.prepare()
                self.assert_stopped_without_rebasing()
                self.assertNotIn("/DCIM/100APPLE/PHOTO.MOV", self.session.reads)
                self.fixture.photos.execute(f"UPDATE ZINTERNALRESOURCE SET {field}=? WHERE rowid=?", (old, rowid))
                self.changed()

    async def test_independent_video_original_resource_changes_stop_refresh(self):
        # Ordinary videos do not use Live Photo pairing, but their resource
        # records still form part of the selected original's identity.
        asset_pk = self.fixture.photos.execute("SELECT Z_PK FROM ZASSET WHERE ZUUID=?", (self.video,)).fetchone()[0]
        cursor = self.fixture.photos.execute(
            "INSERT INTO ZINTERNALRESOURCE VALUES(?,?,?,?,?,?,?,?,?)",
            (asset_pk, 0, "DCIM/100APPLE/STANDALONE.MOV", 1, 0, 0, 0, 1, len(self.session.files[VIDEO]))
        )
        resource_rowid = cursor.lastrowid
        self.changed()
        for field, value in (("ZVERSION", 1), ("ZRECIPEID", 1),
                             ("ZLOCALAVAILABILITY", 0), ("ZDATALENGTH", 19),
                             ("ZDATASTOREKEY", "DCIM/100APPLE/REPLACED.MOV")):
            with self.subTest(field=field):
                await self.scan()
                old = self.fixture.photos.execute(f"SELECT {field} FROM ZINTERNALRESOURCE WHERE rowid=?", (resource_rowid,)).fetchone()[0]
                self.fixture.photos.execute(f"UPDATE ZINTERNALRESOURCE SET {field}=? WHERE rowid=?", (value, resource_rowid))
                self.changed()
                with self.assertRaises(helper.UserError):
                    await self.prepare()
                self.assert_stopped_without_rebasing()
                self.assertNotIn(MOTION, self.session.reads)
                self.fixture.photos.execute(f"UPDATE ZINTERNALRESOURCE SET {field}=? WHERE rowid=?", (old, resource_rowid))
                self.changed()

    async def test_new_derived_resources_before_prepare_do_not_invalidate_originals(self):
        await self.scan()
        for asset_id in (self.live, self.video):
            asset_pk = self.fixture.photos.execute("SELECT Z_PK FROM ZASSET WHERE ZUUID=?", (asset_id,)).fetchone()[0]
            # Both a rendered version and a recipe-based derivative are
            # unrelated to the original resource chosen for archiving.
            self.fixture.photos.executemany(
                "INSERT INTO ZINTERNALRESOURCE VALUES(?,?,?,?,?,?,?,?,?)",
                [(asset_pk, 0, "PhotoData/DERIVED.JPG", 1, 0, 1, 0, 1, 9),
                 (asset_pk, 3, "PhotoData/DERIVED.MOV", 1, 0, 0, 1, 1, 10)]
            )
        self.changed()
        await self.prepare()
        self.assertNotEqual(self.saved["metadata"], self.baseline)
        self.assertEqual(await self.read("PHOTO.HEIC"), b"image")
        self.assertEqual(await self.read("STANDALONE.MOV"), b"independent video")
        self.assertNotIn(MOTION, self.session.reads)
        self.assertFalse(any("DERIVED" in path for path in self.session.reads + self.session.stats))

    async def test_changed_selected_still_or_independent_video_identity_stops_refresh(self):
        for path in (STILL, VIDEO):
            with self.subTest(path=path):
                await self.scan()
                await self.prepare()
                self.session.touch(PHOTOS)
                self.session.touch(path)
                with self.assertRaises(helper.UserError):
                    await self.validate()
                self.assert_stopped_without_rebasing()
                self.assertNotIn(MOTION, self.session.reads)

    async def test_complete_mode_refresh_rechecks_both_live_originals(self):
        await self.scan()
        await self.prepare(complete=True)
        self.session.touch(PHOTOS)
        self.session.touch(MOTION)
        with self.assertRaises(helper.UserError):
            await self.validate()
        self.assert_stopped_without_rebasing()
        self.assertIn(MOTION, self.session.stats)
        self.assertNotIn(MOTION, self.session.reads)

    async def test_unchanged_index_does_not_disable_per_chunk_original_checks(self):
        await self.scan()
        await self.prepare()
        self.session.touch(STILL)
        with self.assertRaises(helper.UserError):
            await self.read("PHOTO.HEIC")
        self.assert_stopped_without_rebasing()
        self.assertNotIn(STILL, self.session.reads)

    async def test_final_validate_checks_selected_originals_when_index_is_unchanged(self):
        for path in (STILL, VIDEO):
            for change in ("size", "mtime", "missing", "link"):
                with self.subTest(path=path, change=change):
                    await self.scan()
                    await self.prepare()
                    await self.read("PHOTO.HEIC")
                    await self.read("STANDALONE.MOV")
                    original = self.session.files[path]
                    if change == "size":
                        self.session.files[path] += b"x"
                    elif change == "mtime":
                        self.session.touch(path)
                    elif change == "missing":
                        del self.session.files[path]
                    else:
                        self.session.stat_overrides[path] = {"LinkTarget": OTHER}
                    self.session.reads.clear()
                    self.session.stats.clear()
                    with self.assertRaises(helper.UserError):
                        await self.validate()
                    self.assert_stopped_without_rebasing()
                    self.assertIn(path, self.session.stats)
                    self.assertNotIn(MOTION, self.session.stats)
                    self.assertFalse(self.session.reads)
                    self.session.files[path] = original
                    self.session.stat_overrides.pop(path, None)

    async def test_final_validate_complete_mode_checks_both_live_components(self):
        for path in (STILL, MOTION):
            with self.subTest(path=path):
                await self.scan()
                await self.prepare(complete=True)
                await self.read("PHOTO.HEIC")
                await self.read("MOTION.MOV")
                self.session.touch(path)
                self.session.reads.clear()
                self.session.stats.clear()
                with self.assertRaises(helper.UserError):
                    await self.validate()
                self.assert_stopped_without_rebasing()
                self.assertIn(path, self.session.stats)
                self.assertFalse(self.session.reads)

    async def test_final_validate_still_only_ignores_unselected_companion_and_other_originals(self):
        await self.scan()
        await self.prepare()
        self.session.touch(MOTION)
        self.session.touch(OTHER)
        self.session.reads.clear()
        self.session.stats.clear()
        await self.validate()
        self.assertEqual(self.saved["metadata"], self.baseline)
        self.assertEqual({p for p in self.session.stats if p.startswith("/DCIM/")}, {STILL, VIDEO})
        self.assertFalse(self.session.reads)

    async def test_prepared_transfer_ignores_continuous_index_activity_without_rebasing(self):
        await self.scan()
        await self.prepare()
        frozen = copy.deepcopy(self.saved)
        self.session.reads.clear()
        self.session.stats.clear()
        changes = 0

        def background_index_update(path):
            nonlocal changes
            if path.startswith("/DCIM/"):
                changes += 1
                self.session.touch(PHOTOS)
                self.session.touch(LEO)

        self.session.after_stat = background_index_update
        with mock.patch.object(helper, "metadata_state", side_effect=AssertionError("prepared plan must not stat indexes")), \
             mock.patch.object(helper, "snapshot", side_effect=AssertionError("prepared plan must not copy indexes")), \
             mock.patch.object(helper, "parse_catalog", side_effect=AssertionError("prepared plan must not be reselected")):
            for _ in range(3):
                self.assertEqual(await self.read("PHOTO.HEIC"), b"image")
                self.assertEqual(await self.read("STANDALONE.MOV"), b"independent video")
            self.session.stats.clear()
            self.session.reads.clear()
            await self.validate()
        self.assertEqual(changes, 14)
        self.assertEqual(self.saved, frozen)
        self.assertCountEqual(self.session.stats, [STILL, VIDEO])
        self.assertFalse(self.session.reads)
        self.assertNotIn(MOTION, self.session.stats)

    async def test_prepared_membership_date_position_and_resource_paths_remain_fixed(self):
        await self.scan()
        await self.prepare()
        frozen = copy.deepcopy(self.saved)
        # These later library edits must not retarget or reclassify an archive
        # whose selection was already confirmed, while physical originals stay.
        self.fixture.photos.execute(
            "UPDATE ZASSET SET ZDATECREATED=ZDATECREATED+864000,ZLATITUDE=40,ZLONGITUDE=110 WHERE ZUUID=?",
            (self.live,))
        self.fixture.leo.execute("UPDATE items SET lexeme_ids=? WHERE identifier=?", (b"", self.live))
        self.fixture.photos.execute("UPDATE ZINTERNALRESOURCE SET ZDATASTOREKEY='DCIM/100APPLE/OTHER.HEIC'")
        self.changed()
        self.session.reads.clear()
        self.session.stats.clear()
        self.assertEqual(await self.read("PHOTO.HEIC"), b"image")
        await self.validate()
        self.assertEqual(self.saved, frozen)
        self.assertTrue(all(path.startswith("/DCIM/") for path in self.session.stats))
        self.assertEqual(self.session.reads, [STILL])
        self.assertNotIn(OTHER, self.session.stats)

    async def test_prepared_validation_does_not_depend_on_index_availability_or_format(self):
        await self.scan()
        await self.prepare()
        frozen = copy.deepcopy(self.saved)
        del self.session.files[LEO]
        self.session.put(PHOTOS, b"temporarily unavailable index structure")
        self.session.stats.clear()
        self.session.reads.clear()
        await self.validate()
        self.assertEqual(self.saved, frozen)
        self.assertCountEqual(self.session.stats, [STILL, VIDEO])
        self.assertFalse(self.session.reads)

    async def test_prepared_read_checks_only_current_original_before_and_after_bytes(self):
        await self.scan()
        await self.prepare(complete=True)
        self.session.stats.clear()
        self.session.reads.clear()
        self.assertEqual(await self.read("MOTION.MOV"), b"movie!!")
        self.assertEqual(self.session.stats, [MOTION, MOTION])
        self.assertEqual(self.session.reads, [MOTION])
        self.session.stats.clear()
        original_read = self.session.read_bytes

        async def changed_during_read(path, offset, length):
            data = await original_read(path, offset, length)
            self.session.touch(path)
            return data

        self.session.read_bytes = changed_during_read
        with self.assertRaises(helper.UserError):
            await self.read("PHOTO.HEIC")
        self.assert_stopped_without_rebasing()
        self.assertEqual(self.session.stats, [STILL, STILL])

    async def test_prepared_disconnect_or_replaced_usb_instance_still_stops(self):
        for change in ("disconnect", "mux"):
            with self.subTest(change=change):
                await self.scan()
                await self.prepare()
                self.session.stats.clear()
                self.session.reads.clear()
                old_mux = self.session.mux_id
                if change == "disconnect":
                    self.session.changed = True
                else:
                    self.session.mux_id += 1
                try:
                    with self.assertRaises(helper.UserError):
                        await self.validate()
                    self.assert_stopped_without_rebasing()
                    self.assertFalse(self.session.stats)
                    self.assertFalse(self.session.reads)
                finally:
                    self.session.changed = False
                    self.session.mux_id = old_mux

    async def test_disconnect_during_last_original_stat_does_not_finish_validation(self):
        await self.scan()
        await self.prepare()
        checked = 0

        def disconnected_after_stat(path):
            nonlocal checked
            if path in (STILL, VIDEO):
                checked += 1
                if checked == 2:
                    self.session.changed = True

        self.session.stats.clear()
        self.session.reads.clear()
        self.session.after_stat = disconnected_after_stat
        with self.assertRaises(helper.UserError):
            await self.validate()
        self.assert_stopped_without_rebasing()
        self.assertEqual(checked, 2)
        self.assertCountEqual(self.session.stats, [STILL, VIDEO])
        self.assertFalse(self.session.reads)

    async def test_unknown_schema_and_corrupt_database_stop_without_rebasing(self):
        for corruption in ("schema", "bytes"):
            with self.subTest(corruption=corruption):
                await self.scan()
                original = self.session.files[PHOTOS]
                if corruption == "schema":
                    self.fixture.photos.execute("ALTER TABLE ZASSET RENAME COLUMN ZKINDSUBTYPE TO UNKNOWN")
                    self.changed()
                else:
                    self.session.put(PHOTOS, b"not a sqlite database")
                with self.assertRaises((helper.UserError, sqlite3.Error)):
                    await self.prepare()
                self.assert_stopped_without_rebasing()
                if corruption == "schema":
                    self.fixture.photos.execute("ALTER TABLE ZASSET RENAME COLUMN UNKNOWN TO ZKINDSUBTYPE")
                    self.changed()
                else:
                    self.session.put(PHOTOS, original)

    async def test_snapshot_rejects_cross_database_late_change(self):
        # On the second Photos read, mutate leo after leo's second read has
        # already been checked. Per-file checks alone would miss this race.
        reads = 0
        def after_close(path):
            nonlocal reads
            if path == PHOTOS:
                reads += 1
                if reads == 2:
                    self.session.touch(LEO)
        self.session.after_close = after_close
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(helper.UserError):
            await helper.snapshot(self.session, Path(directory), progress)
        self.assertEqual(self.session.opened, self.session.closed_handles)
        self.assertFalse(any(p.startswith("/DCIM/") for p in self.session.reads))

    async def test_one_unstable_refresh_snapshot_retries_then_succeeds(self):
        await self.scan()
        self.session.touch(PHOTOS)
        changes = 0
        def after_close(path):
            nonlocal changes
            if path == PHOTOS and changes == 0:
                changes += 1
                self.session.touch(LEO)
        self.session.after_close = after_close
        await self.prepare()
        self.assertEqual(changes, 1)
        self.assertTrue(self.saved["prepared"])
        self.assertNotEqual(self.saved["metadata"], self.baseline)
        self.assertEqual(self.session.opened, self.session.closed_handles)
        self.assertFalse(any(p.startswith("/DCIM/") for p in self.session.reads))

    async def test_continuously_changing_snapshot_has_bounded_retries_and_closes(self):
        await self.scan()
        self.session.touch(PHOTOS)
        changes = 0
        def after_close(path):
            nonlocal changes
            if path == PHOTOS:
                changes += 1
                self.session.touch(LEO)
        self.session.after_close = after_close
        opened = self.session.opened
        with self.assertRaises(helper.UserError):
            await self.prepare()
        self.assert_stopped_without_rebasing()
        self.assertLessEqual(self.session.opened - opened, 8)
        self.assertGreater(changes, 0)
        self.assertFalse(any(p.startswith("/DCIM/") for p in self.session.reads))

    async def test_prepare_index_change_during_selected_file_stat_does_not_adopt_stale_baseline(self):
        await self.scan()
        self.session.touch(PHOTOS)
        changes = 0
        def after_stat(path):
            nonlocal changes
            if path in (STILL, VIDEO):
                changes += 1
                self.session.touch(LEO)
        self.session.after_stat = after_stat
        with self.assertRaises(helper.UserError):
            await self.prepare()
        self.assert_stopped_without_rebasing()
        self.assertGreater(changes, 0)
        self.assertLessEqual(changes, 4)

    async def test_prepare_rechecks_initially_unchanged_index_after_original_stats(self):
        for selected_changes in (True, False):
            with self.subTest(selected_changes=selected_changes):
                await self.scan()
                self.session.reads.clear()
                changes = 0
                changed_asset = self.live if selected_changes else self.other

                def after_stat(path):
                    nonlocal changes
                    if path in (STILL, VIDEO) and changes == 0:
                        changes += 1
                        self.fixture.photos.execute(
                            "UPDATE ZASSET SET ZDATECREATED=ZDATECREATED+1 WHERE ZUUID=?",
                            (changed_asset,)
                        )
                        self.changed()

                self.session.after_stat = after_stat
                try:
                    # The initial metadata comparison still matches. Only
                    # checking again after original stats observes this race.
                    if selected_changes:
                        with self.assertRaises(helper.UserError):
                            await self.prepare()
                        self.assert_stopped_without_rebasing()
                    else:
                        await self.prepare()
                        self.assertNotEqual(self.saved["metadata"], self.baseline)
                        self.assertTrue(self.saved["prepared"])
                    self.assertEqual(changes, 1)
                    self.assertIn(LEO, self.session.reads)
                    self.assertIn(PHOTOS, self.session.reads)
                    self.assertFalse(any(path.startswith("/DCIM/") for path in self.session.reads))
                finally:
                    self.session.after_stat = None
                    self.fixture.photos.execute(
                        "UPDATE ZASSET SET ZDATECREATED=ZDATECREATED-1 WHERE ZUUID=?",
                        (changed_asset,)
                    )
                    self.changed()

    async def test_semantic_signature_stays_private_to_helper_manifest(self):
        result = await self.scan()
        self.assertNotIn("semantics", result)
        for item in result["items"]:
            self.assertNotIn("semantic", item)
            self.assertNotIn("assetID", item)
        for asset in result["assets"]:
            self.assertNotIn("semantic", asset)


if __name__ == "__main__":
    unittest.main()

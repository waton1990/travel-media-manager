"""Existing-city decoding and refresh tests using synthetic plists and SQLite.

No phone services, user databases, original media, or network calls are used.
"""

import json
import plistlib
import struct
import tempfile
import unittest
import uuid
from unittest import mock

from test_iphone_usb_helper import Fixture, cocoa, helper
import test_index_refresh as refresh


UID = plistlib.UID
CITY = "中国 · 示例甲省 · 示例甲市"


def archive_data(city="示例甲市", province="示例甲省", country="中国", code="CN"):
    """Real NSKeyedArchive references, including Foundation NSArray wrapping."""
    def descriptor(name):
        return {"$classname": name, "$classes": [name, "NSObject"]}

    return {
        "$archiver": "NSKeyedArchiver", "$version": 100000, "$top": {"root": UID(1)},
        "$objects": [
            "$null",
            {"$class": UID(2), "postalAddress": UID(3), "mapItem": UID(5),
             "countryCode": code, "addressString": "PRIVATE STREET MUST NOT LEAK",
             "compoundNames": "PRIVATE DISPLAY LABEL", "version": 1},
            descriptor("PLRevGeoLocationInfo"),
            {"$class": UID(4), "_city": city, "_state": province, "_country": country,
             "_ISOCountryCode": code, "_street": "PRIVATE STREET MUST NOT LEAK",
             "_formattedAddress": "PRIVATE FULL ADDRESS MUST NOT LEAK"},
            descriptor("CNPostalAddress"),
            {"$class": UID(6), "sortedPlaceInfos": UID(7)},
            descriptor("PLRevGeoMapItem"),
            {"$class": UID(8), "NS.objects": [UID(9)]},
            descriptor("NSArray"),
            {"$class": UID(10), "placeType": 4, "name": city, "area": 1.0},
            descriptor("PLRevGeoMapItemAdditionalPlaceInfo"),
        ],
    }


def archived(data=None, **kwargs):
    return plistlib.dumps(data if data is not None else archive_data(**kwargs), fmt=plistlib.FMT_BINARY)


def native_plist(objects, *, offsets=None):
    """Small hand-built bplist to probe native containers before keyed decoding."""
    payload = b"bplist00"
    positions = []
    for value in objects:
        positions.append(len(payload))
        payload += value
    table_position = len(payload)
    positions = positions if offsets is None else offsets
    payload += b"".join(struct.pack(">I", position) for position in positions)
    return payload + struct.pack(">6xBBQQQ", 4, 4, len(positions), 0, table_position)


class CityFixture(Fixture):
    def __init__(self, directory):
        super().__init__(directory)
        self.photos.execute("ALTER TABLE ZASSET ADD COLUMN ZADDITIONALATTRIBUTES INTEGER")
        # Deliberately omit affinity from the validity column: tests must retain
        # 1.0 / '1' instead of SQLite silently coercing them to an integer 1.
        self.photos.execute("""CREATE TABLE ZADDITIONALASSETATTRIBUTES(
            Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER,
            ZREVERSELOCATIONDATA BLOB, ZREVERSELOCATIONDATAISVALID)""")

    def add(self, name="IMG_0001.HEIC", date="2026-10-13T12:00:00+08:00", kind=0,
            subtype=0, mine=True, live=False, lat=31.2, lon=121.5, hidden=0, trash=0,
            directory="DCIM/100APPLE"):
        self.number += 1
        identifier = str(uuid.uuid4()).upper()
        ids = ([7] if mine else []) + ([8] if live else [])
        self.leo.execute("INSERT INTO items VALUES(?,1,?)", (identifier, struct.pack("<" + "I" * len(ids), *ids)))
        self.photos.execute("INSERT INTO ZASSET VALUES(?,?,?,?,?,?,?,?,?,?,?,NULL)",
                            (self.number, identifier, kind, subtype, cocoa(date), directory, name, lat, lon, hidden, trash))
        self.commit()
        return identifier

    def city(self, identifier, blob=None, valid=1):
        asset_pk, additional = self.photos.execute(
            "SELECT Z_PK,ZADDITIONALATTRIBUTES FROM ZASSET WHERE ZUUID=?", (identifier,)).fetchone()
        if additional is None:
            additional = asset_pk + 1000
            self.photos.execute("UPDATE ZASSET SET ZADDITIONALATTRIBUTES=? WHERE Z_PK=?", (additional, asset_pk))
        self.photos.execute("INSERT OR REPLACE INTO ZADDITIONALASSETATTRIBUTES VALUES(?,?,?,?)",
                            (additional, asset_pk, archived() if blob is None else blob, valid))
        self.commit()


class LocalCityArchiveTests(unittest.TestCase):
    def test_valid_city_can_follow_uid_strings(self):
        data = archive_data()
        data["$objects"].append("示例甲市")
        data["$objects"][3]["_city"] = UID(11)
        data["$objects"][9]["name"] = UID(11)
        self.assertEqual(helper.parse_local_place(archived(data)), CITY)

    def test_city_text_is_trimmed_and_unicode_normalized(self):
        data = archive_data(city="Que\u0301bec", province="Québec", country="Canada", code="CA")
        data["$objects"][3]["_city"] = "  Québec  "
        self.assertEqual(helper.parse_local_place(archived(data)), "Canada · Québec")

    def test_missing_province_and_duplicate_components_do_not_create_empty_labels(self):
        self.assertEqual(helper.parse_local_place(archived(city="香港", province="香港")), "中国 · 香港")
        self.assertEqual(helper.parse_local_place(archived(province="")), "中国 · 示例甲市")

    def test_same_city_names_retain_country_and_province_context(self):
        first = helper.parse_local_place(archived(city="Springfield", province="Illinois", country="United States", code="US"))
        second = helper.parse_local_place(archived(city="Springfield", province="Massachusetts", country="United States", code="US"))
        self.assertNotEqual(first, second)
        self.assertEqual(first, "United States · Illinois · Springfield")

    def test_absent_country_codes_are_allowed_but_conflicting_or_malformed_codes_are_not(self):
        data = archive_data()
        del data["$objects"][1]["countryCode"]
        del data["$objects"][3]["_ISOCountryCode"]
        self.assertEqual(helper.parse_local_place(archived(data)), CITY)
        for code in ("US", "cn", "CHN", 1):
            with self.subTest(code=code):
                data = archive_data()
                data["$objects"][1]["countryCode"] = code
                self.assertIsNone(helper.parse_local_place(archived(data)))

    def test_conflicting_typed_city_cannot_be_used(self):
        data = archive_data()
        data["$objects"][9]["name"] = "示例乙市"
        self.assertIsNone(helper.parse_local_place(archived(data)))

    def test_two_different_typed_cities_are_ambiguous(self):
        data = archive_data()
        data["$objects"].append({"$class": UID(10), "placeType": 4, "name": "示例乙市"})
        data["$objects"][7]["NS.objects"].append(UID(11))
        self.assertIsNone(helper.parse_local_place(archived(data)))

    def test_subadministrative_or_display_names_are_not_guessed_as_city(self):
        for alternate_type in (1, 2, 3, 6, 99):
            with self.subTest(place_type=alternate_type):
                data = archive_data()
                data["$objects"][9]["placeType"] = alternate_type
                self.assertIsNone(helper.parse_local_place(archived(data)))
        data = archive_data()
        data["$objects"][7]["NS.objects"] = []
        data["$objects"][1]["compoundNames"] = "中国 示例甲省 示例甲市"
        self.assertIsNone(helper.parse_local_place(archived(data)))

    def test_city_type_requires_integer_not_equal_boolean_or_real(self):
        for kind in (4.0, True, "4"):
            with self.subTest(place_type=kind):
                data = archive_data()
                data["$objects"][9]["placeType"] = kind
                self.assertIsNone(helper.parse_local_place(archived(data)))

    def test_missing_country_or_city_and_control_text_are_rejected(self):
        cases = (("_city", ""), ("_country", ""), ("_city", "晋\n城市"),
                 ("_city", "晋\u202e城市"), ("_city", "A" * 257), ("_city", 123))
        for key, value in cases:
            with self.subTest(key=key, value_type=type(value).__name__):
                data = archive_data()
                data["$objects"][3][key] = value
                if key == "_city":
                    data["$objects"][9]["name"] = value
                self.assertIsNone(helper.parse_local_place(archived(data)))

    def test_malformed_unknown_and_oversized_archives_fall_back(self):
        for blob in (None, "not bytes", b"not a plist", b"x" * (helper.MAX_LOCAL_PLACE_BLOB + 1)):
            with self.subTest(blob_type=type(blob).__name__):
                self.assertIsNone(helper.parse_local_place(blob))
        data = archive_data()
        data["$archiver"] = "UnexpectedArchiver"
        self.assertIsNone(helper.parse_local_place(archived(data)))
        data = archive_data()
        data["$objects"].extend(["unused"] * helper.MAX_LOCAL_PLACE_OBJECTS)
        self.assertIsNone(helper.parse_local_place(archived(data)))

    def test_invalid_or_cyclic_references_fall_back_without_global_string_search(self):
        for reference in (UID(99999), UID(11)):
            with self.subTest(index=reference.data):
                data = archive_data()
                data["$objects"][1]["postalAddress"] = reference
                data["$objects"].append(UID(11))
                self.assertIsNone(helper.parse_local_place(archived(data)))

    def test_excessive_uid_chain_depth_falls_back(self):
        data = archive_data()
        data["$objects"][1]["postalAddress"] = UID(11)
        for index in range(11, 11 + helper.MAX_LOCAL_PLACE_DEPTH):
            data["$objects"].append(UID(index + 1))
        data["$objects"].append(UID(3))
        self.assertIsNone(helper.parse_local_place(archived(data)))

    def test_native_container_cycles_and_depth_are_rejected_before_deserialization(self):
        cycle = native_plist([b"\xa1" + struct.pack(">I", 0)])
        deep = native_plist([b"\xa1" + struct.pack(">I", index + 1)
                             for index in range(helper.MAX_LOCAL_PLACE_DEPTH + 1)] + [b"\x00"])
        for blob in (cycle, deep):
            with self.subTest(kind="cycle" if blob == cycle else "depth"):
                with mock.patch.object(helper.plistlib, "loads") as loads:
                    self.assertIsNone(helper.parse_local_place(blob))
                    loads.assert_not_called()

    def test_overlapping_offsets_and_unbounded_native_lengths_never_reach_deserializer(self):
        # 2 logical arrays point to the same physical bytes. Larger versions of
        # this shape can expand a small BLOB into many gigabytes in plistlib.
        overlapping = native_plist([b"\xa1" + struct.pack(">I", 1)], offsets=[8, 8])
        huge_length = native_plist([b"\xaf\x13" + struct.pack(">Q", 2**40)])
        for blob in (overlapping, huge_length):
            with self.subTest(kind="overlap" if blob == overlapping else "length"):
                with mock.patch.object(helper.plistlib, "loads") as loads:
                    self.assertIsNone(helper.parse_local_place(blob))
                    loads.assert_not_called()

    def test_unknown_archive_versions_and_inconsistent_class_descriptors_fall_back(self):
        for version in (None, 100001, 100000.0, True, "100000"):
            with self.subTest(version=version):
                data = archive_data()
                if version is None:
                    data.pop("$version")
                else:
                    data["$version"] = version
                self.assertIsNone(helper.parse_local_place(archived(data)))
        for classes in ([], ["UnexpectedClass", "NSObject"], "PLRevGeoLocationInfo", [123]):
            with self.subTest(classes=classes):
                data = archive_data()
                data["$objects"][2]["$classes"] = classes
                self.assertIsNone(helper.parse_local_place(archived(data)))

    def test_unsupported_classes_or_array_forms_fall_back(self):
        for object_index in (2, 4, 6, 8, 10):
            with self.subTest(class_index=object_index):
                data = archive_data()
                data["$objects"][object_index]["$classname"] = "UnsupportedClass"
                self.assertIsNone(helper.parse_local_place(archived(data)))
        data = archive_data()
        data["$objects"][7]["NS.objects"] = {"unexpected": UID(9)}
        self.assertIsNone(helper.parse_local_place(archived(data)))

    def test_excessive_place_entries_fall_back(self):
        data = archive_data()
        data["$objects"][7]["NS.objects"] = [UID(9)] * (helper.MAX_LOCAL_PLACE_INFOS + 1)
        self.assertIsNone(helper.parse_local_place(archived(data)))

    def test_optional_country_and_province_typed_entries_cannot_contradict_postal_record(self):
        for place_type, name in ((1, "其他国家"), (2, "其他省份")):
            with self.subTest(place_type=place_type):
                data = archive_data()
                data["$objects"].append({"$class": UID(10), "placeType": place_type, "name": name})
                data["$objects"][7]["NS.objects"].append(UID(11))
                self.assertIsNone(helper.parse_local_place(archived(data)))


class LocalCityCatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.fixture = CityFixture(self.temp.name)
        self.identifier = self.fixture.add()
        self.fixture.city(self.identifier)

    def tearDown(self):
        self.fixture.close()
        self.temp.cleanup()

    def asset(self):
        result = self.fixture.parse()
        self.assertEqual(result["issues"], [])
        return next(c["asset"] for c in result["candidates"] if c["asset"]["id"] == self.identifier)

    def test_valid_city_is_exposed_without_postal_or_archive_data(self):
        asset = self.asset()
        self.assertEqual(asset["localPlaceName"], CITY)
        encoded = json.dumps(asset, ensure_ascii=False)
        for forbidden in ("PRIVATE", "NSKeyed", "_street", "postalAddress", "location_blob"):
            self.assertNotIn(forbidden, encoded)

    def test_photo_and_video_assets_both_receive_existing_city(self):
        for index in range(1, 11):
            is_video = index >= 7
            identifier = self.fixture.add(name=f"FILE_{index:04}." + ("MOV" if is_video else "HEIC"), kind=int(is_video))
            self.fixture.city(identifier)
        result = self.fixture.parse()
        self.assertEqual(len(result["candidates"]), 11)
        self.assertEqual(sum(c["asset"]["kind"] == "photo" for c in result["candidates"]), 7)
        self.assertEqual(sum(c["asset"]["kind"] == "video" for c in result["candidates"]), 4)
        self.assertTrue(all(c["asset"]["localPlaceName"] == CITY for c in result["candidates"]))

    def test_missing_or_invalid_current_coordinates_do_not_reuse_cached_city(self):
        for lat, lon in ((None, 121.5), (31.2, None), (999, 121.5), (31.2, 999)):
            with self.subTest(latitude=lat, longitude=lon):
                self.fixture.photos.execute("UPDATE ZASSET SET ZLATITUDE=?,ZLONGITUDE=?", (lat, lon))
                self.fixture.commit()
                self.assertIsNone(self.asset().get("localPlaceName"))

    def test_only_integer_one_is_a_validity_signal(self):
        for flag in (None, 0, -1, 2, 1.0, "1", b"1"):
            with self.subTest(flag=flag):
                self.fixture.photos.execute("UPDATE ZADDITIONALASSETATTRIBUTES SET ZREVERSELOCATIONDATAISVALID=?", (flag,))
                self.fixture.commit()
                self.assertIsNone(self.asset().get("localPlaceName"))

    def test_missing_optional_location_table_preserves_scan_and_fallback(self):
        self.fixture.photos.execute("DROP TABLE ZADDITIONALASSETATTRIBUTES")
        self.fixture.commit()
        self.assertIsNone(self.asset().get("localPlaceName"))

    def test_missing_optional_columns_preserve_scan_and_fallback(self):
        for table, column in (("ZASSET", "ZADDITIONALATTRIBUTES"),
                              ("ZADDITIONALASSETATTRIBUTES", "ZREVERSELOCATIONDATA"),
                              ("ZADDITIONALASSETATTRIBUTES", "ZREVERSELOCATIONDATAISVALID"),
                              ("ZADDITIONALASSETATTRIBUTES", "ZASSET")):
            with self.subTest(table=table, column=column):
                self.fixture.photos.execute(f"ALTER TABLE {table} RENAME COLUMN {column} TO UNRECOGNIZED")
                self.fixture.commit()
                self.assertIsNone(self.asset().get("localPlaceName"))
                self.fixture.photos.execute(f"ALTER TABLE {table} RENAME COLUMN UNRECOGNIZED TO {column}")
                self.fixture.commit()

    def test_missing_blob_or_bad_archive_is_not_a_blocking_media_issue(self):
        for blob in (None, b"", b"broken archive", "not bytes"):
            with self.subTest(blob_type=type(blob).__name__):
                self.fixture.photos.execute("UPDATE ZADDITIONALASSETATTRIBUTES SET ZREVERSELOCATIONDATA=?", (blob,))
                self.fixture.commit()
                self.assertIsNone(self.asset().get("localPlaceName"))

    def test_forward_foreign_key_must_point_to_the_matching_backlink(self):
        other = self.fixture.add(name="OTHER.HEIC")
        self.fixture.city(other, archived(city="示例乙市", province="示例乙省"))
        other_pk = self.fixture.photos.execute("SELECT ZADDITIONALATTRIBUTES FROM ZASSET WHERE ZUUID=?", (other,)).fetchone()[0]
        self.fixture.photos.execute("UPDATE ZASSET SET ZADDITIONALATTRIBUTES=? WHERE ZUUID=?", (other_pk, self.identifier))
        self.fixture.commit()
        self.assertIsNone(self.asset().get("localPlaceName"))

    def test_reverse_foreign_key_must_refer_to_the_same_asset(self):
        self.fixture.photos.execute("UPDATE ZADDITIONALASSETATTRIBUTES SET ZASSET=9999")
        self.fixture.commit()
        self.assertIsNone(self.asset().get("localPlaceName"))

    def test_duplicate_reverse_records_are_ambiguous(self):
        self.fixture.photos.execute("INSERT INTO ZADDITIONALASSETATTRIBUTES SELECT Z_PK+100,ZASSET,ZREVERSELOCATIONDATA,ZREVERSELOCATIONDATAISVALID FROM ZADDITIONALASSETATTRIBUTES")
        self.fixture.commit()
        self.assertIsNone(self.asset().get("localPlaceName"))

    def test_duplicate_additional_primary_values_are_ambiguous(self):
        self.fixture.photos.executescript("""ALTER TABLE ZADDITIONALASSETATTRIBUTES RENAME TO ORIGINAL;
            CREATE TABLE ZADDITIONALASSETATTRIBUTES AS SELECT * FROM ORIGINAL;
            INSERT INTO ZADDITIONALASSETATTRIBUTES SELECT * FROM ORIGINAL;
            DROP TABLE ORIGINAL;""")
        self.fixture.commit()
        self.assertIsNone(self.asset().get("localPlaceName"))

    def test_numeric_type_aliases_cannot_hide_an_ambiguous_join(self):
        original = self.fixture.photos.execute("SELECT * FROM ZADDITIONALASSETATTRIBUTES").fetchone()
        for attribute_id, asset_id in ((2002, 1.0), (1001.0, 2)):
            with self.subTest(attribute_type=type(attribute_id).__name__, asset_type=type(asset_id).__name__):
                # SQLite equates 1 with 1.0 in these joins. An unknown schema
                # must not let Python type filtering hide a matching bad row.
                self.fixture.photos.executescript("""DROP TABLE ZADDITIONALASSETATTRIBUTES;
                    CREATE TABLE ZADDITIONALASSETATTRIBUTES(
                        Z_PK,ZASSET,ZREVERSELOCATIONDATA,ZREVERSELOCATIONDATAISVALID);""")
                self.fixture.photos.execute("INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES(?,?,?,?)", original)
                self.fixture.photos.execute("INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES(?,?,?,1)",
                                            (attribute_id, asset_id, archived(city="示例乙市", province="示例乙省")))
                self.fixture.commit()
                self.assertIsNone(self.asset().get("localPlaceName"))

    def test_bad_unselected_archive_does_not_block_good_city_records(self):
        other = self.fixture.add(name="OTHER.HEIC")
        self.fixture.city(other, b"malformed")
        self.assertEqual(self.asset()["localPlaceName"], CITY)


class LocalCityRefreshTests(unittest.IsolatedAsyncioTestCase):
    # Reuse the already-tested fake transport and protocol helpers, without
    # inheriting or running the unrelated IndexRefreshTests methods a second time.
    scan = refresh.IndexRefreshTests.scan
    prepare = refresh.IndexRefreshTests.prepare
    validate = refresh.IndexRefreshTests.validate
    changed = refresh.IndexRefreshTests.changed
    assert_stopped_without_rebasing = refresh.IndexRefreshTests.assert_stopped_without_rebasing
    asyncTearDown = refresh.IndexRefreshTests.asyncTearDown

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.fixture = CityFixture(self.temporary.name)
        self.live = self.fixture.live_pair(name="PHOTO.HEIC", movie="MOTION.MOV")
        self.video = self.fixture.add(name="STANDALONE.MOV", kind=1)
        self.other = self.fixture.add(name="OTHER.HEIC")
        for identifier in (self.live, self.video, self.other):
            self.fixture.city(identifier)
        self.session = refresh.MutableSession()
        for path, data in ((refresh.STILL, b"image"), (refresh.MOTION, b"movie!!"),
                           (refresh.VIDEO, b"independent video"), (refresh.OTHER, b"other image")):
            self.session.put(path, data)
        self.session.publish(self.fixture)
        self.server = helper.Server(lambda _: self.session)

    async def test_protocol_exports_only_normalized_city_not_archive_fields(self):
        result = await self.scan()
        self.assertTrue(all(asset["localPlaceName"] == CITY for asset in result["assets"]))
        encoded = json.dumps(result, ensure_ascii=False)
        for forbidden in ("PRIVATE", "NSKeyed", "postalAddress", "semantic", "ZREVERSELOCATION"):
            self.assertNotIn(forbidden, encoded)

    async def test_selected_city_change_stops_prepare_without_rebasing(self):
        await self.scan()
        self.fixture.city(self.live, archived(city="示例乙市", province="示例乙省"))
        self.changed()
        with self.assertRaises(helper.UserError):
            await self.prepare()
        self.assert_stopped_without_rebasing()
        self.assertFalse(any(path.startswith("/DCIM/") for path in self.session.reads))

    async def test_selected_video_city_change_stops_preparation(self):
        await self.scan()
        self.fixture.city(self.video, archived(city="示例乙市", province="示例乙省"))
        self.changed()
        with self.assertRaises(helper.UserError):
            await self.prepare()
        self.assert_stopped_without_rebasing()

    async def test_prepared_city_result_remains_fixed_after_later_city_or_validity_updates(self):
        await self.scan()
        await self.prepare()
        frozen_semantics = dict(self.saved["semantics"])
        self.fixture.city(self.video, archived(city="示例乙市", province="示例乙省"))
        self.fixture.city(self.live, valid=0)
        self.changed()
        self.session.stats.clear()
        self.session.reads.clear()
        await self.validate()
        self.assertEqual(self.saved["semantics"], frozen_semantics)
        self.assertEqual(self.saved["metadata"], self.baseline)
        self.assertCountEqual(self.session.stats, [refresh.STILL, refresh.VIDEO])
        self.assertFalse(self.session.reads)
        self.assertTrue(all(asset["localPlaceName"] == CITY for asset in self.result["assets"]))

    async def test_selected_city_becoming_invalid_stops(self):
        await self.scan()
        self.fixture.city(self.live, valid=0)
        self.changed()
        with self.assertRaises(helper.UserError):
            await self.prepare()
        self.assert_stopped_without_rebasing()

    async def test_new_trusted_city_after_scan_requires_new_selection(self):
        self.fixture.city(self.live, valid=0)
        self.changed()
        await self.scan()
        self.fixture.city(self.live, valid=1)
        self.changed()
        with self.assertRaises(helper.UserError):
            await self.prepare()
        self.assert_stopped_without_rebasing()

    async def test_selected_city_association_break_stops(self):
        await self.scan()
        self.fixture.photos.execute("UPDATE ZADDITIONALASSETATTRIBUTES SET ZASSET=9999 WHERE ZASSET=1")
        self.changed()
        with self.assertRaises(helper.UserError):
            await self.prepare()
        self.assert_stopped_without_rebasing()

    async def test_unselected_city_change_allows_selected_originals(self):
        await self.scan()
        self.fixture.city(self.other, archived(city="示例乙市", province="示例乙省"))
        self.changed()
        await self.prepare()
        await self.validate()
        self.assertTrue(self.saved["prepared"])
        self.assertNotEqual(self.saved["metadata"], self.baseline)
        self.assertNotIn(refresh.OTHER, self.session.stats)

    async def test_non_city_private_address_changes_before_prepare_do_not_stop_selection(self):
        await self.scan()
        data = archive_data()
        data["$objects"][1]["addressString"] = "DIFFERENT PRIVATE DISPLAY ADDRESS"
        data["$objects"][1]["compoundNames"] = "DIFFERENT PRIVATE DISPLAY LABEL"
        data["$objects"][3]["_street"] = "DIFFERENT PRIVATE STREET"
        data["$objects"][3]["_formattedAddress"] = "DIFFERENT PRIVATE FULL ADDRESS"
        self.fixture.city(self.live, archived(data))
        self.changed()
        await self.prepare()
        self.assertTrue(self.saved["prepared"])
        self.assertNotEqual(self.saved["metadata"], self.baseline)

    async def test_physical_row_identifiers_can_change_when_city_associations_stay_identical(self):
        await self.scan()
        self.fixture.photos.execute("UPDATE ZASSET SET Z_PK=Z_PK+100,ZADDITIONALATTRIBUTES=ZADDITIONALATTRIBUTES+1000")
        self.fixture.photos.execute("UPDATE ZINTERNALRESOURCE SET ZASSET=ZASSET+100")
        self.fixture.photos.execute("UPDATE ZADDITIONALASSETATTRIBUTES SET Z_PK=Z_PK+1000,ZASSET=ZASSET+100")
        self.changed()
        await self.prepare()
        self.assertTrue(self.saved["prepared"])
        self.assertNotEqual(self.saved["metadata"], self.baseline)

    async def test_invalid_location_metadata_changes_do_not_invent_city_or_read_companion(self):
        self.fixture.city(self.live, b"unrecognized one")
        self.changed()
        await self.scan()
        self.fixture.city(self.live, b"unrecognized two")
        self.changed()
        await self.prepare()
        await self.validate()
        self.assertNotIn(refresh.MOTION, self.session.stats)
        self.assertFalse(any(path.startswith("/DCIM/") for path in self.session.reads))


if __name__ == "__main__":
    unittest.main()

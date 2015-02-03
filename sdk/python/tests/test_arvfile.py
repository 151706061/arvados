#!/usr/bin/env python

import bz2
import gzip
import io
import mock
import os
import unittest
import hashlib

import arvados
from arvados import ArvadosFile, ArvadosFileReader, Range, import_manifest, export_manifest, KeepLocator
from arvados.arvfile import SYNC_READONLY, SYNC_EXPLICIT

import arvados_testutil as tutil
from test_stream import StreamFileReaderTestCase, StreamRetryTestMixin

class ArvadosFileWriterTestCase(unittest.TestCase):
    class MockKeep(object):
        def __init__(self, blocks):
            self.blocks = blocks
            self.requests = []
        def get(self, locator, num_retries=0, cache_only=False):
            self.requests.append(locator)
            return self.blocks.get(locator)
        def put(self, data):
            pdh = "%s+%i" % (hashlib.md5(data).hexdigest(), len(data))
            self.blocks[pdh] = str(data)
            return pdh

    class MockApi(object):
        def __init__(self, b, r):
            self.b = b
            self.r = r
        class MockCollections(object):
            def __init__(self, b, r):
                self.b = b
                self.r = r
            class Execute(object):
                def __init__(self, r):
                    self.r = r
                def execute(self, num_retries=None):
                    return self.r
            def create(self, ensure_unique_name=False, body=None):
                if body != self.b:
                    raise Exception("Body %s does not match expectation %s" % (body, self.b))
                return ArvadosFileWriterTestCase.MockApi.MockCollections.Execute(self.r)
            def update(self, uuid=None, body=None):
                return ArvadosFileWriterTestCase.MockApi.MockCollections.Execute(self.r)
        def collections(self):
            return ArvadosFileWriterTestCase.MockApi.MockCollections(self.b, self.r)


    def test_truncate(self):
        keep = ArvadosFileWriterTestCase.MockKeep({"781e5e245d69b566979b86e28d23f2c7+10": "0123456789"})
        api = ArvadosFileWriterTestCase.MockApi({"name":"test_truncate",
                                                 "manifest_text":". 781e5e245d69b566979b86e28d23f2c7+10 0:8:count.txt\n"},
                                                {"uuid":"zzzzz-4zz18-mockcollection0"})
        with import_manifest('. 781e5e245d69b566979b86e28d23f2c7+10 0:10:count.txt\n',
                             api_client=api, keep=keep, sync=SYNC_EXPLICIT) as c:
            writer = c.open("count.txt", "r+")
            self.assertEqual(writer.size(), 10)
            writer.seek(5)
            self.assertEqual("56789", writer.read(8))
            writer.truncate(8)
            writer.seek(5, os.SEEK_SET)
            self.assertEqual("567", writer.read(8))

            self.assertEqual(None, c._manifest_locator)
            self.assertEqual(True, c.modified())
            c.save_as("test_truncate")
            self.assertEqual("zzzzz-4zz18-mockcollection0", c._manifest_locator)
            self.assertEqual(False, c.modified())

    def test_append(self):
        keep = ArvadosFileWriterTestCase.MockKeep({"781e5e245d69b566979b86e28d23f2c7+10": "0123456789"})
        api = ArvadosFileWriterTestCase.MockApi({"name":"test_append",
                                                 "manifest_text": ". 781e5e245d69b566979b86e28d23f2c7+10 acbd18db4cc2f85cedef654fccc4a4d8+3 0:13:count.txt\n"},
                                                {"uuid":"zzzzz-4zz18-mockcollection0"})
        with import_manifest('. 781e5e245d69b566979b86e28d23f2c7+10 0:10:count.txt\n',
                             api_client=api, keep=keep, sync=SYNC_EXPLICIT) as c:
            writer = c.open("count.txt", "r+")
            writer.seek(5, os.SEEK_SET)
            self.assertEqual("56789", writer.read(8))
            writer.seek(10, os.SEEK_SET)
            writer.write("foo")
            self.assertEqual(writer.size(), 13)
            writer.seek(5, os.SEEK_SET)
            self.assertEqual("56789foo", writer.read(8))

            self.assertEqual(None, c._manifest_locator)
            self.assertEqual(True, c.modified())
            self.assertEqual(None, keep.get("acbd18db4cc2f85cedef654fccc4a4d8+3"))
            c.save_as("test_append")
            self.assertEqual("zzzzz-4zz18-mockcollection0", c._manifest_locator)
            self.assertEqual(False, c.modified())
            self.assertEqual("foo", keep.get("acbd18db4cc2f85cedef654fccc4a4d8+3"))

    def test_write0(self):
        keep = ArvadosFileWriterTestCase.MockKeep({"781e5e245d69b566979b86e28d23f2c7+10": "0123456789"})
        with import_manifest('. 781e5e245d69b566979b86e28d23f2c7+10 0:10:count.txt\n',
                             keep=keep, sync=SYNC_EXPLICIT) as c:
            writer = c.open("count.txt", "r+")
            self.assertEqual("0123456789", writer.readfrom(0, 13))
            writer.seek(0, os.SEEK_SET)
            writer.write("foo")
            self.assertEqual(writer.size(), 10)
            self.assertEqual("foo3456789", writer.readfrom(0, 13))
            self.assertEqual(". acbd18db4cc2f85cedef654fccc4a4d8+3 781e5e245d69b566979b86e28d23f2c7+10 0:3:count.txt 6:7:count.txt\n", export_manifest(c))

    def test_write1(self):
        keep = ArvadosFileWriterTestCase.MockKeep({"781e5e245d69b566979b86e28d23f2c7+10": "0123456789"})
        with import_manifest('. 781e5e245d69b566979b86e28d23f2c7+10 0:10:count.txt\n',
                             keep=keep, sync=SYNC_EXPLICIT) as c:
            writer = c.open("count.txt", "r+")
            self.assertEqual("0123456789", writer.readfrom(0, 13))
            writer.seek(3, os.SEEK_SET)
            writer.write("foo")
            self.assertEqual(writer.size(), 10)
            self.assertEqual("012foo6789", writer.readfrom(0, 13))
            self.assertEqual(". 781e5e245d69b566979b86e28d23f2c7+10 acbd18db4cc2f85cedef654fccc4a4d8+3 0:3:count.txt 10:3:count.txt 6:4:count.txt\n", export_manifest(c))

    def test_write2(self):
        keep = ArvadosFileWriterTestCase.MockKeep({"781e5e245d69b566979b86e28d23f2c7+10": "0123456789"})
        with import_manifest('. 781e5e245d69b566979b86e28d23f2c7+10 0:10:count.txt\n',
                             keep=keep, sync=SYNC_EXPLICIT) as c:
            writer = c.open("count.txt", "r+")
            self.assertEqual("0123456789", writer.readfrom(0, 13))
            writer.seek(7, os.SEEK_SET)
            writer.write("foo")
            self.assertEqual(writer.size(), 10)
            self.assertEqual("0123456foo", writer.readfrom(0, 13))
            self.assertEqual(". 781e5e245d69b566979b86e28d23f2c7+10 acbd18db4cc2f85cedef654fccc4a4d8+3 0:7:count.txt 10:3:count.txt\n", export_manifest(c))

    def test_write3(self):
        keep = ArvadosFileWriterTestCase.MockKeep({"781e5e245d69b566979b86e28d23f2c7+10": "0123456789"})
        with import_manifest('. 781e5e245d69b566979b86e28d23f2c7+10 0:10:count.txt 0:10:count.txt\n',
                             keep=keep, sync=SYNC_EXPLICIT) as c:
            writer = c.open("count.txt", "r+")
            self.assertEqual("012345678901234", writer.readfrom(0, 15))
            writer.seek(7, os.SEEK_SET)
            writer.write("foobar")
            self.assertEqual(writer.size(), 20)
            self.assertEqual("0123456foobar34", writer.readfrom(0, 15))
            self.assertEqual(". 781e5e245d69b566979b86e28d23f2c7+10 3858f62230ac3c915f300c664312c63f+6 0:7:count.txt 10:6:count.txt 3:7:count.txt\n", export_manifest(c))

    def test_write4(self):
        keep = ArvadosFileWriterTestCase.MockKeep({"781e5e245d69b566979b86e28d23f2c7+10": "0123456789"})
        with import_manifest('. 781e5e245d69b566979b86e28d23f2c7+10 0:4:count.txt 0:4:count.txt 0:4:count.txt',
                             keep=keep, sync=SYNC_EXPLICIT) as c:
            writer = c.open("count.txt", "r+")
            self.assertEqual("012301230123", writer.readfrom(0, 15))
            writer.seek(2, os.SEEK_SET)
            writer.write("abcdefg")
            self.assertEqual(writer.size(), 12)
            self.assertEqual("01abcdefg123", writer.readfrom(0, 15))
            self.assertEqual(". 781e5e245d69b566979b86e28d23f2c7+10 7ac66c0f148de9519b8bd264312c4d64+7 0:2:count.txt 10:7:count.txt 1:3:count.txt\n", export_manifest(c))

    def test_write_large(self):
        keep = ArvadosFileWriterTestCase.MockKeep({})
        api = ArvadosFileWriterTestCase.MockApi({"name":"test_write_large",
                                                 "manifest_text": ". a5de24f4417cfba9d5825eadc2f4ca49+67108000 598cc1a4ccaef8ab6e4724d87e675d78+32892000 0:100000000:count.txt\n"},
                                                {"uuid":"zzzzz-4zz18-mockcollection0"})
        with import_manifest('. ' + arvados.config.EMPTY_BLOCK_LOCATOR + ' 0:0:count.txt',
                             api_client=api, keep=keep, sync=SYNC_EXPLICIT) as c:
            writer = c.open("count.txt", "r+")
            text = ''.join(["0123456789" for a in xrange(0, 100)])
            for b in xrange(0, 100000):
                writer.write(text)
            self.assertEqual(writer.size(), 100000000)

            self.assertEqual(None, c._manifest_locator)
            self.assertEqual(True, c.modified())
            c.save_as("test_write_large")
            self.assertEqual("zzzzz-4zz18-mockcollection0", c._manifest_locator)
            self.assertEqual(False, c.modified())

    def test_write_rewrite0(self):
        keep = ArvadosFileWriterTestCase.MockKeep({})
        with import_manifest('. ' + arvados.config.EMPTY_BLOCK_LOCATOR + ' 0:0:count.txt',
                             keep=keep, sync=SYNC_EXPLICIT) as c:
            writer = c.open("count.txt", "r+")
            for b in xrange(0, 10):
                writer.seek(0, os.SEEK_SET)
                writer.write("0123456789")
            writer.arvadosfile._repack_writes()
            self.assertEqual(writer.size(), 10)
            self.assertEqual("0123456789", writer.readfrom(0, 20))
            self.assertEqual(". 781e5e245d69b566979b86e28d23f2c7+10 0:10:count.txt\n", export_manifest(c))

    def test_write_rewrite1(self):
        keep = ArvadosFileWriterTestCase.MockKeep({"781e5e245d69b566979b86e28d23f2c7+10": "0123456789"})
        with import_manifest('. 781e5e245d69b566979b86e28d23f2c7+10 0:10:count.txt',
                             keep=keep, sync=SYNC_EXPLICIT) as c:
            writer = c.open("count.txt", "r+")
            for b in xrange(0, 10):
                writer.seek(10, os.SEEK_SET)
                writer.write("abcdefghij")
            writer.arvadosfile._repack_writes()
            self.assertEqual(writer.size(), 20)
            self.assertEqual("0123456789abcdefghij", writer.readfrom(0, 20))
            self.assertEqual(". 781e5e245d69b566979b86e28d23f2c7+10 a925576942e94b2ef57a066101b48876+10 0:20:count.txt\n", export_manifest(c))

    def test_write_rewrite2(self):
        keep = ArvadosFileWriterTestCase.MockKeep({"781e5e245d69b566979b86e28d23f2c7+10": "0123456789"})
        with import_manifest('. 781e5e245d69b566979b86e28d23f2c7+10 0:10:count.txt',
                             keep=keep, sync=SYNC_EXPLICIT) as c:
            writer = c.open("count.txt", "r+")
            for b in xrange(0, 10):
                writer.seek(5, os.SEEK_SET)
                writer.write("abcdefghij")
            writer.arvadosfile._repack_writes()
            self.assertEqual(writer.size(), 15)
            self.assertEqual("01234abcdefghij", writer.readfrom(0, 20))
            self.assertEqual(". 781e5e245d69b566979b86e28d23f2c7+10 a925576942e94b2ef57a066101b48876+10 0:5:count.txt 10:10:count.txt\n", export_manifest(c))

    def test_write_large_rewrite0(self):
        keep = ArvadosFileWriterTestCase.MockKeep({})
        api = ArvadosFileWriterTestCase.MockApi({"name":"test_write_large",
                                                 "manifest_text": ". 37400a68af9abdd76ca5bf13e819e42a+32892003 a5de24f4417cfba9d5825eadc2f4ca49+67108000 32892000:3:count.txt 32892006:67107997:count.txt 0:32892000:count.txt\n"},
                                                {"uuid":"zzzzz-4zz18-mockcollection0"})
        with import_manifest('. ' + arvados.config.EMPTY_BLOCK_LOCATOR + ' 0:0:count.txt',
                             api_client=api, keep=keep, sync=SYNC_EXPLICIT) as c:
            writer = c.open("count.txt", "r+")
            text = ''.join(["0123456789" for a in xrange(0, 100)])
            for b in xrange(0, 100000):
                writer.write(text)
            writer.seek(0, os.SEEK_SET)
            writer.write("foo")
            self.assertEqual(writer.size(), 100000000)

            self.assertEqual(None, c._manifest_locator)
            self.assertEqual(True, c.modified())
            c.save_as("test_write_large")
            self.assertEqual("zzzzz-4zz18-mockcollection0", c._manifest_locator)
            self.assertEqual(False, c.modified())

    def test_create(self):
        keep = ArvadosFileWriterTestCase.MockKeep({})
        api = ArvadosFileWriterTestCase.MockApi({"name":"test_create",
                                                 "manifest_text":". 2e9ec317e197819358fbc43afca7d837+8 0:8:count.txt\n"},
                                                {"uuid":"zzzzz-4zz18-mockcollection0"})
        with arvados.Collection(api_client=api, keep_client=keep, sync=SYNC_EXPLICIT) as c:
            writer = c.open("count.txt", "w+")
            self.assertEqual(writer.size(), 0)
            writer.write("01234567")
            self.assertEqual(writer.size(), 8)

            self.assertEqual(None, c._manifest_locator)
            self.assertEqual(True, c.modified())
            self.assertEqual(None, keep.get("2e9ec317e197819358fbc43afca7d837+8"))
            c.save_as("test_create")
            self.assertEqual("zzzzz-4zz18-mockcollection0", c._manifest_locator)
            self.assertEqual(False, c.modified())
            self.assertEqual("01234567", keep.get("2e9ec317e197819358fbc43afca7d837+8"))


    def test_create_subdir(self):
        keep = ArvadosFileWriterTestCase.MockKeep({})
        api = ArvadosFileWriterTestCase.MockApi({"name":"test_create",
                                                 "manifest_text":"./foo/bar 2e9ec317e197819358fbc43afca7d837+8 0:8:count.txt\n"},
                                                {"uuid":"zzzzz-4zz18-mockcollection0"})
        with arvados.Collection(api_client=api, keep_client=keep, sync=SYNC_EXPLICIT) as c:
            writer = c.open("foo/bar/count.txt", "w+")
            writer.write("01234567")
            c.save_as("test_create")

    def test_overwrite(self):
        keep = ArvadosFileWriterTestCase.MockKeep({"781e5e245d69b566979b86e28d23f2c7+10": "0123456789"})
        api = ArvadosFileWriterTestCase.MockApi({"name":"test_overwrite",
                                                 "manifest_text":". 2e9ec317e197819358fbc43afca7d837+8 0:8:count.txt\n"},
                                                {"uuid":"zzzzz-4zz18-mockcollection0"})
        with import_manifest('. 781e5e245d69b566979b86e28d23f2c7+10 0:10:count.txt\n',
                             api_client=api, keep=keep, sync=SYNC_EXPLICIT) as c:
            writer = c.open("count.txt", "w+")
            self.assertEqual(writer.size(), 0)
            writer.write("01234567")
            self.assertEqual(writer.size(), 8)

            self.assertEqual(None, c._manifest_locator)
            self.assertEqual(True, c.modified())
            c.save_as("test_overwrite")
            self.assertEqual("zzzzz-4zz18-mockcollection0", c._manifest_locator)
            self.assertEqual(False, c.modified())

    def test_file_not_found(self):
        with import_manifest('. 781e5e245d69b566979b86e28d23f2c7+10 0:10:count.txt\n') as c:
            with self.assertRaises(IOError):
                writer = c.open("nocount.txt", "r")

    def test_cannot_open_directory(self):
        with import_manifest('. 781e5e245d69b566979b86e28d23f2c7+10 0:10:count.txt\n') as c:
            with self.assertRaises(IOError):
                writer = c.open(".", "r")

    def test_create_multiple(self):
        keep = ArvadosFileWriterTestCase.MockKeep({})
        api = ArvadosFileWriterTestCase.MockApi({"name":"test_create_multiple",
                                                 "manifest_text":". 2e9ec317e197819358fbc43afca7d837+8 e8dc4081b13434b45189a720b77b6818+8 0:8:count1.txt 8:8:count2.txt\n"},
                                                {"uuid":"zzzzz-4zz18-mockcollection0"})
        with arvados.Collection(api_client=api, keep_client=keep, sync=SYNC_EXPLICIT) as c:
            w1 = c.open("count1.txt", "w")
            w2 = c.open("count2.txt", "w")
            w1.write("01234567")
            w2.write("abcdefgh")
            self.assertEqual(w1.size(), 8)
            self.assertEqual(w2.size(), 8)

            self.assertEqual(None, c._manifest_locator)
            self.assertEqual(True, c.modified())
            self.assertEqual(None, keep.get("2e9ec317e197819358fbc43afca7d837+8"))
            c.save_as("test_create_multiple")
            self.assertEqual("zzzzz-4zz18-mockcollection0", c._manifest_locator)
            self.assertEqual(False, c.modified())
            self.assertEqual("01234567", keep.get("2e9ec317e197819358fbc43afca7d837+8"))

    def test_remove(self):
        with import_manifest('. 781e5e245d69b566979b86e28d23f2c7+10 0:10:count1.txt 0:10:count2.txt\n', sync=SYNC_EXPLICIT) as c:
            self.assertEqual(". 781e5e245d69b566979b86e28d23f2c7+10 0:10:count1.txt 0:10:count2.txt\n", export_manifest(c))
            self.assertTrue("count1.txt" in c)
            c.remove("count1.txt")
            self.assertFalse("count1.txt" in c)
            self.assertEqual(". 781e5e245d69b566979b86e28d23f2c7+10 0:10:count2.txt\n", export_manifest(c))

    def test_remove_in_subdir(self):
        with import_manifest('. 781e5e245d69b566979b86e28d23f2c7+10 0:10:count1.txt\n./foo 781e5e245d69b566979b86e28d23f2c7+10 0:10:count2.txt\n', sync=SYNC_EXPLICIT) as c:
            c.remove("foo/count2.txt")
            self.assertEqual(". 781e5e245d69b566979b86e28d23f2c7+10 0:10:count1.txt\n", export_manifest(c))

    def test_remove_empty_subdir(self):
        with import_manifest('. 781e5e245d69b566979b86e28d23f2c7+10 0:10:count1.txt\n./foo 781e5e245d69b566979b86e28d23f2c7+10 0:10:count2.txt\n', sync=SYNC_EXPLICIT) as c:
            c.remove("foo/count2.txt")
            c.remove("foo")
            self.assertEqual(". 781e5e245d69b566979b86e28d23f2c7+10 0:10:count1.txt\n", export_manifest(c))

    def test_remove_empty_subdir(self):
        with import_manifest('. 781e5e245d69b566979b86e28d23f2c7+10 0:10:count1.txt\n./foo 781e5e245d69b566979b86e28d23f2c7+10 0:10:count2.txt\n', sync=SYNC_EXPLICIT) as c:
            with self.assertRaises(IOError):
                c.remove("foo")
            c.remove("foo", rm_r=True)
            self.assertEqual(". 781e5e245d69b566979b86e28d23f2c7+10 0:10:count1.txt\n", export_manifest(c))

    def test_prefetch(self):
        keep = ArvadosFileWriterTestCase.MockKeep({"2e9ec317e197819358fbc43afca7d837+8": "01234567", "e8dc4081b13434b45189a720b77b6818+8": "abcdefgh"})
        with import_manifest(". 2e9ec317e197819358fbc43afca7d837+8 e8dc4081b13434b45189a720b77b6818+8 0:16:count.txt\n", keep=keep) as c:
            r = c.open("count.txt", "r")
            self.assertEqual("0123", r.read(4))
        self.assertTrue("2e9ec317e197819358fbc43afca7d837+8" in keep.requests)
        self.assertTrue("e8dc4081b13434b45189a720b77b6818+8" in keep.requests)

class ArvadosFileReaderTestCase(StreamFileReaderTestCase):
    class MockParent(object):
        class MockBlockMgr(object):
            def __init__(self, blocks, nocache):
                self.blocks = blocks
                self.nocache = nocache

            def block_prefetch(self, loc):
                pass

            def get_block(self, loc, num_retries=0, cache_only=False):
                if self.nocache and cache_only:
                    return None
                return self.blocks[loc]

        def __init__(self, blocks, nocache):
            self.blocks = blocks
            self.nocache = nocache

        def _my_block_manager(self):
            return ArvadosFileReaderTestCase.MockParent.MockBlockMgr(self.blocks, self.nocache)

        def sync_mode(self):
            return SYNC_READONLY

    def make_count_reader(self, nocache=False):
        stream = []
        n = 0
        blocks = {}
        for d in ['01234', '34567', '67890']:
            loc = '{}+{}'.format(hashlib.md5(d).hexdigest(), len(d))
            blocks[loc] = d
            stream.append(Range(loc, n, len(d)))
            n += len(d)
        af = ArvadosFile(ArvadosFileReaderTestCase.MockParent(blocks, nocache), stream=stream, segments=[Range(1, 0, 3), Range(6, 3, 3), Range(11, 6, 3)])
        return ArvadosFileReader(af, "count.txt")

    def test_read_returns_first_block(self):
        # read() calls will be aligned on block boundaries - see #3663.
        sfile = self.make_count_reader(nocache=True)
        self.assertEqual('123', sfile.read(10))

    def test_successive_reads(self):
        sfile = self.make_count_reader(nocache=True)
        for expect in ['123', '456', '789', '']:
            self.assertEqual(expect, sfile.read(10))

    def test_tell_after_block_read(self):
        sfile = self.make_count_reader(nocache=True)
        sfile.read(5)
        self.assertEqual(3, sfile.tell())


class ArvadosFileReadTestCase(unittest.TestCase, StreamRetryTestMixin):
    def reader_for(self, coll_name, **kwargs):
        stream = []
        segments = []
        n = 0
        for d in self.manifest_for(coll_name).split():
            try:
                k = KeepLocator(d)
                segments.append(Range(n, n, k.size))
                stream.append(Range(d, n, k.size))
                n += k.size
            except ValueError:
                pass
        col = arvados.Collection(keep_client=self.keep_client())
        col._my_block_manager().prefetch_enabled = False
        af = ArvadosFile(col,
                         stream=stream,
                         segments=segments)
        return ArvadosFileReader(af, "test", **kwargs)

    def read_for_test(self, reader, byte_count, **kwargs):
        return reader.read(byte_count, **kwargs)


class ArvadosFileReadFromTestCase(ArvadosFileReadTestCase):
    def read_for_test(self, reader, byte_count, **kwargs):
        return reader.readfrom(0, byte_count, **kwargs)


class ArvadosFileReadAllTestCase(ArvadosFileReadTestCase):
    def read_for_test(self, reader, byte_count, **kwargs):
        return ''.join(reader.readall(**kwargs))


class ArvadosFileReadAllDecompressedTestCase(ArvadosFileReadTestCase):
    def read_for_test(self, reader, byte_count, **kwargs):
        return ''.join(reader.readall_decompressed(**kwargs))


class ArvadosFileReadlinesTestCase(ArvadosFileReadTestCase):
    def read_for_test(self, reader, byte_count, **kwargs):
        return ''.join(reader.readlines(**kwargs))

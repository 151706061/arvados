import bz2
import collections
import hashlib
import os
import re
import zlib
import threading
import functools

from .arvfile import ArvadosFileBase
from arvados.retry import retry_method
from keep import *
import config
import errors

LOCATOR = 0
BLOCKSIZE = 1
OFFSET = 2
SEGMENTSIZE = 3

def first_block(data_locators, range_start, range_size, debug=False):
    block_start = 0L

    # range_start/block_start is the inclusive lower bound
    # range_end/block_end is the exclusive upper bound

    hi = len(data_locators)
    lo = 0
    i = int((hi + lo) / 2)
    block_size = data_locators[i][BLOCKSIZE]
    block_start = data_locators[i][OFFSET]
    block_end = block_start + block_size
    if debug: print '---'

    # perform a binary search for the first block
    # assumes that all of the blocks are contigious, so range_start is guaranteed
    # to either fall into the range of a block or be outside the block range entirely
    while not (range_start >= block_start and range_start < block_end):
        if lo == i:
            # must be out of range, fail
            return None
        if range_start > block_start:
            lo = i
        else:
            hi = i
        i = int((hi + lo) / 2)
        if debug: print lo, i, hi
        block_size = data_locators[i][BLOCKSIZE]
        block_start = data_locators[i][OFFSET]
        block_end = block_start + block_size

    return i

def locators_and_ranges(data_locators, range_start, range_size, debug=False):
    '''
    Get blocks that are covered by the range
    data_locators: list of [locator, block_size, block_start], assumes that blocks are in order and contigous
    range_start: start of range
    range_size: size of range
    returns list of [block locator, blocksize, segment offset, segment size] that satisfies the range
    '''
    if range_size == 0:
        return []
    resp = []
    range_start = long(range_start)
    range_size = long(range_size)
    range_end = range_start + range_size

    i = first_block(data_locators, range_start, range_size, debug)
    if i is None:
        return []

    while i < len(data_locators):
        locator, block_size, block_start = data_locators[i]
        block_end = block_start + block_size
        if debug:
            print locator, "range_start", range_start, "block_start", block_start, "range_end", range_end, "block_end", block_end
        if range_end <= block_start:
            # range ends before this block starts, so don't look at any more locators
            break

        #if range_start >= block_end:
            # range starts after this block ends, so go to next block
            # we should always start at the first block due to the binary above, so this test is redundant
            #next

        if range_start >= block_start and range_end <= block_end:
            # range starts and ends in this block
            resp.append([locator, block_size, range_start - block_start, range_size])
        elif range_start >= block_start and range_end > block_end:
            # range starts in this block
            resp.append([locator, block_size, range_start - block_start, block_end - range_start])
        elif range_start < block_start and range_end > block_end:
            # range starts in a previous block and extends to further blocks
            resp.append([locator, block_size, 0L, block_size])
        elif range_start < block_start and range_end <= block_end:
            # range starts in a previous block and ends in this block
            resp.append([locator, block_size, 0L, range_end - block_start])
        block_start = block_end
        i += 1
    return resp

def replace_range(data_locators, range_start, range_size, new_locator, debug=False):
    '''
    Replace a range with a new block.
    data_locators: list of [locator, block_size, block_start], assumes that blocks are in order and contigous
    range_start: start of range
    range_size: size of range
    new_locator: locator for new block to be inserted
    !!! data_locators will be updated in place !!!
    '''
    if range_size == 0:
        return

    range_start = long(range_start)
    range_size = long(range_size)
    range_end = range_start + range_size

    last = data_locators[-1]
    if (last[OFFSET]+last[BLOCKSIZE]) == range_start:
        # append new block
        data_locators.append([new_locator, range_size, range_start])
        return

    i = first_block(data_locators, range_start, range_size, debug)
    if i is None:
        return

    while i < len(data_locators):
        locator, block_size, block_start = data_locators[i]
        block_end = block_start + block_size
        if debug:
            print locator, "range_start", range_start, "block_start", block_start, "range_end", range_end, "block_end", block_end
        if range_end <= block_start:
            # range ends before this block starts, so don't look at any more locators
            break

        #if range_start >= block_end:
            # range starts after this block ends, so go to next block
            # we should always start at the first block due to the binary above, so this test is redundant
            #next

        if range_start >= block_start and range_end <= block_end:
            # range starts and ends in this block
            # split block into 3 pieces
            #resp.append([locator, block_size, range_start - block_start, range_size])
            pass
        elif range_start >= block_start and range_end > block_end:
            # range starts in this block
            # split block into 2 pieces
            #resp.append([locator, block_size, range_start - block_start, block_end - range_start])
            pass
        elif range_start < block_start and range_end > block_end:
            # range starts in a previous block and extends to further blocks
            # zero out this block
            #resp.append([locator, block_size, 0L, block_size])
            pass
        elif range_start < block_start and range_end <= block_end:
            # range starts in a previous block and ends in this block
            # split into 2 pieces
            #resp.append([locator, block_size, 0L, range_end - block_start])
            pass
        block_start = block_end
        i += 1


def split(path):
    """split(path) -> streamname, filename

    Separate the stream name and file name in a /-separated stream path.
    If no stream name is available, assume '.'.
    """
    try:
        stream_name, file_name = path.rsplit('/', 1)
    except ValueError:  # No / in string
        stream_name, file_name = '.', path
    return stream_name, file_name

class StreamFileReader(ArvadosFileBase):
    class _NameAttribute(str):
        # The Python file API provides a plain .name attribute.
        # Older SDK provided a name() method.
        # This class provides both, for maximum compatibility.
        def __call__(self):
            return self


    def __init__(self, stream, segments, name):
        super(StreamFileReader, self).__init__(self._NameAttribute(name), 'rb')
        self._stream = stream
        self.segments = segments
        self._filepos = 0L
        self.num_retries = stream.num_retries
        self._readline_cache = (None, None)

    def __iter__(self):
        while True:
            data = self.readline()
            if not data:
                break
            yield data

    def decompressed_name(self):
        return re.sub('\.(bz2|gz)$', '', self.name)

    def stream_name(self):
        return self._stream.name()

    @ArvadosFileBase._before_close
    def seek(self, pos, whence=os.SEEK_CUR):
        if whence == os.SEEK_CUR:
            pos += self._filepos
        elif whence == os.SEEK_END:
            pos += self.size()
        self._filepos = min(max(pos, 0L), self._size())

    def tell(self):
        return self._filepos

    def _size(self):
        n = self.segments[-1]
        return n[OFFSET] + n[BLOCKSIZE]

    def size(self):
        return self._size()

    @ArvadosFileBase._before_close
    @retry_method
    def read(self, size, num_retries=None):
        """Read up to 'size' bytes from the stream, starting at the current file position"""
        if size == 0:
            return ''

        data = ''
        available_chunks = locators_and_ranges(self.segments, self._filepos, size)
        if available_chunks:
            locator, blocksize, segmentoffset, segmentsize = available_chunks[0]
            data = self._stream._readfrom(locator+segmentoffset, segmentsize,
                                         num_retries=num_retries)

        self._filepos += len(data)
        return data

    @ArvadosFileBase._before_close
    @retry_method
    def readfrom(self, start, size, num_retries=None):
        """Read up to 'size' bytes from the stream, starting at 'start'"""
        if size == 0:
            return ''

        data = []
        for locator, blocksize, segmentoffset, segmentsize in locators_and_ranges(self.segments, start, size):
            data.append(self._stream._readfrom(locator+segmentoffset, segmentsize,
                                              num_retries=num_retries))
        return ''.join(data)

    @ArvadosFileBase._before_close
    @retry_method
    def readall(self, size=2**20, num_retries=None):
        while True:
            data = self.read(size, num_retries=num_retries)
            if data == '':
                break
            yield data

    @ArvadosFileBase._before_close
    @retry_method
    def readline(self, size=float('inf'), num_retries=None):
        cache_pos, cache_data = self._readline_cache
        if self.tell() == cache_pos:
            data = [cache_data]
        else:
            data = ['']
        data_size = len(data[-1])
        while (data_size < size) and ('\n' not in data[-1]):
            next_read = self.read(2 ** 20, num_retries=num_retries)
            if not next_read:
                break
            data.append(next_read)
            data_size += len(next_read)
        data = ''.join(data)
        try:
            nextline_index = data.index('\n') + 1
        except ValueError:
            nextline_index = len(data)
        nextline_index = min(nextline_index, size)
        self._readline_cache = (self.tell(), data[nextline_index:])
        return data[:nextline_index]

    @ArvadosFileBase._before_close
    @retry_method
    def decompress(self, decompress, size, num_retries=None):
        for segment in self.readall(size, num_retries):
            data = decompress(segment)
            if data:
                yield data

    @ArvadosFileBase._before_close
    @retry_method
    def readall_decompressed(self, size=2**20, num_retries=None):
        self.seek(0)
        if self.name.endswith('.bz2'):
            dc = bz2.BZ2Decompressor()
            return self.decompress(dc.decompress, size,
                                   num_retries=num_retries)
        elif self.name.endswith('.gz'):
            dc = zlib.decompressobj(16+zlib.MAX_WBITS)
            return self.decompress(lambda segment: dc.decompress(dc.unconsumed_tail + segment),
                                   size, num_retries=num_retries)
        else:
            return self.readall(size, num_retries=num_retries)

    @ArvadosFileBase._before_close
    @retry_method
    def readlines(self, sizehint=float('inf'), num_retries=None):
        data = []
        data_size = 0
        for s in self.readall(num_retries=num_retries):
            data.append(s)
            data_size += len(s)
            if data_size >= sizehint:
                break
        return ''.join(data).splitlines(True)

    def as_manifest(self):
        manifest_text = ['.']
        manifest_text.extend([d[LOCATOR] for d in self._stream._data_locators])
        manifest_text.extend(["{}:{}:{}".format(seg[LOCATOR], seg[BLOCKSIZE], self.name().replace(' ', '\\040')) for seg in self.segments])
        return arvados.CollectionReader(' '.join(manifest_text) + '\n').manifest_text(normalize=True)


class StreamReader(object):
    def __init__(self, tokens, keep=None, debug=False, _empty=False,
                 num_retries=0):
        self._stream_name = None
        self._data_locators = []
        self._files = collections.OrderedDict()
        self._keep = keep
        self.num_retries = num_retries

        streamoffset = 0L

        # parse stream
        for tok in tokens:
            if debug: print 'tok', tok
            if self._stream_name is None:
                self._stream_name = tok.replace('\\040', ' ')
                continue

            s = re.match(r'^[0-9a-f]{32}\+(\d+)(\+\S+)*$', tok)
            if s:
                blocksize = long(s.group(1))
                self._data_locators.append([tok, blocksize, streamoffset])
                streamoffset += blocksize
                continue

            s = re.search(r'^(\d+):(\d+):(\S+)', tok)
            if s:
                pos = long(s.group(1))
                size = long(s.group(2))
                name = s.group(3).replace('\\040', ' ')
                if name not in self._files:
                    self._files[name] = StreamFileReader(self, [[pos, size, 0]], name)
                else:
                    filereader = self._files[name]
                    filereader.segments.append([pos, size, filereader.size()])
                continue

            raise errors.SyntaxError("Invalid manifest format")

    def name(self):
        return self._stream_name

    def files(self):
        return self._files

    def all_files(self):
        return self._files.values()

    def _size(self):
        n = self._data_locators[-1]
        return n[OFFSET] + n[BLOCKSIZE]

    def size(self):
        return self._size()

    def locators_and_ranges(self, range_start, range_size):
        return locators_and_ranges(self._data_locators, range_start, range_size)

    def _keepget(self, locator, num_retries=None):
        return self._keep.get(locator, num_retries=num_retries)

    @retry_method
    def readfrom(self, start, size, num_retries=None):
        self._readfrom(start, size, num_retries=num_retries)

    def _readfrom(self, start, size, num_retries=None):
        """Read up to 'size' bytes from the stream, starting at 'start'"""
        if size == 0:
            return ''
        if self._keep is None:
            self._keep = KeepClient(num_retries=self.num_retries)
        data = []
        for locator, blocksize, segmentoffset, segmentsize in locators_and_ranges(self._data_locators, start, size):
            data.append(self._keepget(locator, num_retries=num_retries)[segmentoffset:segmentoffset+segmentsize])
        return ''.join(data)

    def manifest_text(self, strip=False):
        manifest_text = [self.name().replace(' ', '\\040')]
        if strip:
            for d in self._data_locators:
                m = re.match(r'^[0-9a-f]{32}\+\d+', d[LOCATOR])
                manifest_text.append(m.group(0))
        else:
            manifest_text.extend([d[LOCATOR] for d in self._data_locators])
        manifest_text.extend([' '.join(["{}:{}:{}".format(seg[LOCATOR], seg[BLOCKSIZE], f.name().replace(' ', '\\040'))
                                        for seg in f.segments])
                              for f in self._files.values()])
        return ' '.join(manifest_text) + '\n'

class BufferBlock(object):
    def __init__(self, locator, streamoffset):
        self.locator = locator
        self.buffer_block = bytearray(config.KEEP_BLOCK_SIZE)
        self.buffer_view = memoryview(self.buffer_block)
        self.write_pointer = 0
        self.locator_list_entry = [locator, 0, streamoffset]

    def append(self, data):
        self.buffer_view[self.write_pointer:self.write_pointer+len(data)] = data
        self.write_pointer += len(data)
        self.locator_list_entry[1] = self.write_pointer

class StreamWriter(StreamReader):
    def __init__(self, tokens, keep=None, debug=False, _empty=False,
                 num_retries=0):
        super(StreamWriter, self).__init__(tokens, keep, debug, _empty, num_retries)

        if len(self._files) != 1:
            raise AssertionError("StreamWriter can only have one file at a time")
        sr = self._files.popitem()[1]
        self._files[sr.name] = StreamFileWriter(self, sr.segments, sr.name)

        self.mutex = threading.Lock()
        self.current_bblock = None
        self.bufferblocks = {}

    # wrap superclass methods in mutex
    def _proxy_method(name):
        method = getattr(StreamReader, name)
        @functools.wraps(method, ('__name__', '__doc__'))
        def wrapper(self, *args, **kwargs):
            with self.mutex:
                return method(self, *args, **kwargs)
        return wrapper

    for _method_name in ['name', 'files', 'all_files', 'size', 'locators_and_ranges', 'readfrom', 'manifest_text']:
        locals()[_method_name] = _proxy_method(_method_name)

    def _keepget(self, locator, num_retries=None):
        if locator in self.bufferblocks:
            bb = self.bufferblocks[locator]
            return str(bb.buffer_block[0:bb.write_pointer])
        else:
            return self._keep.get(locator, num_retries=num_retries)

    def _append(self, data):
        if self.current_bblock is None:
            last = self._data_locators[-1]
            streamoffset = last[OFFSET] + last[BLOCKSIZE]
            self.current_bblock = BufferBlock("bufferblock%i" % len(self.bufferblocks), streamoffset)
            self.bufferblocks[self.current_bblock.locator] = self.current_bblock
            self._data_locators.append(self.current_bblock.locator_list_entry)
        self.current_bblock.append(data)

    def append(self, data):
        with self.mutex:
            self._append(data)

class StreamFileWriter(StreamFileReader):
    def __init__(self, stream, segments, name):
        super(StreamFileWriter, self).__init__(stream, segments, name)
        self.mode = 'wb'

    # wrap superclass methods in mutex
    def _proxy_method(name):
        method = getattr(StreamFileReader, name)
        @functools.wraps(method, ('__name__', '__doc__'))
        def wrapper(self, *args, **kwargs):
            with self._stream.mutex:
                return method(self, *args, **kwargs)
        return wrapper

    for _method_name in ['__iter__', 'seek', 'tell', 'size', 'read', 'readfrom', 'readall', 'readline', 'decompress', 'readall_decompressed', 'readlines', 'as_manifest']:
        locals()[_method_name] = _proxy_method(_method_name)

    def truncate(self, size=None):
        with self._stream.mutex:
            if size is None:
                size = self._filepos

            segs = locators_and_ranges(self.segments, 0, size)

            newstream = []
            self.segments = []
            streamoffset = 0L
            fileoffset = 0L

            for seg in segs:
                for locator, blocksize, segmentoffset, segmentsize in locators_and_ranges(self._stream._data_locators, seg[LOCATOR]+seg[OFFSET], seg[SEGMENTSIZE]):
                    newstream.append([locator, blocksize, streamoffset])
                    self.segments.append([streamoffset+segmentoffset, segmentsize, fileoffset])
                    streamoffset += blocksize
                    fileoffset += segmentsize
            if len(newstream) == 0:
                newstream.append(config.EMPTY_BLOCK_LOCATOR)
                self.segments.append([0, 0, 0])
            self._stream._data_locators = newstream
            if self._filepos > fileoffset:
                self._filepos = fileoffset

    def _writeto(self, offset, data):
        self._stream._append(data)
        replace_range(self.segments, self._filepos, len(data), self._stream._size()-len(data))
        self._filepos += len(data)

    def writeto(self, offset, data):
        with self._stream.mutex:
            self._writeto(offset, data)

    def write(self, data):
        with self._stream.mutex:
            self._writeto(self._filepos, data)
            self._filepos += len(data)

    def writelines(self, seq):
        with self._stream.mutex:
            for s in seq:
                self._writeto(self._filepos, s)
                self._filepos += len(s)

    def flush(self):
        pass

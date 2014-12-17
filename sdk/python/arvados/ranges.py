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
    Replace a file segment range with a new segment.
    data_locators: list of [locator, segment_size, segment_start], assumes that segments are in order and contigous
    range_start: start of range
    range_size: size of range
    new_locator: locator for new segment to be inserted
    !!! data_locators will be updated in place !!!
    '''
    if range_size == 0:
        return

    range_start = long(range_start)
    range_size = long(range_size)
    range_end = range_start + range_size

    last = data_locators[-1]
    if (last[OFFSET]+last[BLOCKSIZE]) == range_start:
        # extend last segment
        last[BLOCKSIZE] += range_size
        return

    i = first_block(data_locators, range_start, range_size, debug)
    if i is None:
        return

    while i < len(data_locators):
        locator, segment_size, segment_start = data_locators[i]
        segment_end = segment_start + segment_size
        if debug:
            print locator, "range_start", range_start, "segment_start", segment_start, "range_end", range_end, "segment_end", segment_end
        if range_end <= segment_start:
            # range ends before this segment starts, so don't look at any more locators
            break

        #if range_start >= segment_end:
            # range starts after this segment ends, so go to next segment
            # we should always start at the first segment due to the binary above, so this test is redundant
            #next

        if range_start >= segment_start and range_end <= segment_end:
            # range starts and ends in this segment
            # split segment into 3 pieces
            if (range_start-segment_start) > 0:
                data_locators[i] = [locator, (range_start-segment_start), segment_start]
                data_locators.insert(i+1, [new_locator, range_size, range_start])
            else:
                data_locators[i] = [new_locator, range_size, range_start]
                i -= 1
            if (segment_end-range_end) > 0:
                data_locators.insert(i+2, [(locator + (range_start-segment_start) + range_size), (segment_end-range_end), range_end])
            return
        elif range_start >= segment_start and range_end > segment_end:
            # range starts in this segment
            # split segment into 2 pieces
            data_locators[i] = [locator, (range_start-segment_start), segment_start]
            data_locators.insert(i+1, [new_locator, range_size, range_start])
            i += 1
        elif range_start < segment_start and range_end > segment_end:
            # range starts in a previous segment and extends to further segments
            # delete this segment
            del data_locators[i]
            i -= 1
        elif range_start < segment_start and range_end <= segment_end:
            # range starts in a previous segment and ends in this segment
            # move the starting point of this segment up, and shrink it.
            data_locators[i] = [locator+(range_end-segment_start), (segment_end-range_end), range_end]
            return
        segment_start = segment_end
        i += 1

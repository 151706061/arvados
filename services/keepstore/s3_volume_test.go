package main

import (
	"bytes"
	"crypto/md5"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/AdRoll/goamz/aws"
	"github.com/AdRoll/goamz/s3"
	"github.com/AdRoll/goamz/s3/s3test"
	check "gopkg.in/check.v1"
)

type TestableS3Volume struct {
	*S3Volume
	server      *s3test.Server
	c           *check.C
	serverClock *fakeClock
}

const (
	TestBucketName = "testbucket"
)

type fakeClock struct {
	now *time.Time
}

func (c *fakeClock) Now() time.Time {
	if c.now == nil {
		return time.Now()
	}
	return *c.now
}

func init() {
	// Deleting isn't safe from races, but if it's turned on
	// anyway we do expect it to pass the generic volume tests.
	s3UnsafeDelete = true
}

func NewTestableS3Volume(c *check.C, raceWindow time.Duration, readonly bool, replication int) *TestableS3Volume {
	clock := &fakeClock{}
	srv, err := s3test.NewServer(&s3test.Config{Clock: clock})
	c.Assert(err, check.IsNil)
	auth := aws.Auth{}
	region := aws.Region{
		Name:                 "test-region-1",
		S3Endpoint:           srv.URL(),
		S3LocationConstraint: true,
	}
	bucket := &s3.Bucket{
		S3:   s3.New(auth, region),
		Name: TestBucketName,
	}
	err = bucket.PutBucket(s3.ACL("private"))
	c.Assert(err, check.IsNil)

	return &TestableS3Volume{
		S3Volume:    NewS3Volume(auth, region, TestBucketName, raceWindow, readonly, replication),
		server:      srv,
		serverClock: clock,
	}
}

var _ = check.Suite(&StubbedS3Suite{})

type StubbedS3Suite struct {
	volumes []*TestableS3Volume
}

func (s *StubbedS3Suite) TestGeneric(c *check.C) {
	DoGenericVolumeTests(c, func(t TB) TestableVolume {
		// Use a negative raceWindow so s3test's 1-second
		// timestamp precision doesn't confuse fixRace.
		return NewTestableS3Volume(c, -2*time.Second, false, 2)
	})
}

func (s *StubbedS3Suite) TestGenericReadOnly(c *check.C) {
	DoGenericVolumeTests(c, func(t TB) TestableVolume {
		return NewTestableS3Volume(c, -2*time.Second, true, 2)
	})
}

func (s *StubbedS3Suite) TestIndex(c *check.C) {
	v := NewTestableS3Volume(c, 0, false, 2)
	v.indexPageSize = 3
	for i := 0; i < 256; i++ {
		v.PutRaw(fmt.Sprintf("%02x%030x", i, i), []byte{102, 111, 111})
	}
	for _, spec := range []struct {
		prefix      string
		expectMatch int
	}{
		{"", 256},
		{"c", 16},
		{"bc", 1},
		{"abc", 0},
	} {
		buf := new(bytes.Buffer)
		err := v.IndexTo(spec.prefix, buf)
		c.Check(err, check.IsNil)

		idx := bytes.SplitAfter(buf.Bytes(), []byte{10})
		c.Check(len(idx), check.Equals, spec.expectMatch+1)
		c.Check(len(idx[len(idx)-1]), check.Equals, 0)
	}
}

func (s *StubbedS3Suite) TestBackendStates(c *check.C) {
	defer func(tl, bs time.Duration) {
		trashLifetime = tl
		blobSignatureTTL = bs
	}(trashLifetime, blobSignatureTTL)
	trashLifetime = time.Hour
	blobSignatureTTL = time.Hour

	v := NewTestableS3Volume(c, 5*time.Minute, false, 2)
	var none time.Time

	putS3Obj := func(t time.Time, key string, data []byte) {
		if t == none {
			return
		}
		v.serverClock.now = &t
		v.Bucket.Put(key, data, "application/octet-stream", s3ACL, s3.Options{})
	}

	t0 := time.Now()
	nextKey := 0
	for _, scenario := range []struct {
		label               string
		dataT               time.Time
		recentT             time.Time
		trashT              time.Time
		canGet              bool
		canTrash            bool
		canGetAfterTrash    bool
		canUntrash          bool
		haveTrashAfterEmpty bool
		freshAfterEmpty     bool
	}{
		{
			"No related objects",
			none, none, none,
			false, false, false, false, false, false,
		},
		{
			// Stored by older version, or there was a
			// race between EmptyTrash and Put: Trash is a
			// no-op even though the data object is very
			// old
			"No recent/X",
			t0.Add(-48 * time.Hour), none, none,
			true, true, true, false, false, false,
		},
		{
			"Not trash, but old enough to be eligible for trash",
			t0.Add(-24 * time.Hour), t0.Add(-2 * time.Hour), none,
			true, true, false, false, false, false,
		},
		{
			"Not trash, and not old enough to be eligible for trash",
			t0.Add(-24 * time.Hour), t0.Add(-30 * time.Minute), none,
			true, true, true, false, false, false,
		},
		{
			"Trashed + untrashed copies exist, due to recent race between Trash and Put",
			t0.Add(-24 * time.Hour), t0.Add(-3 * time.Minute), t0.Add(-2 * time.Minute),
			true, true, true, true, true, false,
		},
		{
			"Trashed + untrashed copies exist, trash nearly eligible for deletion: prone to Trash race",
			t0.Add(-24 * time.Hour), t0.Add(-12 * time.Hour), t0.Add(-59 * time.Minute),
			true, false, true, true, true, false,
		},
		{
			"Trashed + untrashed copies exist, trash is eligible for deletion: prone to Trash race",
			t0.Add(-24 * time.Hour), t0.Add(-12 * time.Hour), t0.Add(-61 * time.Minute),
			true, false, true, true, false, false,
		},
		{
			"Trashed + untrashed copies exist, due to old race between Put and unfinished Trash: emptying trash is unsafe",
			t0.Add(-24 * time.Hour), t0.Add(-12 * time.Hour), t0.Add(-12 * time.Hour),
			true, false, true, true, true, true,
		},
		{
			"Trashed + untrashed copies exist, used to be unsafe to empty, but since made safe by fixRace+Touch",
			t0.Add(-time.Second), t0.Add(-time.Second), t0.Add(-12 * time.Hour),
			true, true, true, true, false, false,
		},
		{
			"Trashed + untrashed copies exist because Trash operation was interrupted (no race)",
			t0.Add(-24 * time.Hour), t0.Add(-24 * time.Hour), t0.Add(-12 * time.Hour),
			true, false, true, true, false, false,
		},
		{
			"Trash, not yet eligible for deletion",
			none, t0.Add(-12 * time.Hour), t0.Add(-time.Minute),
			false, false, false, true, true, false,
		},
		{
			"Trash, not yet eligible for deletion, prone to races",
			none, t0.Add(-12 * time.Hour), t0.Add(-59 * time.Minute),
			false, false, false, true, true, false,
		},
		{
			"Trash, eligible for deletion",
			none, t0.Add(-12 * time.Hour), t0.Add(-2 * time.Hour),
			false, false, false, true, false, false,
		},
		{
			"Erroneously trashed during a race, detected before trashLifetime",
			none, t0.Add(-30 * time.Minute), t0.Add(-29 * time.Minute),
			true, false, true, true, true, false,
		},
		{
			"Erroneously trashed during a race, rescue during EmptyTrash despite reaching trashLifetime",
			none, t0.Add(-90 * time.Minute), t0.Add(-89 * time.Minute),
			true, false, true, true, true, false,
		},
	} {
		c.Log("Scenario: ", scenario.label)

		// We have a few tests to run for each scenario, and
		// the tests are expected to change state. By calling
		// this setup func between tests, we (re)create the
		// scenario as specified, using a new unique block
		// locator to prevent interference from previous
		// tests.

		setupScenario := func() (string, []byte) {
			nextKey++
			blk := []byte(fmt.Sprintf("%d", nextKey))
			loc := fmt.Sprintf("%x", md5.Sum(blk))
			c.Log("\t", loc)
			putS3Obj(scenario.dataT, loc, blk)
			putS3Obj(scenario.recentT, "recent/"+loc, nil)
			putS3Obj(scenario.trashT, "trash/"+loc, blk)
			v.serverClock.now = &t0
			return loc, blk
		}

		loc, blk := setupScenario()
		buf := make([]byte, len(blk))
		_, err := v.Get(loc, buf)
		c.Check(err == nil, check.Equals, scenario.canGet)
		if err != nil {
			c.Check(os.IsNotExist(err), check.Equals, true)
		}

		loc, blk = setupScenario()
		err = v.Trash(loc)
		c.Check(err == nil, check.Equals, scenario.canTrash)
		_, err = v.Get(loc, buf)
		c.Check(err == nil, check.Equals, scenario.canGetAfterTrash)
		if err != nil {
			c.Check(os.IsNotExist(err), check.Equals, true)
		}

		loc, blk = setupScenario()
		err = v.Untrash(loc)
		c.Check(err == nil, check.Equals, scenario.canUntrash)

		loc, blk = setupScenario()
		v.EmptyTrash()
		_, err = v.Bucket.Head("trash/"+loc, nil)
		c.Check(err == nil, check.Equals, scenario.haveTrashAfterEmpty)
		if scenario.freshAfterEmpty {
			t, err := v.Mtime(loc)
			c.Check(err, check.IsNil)
			// new mtime must be current (with an
			// allowance for 1s timestamp precision)
			c.Check(t.After(t0.Add(-time.Second)), check.Equals, true)
		}
	}
}

// PutRaw skips the ContentMD5 test
func (v *TestableS3Volume) PutRaw(loc string, block []byte) {
	err := v.Bucket.Put(loc, block, "application/octet-stream", s3ACL, s3.Options{})
	if err != nil {
		log.Printf("PutRaw: %+v", err)
	}
}

// TouchWithDate turns back the clock while doing a Touch(). We assume
// there are no other operations happening on the same s3test server
// while we do this.
func (v *TestableS3Volume) TouchWithDate(locator string, lastPut time.Time) {
	v.serverClock.now = &lastPut
	err := v.Bucket.Put("recent/"+locator, nil, "application/octet-stream", s3ACL, s3.Options{})
	if err != nil {
		panic(err)
	}
	v.serverClock.now = nil
}

func (v *TestableS3Volume) Teardown() {
	v.server.Quit()
}

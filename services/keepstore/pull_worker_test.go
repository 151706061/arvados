package main

import (
	"bytes"
	"errors"
	"git.curoverse.com/arvados.git/sdk/go/arvadosclient"
	"git.curoverse.com/arvados.git/sdk/go/keepclient"
	. "gopkg.in/check.v1"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

type PullWorkerTestSuite struct{}

// Gocheck boilerplate
func TestPullWorker(t *testing.T) {
	TestingT(t)
}

// Gocheck boilerplate
var _ = Suite(&PullWorkerTestSuite{})

var testPullLists map[string]string
var processedPullLists map[string]string
var readContent string
var readError error
var putContent []byte
var putError error
var currentTestData PullWorkerTestData

const READ_CONTENT = "Hi!"

func RunTestPullWorker(c *C) {
	// Since keepstore does not come into picture in tests,
	// we need to explicitly start the goroutine in tests.
	arv, err := arvadosclient.MakeArvadosClient()
	c.Assert(err, Equals, nil)
	keepClient, err := keepclient.MakeKeepClient(&arv)
	c.Assert(err, Equals, nil)

	pullq = NewWorkQueue()
	go RunPullWorker(pullq, keepClient)
}

func (s *PullWorkerTestSuite) SetUpTest(c *C) {
	readContent = ""
	readError = nil
	putContent = []byte("")
	putError = nil

	// When a new pull request arrives, the old one will be overwritten.
	// This behavior is simulated with delay tests below.
	testPullLists = make(map[string]string)
	processedPullLists = make(map[string]string)
}

func (s *PullWorkerTestSuite) TearDownTest(c *C) {
	time.Sleep(20 * time.Millisecond)
	expectWorkerChannelEmpty(c, pullq.NextItem)

	// give the channel some time to read and process all pull list entries
	//	time.Sleep(1000 * time.Millisecond)
	//	expectWorkerChannelEmpty(c, pullq.NextItem)
	//	c.Assert(len(processedPullLists), Not(Equals), len(testPullLists))

	if currentTestData.read_error {
		c.Assert(readError, NotNil)
	} else {
		c.Assert(readError, IsNil)
		c.Assert(readContent, Equals, READ_CONTENT)
		if currentTestData.put_error {
			c.Assert(putError, NotNil)
		} else {
			c.Assert(putError, IsNil)
			c.Assert(string(putContent), Equals, READ_CONTENT)
		}
	}
}

var first_pull_list = []byte(`[
		{
			"locator":"locator1",
			"servers":[
				"server_1",
				"server_2"
		 	]
		},
    {
			"locator":"locator2",
			"servers":[
				"server_3"
		 	]
		}
	]`)

var second_pull_list = []byte(`[
		{
			"locator":"locator3",
			"servers":[
				"server_1",
        "server_2"
		 	]
		}
	]`)

type PullWorkerTestData struct {
	name          string
	req           RequestTester
	response_code int
	response_body string
	read_content  string
	read_error    bool
	put_error     bool
}

func (s *PullWorkerTestSuite) TestPullWorker_pull_list_with_two_locators(c *C) {
	defer teardown()

	data_manager_token = "DATA MANAGER TOKEN"
	testData := PullWorkerTestData{
		name:          "TestPullWorker_pull_list_with_two_locators",
		req:           RequestTester{"/pull", data_manager_token, "PUT", first_pull_list},
		response_code: http.StatusOK,
		response_body: "Received 2 pull requests\n",
		read_content:  "hello",
		read_error:    false,
		put_error:     false,
	}

	performTest(testData, c)
}

func (s *PullWorkerTestSuite) TestPullWorker_pull_list_with_one_locator(c *C) {
	defer teardown()

	data_manager_token = "DATA MANAGER TOKEN"
	testData := PullWorkerTestData{
		name:          "TestPullWorker_pull_list_with_one_locator",
		req:           RequestTester{"/pull", data_manager_token, "PUT", second_pull_list},
		response_code: http.StatusOK,
		response_body: "Received 1 pull requests\n",
		read_content:  "hola",
		read_error:    false,
		put_error:     false,
	}

	performTest(testData, c)
}

// When a new pull request arrives, the old one will be overwritten.
// Simulate this behavior by inducing delay in GetContent for the delay test(s).
// To ensure this delay test is not the last one executed and
// hence we cannot verify this behavior, let's run the delay test twice.
func (s *PullWorkerTestSuite) TestPullWorker_pull_list_with_one_locator_with_delay_1(c *C) {
	defer teardown()

	data_manager_token = "DATA MANAGER TOKEN"
	testData := PullWorkerTestData{
		name:          "TestPullWorker_pull_list_with_one_locator_with_delay_1",
		req:           RequestTester{"/pull", data_manager_token, "PUT", second_pull_list},
		response_code: http.StatusOK,
		response_body: "Received 1 pull requests\n",
		read_content:  "hola",
		read_error:    false,
		put_error:     false,
	}

	performTest(testData, c)
}

func (s *PullWorkerTestSuite) TestPullWorker_pull_list_with_one_locator_with_delay_2(c *C) {
	defer teardown()

	data_manager_token = "DATA MANAGER TOKEN"
	testData := PullWorkerTestData{
		name:          "TestPullWorker_pull_list_with_one_locator_with_delay_2",
		req:           RequestTester{"/pull", data_manager_token, "PUT", second_pull_list},
		response_code: http.StatusOK,
		response_body: "Received 1 pull requests\n",
		read_content:  "hola",
		read_error:    false,
		put_error:     false,
	}

	performTest(testData, c)
}

func (s *PullWorkerTestSuite) TestPullWorker_error_on_get_one_locator(c *C) {
	defer teardown()

	data_manager_token = "DATA MANAGER TOKEN"
	testData := PullWorkerTestData{
		name:          "TestPullWorker_error_on_get_one_locator",
		req:           RequestTester{"/pull", data_manager_token, "PUT", second_pull_list},
		response_code: http.StatusOK,
		response_body: "Received 1 pull requests\n",
		read_content:  "unused",
		read_error:    true,
		put_error:     false,
	}

	performTest(testData, c)
}

func (s *PullWorkerTestSuite) TestPullWorker_error_on_get_two_locators(c *C) {
	defer teardown()

	data_manager_token = "DATA MANAGER TOKEN"
	testData := PullWorkerTestData{
		name:          "TestPullWorker_error_on_get_two_locators",
		req:           RequestTester{"/pull", data_manager_token, "PUT", first_pull_list},
		response_code: http.StatusOK,
		response_body: "Received 2 pull requests\n",
		read_content:  "unused",
		read_error:    true,
		put_error:     false,
	}

	performTest(testData, c)
}

func (s *PullWorkerTestSuite) TestPullWorker_error_on_put_one_locator(c *C) {
	defer teardown()

	data_manager_token = "DATA MANAGER TOKEN"
	testData := PullWorkerTestData{
		name:          "TestPullWorker_error_on_put_one_locator",
		req:           RequestTester{"/pull", data_manager_token, "PUT", second_pull_list},
		response_code: http.StatusOK,
		response_body: "Received 1 pull requests\n",
		read_content:  "unused",
		read_error:    false,
		put_error:     true,
	}

	performTest(testData, c)
}

func (s *PullWorkerTestSuite) TestPullWorker_error_on_put_two_locators(c *C) {
	defer teardown()

	data_manager_token = "DATA MANAGER TOKEN"
	testData := PullWorkerTestData{
		name:          "TestPullWorker_error_on_put_two_locators",
		req:           RequestTester{"/pull", data_manager_token, "PUT", first_pull_list},
		response_code: http.StatusOK,
		response_body: "Received 2 pull requests\n",
		read_content:  "unused",
		read_error:    false,
		put_error:     true,
	}

	performTest(testData, c)
}

func performTest(testData PullWorkerTestData, c *C) {
	RunTestPullWorker(c)

	currentTestData = testData
	testPullLists[testData.name] = testData.response_body

	// We need to make sure the tests have a slight delay so that we can verify the pull list channel overwrites.
	//	time.Sleep(25 * time.Millisecond)

	// Override GetContent to mock keepclient Get functionality
	GetContent = func(signedLocator string, keepClient keepclient.KeepClient) (
		reader io.ReadCloser, contentLength int64, url string, err error) {
		if strings.HasPrefix(testData.name, "TestPullWorker_pull_list_with_one_locator_with_delay_1") {
			//			time.Sleep(100 * time.Millisecond)
		}

		processedPullLists[testData.name] = testData.response_body
		if testData.read_error {
			err = errors.New("Error getting data")
			readError = err
			return nil, 0, "", err
		} else {
			readContent = READ_CONTENT
			cb := &ClosingBuffer{bytes.NewBufferString(readContent)}
			var rc io.ReadCloser
			rc = cb
			return rc, 3, "", nil
		}
	}

	// Override PutContent to mock PutBlock functionality
	PutContent = func(content []byte, locator string) (err error) {
		if testData.put_error {
			err = errors.New("Error putting data")
			putError = err
			return err
		} else {
			putContent = content
			return nil
		}
	}

	response := IssueRequest(&testData.req)
	c.Assert(testData.response_code, Equals, response.Code)
	c.Assert(testData.response_body, Equals, response.Body.String())
}

type ClosingBuffer struct {
	*bytes.Buffer
}

func (cb *ClosingBuffer) Close() (err error) {
	return
}

func expectWorkerChannelEmpty(c *C, workerChannel <-chan interface{}) {
	select {
	case item := <-workerChannel:
		c.Fatalf("Received value (%v) from channel that was expected to be empty", item)
	default:
	}
}

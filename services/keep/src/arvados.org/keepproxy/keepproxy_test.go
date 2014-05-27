package main

import (
	"arvados.org/keepclient"
	"crypto/md5"
	"crypto/tls"
	"fmt"
	. "gopkg.in/check.v1"
	"io"
	"io/ioutil"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// Gocheck boilerplate
func Test(t *testing.T) {
	TestingT(t)
}

// Gocheck boilerplate
var _ = Suite(&ServerRequiredSuite{})

// Tests that require the Keep server running
type ServerRequiredSuite struct{}

func pythonDir() string {
	gopath := os.Getenv("GOPATH")
	return fmt.Sprintf("%s/../../sdk/python", strings.Split(gopath, ":")[0])
}

func (s *ServerRequiredSuite) SetUpSuite(c *C) {
	cwd, _ := os.Getwd()
	defer os.Chdir(cwd)

	os.Chdir(pythonDir())

	if err := exec.Command("python", "run_test_server.py", "start").Run(); err != nil {
		panic("'python run_test_server.py start' returned error")
	}
	if err := exec.Command("python", "run_test_server.py", "start_keep").Run(); err != nil {
		panic("'python run_test_server.py start_keep' returned error")
	}

	os.Setenv("ARVADOS_API_HOST", "localhost:3001")
	os.Setenv("ARVADOS_API_TOKEN", "4axaw8zxe0qm22wa6urpp5nskcne8z88cvbupv653y1njyi05h")
	os.Setenv("ARVADOS_API_HOST_INSECURE", "true")
}

func (s *ServerRequiredSuite) TearDownSuite(c *C) {
	cwd, _ := os.Getwd()
	defer os.Chdir(cwd)

	os.Chdir(pythonDir())
	exec.Command("python", "run_test_server.py", "stop_keep").Run()
	exec.Command("python", "run_test_server.py", "stop").Run()
}

func setupProxyService() {

	client := &http.Client{Transport: &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}}

	var req *http.Request
	var err error
	if req, err = http.NewRequest("POST", fmt.Sprintf("https://%s/arvados/v1/keep_services", os.Getenv("ARVADOS_API_HOST")), nil); err != nil {
		panic(err.Error())
	}
	req.Header.Add("Authorization", fmt.Sprintf("OAuth2 %s", os.Getenv("ARVADOS_API_TOKEN")))

	reader, writer := io.Pipe()

	req.Body = reader

	go func() {
		data := url.Values{}
		data.Set("keep_service", `{
  "service_host": "localhost",
  "service_port": 29950,
  "service_ssl_flag": false,
  "service_type": "proxy"
}`)

		writer.Write([]byte(data.Encode()))
		writer.Close()
	}()

	var resp *http.Response
	if resp, err = client.Do(req); err != nil {
		panic(err.Error())
	}
	if resp.StatusCode != 200 {
		panic(resp.Status)
	}
}

func runProxy(c *C, args []string, token string, port int) keepclient.KeepClient {
	os.Args = append(args, fmt.Sprintf("-listen=:%v", port))
	os.Setenv("ARVADOS_API_TOKEN", "4axaw8zxe0qm22wa6urpp5nskcne8z88cvbupv653y1njyi05h")

	go main()
	time.Sleep(100 * time.Millisecond)

	os.Setenv("ARVADOS_KEEP_PROXY", fmt.Sprintf("http://localhost:%v", port))
	os.Setenv("ARVADOS_API_TOKEN", token)
	kc, err := keepclient.MakeKeepClient()
	c.Check(kc.Using_proxy, Equals, true)
	c.Check(len(kc.ServiceRoots()), Equals, 1)
	c.Check(kc.ServiceRoots()[0], Equals, fmt.Sprintf("http://localhost:%v", port))
	c.Check(err, Equals, nil)
	os.Setenv("ARVADOS_KEEP_PROXY", "")
	log.Print("keepclient created")
	return kc
}

func (s *ServerRequiredSuite) TestPutAskGet(c *C) {
	log.Print("TestPutAndGet start")

	os.Args = []string{"keepproxy", "-listen=:29950"}
	os.Setenv("ARVADOS_API_TOKEN", "4axaw8zxe0qm22wa6urpp5nskcne8z88cvbupv653y1njyi05h")
	go main()
	time.Sleep(100 * time.Millisecond)

	setupProxyService()

	os.Setenv("ARVADOS_EXTERNAL_CLIENT", "true")
	kc, err := keepclient.MakeKeepClient()
	c.Check(kc.External, Equals, true)
	c.Check(kc.Using_proxy, Equals, true)
	c.Check(len(kc.ServiceRoots()), Equals, 1)
	c.Check(kc.ServiceRoots()[0], Equals, "http://localhost:29950")
	c.Check(err, Equals, nil)
	os.Setenv("ARVADOS_EXTERNAL_CLIENT", "")
	log.Print("keepclient created")

	defer listener.Close()

	hash := fmt.Sprintf("%x", md5.Sum([]byte("foo")))
	var hash2 string

	{
		_, _, err := kc.Ask(hash)
		c.Check(err, Equals, keepclient.BlockNotFound)
		log.Print("Ask 1")
	}

	{
		var rep int
		var err error
		hash2, rep, err = kc.PutB([]byte("foo"))
		c.Check(hash2, Equals, fmt.Sprintf("%s+3", hash))
		c.Check(rep, Equals, 2)
		c.Check(err, Equals, nil)
		log.Print("PutB")
	}

	{
		blocklen, _, err := kc.Ask(hash2)
		c.Assert(err, Equals, nil)
		c.Check(blocklen, Equals, int64(3))
		log.Print("Ask 2")
	}

	{
		reader, blocklen, _, err := kc.Get(hash2)
		c.Assert(err, Equals, nil)
		all, err := ioutil.ReadAll(reader)
		c.Check(all, DeepEquals, []byte("foo"))
		c.Check(blocklen, Equals, int64(3))
		log.Print("Get")
	}

	log.Print("TestPutAndGet done")
}

func (s *ServerRequiredSuite) TestPutAskGetForbidden(c *C) {
	log.Print("TestPutAndGet start")

	kc := runProxy(c, []string{"keepproxy"}, "123abc", 29951)
	defer listener.Close()

	log.Print("keepclient created")

	hash := fmt.Sprintf("%x", md5.Sum([]byte("bar")))

	{
		_, _, err := kc.Ask(hash)
		c.Check(err, Equals, keepclient.BlockNotFound)
		log.Print("Ask 1")
	}

	{
		hash2, rep, err := kc.PutB([]byte("bar"))
		c.Check(hash2, Equals, "")
		c.Check(rep, Equals, 0)
		c.Check(err, Equals, keepclient.InsufficientReplicasError)
		log.Print("PutB")
	}

	{
		blocklen, _, err := kc.Ask(hash)
		c.Assert(err, Equals, keepclient.BlockNotFound)
		c.Check(blocklen, Equals, int64(0))
		log.Print("Ask 2")
	}

	{
		_, blocklen, _, err := kc.Get(hash)
		c.Assert(err, Equals, keepclient.BlockNotFound)
		c.Check(blocklen, Equals, int64(0))
		log.Print("Get")
	}

	log.Print("TestPutAndGetForbidden done")
}

func (s *ServerRequiredSuite) TestGetDisabled(c *C) {
	log.Print("TestGetDisabled start")

	kc := runProxy(c, []string{"keepproxy", "-no-get"}, "4axaw8zxe0qm22wa6urpp5nskcne8z88cvbupv653y1njyi05h", 29952)
	defer listener.Close()

	hash := fmt.Sprintf("%x", md5.Sum([]byte("baz")))

	{
		_, _, err := kc.Ask(hash)
		c.Check(err, Equals, keepclient.BlockNotFound)
		log.Print("Ask 1")
	}

	{
		hash2, rep, err := kc.PutB([]byte("baz"))
		c.Check(hash2, Equals, fmt.Sprintf("%s+3", hash))
		c.Check(rep, Equals, 2)
		c.Check(err, Equals, nil)
		log.Print("PutB")
	}

	{
		blocklen, _, err := kc.Ask(hash)
		c.Assert(err, Equals, keepclient.BlockNotFound)
		c.Check(blocklen, Equals, int64(0))
		log.Print("Ask 2")
	}

	{
		_, blocklen, _, err := kc.Get(hash)
		c.Assert(err, Equals, keepclient.BlockNotFound)
		c.Check(blocklen, Equals, int64(0))
		log.Print("Get")
	}

	log.Print("TestGetDisabled done")
}

func (s *ServerRequiredSuite) TestPutDisabled(c *C) {
	log.Print("TestPutDisabled start")

	kc := runProxy(c, []string{"keepproxy", "-no-put"}, "4axaw8zxe0qm22wa6urpp5nskcne8z88cvbupv653y1njyi05h", 29953)
	defer listener.Close()

	{
		hash2, rep, err := kc.PutB([]byte("quux"))
		c.Check(hash2, Equals, "")
		c.Check(rep, Equals, 0)
		c.Check(err, Equals, keepclient.InsufficientReplicasError)
		log.Print("PutB")
	}

	log.Print("TestPutDisabled done")
}

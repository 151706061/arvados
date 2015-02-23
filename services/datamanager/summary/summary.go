/* Computes Summary based on data read from API server. */

package summary

import (
	"encoding/gob"
	"flag"
	"fmt"
	"git.curoverse.com/arvados.git/sdk/go/logger"
	"git.curoverse.com/arvados.git/services/datamanager/collection"
	"git.curoverse.com/arvados.git/services/datamanager/keep"
	"git.curoverse.com/arvados.git/services/datamanager/loggerutil"
	"log"
	"os"
)

var (
	// These are just used for development, to save network i/o
	writeDataTo  string
	readDataFrom string
)

type serializedData struct {
	ReadCollections collection.ReadCollections
	KeepServerInfo  keep.ReadServers
}

func init() {
	flag.StringVar(&writeDataTo,
		"write-data-to",
		"",
		"Write summary of data received to this file. Used for development only.")
	flag.StringVar(&readDataFrom,
		"read-data-from",
		"",
		"Avoid network i/o and read summary data from this file instead. Used for development only.")
}

// Writes data we've read to a file.
//
// This is useful for development, so that we don't need to read all our data from the network every time we tweak something.
//
// This should not be used outside of development, since you'll be
// working with stale data.
func MaybeWriteData(arvLogger *logger.Logger,
	readCollections collection.ReadCollections,
	keepServerInfo keep.ReadServers) bool {
	if writeDataTo == "" {
		return false
	} else {
		summaryFile, err := os.Create(writeDataTo)
		if err != nil {
			loggerutil.FatalWithMessage(arvLogger,
				fmt.Sprintf("Failed to open %s: %v", writeDataTo, err))
		}
		defer summaryFile.Close()

		enc := gob.NewEncoder(summaryFile)
		data := serializedData{
			ReadCollections: readCollections,
			KeepServerInfo:  keepServerInfo}
		err = enc.Encode(data)
		if err != nil {
			loggerutil.FatalWithMessage(arvLogger,
				fmt.Sprintf("Failed to write summary data: %v", err))
		}
		log.Printf("Wrote summary data to: %s", writeDataTo)
		return true
	}
}

// Reads data that we've read to a file.
//
// This is useful for development, so that we don't need to read all our data from the network every time we tweak something.
//
// This should not be used outside of development, since you'll be
// working with stale data.
func MaybeReadData(arvLogger *logger.Logger,
	readCollections *collection.ReadCollections,
	keepServerInfo *keep.ReadServers) bool {
	if readDataFrom == "" {
		return false
	} else {
		summaryFile, err := os.Open(readDataFrom)
		if err != nil {
			loggerutil.FatalWithMessage(arvLogger,
				fmt.Sprintf("Failed to open %s: %v", readDataFrom, err))
		}
		defer summaryFile.Close()

		dec := gob.NewDecoder(summaryFile)
		data := serializedData{}
		err = dec.Decode(&data)
		if err != nil {
			loggerutil.FatalWithMessage(arvLogger,
				fmt.Sprintf("Failed to read summary data: %v", err))
		}
		log.Printf("Read summary data from: %s", readDataFrom)
		return true
	}
}

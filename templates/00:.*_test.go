package ${1:package_name}

import (
	"testing"

	"github.com/google/go-cmp/cmp"
	"github.com/stretchr/testify/suite"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/testing/protocmp"
)

type ${2:name}TestSuite struct {
	suite.Suite
}

func (s *$2TestSuite) SetupSuite() {
}

func (s *$2TestSuite) BeforeTest(suiteName, methodName string) {
}

func (s *$2TestSuite) TearDownSuite() {
}

func (s *$2TestSuite) TestBar() {
}

func Test$2(t *testing.T) {
	suite.Run(t, &$2TestSuite{})
}

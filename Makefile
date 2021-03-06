### Makefile for tidb

GOPATH ?= $(shell go env GOPATH)

# Ensure GOPATH is set before running build process.
ifeq "$(GOPATH)" ""
  $(error Please set the environment variable GOPATH before running `make`)
endif

CURDIR := $(shell pwd)
path_to_add := $(addsuffix /bin,$(subst :,/bin:,$(CURDIR)/_vendor:$(GOPATH)))
export PATH := $(path_to_add):$(PATH)

GO        := go
GOBUILD   := GOPATH=$(CURDIR)/_vendor:$(GOPATH) CGO_ENABLED=0 $(GO) build
GOTEST    := GOPATH=$(CURDIR)/_vendor:$(GOPATH) CGO_ENABLED=1 $(GO) test -p 3
OVERALLS  := GOPATH=$(CURDIR)/_vendor:$(GOPATH) CGO_ENABLED=1 overalls
GOVERALLS := goveralls

ARCH      := "`uname -s`"
LINUX     := "Linux"
MAC       := "Darwin"
PACKAGES  := $$(go list ./...| grep -vE "vendor")
FILES     := $$(find . -name "*.go" | grep -vE "vendor")
TOPDIRS   := $$(ls -d */ | grep -vE "vendor")

LDFLAGS += -X "github.com/pingcap/tidb/util/printer.TiDBBuildTS=$(shell date -u '+%Y-%m-%d %I:%M:%S')"
LDFLAGS += -X "github.com/pingcap/tidb/util/printer.TiDBGitHash=$(shell git rev-parse HEAD)"
LDFLAGS += -X "github.com/pingcap/tidb/util/printer.TiDBGitBranch=$(shell git rev-parse --abbrev-ref HEAD)"

TARGET = ""

.PHONY: all build update parser clean todo test gotest interpreter server dev benchkv benchraw check parserlib checklist

default: server buildsucc

buildsucc:
	@echo Build TiDB Server successfully!

all: dev server benchkv

dev: checklist parserlib build benchkv test check

build:
	$(GOBUILD)

goyacc:
	$(GOBUILD) -o bin/goyacc parser/goyacc/main.go

parser: goyacc
	bin/goyacc -o /dev/null parser/parser.y
	bin/goyacc -o parser/parser.go parser/parser.y 2>&1 | egrep "(shift|reduce)/reduce" | awk '{print} END {if (NR > 0) {print "Find conflict in parser.y. Please check y.output for more information."; exit 1;}}'
	rm -f y.output

	@if [ $(ARCH) = $(LINUX) ]; \
	then \
		sed -i -e 's|//line.*||' -e 's/yyEofCode/yyEOFCode/' parser/parser.go; \
	elif [ $(ARCH) = $(MAC) ]; \
	then \
		/usr/bin/sed -i "" 's|//line.*||' parser/parser.go; \
		/usr/bin/sed -i "" 's/yyEofCode/yyEOFCode/' parser/parser.go; \
	fi

	@awk 'BEGIN{print "// Code generated by goyacc"} {print $0}' parser/parser.go > tmp_parser.go && mv tmp_parser.go parser/parser.go;

parserlib: parser/parser.go

parser/parser.go: parser/parser.y
	make parser

check:
	go get github.com/golang/lint/golint

	@echo "vet"
	@ go tool vet -all -shadow $(TOPDIRS) 2>&1 | awk '{print} END{if(NR>0) {exit 1}}'
	@ go tool vet -all -shadow *.go 2>&1 | awk '{print} END{if(NR>0) {exit 1}}'
	@echo "golint"
	@ golint ./... 2>&1 | grep -vE 'context\.Context|LastInsertId|NewLexer|\.pb\.go' | awk '{print} END{if(NR>0) {exit 1}}'
	@echo "gofmt (simplify)"
	@ gofmt -s -l -w $(FILES) 2>&1 | grep -v "parser/parser.go" | awk '{print} END{if(NR>0) {exit 1}}'

goword:
	go get github.com/chzchzchz/goword
	@echo "goword"
	@ goword $(FILES) | awk '{print} END{if(NR>0) {exit 1}}'

errcheck:
	go get github.com/kisielk/errcheck
	errcheck -blank $(PACKAGES)

clean:
	$(GO) clean -i ./...
	rm -rf *.out

todo:
	@grep -n ^[[:space:]]*_[[:space:]]*=[[:space:]][[:alpha:]][[:alnum:]]* */*.go parser/parser.y || true
	@grep -n TODO */*.go parser/parser.y || true
	@grep -n BUG */*.go parser/parser.y || true
	@grep -n println */*.go parser/parser.y || true

test: checklist gotest

gotest: parserlib
ifeq ("$(TRAVIS_COVERAGE)", "1")
	@echo "Running in TRAVIS_COVERAGE mode."
	@export log_level=error; \
	go get github.com/go-playground/overalls
	go get github.com/mattn/goveralls
	$(OVERALLS) -project=github.com/pingcap/tidb -covermode=count -ignore='.git,_vendor'
	$(GOVERALLS) -service=travis-ci -coverprofile=overalls.coverprofile
else
	@echo "Running in native mode."
	@export log_level=error; \
	$(GOTEST) -cover $(PACKAGES)
endif

race: parserlib
	@export log_level=debug; \
	$(GOTEST) -race $(PACKAGES)

leak: parserlib
	@export log_level=debug; \
	$(GOTEST) -tags leak $(PACKAGES)

tikv_integration_test: parserlib
	$(GOTEST) ./store/tikv/. -with-tikv=true

RACE_FLAG = 
ifeq ("$(WITH_RACE)", "1")
	RACE_FLAG = -race
	GOBUILD   = GOPATH=$(CURDIR)/_vendor:$(GOPATH) CGO_ENABLED=1 $(GO) build
endif

server: parserlib
ifeq ($(TARGET), "")
	$(GOBUILD) $(RACE_FLAG) -ldflags '$(LDFLAGS)' -o bin/tidb-server tidb-server/main.go
else
	$(GOBUILD) $(RACE_FLAG) -ldflags '$(LDFLAGS)' -o '$(TARGET)' tidb-server/main.go
endif

benchkv:
	$(GOBUILD) -ldflags '$(LDFLAGS)' -o bin/benchkv cmd/benchkv/main.go

benchraw:
	$(GOBUILD) -ldflags '$(LDFLAGS)' -o bin/benchraw cmd/benchraw/main.go

benchdb:
	$(GOBUILD) -ldflags '$(LDFLAGS)' -o bin/benchdb cmd/benchdb/main.go

update:
	which glide >/dev/null || curl https://glide.sh/get | sh
	which glide-vc || go get -v -u github.com/sgotti/glide-vc
	rm -r vendor && mv _vendor/src vendor || true
	rm -rf _vendor
ifdef PKG
	glide get -s -v --skip-test ${PKG}
else
	glide update -s -v -u --skip-test
endif
	@echo "removing test files"
	glide vc --only-code --no-tests
	mkdir -p _vendor
	mv vendor _vendor/src

checklist:
	cat checklist.md

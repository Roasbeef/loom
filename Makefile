# Loom — common developer commands.
#
# Every target is a thin wrapper over the scripts and package tooling, so
# what CI runs and what you run locally are the same commands.

PACKAGES := core storage session machine runtime provider broker tools events client conformance
GO_PKG   := packages/sandbox
HELPER   := $(GO_PKG)/loom-exec

.DEFAULT_GOAL := help

# ---------------------------------------------------------------- checking

.PHONY: check
check: ## Full gate: format check, warning-free build, tests (all packages)
	@scripts/check.sh

.PHONY: check-gleam
check-gleam: ## Full gate for the Gleam packages only
	@scripts/check.sh $(PACKAGES)

.PHONY: check-%
check-%: ## Full gate for one package, e.g. make check-machine
	@scripts/check.sh $*

.PHONY: test
test: ## Run tests only (skips format check), all Gleam packages
	@set -e; for p in $(PACKAGES); do \
		echo "==> $$p"; (cd packages/$$p && gleam test); \
	done

.PHONY: test-%
test-%: ## Run tests for one package, e.g. make test-core
	@cd packages/$* && gleam test

.PHONY: build
build: ## Warning-free build of every Gleam package
	@set -e; for p in $(PACKAGES); do \
		echo "==> $$p"; (cd packages/$$p && gleam build --warnings-as-errors); \
	done

# --------------------------------------------------------------- formatting

.PHONY: fmt
fmt: ## Format all Gleam and Go sources in place
	@set -e; for p in $(PACKAGES); do \
		(cd packages/$$p && gleam format src test); \
	done
	@cd $(GO_PKG) && gofmt -w .
	@echo "formatted"

.PHONY: fmt-check
fmt-check: ## Verify formatting without writing (what CI enforces)
	@set -e; for p in $(PACKAGES); do \
		(cd packages/$$p && gleam format --check src test); \
	done
	@test -z "$$(cd $(GO_PKG) && gofmt -l .)" || { \
		echo "unformatted Go files:"; (cd $(GO_PKG) && gofmt -l .); exit 1; }
	@echo "formatting clean"

# -------------------------------------------------------------- the sandbox

.PHONY: sandbox
sandbox: ## Build the loom-exec sandbox helper binary
	@cd $(GO_PKG) && go build -o loom-exec ./cmd/loom-exec
	@echo "built $(HELPER)"

.PHONY: sandbox-test
sandbox-test: ## Vet, build, and test the Go sandbox package
	@cd $(GO_PKG) && go vet ./... && go build ./... && go test ./...

.PHONY: selftest
selftest: sandbox ## Probe this kernel's enforcement layers (ENFORCED/SKIPPED per probe)
	@./$(HELPER) --self-test

# ---------------------------------------------------------------- end to end

.PHONY: e2e
e2e: sandbox ## Run the jailed end-to-end acceptance against the real helper
	@cd packages/conformance && gleam test

.PHONY: conformance
conformance: ## Run the shared suites (storage conformance + wiring + e2e)
	@cd packages/conformance && gleam test

# ------------------------------------------------------------ the simulator

SOAK_SEEDS ?= 2000
SOAK_FROM  ?= 1
# Seeds per test-runner invocation. The test framework imposes a per-test
# timeout (about a minute), and per-seed cost varies enough that a single
# invocation of more than a few dozen seeds can trip it and report a
# timeout rather than a result. The soak therefore runs in chunks; raise
# this only if you have measured that your seeds are cheap.
SOAK_CHUNK ?= 50

.PHONY: soak
soak: ## Long deterministic-simulation run (SOAK_SEEDS=n SOAK_FROM=n SOAK_CHUNK=n)
	@from=$(SOAK_FROM); left=$(SOAK_SEEDS); \
	while [ $$left -gt 0 ]; do \
		n=$$( [ $$left -lt $(SOAK_CHUNK) ] && echo $$left || echo $(SOAK_CHUNK) ); \
		echo "==> seeds $$from..$$(( from + n - 1 ))"; \
		( cd packages/conformance && \
			LOOM_SOAK_SEEDS=$$n LOOM_SOAK_FROM=$$from gleam test ) || \
			{ echo "soak FAILED in seeds $$from..$$(( from + n - 1 ))"; exit 1; }; \
		from=$$(( from + n )); left=$$(( left - n )); \
	done; \
	echo "soak clean: $(SOAK_SEEDS) seeds from $(SOAK_FROM)"

# ---------------------------------------------------------------- utilities

.PHONY: deps
deps: ## Download dependencies for every package
	@set -e; for p in $(PACKAGES); do \
		echo "==> $$p"; (cd packages/$$p && gleam deps download); \
	done
	@cd $(GO_PKG) && go mod download

.PHONY: docs
docs: ## Build HexDocs-style API documentation for every Gleam package
	@set -e; for p in $(PACKAGES); do \
		echo "==> $$p"; (cd packages/$$p && gleam docs build); \
	done

.PHONY: clean
clean: ## Remove build artifacts
	@rm -rf packages/*/build $(HELPER)
	@echo "cleaned"

.PHONY: loc
loc: ## Report source and test line counts per package
	@for p in $(PACKAGES); do \
		src=$$(find packages/$$p/src -name '*.gleam' 2>/dev/null | xargs cat 2>/dev/null | wc -l); \
		tst=$$(find packages/$$p/test -name '*.gleam' 2>/dev/null | xargs cat 2>/dev/null | wc -l); \
		printf '%-12s src %6s  test %6s\n' "$$p" "$$src" "$$tst"; \
	done
	@go_src=$$(find $(GO_PKG) -name '*.go' | xargs cat | wc -l); \
		printf '%-12s src %6s\n' sandbox "$$go_src"

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_%-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

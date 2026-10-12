# Build, test and preview the Loom website.
#
# Run from anywhere with `make -C site <target>`. The site is a client-side
# Lustre application compiled to JavaScript; `dist/` is what GitHub Pages
# serves. `build.sh` does the packaging, and these targets only name the
# common tasks.

PORT ?= 8702

.PHONY: help build test copy-check check serve clean

help:
	@echo "make build       compile and assemble dist/"
	@echo "make test        run the gleeunit tests on the JavaScript target"
	@echo "make copy-check  look for banned words and em dashes in the copy"
	@echo "make check       test, copy-check and build"
	@echo "make serve       serve dist/ on PORT (default $(PORT))"
	@echo "make clean       remove build output"

build:
	./build.sh

test:
	gleam test --target javascript

copy-check:
	./scripts/copy-check.sh

check: test copy-check build

serve: build
	python3 -m http.server $(PORT) --directory dist

clean:
	rm -rf build dist

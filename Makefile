# mgtt2writ — an mgtt model export, translated into a writ model.
#
#   make build       # compile
#   make test        # the unit suite (72 checks, no writ needed)
#   make pipeline    # the end-to-end check (needs writ on PATH)
#   make check       # both
#   make lint        # format check + warnings-as-errors typecheck
#
# Two ways to get a binary you can run anywhere:
#   make install     # this checkout -> ~/.local (plain cp; no opam needed)
#   make opam-install
#
# The toolchain is resolved the way writ's is: dune on PATH, else $SWITCH, else
# a local ./_opam. Set SWITCH=/path/to/switch to force one.

DUNE   = ./scripts/with-ocaml.sh dune
PREFIX ?= $(HOME)/.local

.PHONY: build test pipeline check lint fmt install uninstall opam-install \
        opam-uninstall clean

build:
	$(DUNE) build

# The unit suite. It links the vendored JSON reader and nothing representing
# writ's front end, which is the whole reason `pipeline` exists separately.
test:
	$(DUNE) runtest --force

# The end-to-end check: a real export, through this translator, into the real
# writ. Skips with 77 when writ is not installed rather than failing, because a
# machine without writ can still legitimately build and unit-test this tool.
pipeline: build
	@MGTT2WRIT=$(CURDIR)/_build/default/bin/main.exe sh test/pipeline.sh

check: test pipeline

lint:
	$(DUNE) build @fmt @all

fmt:
	$(DUNE) build @fmt --auto-promote

# Plain cp, no opam machinery — the same shape writ's install-writ has, and for
# the same reason: the tool should be gettable on a machine that has OCaml but
# has never been introduced to opam's package layer.
install: build
	@mkdir -p "$(PREFIX)/bin"
	@cp -f _build/default/bin/main.exe "$(PREFIX)/bin/mgtt2writ"
	@chmod u+w "$(PREFIX)/bin/mgtt2writ"
	@cp -f bin/mgtt-contradict-check "$(PREFIX)/bin/mgtt-contradict-check"
	@chmod u+x "$(PREFIX)/bin/mgtt-contradict-check"
	@echo "installed mgtt2writ and mgtt-contradict-check -> $(PREFIX)/bin"

uninstall:
	@rm -f "$(PREFIX)/bin/mgtt2writ" "$(PREFIX)/bin/mgtt-contradict-check"
	@echo "removed mgtt2writ and mgtt-contradict-check from $(PREFIX)/bin"

opam-install:
	opam install .

opam-uninstall:
	opam remove mgtt2writ

clean:
	$(DUNE) clean

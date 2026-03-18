PREFIX ?= /usr/local

build:
	swift build -c release

install: build
	install -d $(PREFIX)/bin
	install .build/release/AudioGuard $(PREFIX)/bin/audio-guard

uninstall:
	rm -f $(PREFIX)/bin/audio-guard

.PHONY: build install uninstall

PREFIX ?= /usr/local

build:
	swift build -c release

install: build
	install -d $(PREFIX)/bin
	install .build/release/MicGuard $(PREFIX)/bin/mic-guard

uninstall:
	rm -f $(PREFIX)/bin/mic-guard

.PHONY: build install uninstall

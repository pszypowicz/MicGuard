# Codesign identity passed to scripts/bundle.sh: "adhoc", or a substring of a
# `security find-identity -v -p codesigning` entry. Release builds go through
# scripts/notarize-release.sh, which picks the Developer ID identity itself.
IDENTITY ?= adhoc

build:
	bash scripts/bundle.sh --identity "$(IDENTITY)"

# Remove any existing install first: cp -R into an existing bundle merges
# stale files (or nests the app) instead of replacing it.
install: build
	rm -rf /Applications/MicGuard.app
	cp -R .build/MicGuard.app /Applications/MicGuard.app

uninstall:
	rm -rf /Applications/MicGuard.app

# zip -r updates an existing archive in place and keeps entries the bundle
# no longer has, so start from an empty one.
zip: build
	rm -f .build/MicGuard.zip
	cd .build && zip -ry MicGuard.zip MicGuard.app

# Development: build the bundle and (re)launch it.
dev: build
	-killall MicGuard 2>/dev/null
	open .build/MicGuard.app

dev-stop:
	-killall MicGuard 2>/dev/null

.PHONY: build install uninstall zip dev dev-stop

build:
	bash scripts/bundle.sh

# Remove any existing install first: cp -R into an existing bundle merges
# stale files (or nests the app) instead of replacing it.
install: build
	rm -rf /Applications/MicGuard.app
	cp -R .build/MicGuard.app /Applications/MicGuard.app

uninstall:
	rm -rf /Applications/MicGuard.app

zip: build
	cd .build && zip -ry MicGuard.zip MicGuard.app

# Development: build the bundle and (re)launch it.
dev: build
	-killall MicGuard 2>/dev/null
	open .build/MicGuard.app

dev-stop:
	-killall MicGuard 2>/dev/null

.PHONY: build install uninstall zip dev dev-stop

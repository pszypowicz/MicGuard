build:
	bash scripts/bundle.sh

install: build
	cp -R .build/MicGuard.app /Applications/MicGuard.app
	ln -sf /Applications/MicGuard.app/Contents/MacOS/MicGuard /usr/local/bin/mic-guard

uninstall:
	rm -rf /Applications/MicGuard.app
	rm -f /usr/local/bin/mic-guard

zip: build
	cd .build && zip -ry MicGuard.zip MicGuard.app bin/mic-guard

.PHONY: build install uninstall zip

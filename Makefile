build:
	bash scripts/bundle.sh

install: build
	cp -R .build/MicGuard.app /Applications/MicGuard.app
	mkdir -p $(HOME)/.local/bin
	ln -sf /Applications/MicGuard.app/Contents/MacOS/MicGuard $(HOME)/.local/bin/mic-guard

uninstall:
	rm -rf /Applications/MicGuard.app
	rm -f $(HOME)/.local/bin/mic-guard

zip: build
	cd .build && zip -r MicGuard.app.zip MicGuard.app

.PHONY: build install uninstall zip

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

# Development: build bundle, register LaunchAgent (Mach service), and launch daemon.
# After this, `mic-guard` CLI commands work via XPC.
dev: build
	-killall MicGuard 2>/dev/null
	-launchctl bootout gui/$$(id -u)/com.pszypowicz.MicGuard 2>/dev/null
	@# Generate dev plist with absolute ProgramArguments (launchctl needs it, SMAppService doesn't)
	/usr/libexec/PlistBuddy -c "Copy :. :" \
		-c "Add :ProgramArguments array" \
		-c "Add :ProgramArguments:0 string $$(pwd)/.build/MicGuard.app/Contents/MacOS/MicGuard" \
		.build/MicGuard.app/Contents/Library/LaunchAgents/com.pszypowicz.MicGuard.agent.plist 2>/dev/null || \
	/usr/libexec/PlistBuddy \
		-c "Set :ProgramArguments:0 $$(pwd)/.build/MicGuard.app/Contents/MacOS/MicGuard" \
		.build/MicGuard.app/Contents/Library/LaunchAgents/com.pszypowicz.MicGuard.agent.plist
	launchctl bootstrap gui/$$(id -u) .build/MicGuard.app/Contents/Library/LaunchAgents/com.pszypowicz.MicGuard.agent.plist
	@echo "Daemon running with XPC. Test with: .build/bin/mic-guard list"

# Stop the dev daemon and unregister the LaunchAgent.
dev-stop:
	-killall MicGuard 2>/dev/null
	-launchctl bootout gui/$$(id -u)/com.pszypowicz.MicGuard 2>/dev/null
	@echo "Daemon stopped and LaunchAgent unregistered."

.PHONY: build install uninstall zip dev dev-stop

.PHONY: all icon test install uninstall run-dry clean

all:
	./scripts/build-app.sh

# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift.
icon:
	rm -rf build/AppIcon.iconset
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

# With only the Command Line Tools installed, swift-testing must be located explicitly.
TESTING_FW := /Library/Developer/CommandLineTools/Library/Developer/Frameworks

test:
	@if [ "$$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ]; then \
		swift test -Xswiftc -F -Xswiftc $(TESTING_FW) -Xlinker -F -Xlinker $(TESTING_FW) -Xlinker -rpath -Xlinker $(TESTING_FW) \
			-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays; \
	else \
		swift test; \
	fi

install: all
	sudo ./scripts/install.sh

uninstall:
	sudo ./scripts/uninstall.sh

# Run the control loop against a scratch directory without touching the SMC.
run-dry:
	swift build
	mkdir -p .dev
	BATTERY_ANCHOR_SUPPORT_DIR=$(CURDIR)/.dev .build/debug/battery-anchord --dry-run

clean:
	rm -rf .build build .dev

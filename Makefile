APP  := Crema.app
REL  := .build/release/crema

.PHONY: build test app run sign release clean

build:
	swift build -c release

test:
	swift test

# Assemble a runnable .app bundle around the release binary.
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(REL) $(APP)/Contents/MacOS/crema
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	@echo "Built $(APP). Launch with: open $(APP)"

run: app
	open $(APP)

# Build + Developer ID sign + verify, no Apple round trip (local check).
sign:
	./scripts/release.sh sign-only

# Full release: sign, notarize, staple, zip. Needs the crema-notary keychain
# profile (see scripts/release.sh header).
release:
	./scripts/release.sh

clean:
	rm -rf .build $(APP) Crema-*.zip

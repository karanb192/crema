APP  := Crema.app
REL  := .build/release/crema

.PHONY: build test app run clean

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
	@echo "Built $(APP). Launch with: open $(APP)"

run: app
	open $(APP)

clean:
	rm -rf .build $(APP)

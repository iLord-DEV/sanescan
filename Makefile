# SaneScan - build the SwiftUI app bundle without Xcode project files.
APP     = SaneScan
BIN     = .build/release/$(APP)
APPDIR  = build/$(APP).app
ICNS    = build/AppIcon.icns
DMG     = build/$(APP).dmg
# Version written into the bundle, e.g. `make dmg VERSION=1.1`. Defaults to Info.plist.
VERSION ?=

.PHONY: build app run install clean icon icon-png dmg

build:
	swift build -c release

app: build $(ICNS)
	rm -rf $(APPDIR)
	mkdir -p $(APPDIR)/Contents/MacOS $(APPDIR)/Contents/Resources
	cp $(BIN) $(APPDIR)/Contents/MacOS/$(APP)
	cp Info.plist $(APPDIR)/Contents/
	cp $(ICNS) $(APPDIR)/Contents/Resources/AppIcon.icns
	cp -R Resources/*.lproj $(APPDIR)/Contents/Resources/
	if [ -n "$(VERSION)" ]; then \
	    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(APPDIR)/Contents/Info.plist; \
	fi
	codesign --force --sign - $(APPDIR)
	@echo "Fertig: $(APPDIR)"

run: app
	open $(APPDIR)

install: app
	rm -rf /Applications/$(APP).app
	cp -R $(APPDIR) /Applications/
	@echo "Installiert: /Applications/$(APP).app"

# Disk image with the app and a link to /Applications, ready to drag and drop.
dmg: app
	rm -rf build/dmg $(DMG)
	mkdir -p build/dmg
	cp -R $(APPDIR) build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname $(APP) -srcfolder build/dmg -ov -format UDZO -quiet $(DMG)
	rm -rf build/dmg
	@echo "Fertig: $(DMG)"

icon: $(ICNS)

# Assets/AppIcon.png is the rendered Assets/AppIcon.svg and is committed, so building
# needs no SVG renderer. Re-render after editing the SVG with `make icon-png`
# (QuickLook handles gradients and groups, ImageMagick's own SVG renderer does not).
icon-png:
	rm -f build/AppIcon.svg.png
	mkdir -p build
	qlmanage -t -s 1024 -o build Assets/AppIcon.svg >/dev/null
	mv build/AppIcon.svg.png Assets/AppIcon.png

# The icns is assembled with sips and iconutil only, both ship with macOS.
$(ICNS): Assets/AppIcon.png
	rm -rf build/AppIcon.iconset
	mkdir -p build/AppIcon.iconset
	for s in 16 32 128 256 512; do \
	    sips -z $$s $$s Assets/AppIcon.png --out build/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
	    sips -z $$((s*2)) $$((s*2)) Assets/AppIcon.png --out build/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns build/AppIcon.iconset -o $(ICNS)

clean:
	rm -rf .build build

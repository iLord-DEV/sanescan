# SaneScan - build the SwiftUI app bundle without Xcode project files.
APP     = SaneScan
BIN     = .build/release/$(APP)
APPDIR  = build/$(APP).app
ICNS    = build/AppIcon.icns

.PHONY: build app run install clean icon

build:
	swift build -c release

app: build $(ICNS)
	rm -rf $(APPDIR)
	mkdir -p $(APPDIR)/Contents/MacOS $(APPDIR)/Contents/Resources
	cp $(BIN) $(APPDIR)/Contents/MacOS/$(APP)
	cp Info.plist $(APPDIR)/Contents/
	cp $(ICNS) $(APPDIR)/Contents/Resources/AppIcon.icns
	cp -R Resources/*.lproj $(APPDIR)/Contents/Resources/
	codesign --force --sign - $(APPDIR)
	@echo "Fertig: $(APPDIR)"

run: app
	open $(APPDIR)

install: app
	rm -rf /Applications/$(APP).app
	cp -R $(APPDIR) /Applications/
	@echo "Installiert: /Applications/$(APP).app"

icon: $(ICNS)

# Icon: Assets/AppIcon.svg rendered by QuickLook (full SVG support, ships with macOS),
# scaled with ImageMagick and packed with iconutil.
$(ICNS): Assets/AppIcon.svg
	mkdir -p build/AppIcon.iconset
	rm -f build/AppIcon.svg.png
	qlmanage -t -s 1024 -o build Assets/AppIcon.svg >/dev/null
	mv build/AppIcon.svg.png build/icon-1024.png
	for s in 16 32 128 256 512; do \
	    magick build/icon-1024.png -resize $${s}x$${s} build/AppIcon.iconset/icon_$${s}x$${s}.png; \
	    magick build/icon-1024.png -resize $$((s*2))x$$((s*2)) build/AppIcon.iconset/icon_$${s}x$${s}@2x.png; \
	done
	iconutil -c icns build/AppIcon.iconset -o $(ICNS)

clean:
	rm -rf .build build

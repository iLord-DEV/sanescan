# PageScan - build the SwiftUI app bundle without Xcode project files.
APP     = PageScan
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
	codesign --force --sign - $(APPDIR)
	@echo "Fertig: $(APPDIR)"

run: app
	open $(APPDIR)

install: app
	rm -rf /Applications/$(APP).app
	cp -R $(APPDIR) /Applications/
	@echo "Installiert: /Applications/$(APP).app"

icon: $(ICNS)

# Simple generated icon: blue rounded square with a white page and text lines.
$(ICNS): Makefile
	mkdir -p build/AppIcon.iconset
	magick -size 1024x1024 xc:none \
	    -fill '#2F6BD8' -draw 'roundrectangle 64,64 960,960 220,220' \
	    -fill white -draw 'roundrectangle 300,190 724,834 36,36' \
	    -fill '#2F6BD8' \
	    -draw 'roundrectangle 370,300 654,336 18,18' \
	    -draw 'roundrectangle 370,400 654,436 18,18' \
	    -draw 'roundrectangle 370,500 654,536 18,18' \
	    -draw 'roundrectangle 370,600 560,636 18,18' \
	    build/icon-1024.png
	for s in 16 32 128 256 512; do \
	    magick build/icon-1024.png -resize $${s}x$${s} build/AppIcon.iconset/icon_$${s}x$${s}.png; \
	    magick build/icon-1024.png -resize $$((s*2))x$$((s*2)) build/AppIcon.iconset/icon_$${s}x$${s}@2x.png; \
	done
	iconutil -c icns build/AppIcon.iconset -o $(ICNS)

clean:
	rm -rf .build build

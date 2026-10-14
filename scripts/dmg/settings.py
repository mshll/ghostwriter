# dmgbuild settings for the DMG window. Finder ignores AppleScript layout on macOS 26+.
# dmgbuild pairs background.png with background@2x.png. Rebuild both after editing background.svg:
#   rsvg-convert -w 640 -h 400 background.svg -o background.png
#   rsvg-convert -w 1280 -h 800 background.svg -o background@2x.png
import os.path

app = defines["app"]
name = os.path.basename(app)

format = "ULFO"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [name]
background = defines["background"]
# 400 pt of background plus the title bar.
window_rect = ((200, 120), (640, 432))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
# Either side of the arrow in background.svg.
icon_locations = {name: (170, 190), "Applications": (470, 190)}

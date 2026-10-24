# dmgbuild settings for VideoLibrary.dmg (used by scripts/package.sh).
# The background is drawn by scripts/draw_dmg_background.swift; icon
# positions here must match the arrow in that drawing.
import os.path

app = defines.get("app", "VideoLibrary.app")  # noqa: F821 (defines is provided by dmgbuild)
background_dir = defines.get("background_dir", "assets/dmg")  # noqa: F821

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extension = [os.path.basename(app)]

background = os.path.join(background_dir, "background.png")  # @2x is picked up automatically
# Window frame: 400 pt of content (the background) plus the title bar.
window_rect = ((200, 160), (660, 428))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    os.path.basename(app): (170, 190),
    "Applications": (490, 190),
}

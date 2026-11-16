#!/usr/bin/env python3
"""Builds the Gauss app icon from Christian Albrecht Jensen's 1840 portrait of
Carl Friedrich Gauss (public domain, via Wikimedia Commons):
https://commons.wikimedia.org/wiki/File:Carl_Friedrich_Gauss_1840_by_Jensen.jpg

Usage: python3 Design/make-icon.py path/to/Carl_Friedrich_Gauss_1840_by_Jensen.jpg
Needs Pillow. Writes Design/AppIcon-1024.png and the app's icon assets."""
import sys
from pathlib import Path
from PIL import Image, ImageOps

root = Path(__file__).resolve().parent.parent
src = Image.open(sys.argv[1]).convert("RGB")

# Square crop around the face, then a navy-to-cream duotone.
cx, cy, side = 835, 600, 820
face = src.crop((cx - side // 2, cy - side // 2, cx + side // 2, cy + side // 2))
face = face.resize((1024, 1024), Image.LANCZOS)
grey = ImageOps.autocontrast(face.convert("L"), cutoff=1)
icon = ImageOps.colorize(grey, black="#101a4a", white="#f4ead8", mid="#6a7fb8")

icon.save(root / "Design/AppIcon-1024.png")
icon.save(root / "Gauss/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
icon.resize((240, 240), Image.LANCZOS).save(root / "Gauss/Assets.xcassets/AboutIcon.imageset/AboutIcon.png")

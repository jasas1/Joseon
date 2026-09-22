# App icon

`icon.swift` draws the icon variants in code (Core Graphics): `swift scripts/icon/icon.swift <outDir>` writes `icon-A.png`, `icon-B.png`, `icon-C.png` (1024 px).
The shipped `scripts/AppIcon.icns` uses variant A (spectrum with harmonic peaks) for 64 px and up, and the simplified silhouette B for the 16 and 32 px slots, where A's peaks turn to mud.
Rebuild: scale the PNGs into an `AppIcon.iconset` with `sips`, then `iconutil -c icns AppIcon.iconset -o scripts/AppIcon.icns`. `scripts/bundle.sh` copies the icns into the app.

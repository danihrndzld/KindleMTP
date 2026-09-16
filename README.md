# KindleMTP

Native macOS app for Kindles that only expose MTP (Scribe, Paperwhite 5/6,
Colorsoft, Kindle 2022+). macOS has no MTP support built in.

    brew install libmtp
    ./build.sh
    open KindleMTP.app

Browse folders, drag files in from Finder to send, download or delete the
selection, make folders. Double-click a text file (`.txt`, `.json`, `.opf`,
…) to edit it in place — saving uploads the new copy before deleting the
old one, so a failed save can't lose the file. Anything else downloads to
`~/Downloads`.

Headless check, also the smoke test:

    ./KindleMTP.app/Contents/MacOS/KindleMTP --probe

Notes:
- If your Kindle mounts under `/Volumes` it's mass-storage, not MTP — just use Finder.
- Links `libmtp` by absolute Homebrew path, so it only runs on a machine that has it installed.
- Editors flag `LIBMTP_*` symbols as unresolved since there's no Xcode project; `./build.sh` compiles fine.

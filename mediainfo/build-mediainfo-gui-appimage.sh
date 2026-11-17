#!/usr/bin/env bash
# Build MediaInfo (GUI + CLI) from a pinned release into a portable AppImage.
#
# Builds in a Debian 12 container, so the AppImage needs glibc 2.36 or newer.
# Run the AppImage for the GUI, or "AppImage --cli ARGS" for the CLI.
#
# Settings (environment): WORK_DIR, OUT_DIR, CONTAINER_ENGINE (see README).
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"

MEDIAINFO_VER=26.10
MEDIAINFO_SHA256=33b0d63a9d4c16fe0579173bb2d1cb8d665f722875db791bac11ba881b5099bb
MEDIAINFOLIB_SHA256=3985db56d18d504b0852c1485cfa9dbaf2733876058e9b8dc1b1411ebeba225d
ZENLIB_VER=0.4.41
ZENLIB_SHA256=45d5173fa0278f5264daa6836ae297aa303984482227d00b35c4f03929494c8f
# debian:bookworm-20261104
DEBIAN_IMAGE=docker.io/library/debian@sha256:268fb24c39bca92d326dd83ea3abebe4a3f7751c804ffef23bb6d857dd343ff8

# ── Inside the container: build and assemble /work/MediaInfo.AppDir ─────────
container_main() {
  local prefix=/work/prefix appdir=/work/MediaInfo.AppDir src=/work/src
  export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"

  log "apt packages"
  # librsvg2-common: SVG image loader, for the SVG icons in GTK themes.
  apt_install build-essential autoconf automake libtool pkg-config \
    libwxgtk3.2-dev zlib1g-dev libgtk-3-dev libgdk-pixbuf2.0-bin \
    librsvg2-common libglib2.0-bin patchelf python3

  rm -rf "$src" "$prefix" "$appdir"
  mkdir -p "$src"
  tar -xzf "/work/cache/ZenLib-$ZENLIB_VER.tar.gz" -C "$src"
  tar -xzf "/work/cache/MediaInfoLib-$MEDIAINFO_VER.tar.gz" -C "$src"
  tar -xzf "/work/cache/MediaInfo-$MEDIAINFO_VER.tar.gz" -C "$src"
  local zen="$src/ZenLib-$ZENLIB_VER" mil="$src/MediaInfoLib-$MEDIAINFO_VER"
  local mi="$src/MediaInfo-$MEDIAINFO_VER"

  autotools() { # autotools NAME DIR CONFIGURE_ARGS...
    local name=$1 dir=$2
    shift 2
    log "build $name"
    (
      cd "$dir"
      ./autogen.sh >/dev/null
      ./configure --prefix="$prefix" "$@" >/dev/null
      make -s -j"$(nproc)" >/dev/null
      make -s install >/dev/null
    )
  }
  autotools ZenLib "$zen/Project/GNU/Library" --enable-static --disable-shared
  autotools MediaInfoLib "$mil/Project/GNU/Library" --enable-static --disable-shared
  autotools "MediaInfo CLI" "$mi/Project/GNU/CLI" --enable-staticlibs
  autotools "MediaInfo GUI" "$mi/Project/GNU/GUI" --enable-staticlibs

  log "assemble AppDir"
  mkdir -p "$appdir/usr/bin" "$appdir/usr/share/applications" "$appdir/usr/share/metainfo"
  install -m 755 "$prefix/bin/mediainfo" "$prefix/bin/mediainfo-gui" "$appdir/usr/bin/"
  strip --strip-unneeded "$appdir/usr/bin/mediainfo" "$appdir/usr/bin/mediainfo-gui"
  local desktop="$prefix/share/applications/mediainfo-gui.desktop"
  install -m 644 "$desktop" "$appdir/usr/share/applications/"
  install -m 644 "$desktop" "$appdir/mediainfo-gui.desktop"
  install -m 644 "$prefix/share/metainfo/mediainfo-gui.metainfo.xml" "$appdir/usr/share/metainfo/"
  cp -r "$prefix/share/icons" "$appdir/usr/share/"
  install -m 644 "$prefix/share/icons/hicolor/256x256/apps/mediainfo.png" "$appdir/mediainfo.png"
  stage_pixbuf_loaders "$appdir"

  # GTK's own settings schemas (the file chooser aborts without them). Only
  # GTK's: the host's schemas stay visible through XDG_DATA_DIRS.
  mkdir -p "$appdir/usr/share/glib-2.0/schemas"
  cp /usr/share/glib-2.0/schemas/org.gtk.Settings.*.gschema.xml "$appdir/usr/share/glib-2.0/schemas/"
  glib-compile-schemas "$appdir/usr/share/glib-2.0/schemas"

  log "bundle libraries"
  bundle "$appdir"

  log "licenses"
  local lic="$appdir/usr/share/licenses"
  mkdir -p "$lic/MediaInfo" "$lic/MediaInfoLib" "$lic/ZenLib"
  cp "$mi/LICENSE" "$mi/License.html" "$lic/MediaInfo/"
  cp "$mil/LICENSE" "$lic/MediaInfoLib/"
  cp "$zen/License.txt" "$lic/ZenLib/"
  licenses "$appdir" libgtk-3-common librsvg2-common libgdk-pixbuf-2.0-0

  container_done
}

if [[ "${1:-}" == "--in-container" ]]; then
  container_main
  exit 0
fi

# ── On the host: download, build in the container, pack ─────────────────────
host_init mediainfo
GH=https://github.com/MediaArea
fetch "$GH/ZenLib/archive/refs/tags/v$ZENLIB_VER.tar.gz" \
  "ZenLib-$ZENLIB_VER.tar.gz" "$ZENLIB_SHA256"
fetch "$GH/MediaInfoLib/archive/refs/tags/v$MEDIAINFO_VER.tar.gz" \
  "MediaInfoLib-$MEDIAINFO_VER.tar.gz" "$MEDIAINFOLIB_SHA256"
fetch "$GH/MediaInfo/archive/refs/tags/v$MEDIAINFO_VER.tar.gz" \
  "MediaInfo-$MEDIAINFO_VER.tar.gz" "$MEDIAINFO_SHA256"

run_in_container "$DEBIAN_IMAGE" "${BASH_SOURCE[0]}"

APPDIR="$WORK/MediaInfo.AppDir"
{
  cat <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
EOF
  apprun_pixbuf mediainfo-appimage
  cat <<'EOF'
# Our share/ first (GTK schemas, icons), then the host's. An unset
# XDG_DATA_DIRS means the spec default, which must be kept.
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

if [ "${1:-}" = "--cli" ]; then
  shift
  exec "$HERE/usr/bin/mediainfo" "$@"
fi
exec "$HERE/usr/bin/mediainfo-gui" "$@"
EOF
} >"$APPDIR/AppRun"
chmod 755 "$APPDIR/AppRun"

OUT="$OUT_DIR/MediaInfo-$MEDIAINFO_VER-x86_64.AppImage"
pack_appimage "$APPDIR" "$OUT" "$MEDIAINFO_VER"
"$OUT" --cli --Version
log "Done. GUI: $OUT   CLI: $OUT --cli FILE"

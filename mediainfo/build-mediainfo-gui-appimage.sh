#!/usr/bin/env bash
# Build MediaInfo (GUI + CLI) from a pinned release into a portable AppImage.
#
# The build runs in a Debian 12 container (podman or docker), so the AppImage
# needs glibc 2.36 or newer and runs on Debian 12, Ubuntu 22.10+, Fedora 37+,
# Arch and the like. Everything downloaded is pinned and checked with SHA-256;
# Debian packages come from apt, which checks their signatures.
#
# Usage: ./build-mediainfo-gui-appimage.sh
#
# Settings (environment):
#   WORK_DIR          build folder       (default ~/.cache/mediainfo-appimage)
#   OUT_DIR           where the AppImage goes            (default ~/Desktop)
#   CONTAINER_ENGINE  podman or docker            (default: whichever exists)
#
# Run it as: AppImage = GUI, "AppImage --cli ARGS" = command-line mediainfo.
set -euo pipefail

# ── Pins ────────────────────────────────────────────────────────────────────
MEDIAINFO_VER=26.10
MEDIAINFO_SHA256=33b0d63a9d4c16fe0579173bb2d1cb8d665f722875db791bac11ba881b5099bb
MEDIAINFOLIB_SHA256=3985db56d18d504b0852c1485cfa9dbaf2733876058e9b8dc1b1411ebeba225d
ZENLIB_VER=0.4.41
ZENLIB_SHA256=45d5173fa0278f5264daa6836ae297aa303984482227d00b35c4f03929494c8f
# debian:bookworm-20261104
DEBIAN_IMAGE=docker.io/library/debian@sha256:268fb24c39bca92d326dd83ea3abebe4a3f7751c804ffef23bb6d857dd343ff8
APPIMAGETOOL_VER=1.9.1
APPIMAGETOOL_SHA256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
RUNTIME_VER=20251108
RUNTIME_SHA256=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

# ════════════════════════════════════════════════════════════════════════════
# Inside the container: build MediaInfo and assemble /work/MediaInfo.AppDir.
# ════════════════════════════════════════════════════════════════════════════
container_main() {
  local W=/work PREFIX=/work/prefix APPDIR=/work/MediaInfo.AppDir
  local MULTIARCH=x86_64-linux-gnu
  local PIXBUF_DIR="/usr/lib/$MULTIARCH/gdk-pixbuf-2.0"
  export DEBIAN_FRONTEND=noninteractive
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

  log "apt packages"
  apt-get update -qq
  # librsvg2-common: SVG loader, needed for the many SVG icons in GTK themes.
  apt-get install -y -qq --no-install-recommends \
    build-essential autoconf automake libtool pkg-config ca-certificates \
    libwxgtk3.2-dev zlib1g-dev libgtk-3-dev libgdk-pixbuf2.0-bin librsvg2-common \
    libglib2.0-bin patchelf python3 >/dev/null

  log "unpack sources"
  rm -rf "$W/src" "$PREFIX" "$APPDIR"
  mkdir -p "$W/src"
  tar -xzf "$W/cache/ZenLib-$ZENLIB_VER.tar.gz" -C "$W/src"
  tar -xzf "$W/cache/MediaInfoLib-$MEDIAINFO_VER.tar.gz" -C "$W/src"
  tar -xzf "$W/cache/MediaInfo-$MEDIAINFO_VER.tar.gz" -C "$W/src"
  local ZEN="$W/src/ZenLib-$ZENLIB_VER" MIL="$W/src/MediaInfoLib-$MEDIAINFO_VER"
  local MI="$W/src/MediaInfo-$MEDIAINFO_VER"

  build() { # build NAME DIR CONFIGURE_ARGS...
    local name=$1 dir=$2; shift 2
    log "build $name"
    (
      cd "$dir"
      ./autogen.sh >/dev/null
      ./configure --prefix="$PREFIX" "$@" >/dev/null
      make -s -j"$(nproc)" >/dev/null
      make -s install >/dev/null
    )
  }
  build ZenLib       "$ZEN/Project/GNU/Library" --enable-static --disable-shared
  build MediaInfoLib "$MIL/Project/GNU/Library" --enable-static --disable-shared
  build "MediaInfo CLI" "$MI/Project/GNU/CLI"   --enable-staticlibs
  build "MediaInfo GUI" "$MI/Project/GNU/GUI"   --enable-staticlibs

  log "assemble AppDir"
  mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib/gdk-pixbuf-2.0" \
    "$APPDIR/usr/share/applications" "$APPDIR/usr/share/metainfo"
  install -m 755 "$PREFIX/bin/mediainfo" "$PREFIX/bin/mediainfo-gui" "$APPDIR/usr/bin/"
  strip --strip-unneeded "$APPDIR/usr/bin/mediainfo" "$APPDIR/usr/bin/mediainfo-gui"

  local desktop="$PREFIX/share/applications/mediainfo-gui.desktop"
  install -m 644 "$desktop" "$APPDIR/usr/share/applications/"
  install -m 644 "$desktop" "$APPDIR/mediainfo-gui.desktop"
  install -m 644 "$PREFIX/share/metainfo/mediainfo-gui.metainfo.xml" "$APPDIR/usr/share/metainfo/"
  cp -r "$PREFIX/share/icons" "$APPDIR/usr/share/"
  install -m 644 "$PREFIX/share/icons/hicolor/256x256/apps/mediainfo.png" "$APPDIR/mediainfo.png"

  # Image loaders; AppRun writes the loader cache at launch, because it holds
  # absolute paths and the AppImage mount point changes every run.
  cp -r "$PIXBUF_DIR/2.10.0/loaders" "$APPDIR/usr/lib/gdk-pixbuf-2.0/"
  install -m 755 "$PIXBUF_DIR/gdk-pixbuf-query-loaders" "$APPDIR/usr/bin/"

  # GTK's own settings schemas (the file chooser aborts without them). Only
  # GTK's: the host's schemas stay visible through XDG_DATA_DIRS.
  mkdir -p "$APPDIR/usr/share/glib-2.0/schemas"
  cp /usr/share/glib-2.0/schemas/org.gtk.Settings.*.gschema.xml "$APPDIR/usr/share/glib-2.0/schemas/"
  glib-compile-schemas "$APPDIR/usr/share/glib-2.0/schemas"

  log "bundle shared libraries"
  bundle_libs "$APPDIR"

  # RUNPATH instead of LD_LIBRARY_PATH, so programs started from the GUI
  # (browser, file manager) don't inherit our libraries.
  local f
  for f in "$APPDIR"/usr/bin/*; do patchelf --set-rpath '$ORIGIN/../lib' "$f"; done
  for f in "$APPDIR"/usr/lib/*.so*; do patchelf --set-rpath '$ORIGIN' "$f"; done
  for f in "$APPDIR"/usr/lib/gdk-pixbuf-2.0/loaders/*.so; do
    patchelf --set-rpath '$ORIGIN/../..' "$f"
  done

  log "check that every library resolves"
  local missing
  missing="$(for f in "$APPDIR"/usr/bin/* "$APPDIR"/usr/lib/*.so* "$APPDIR"/usr/lib/gdk-pixbuf-2.0/loaders/*.so; do
      ldd "$f" | grep 'not found' || true
    done | sort -u)"
  [[ -z "$missing" ]] || die "unresolved libraries:"$'\n'"$missing"

  log "licenses"
  write_licenses "$APPDIR" "$MI" "$MIL" "$ZEN"

  local glibc
  glibc="$(for f in "$APPDIR"/usr/bin/* "$APPDIR"/usr/lib/*.so* "$APPDIR"/usr/lib/gdk-pixbuf-2.0/loaders/*.so; do
      objdump -T "$f" 2>/dev/null | grep -o 'GLIBC_2\.[0-9]*' || true
    done | sort -t. -k2 -n -u | tail -1)"
  log "needs ${glibc:-GLIBC_?} or newer"

  if [[ -n "${CHOWN_TO:-}" ]]; then
    chown -R "$CHOWN_TO" "$W"
  fi
}

# Copy the dependencies of everything in the AppDir into usr/lib, except
# libraries the host must provide: glibc, the C++ runtime (the host's is newer
# than Debian 12's, and graphics drivers need the newer one), graphics drivers,
# and X11/font libraries, which have to match the host's setup. Writes the
# source path of each bundled library to usr/lib/.bundled for write_licenses.
bundle_libs() {
  python3 -I - "$1" <<'PY'
import re, shutil, subprocess, sys
from pathlib import Path

appdir = Path(sys.argv[1])
libdir = appdir / "usr" / "lib"

HOST_PROVIDED = (
    # glibc
    "ld-linux", "libc.so", "libm.so", "libmvec.so", "libdl.so", "libpthread.so",
    "librt.so", "libresolv.so", "libnss_", "libnsl.so", "libutil.so", "libanl.so",
    "libBrokenLocale", "libthread_db",
    # compiler runtime
    "libstdc++.so", "libgcc_s.so",
    # graphics drivers
    "libGL.so", "libGLX", "libGLdispatch", "libOpenGL", "libEGL", "libGLES",
    "libglapi", "libdrm", "libgbm", "libvulkan", "libwayland-egl",
    # X11 and fonts
    "libX11.so", "libX11-xcb", "libxcb.so", "libxcb-dri", "libxcb-glx",
    "libxcb-present", "libxcb-sync", "libxshmfence",
    "libfontconfig", "libfreetype", "libharfbuzz.so",
    # base system
    "libz.so", "libexpat", "libcom_err", "libgpg-error", "libuuid", "libasound",
    "linux-vdso",
)

def host_provided(name):
    return name.startswith(HOST_PROVIDED)

def deps(path):
    out = subprocess.run(["ldd", str(path)], capture_output=True, text=True).stdout
    for line in out.splitlines():
        m = re.match(r"\s*(\S+) => (/\S+) \(", line)
        if m:
            yield m.group(1), Path(m.group(2))

seeds = [p for p in (appdir / "usr" / "bin").iterdir()]
seeds += list((libdir / "gdk-pixbuf-2.0" / "loaders").glob("*.so"))
queue = [d for s in seeds for d in deps(s)]
bundled = {}
while queue:
    name, real = queue.pop()
    if name in bundled or host_provided(name):
        continue
    real = real.resolve()
    shutil.copy2(real, libdir / name)
    (libdir / name).chmod(0o755)
    bundled[name] = real
    queue.extend(deps(real))

(libdir / ".bundled").write_text("".join(f"{n}\t{p}\n" for n, p in sorted(bundled.items())))
print(f"bundled {len(bundled)} libraries")
PY
}

# usr/share/licenses: MediaInfo's own licenses, plus the Debian copyright file
# of every package a bundled library (or image loader) came from.
write_licenses() {
  local appdir=$1 mi=$2 mil=$3 zen=$4
  local lic="$appdir/usr/share/licenses"
  mkdir -p "$lic/MediaInfo" "$lic/MediaInfoLib" "$lic/ZenLib"
  cp "$mi/LICENSE" "$mi/License.html" "$lic/MediaInfo/"
  cp "$mil/LICENSE" "$lic/MediaInfoLib/"
  cp "$zen/License.txt" "$lic/ZenLib/"

  local path pkg pkgs=()
  while IFS=$'\t' read -r _ path; do
    pkg="$(dpkg -S "$path" 2>/dev/null || dpkg -S "${path#/usr}" 2>/dev/null || true)"
    pkgs+=("${pkg%%:*}")
  done <"$appdir/usr/lib/.bundled"
  for path in "$appdir"/usr/lib/gdk-pixbuf-2.0/loaders/*.so; do
    pkg="$(dpkg -S "*/$(basename "$path")" 2>/dev/null | head -1 || true)"
    pkgs+=("${pkg%%:*}")
  done
  pkgs+=(libgdk-pixbuf-2.0-0 libgtk-3-common)
  rm "$appdir/usr/lib/.bundled"

  local n=0
  for pkg in $(printf '%s\n' "${pkgs[@]}" | grep -v '^$' | sort -u); do
    if [[ -f "/usr/share/doc/$pkg/copyright" ]]; then
      mkdir -p "$lic/$pkg"
      cp "/usr/share/doc/$pkg/copyright" "$lic/$pkg/"
      n=$((n + 1))
    fi
  done
  echo "copyright files for $n Debian packages"
}

if [[ "${1:-}" == "--in-container" ]]; then
  container_main
  exit 0
fi

# ════════════════════════════════════════════════════════════════════════════
# On the host: download and verify, run the container build, pack, test.
# ════════════════════════════════════════════════════════════════════════════
[[ "$(uname -m)" == "x86_64" ]] || die "only x86_64 is supported"
for c in curl sha256sum; do command -v "$c" >/dev/null || die "missing command: $c"; done

ENGINE="${CONTAINER_ENGINE:-}"
if [[ -z "$ENGINE" ]]; then
  if command -v podman >/dev/null; then ENGINE=podman
  elif command -v docker >/dev/null; then ENGINE=docker
  else die "needs podman or docker (Arch: sudo pacman -S podman)"
  fi
fi

SELF="$(readlink -f "$0")"
WORK="${WORK_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/mediainfo-appimage}"
OUT_DIR="${OUT_DIR:-$HOME/Desktop}"
OUT="$OUT_DIR/MediaInfo-${MEDIAINFO_VER}-x86_64.AppImage"
CACHE="$WORK/cache"
mkdir -p "$CACHE" "$OUT_DIR"

# fetch URL FILE SHA256: download into the cache unless a verified copy is
# already there. Downloads go to a temp name first, so an interrupted
# transfer never looks like a finished file.
fetch() {
  local url=$1 dest="$CACHE/$2" want=$3
  if [[ -f "$dest" ]] && [[ "$(sha256sum "$dest" | cut -d' ' -f1)" == "$want" ]]; then
    return
  fi
  log "download $2"
  curl -fsSL --retry 3 -o "$dest.part" "$url"
  local got
  got="$(sha256sum "$dest.part" | cut -d' ' -f1)"
  if [[ "$got" != "$want" ]]; then
    rm -f "$dest.part"
    die "SHA-256 mismatch for $2: expected $want, got $got"
  fi
  mv -f "$dest.part" "$dest"
}

GH=https://github.com
fetch "$GH/MediaArea/ZenLib/archive/refs/tags/v$ZENLIB_VER.tar.gz" \
  "ZenLib-$ZENLIB_VER.tar.gz" "$ZENLIB_SHA256"
fetch "$GH/MediaArea/MediaInfoLib/archive/refs/tags/v$MEDIAINFO_VER.tar.gz" \
  "MediaInfoLib-$MEDIAINFO_VER.tar.gz" "$MEDIAINFOLIB_SHA256"
fetch "$GH/MediaArea/MediaInfo/archive/refs/tags/v$MEDIAINFO_VER.tar.gz" \
  "MediaInfo-$MEDIAINFO_VER.tar.gz" "$MEDIAINFO_SHA256"
fetch "$GH/AppImage/appimagetool/releases/download/$APPIMAGETOOL_VER/appimagetool-x86_64.AppImage" \
  "appimagetool-$APPIMAGETOOL_VER-x86_64.AppImage" "$APPIMAGETOOL_SHA256"
fetch "$GH/AppImage/type2-runtime/releases/download/$RUNTIME_VER/runtime-x86_64" \
  "runtime-$RUNTIME_VER-x86_64" "$RUNTIME_SHA256"

# Rootless podman maps container root to you, so files come out owned by you.
# Docker's root is the real root, so hand the files back at the end.
CHOWN_ARGS=()
if [[ "$ENGINE" == docker ]]; then
  CHOWN_ARGS=(-e "CHOWN_TO=$(id -u):$(id -g)")
fi

log "container build ($ENGINE, Debian 12)"
"$ENGINE" run --rm \
  "${CHOWN_ARGS[@]}" \
  -v "$SELF:/build.sh:ro" -v "$WORK:/work" \
  "$DEBIAN_IMAGE" bash /build.sh --in-container

APPDIR="$WORK/MediaInfo.AppDir"
cat >"$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"

# Image loader cache: regenerated each launch (the mount point changes), written
# to a temp name and renamed so two instances starting at once don't clash.
cache="${XDG_CACHE_HOME:-$HOME/.cache}/mediainfo-appimage"
if mkdir -p "$cache" 2>/dev/null; then
  export GDK_PIXBUF_MODULEDIR="$HERE/usr/lib/gdk-pixbuf-2.0/loaders"
  export GDK_PIXBUF_MODULE_FILE="$cache/pixbuf-loaders.cache"
  "$HERE/usr/bin/gdk-pixbuf-query-loaders" >"$GDK_PIXBUF_MODULE_FILE.$$" 2>/dev/null \
    && mv -f "$GDK_PIXBUF_MODULE_FILE.$$" "$GDK_PIXBUF_MODULE_FILE"
  rm -f "$GDK_PIXBUF_MODULE_FILE.$$"
fi

# Our share/ first (GTK schemas, icons), then the host's. An unset
# XDG_DATA_DIRS means the spec default, which must be kept.
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

if [ "${1:-}" = "--cli" ]; then
  shift
  exec "$HERE/usr/bin/mediainfo" "$@"
fi
exec "$HERE/usr/bin/mediainfo-gui" "$@"
EOF
chmod 755 "$APPDIR/AppRun"

log "pack $OUT"
AT="$CACHE/appimagetool-$APPIMAGETOOL_VER-x86_64.AppImage"
chmod 755 "$AT"
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 VERSION="$MEDIAINFO_VER" \
  "$AT" -n --runtime-file "$CACHE/runtime-$RUNTIME_VER-x86_64" "$APPDIR" "$OUT.part" >/dev/null
chmod 755 "$OUT.part"
mv -f "$OUT.part" "$OUT"

log "test"
"$OUT" --cli --Version
ls -lh "$OUT"
log "Done. GUI: $OUT   CLI: $OUT --cli FILE"

#!/usr/bin/env bash
# Build Mousam (GTK 4 / libadwaita weather app) from a pinned release into a
# portable AppImage, with its own Python, GTK 4 and libadwaita.
#
# Mousam 3 needs libadwaita 1.6+, so this builds in a Debian 13 container and
# the AppImage needs glibc 2.41 or newer.
#
# Settings (environment): WORK_DIR, OUT_DIR, CONTAINER_ENGINE (see README).
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"

MOUSAM_VER=3.0.0
MOUSAM_SHA256=ae8a57bca6dbad7b7be5d27121f178bb3cd76e027e327a70c6be09ffc92e5c87
# debian:trixie-20261104
DEBIAN_IMAGE=docker.io/library/debian@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6
APP_ID=io.github.amit9838.mousam
PY=python3.13

# Python packages Mousam uses, with their dependencies (from Debian).
PY_PACKAGES=(gi cairo requests urllib3 idna certifi charset_normalizer chardet)

# ── Inside the container: build and assemble /work/Mousam.AppDir ────────────
container_main() {
  local appdir=/work/Mousam.AppDir src=/work/src build=/work/meson-build

  log "apt packages"
  apt_install patch meson ninja-build gettext libglib2.0-bin libglib2.0-dev-bin \
    desktop-file-utils gtk-update-icon-cache binutils patchelf tzdata \
    python3 python3-gi python3-gi-cairo python3-cairo python3-requests \
    gir1.2-gtk-4.0 gir1.2-adw-1 libgdk-pixbuf2.0-bin librsvg2-common \
    adwaita-icon-theme hicolor-icon-theme dconf-gsettings-backend

  rm -rf "$src" "$build" "$appdir"
  mkdir -p "$src"
  tar -xzf "/work/cache/mousam-$MOUSAM_VER.tar.gz" -C "$src"
  local mousam="$src/mousam-$MOUSAM_VER" patch_file
  # Our fixes on top of the release, in order; any that doesn't apply cleanly
  # stops the build.
  for patch_file in "$REPO"/mousam/patches/*.patch; do
    log "patch $(basename "$patch_file")"
    patch -d "$mousam" -p1 --forward --batch --fuzz=0 --quiet <"$patch_file"
  done

  log "build Mousam $MOUSAM_VER"
  meson setup "$build" "$mousam" --prefix=/usr --buildtype=plain >/dev/null
  meson compile -C "$build" >/dev/null
  # Upstream's checks: desktop file, AppStream data and settings schema.
  meson test -C "$build" --print-errorlogs >/dev/null
  meson install -C "$build" --destdir "$appdir" >/dev/null
  make_relocatable "$appdir"

  log "assemble AppDir"
  stage_python "$appdir"
  stage_gtk "$appdir"
  install -m 644 "$appdir/usr/share/applications/$APP_ID.desktop" "$appdir/"
  install -m 644 "$appdir/usr/share/icons/hicolor/scalable/apps/$APP_ID.svg" "$appdir/"

  log "bundle libraries"
  # GTK, libadwaita and friends are loaded by GObject introspection at
  # runtime, so nothing links to them: import what Mousam imports and take
  # every library the process ends up with.
  local runtime_libs
  mapfile -t runtime_libs < <(python3 -I - <<'PY'
import gi
for ns, ver in (("Gtk", "4.0"), ("Adw", "1"), ("Gsk", "4.0"), ("Graphene", "1.0"),
                ("PangoCairo", "1.0")):
    gi.require_version(ns, ver)
from gi.repository import Adw, GLib, Gio, Graphene, Gsk, Gtk, PangoCairo  # noqa: F401

repo = gi.Repository.get_default()
for ns in repo.get_loaded_namespaces():  # make sure each library is loaded
    for info in repo.get_infos(ns):
        if hasattr(info, "get_g_type"):
            try:
                info.get_g_type()
                break
            except Exception:  # some types can't be resolved; any one will do
                continue
seen = set()
with open("/proc/self/maps") as maps:
    for line in maps:
        path = line.split()[-1]
        if ".so" in path and path.startswith("/usr/lib/x86_64-linux-gnu/") and path not in seen:
            seen.add(path)
            print(path)
PY
  )
  ((${#runtime_libs[@]})) || die "found no runtime libraries"
  bundle "$appdir" "${runtime_libs[@]}"

  log "licenses"
  mkdir -p "$appdir/usr/share/licenses/mousam"
  cp "$mousam/COPYING" "$appdir/usr/share/licenses/mousam/"
  local py_paths=() pkg
  for pkg in "${PY_PACKAGES[@]}"; do
    py_paths+=("/usr/lib/python3/dist-packages/$pkg/__init__.py")
  done
  licenses "$appdir" "/usr/bin/$PY" "/usr/lib/$PY/os.py" \
    "/usr/lib/$PY/lib-dynload/_ssl.cpython-313-x86_64-linux-gnu.so" "${py_paths[@]}" \
    /usr/lib/x86_64-linux-gnu/girepository-1.0/*.typelib \
    tzdata adwaita-icon-theme hicolor-icon-theme librsvg2-common libgtk-4-common \
    dconf-gsettings-backend

  container_done
}

# Mousam bakes /usr/share paths in at install time; compute them from the
# file's own location instead, so the AppImage works from any mount point.
make_relocatable() {
  python3 -I - "$1" <<'PY'
import sys
from pathlib import Path

appdir = Path(sys.argv[1])

def patch(path, old, new, count):
    text = path.read_text()
    if text.count(old) != count:
        sys.exit(f"ERROR: {path}: expected {count}x {old!r}; upstream changed, update the patch")
    path.write_text(text.replace(old, new))

patch(appdir / "usr/bin/mousam",
      "pkgdatadir = '/usr/share/mousam'\nlocaledir = '/usr/share/locale'\n",
      "_share = os.path.join(os.path.dirname(os.path.realpath(__file__)), '..', 'share')\n"
      "pkgdatadir = os.path.join(_share, 'mousam')\n"
      "localedir = os.path.join(_share, 'locale')\n", 1)

icons = appdir / "usr/share/mousam/mousam/CORE_Icons.py"
patch(icons, '"/usr/share/icons/hicolor/scalable/', '_ICON_ROOT + "/', 2)
icons.write_text(
    "import os\n_ICON_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)),"
    ' "..", "..", "icons", "hicolor", "scalable")\n' + icons.read_text())

left = [str(p) for p in (appdir / "usr").rglob("*.py") if "/usr/" in p.read_text()]
left += [str(appdir / "usr/bin/mousam")] if "'/usr/" in (appdir / "usr/bin/mousam").read_text() else []
if left:
    sys.exit("ERROR: hardcoded /usr paths left in: " + ", ".join(left))
PY
  python3 -I -m compileall -q "$1/usr/share/mousam"
}

# Python interpreter, standard library and the Python packages Mousam uses.
stage_python() {
  local appdir=$1 pkg
  install -m 755 "/usr/bin/$PY" "$appdir/usr/bin/python3"
  mkdir -p "$appdir/usr/lib/python3/dist-packages"
  tar -C /usr/lib -cf - \
    --exclude="$PY/test" --exclude="$PY/idlelib" --exclude="$PY/tkinter" \
    --exclude="$PY/turtledemo" --exclude="$PY/ensurepip" --exclude="$PY/config-*" \
    "$PY" | tar -C "$appdir/usr/lib" -xf -
  local dist=/usr/lib/python3/dist-packages
  for pkg in "${PY_PACKAGES[@]}"; do
    cp -r "$dist/$pkg" "$appdir/usr/lib/python3/dist-packages/"
  done
  # Time zone database, used only when the host has none.
  cp -r /usr/share/zoneinfo "$appdir/usr/share/"
}

# GTK 4 runtime data: introspection typelibs, image loaders, the dconf
# settings module, settings schemas and the Adwaita icon theme (libadwaita's
# symbolic icons).
stage_gtk() {
  local appdir=$1 multiarch=/usr/lib/x86_64-linux-gnu
  mkdir -p "$appdir/usr/lib/girepository-1.0" "$appdir/usr/lib/gio/modules"
  cp "$multiarch"/girepository-1.0/*.typelib "$appdir/usr/lib/girepository-1.0/"
  stage_pixbuf_loaders "$appdir"
  # dconf: share settings with a regular Mousam install and with the desktop.
  install -m 755 "$multiarch/gio/modules/libdconfsettings.so" "$appdir/usr/lib/gio/modules/"
  "$multiarch/glib-2.0/gio-querymodules" "$appdir/usr/lib/gio/modules"

  local schemas="$appdir/usr/share/glib-2.0/schemas"
  cp /usr/share/glib-2.0/schemas/org.gtk.gtk4.*.gschema.xml "$schemas/"
  glib-compile-schemas --strict "$schemas"

  local icons="$appdir/usr/share/icons"
  cp -r /usr/share/icons/Adwaita "$icons/"
  rm -rf "$icons/Adwaita/cursors"  # the host's cursor theme is used
  cp /usr/share/icons/hicolor/index.theme "$icons/hicolor/"
  gtk-update-icon-cache -q -f "$icons/Adwaita"
  gtk-update-icon-cache -q -f "$icons/hicolor"
}

if [[ "${1:-}" == "--in-container" ]]; then
  container_main
  exit 0
fi

# ── On the host: download, build in the container, pack ─────────────────────
host_init mousam
fetch "https://github.com/amit9838/mousam/archive/refs/tags/v$MOUSAM_VER.tar.gz" \
  "mousam-$MOUSAM_VER.tar.gz" "$MOUSAM_SHA256"

run_in_container "$DEBIAN_IMAGE" "${BASH_SOURCE[0]}"

APPDIR="$WORK/Mousam.AppDir"
{
  cat <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
EOF
  apprun_pixbuf mousam-appimage
  cat <<'EOF'
# Our share/ first (schemas, icons, translations), then the host's. An unset
# XDG_DATA_DIRS means the spec default, which must be kept.
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export GI_TYPELIB_PATH="$HERE/usr/lib/girepository-1.0"
# The host's GIO modules are built for the host's GLib, so load only ours.
export GIO_MODULE_DIR="$HERE/usr/lib/gio/modules"
# Settings go to dconf, like a regular install, so they are shared with it.
# Without a dconf service on the host, use a key file instead
# (~/.config/glib-2.0/settings/keyfile).
if [ -z "${GSETTINGS_BACKEND:-}" ]; then
  dconf_service=
  old_ifs=$IFS
  IFS=:
  for d in $XDG_DATA_DIRS; do
    if [ -f "$d/dbus-1/services/ca.desrt.dconf.service" ]; then
      dconf_service=1
      break
    fi
  done
  IFS=$old_ifs
  [ -n "$dconf_service" ] || export GSETTINGS_BACKEND=keyfile
fi

export PYTHONHOME="$HERE/usr" PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1
unset PYTHONPATH PYTHONSTARTUP
# Time zones: the host's database first (the distro keeps it current).
export PYTHONTZPATH="/usr/share/zoneinfo:/usr/lib/zoneinfo:/usr/share/lib/zoneinfo:$HERE/usr/share/zoneinfo"
# CA certificates: our Python looks where Debian keeps them; other distros
# keep the bundle elsewhere.
if [ -z "${SSL_CERT_FILE:-}" ]; then
  for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
           /etc/ssl/ca-bundle.pem /etc/ssl/cert.pem; do
    if [ -r "$f" ]; then
      export SSL_CERT_FILE="$f"
      break
    fi
  done
fi
if [ -n "${SSL_CERT_FILE:-}" ] && [ -z "${REQUESTS_CA_BUNDLE:-}" ]; then
  export REQUESTS_CA_BUNDLE="$SSL_CERT_FILE"
fi

exec "$HERE/usr/bin/python3" "$HERE/usr/bin/mousam" "$@"
EOF
} >"$APPDIR/AppRun"
chmod 755 "$APPDIR/AppRun"

OUT="$OUT_DIR/Mousam-$MOUSAM_VER-x86_64.AppImage"
pack_appimage "$APPDIR" "$OUT" "$MOUSAM_VER"
log "Done: $OUT"

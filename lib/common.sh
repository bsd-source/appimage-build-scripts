# shellcheck shell=bash
# Shared helpers for the build scripts, sourced on the host and in the
# container. Callers set REPO (the repository root) before sourcing.

APPIMAGETOOL_VER=1.9.1
APPIMAGETOOL_SHA256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
RUNTIME_VER=20251108
RUNTIME_SHA256=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

# ── Host ────────────────────────────────────────────────────────────────────

# host_init NAME: check the build machine and set ENGINE, WORK, CACHE, OUT_DIR.
host_init() {
  local name=$1
  [[ "$(uname -m)" == x86_64 ]] || die "only x86_64 is supported"
  local c
  for c in curl sha256sum; do
    command -v "$c" >/dev/null || die "missing command: $c"
  done
  ENGINE="${CONTAINER_ENGINE:-}"
  if [[ -z "$ENGINE" ]]; then
    if command -v podman >/dev/null; then ENGINE=podman
    elif command -v docker >/dev/null; then ENGINE=docker
    else die "needs podman or docker (Arch: sudo pacman -S podman)"
    fi
  fi
  WORK="${WORK_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/appimage-build/$name}"
  CACHE="$WORK/cache"
  OUT_DIR="${OUT_DIR:-$HOME/Desktop}"
  mkdir -p "$CACHE" "$OUT_DIR"
}

# fetch URL NAME SHA256: download into $CACHE/NAME unless a copy with the
# right hash is already there. The download goes to a temp name first, so an
# interrupted transfer never looks like a finished file.
fetch() {
  local url=$1 dest="$CACHE/$2" want=$3 got
  if [[ -f "$dest" ]] && [[ "$(sha256sum "$dest" | cut -d' ' -f1)" == "$want" ]]; then
    return
  fi
  log "download $2"
  curl -fsSL --retry 3 -o "$dest.part" "$url"
  got="$(sha256sum "$dest.part" | cut -d' ' -f1)"
  if [[ "$got" != "$want" ]]; then
    rm -f "$dest.part"
    die "SHA-256 mismatch for $2: expected $want, got $got"
  fi
  mv -f "$dest.part" "$dest"
}

# run_in_container IMAGE SCRIPT: run "SCRIPT --in-container" in IMAGE, with
# the repository mounted read-only at /repo and $WORK at /work.
run_in_container() {
  local image=$1 script rel args=()
  script="$(readlink -f "$2")"
  rel="${script#"$REPO"/}"
  # Rootless podman maps container root to you, so files come out owned by
  # you. Docker's root is the real root, so the build hands them back.
  if [[ "$ENGINE" == docker ]]; then
    args+=(-e "CHOWN_TO=$(id -u):$(id -g)")
  fi
  log "container build ($ENGINE)"
  # z: relabel for SELinux hosts (Fedora); ignored elsewhere.
  "$ENGINE" run --rm "${args[@]}" \
    -v "$REPO:/repo:ro,z" -v "$WORK:/work:z" \
    "$image" bash "/repo/$rel" --in-container
}

# pack_appimage APPDIR OUT VERSION: pack with the pinned appimagetool and
# runtime. The AppImage appears at OUT only once it is complete.
pack_appimage() {
  local appdir=$1 out=$2 version=$3
  local tool="appimagetool-$APPIMAGETOOL_VER-x86_64.AppImage"
  local runtime="runtime-$RUNTIME_VER-x86_64"
  local gh=https://github.com/AppImage
  fetch "$gh/appimagetool/releases/download/$APPIMAGETOOL_VER/appimagetool-x86_64.AppImage" \
    "$tool" "$APPIMAGETOOL_SHA256"
  fetch "$gh/type2-runtime/releases/download/$RUNTIME_VER/runtime-x86_64" \
    "$runtime" "$RUNTIME_SHA256"
  chmod 755 "$CACHE/$tool"

  log "pack $out"
  APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 VERSION="$version" \
    "$CACHE/$tool" -n --runtime-file "$CACHE/$runtime" "$appdir" "$out.part" >/dev/null
  chmod 755 "$out.part"
  mv -f "$out.part" "$out"
  ls -lh "$out"
}

# ── Container ───────────────────────────────────────────────────────────────

# apt_install PKG...: install Debian packages (apt checks their signatures).
apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends "$@" >/dev/null
}

# bundle APPDIR [EXTRA_LIB...]: bundle shared libraries, set RUNPATHs, check.
bundle() { python3 -I "$REPO/lib/bundle.py" libs "$@"; }

# licenses APPDIR [PKG...]: copy Debian copyright files into the AppDir.
licenses() { python3 -I "$REPO/lib/bundle.py" licenses "$@"; }

# container_done: give the files back to the host user under docker.
container_done() {
  if [[ -n "${CHOWN_TO:-}" ]]; then
    chown -R "$CHOWN_TO" /work
  fi
}

# apprun_pixbuf CACHE_NAME: print the AppRun lines that point gdk-pixbuf at
# the bundled image loaders. The loader cache holds absolute paths and the
# AppImage mount point changes on every run, so it is rebuilt at launch,
# written to a temp name and renamed so two instances starting together don't
# clash. Expects HERE to be set.
apprun_pixbuf() {
  printf 'cache="${XDG_CACHE_HOME:-$HOME/.cache}/%s"\n' "$1"
  cat <<'EOF'
if mkdir -p "$cache" 2>/dev/null; then
  export GDK_PIXBUF_MODULEDIR="$HERE/usr/lib/gdk-pixbuf-2.0/loaders"
  export GDK_PIXBUF_MODULE_FILE="$cache/pixbuf-loaders.cache"
  "$HERE/usr/bin/gdk-pixbuf-query-loaders" >"$GDK_PIXBUF_MODULE_FILE.$$" 2>/dev/null \
    && mv -f "$GDK_PIXBUF_MODULE_FILE.$$" "$GDK_PIXBUF_MODULE_FILE"
  rm -f "$GDK_PIXBUF_MODULE_FILE.$$"
fi
EOF
}

# stage_pixbuf_loaders APPDIR: copy Debian's gdk-pixbuf loaders and the
# query tool into the AppDir.
stage_pixbuf_loaders() {
  local appdir=$1 src=/usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0
  mkdir -p "$appdir/usr/lib/gdk-pixbuf-2.0" "$appdir/usr/bin"
  cp -r "$src/2.10.0/loaders" "$appdir/usr/lib/gdk-pixbuf-2.0/"
  install -m 755 "$src/gdk-pixbuf-query-loaders" "$appdir/usr/bin/"
}

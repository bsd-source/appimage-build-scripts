#!/usr/bin/env python3
"""Bundle shared libraries into an AppDir. Runs inside the build container.

bundle.py libs APPDIR [EXTRA_LIB...]
    Copy the shared-library dependencies of every ELF file in APPDIR, and of
    any EXTRA_LIB (libraries loaded at runtime that nothing links to), into
    APPDIR/usr/lib. Then point each ELF file's RUNPATH at usr/lib, fail if any
    dependency is unresolved, and report the newest glibc version needed.

bundle.py licenses APPDIR [PACKAGE_OR_PATH...]
    Copy into APPDIR/usr/share/licenses the Debian copyright file of every
    package a bundled library came from, plus those of the named packages and
    of the packages owning the given absolute paths.
"""

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# Libraries the host must provide, matched by name prefix: glibc; the C++
# runtime (the host's is at least as new, and graphics drivers need the host's
# one); graphics drivers; X11 and fonts, which must match the host's setup;
# and small base libraries every distro has.
HOST_PROVIDED = (
    "ld-linux", "libc.so", "libm.so", "libmvec.so", "libdl.so", "libpthread.so",
    "librt.so", "libresolv.so", "libnss_", "libnsl.so", "libutil.so", "libanl.so",
    "libBrokenLocale", "libthread_db", "linux-vdso",
    "libstdc++.so", "libgcc_s.so",
    "libGL.so", "libGLX", "libGLdispatch", "libOpenGL", "libEGL", "libGLES",
    "libglapi", "libdrm", "libgbm", "libvulkan", "libwayland-egl",
    "libX11.so", "libX11-xcb", "libxcb.so", "libxcb-dri", "libxcb-glx",
    "libxcb-present", "libxcb-sync", "libxshmfence",
    "libfontconfig", "libfreetype", "libharfbuzz.so",
    "libz.so", "libexpat", "libcom_err", "libgpg-error", "libuuid", "libasound",
)

SOURCES = ".bundled-sources"  # name -> original path, read by "licenses"
LDD_LINE = re.compile(r"\s*(\S+) => (\S+)")
GLIBC_VER = re.compile(rb"GLIBC_2\.(\d+)")


def die(msg):
    sys.exit(f"ERROR: {msg}")


def is_elf(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False


def elf_files(appdir):
    for root, _, files in os.walk(appdir):
        for name in files:
            p = Path(root, name)
            if not p.is_symlink() and is_elf(p):
                yield p


def ldd(path):
    """Yield (soname, resolved path or None) for each dependency."""
    out = subprocess.run(["ldd", str(path)], capture_output=True, text=True).stdout
    for line in out.splitlines():
        m = LDD_LINE.match(line)
        if m:
            yield m.group(1), None if m.group(2) == "not" else Path(m.group(2))


def has_dynamic_section(path):
    out = subprocess.run(["readelf", "-d", str(path)], capture_output=True, text=True).stdout
    return "NEEDED" in out or "SONAME" in out


def cmd_libs(appdir, extra):
    libdir = appdir / "usr" / "lib"
    libdir.mkdir(parents=True, exist_ok=True)
    sources = {}

    def take(name, real):
        dest = libdir / name
        if name in sources or dest.exists() or name.startswith(HOST_PROVIDED):
            return False
        shutil.copy2(real.resolve(), dest)
        dest.chmod(0o755)
        sources[name] = real.resolve()
        return True

    queue = []
    for lib in extra:
        lib = Path(lib)
        if take(lib.name, lib):
            queue.append(libdir / lib.name)
    queue += list(elf_files(appdir))
    while queue:
        for name, real in ldd(queue.pop()):
            if real is not None and take(name, real):
                queue.append(libdir / name)
    print(f"bundled {len(sources)} libraries")

    # RUNPATH, not LD_LIBRARY_PATH: programs launched from the app must not
    # inherit our libraries.
    elves = [p for p in elf_files(appdir) if has_dynamic_section(p)]
    for p in elves:
        rel = os.path.relpath(libdir, p.parent)
        runpath = "$ORIGIN" if rel == "." else f"$ORIGIN/{rel}"
        subprocess.run(["patchelf", "--set-rpath", runpath, str(p)], check=True)

    missing = sorted({
        f"{p.relative_to(appdir)}: {name}"
        for p in elves for name, real in ldd(p) if real is None
    })
    if missing:
        die("unresolved libraries:\n  " + "\n  ".join(missing))

    newest = 0
    for p in elves:
        out = subprocess.run(["objdump", "-T", str(p)], capture_output=True).stdout
        newest = max([newest, *map(int, GLIBC_VER.findall(out))])
    print(f"needs glibc 2.{newest} or newer")

    (appdir.parent / f"{appdir.name}{SOURCES}").write_text(
        "".join(f"{n}\t{p}\n" for n, p in sorted(sources.items()))
    )


def dpkg_owners(path):
    """Debian packages that own PATH (merged /usr: try both spellings)."""
    for candidate in (str(path), str(path).removeprefix("/usr")):
        out = subprocess.run(["dpkg", "-S", candidate], capture_output=True, text=True)
        if out.returncode == 0:
            first = out.stdout.splitlines()[0]
            return {p.split(":")[0].strip() for p in first.rsplit(": ", 1)[0].split(",")}
    die(f"no Debian package owns {path}")


def cmd_licenses(appdir, args):
    pkgs = set()
    for arg in args:
        pkgs |= dpkg_owners(arg) if arg.startswith("/") else {arg}
    sources = appdir.parent / f"{appdir.name}{SOURCES}"
    for line in sources.read_text().splitlines():
        pkgs |= dpkg_owners(line.split("\t", 1)[1])
    dest_root = appdir / "usr" / "share" / "licenses"
    missing = []
    for pkg in sorted(pkgs):
        src = Path("/usr/share/doc", pkg, "copyright")
        if src.is_file():
            (dest_root / pkg).mkdir(parents=True, exist_ok=True)
            shutil.copy(src, dest_root / pkg / "copyright")
        else:
            missing.append(pkg)
    print(f"copyright files for {len(pkgs) - len(missing)} Debian packages")
    if missing:
        die("no copyright file for: " + ", ".join(missing))


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("libs", "licenses"):
        sys.exit(__doc__)
    appdir = Path(sys.argv[2]).resolve()
    if sys.argv[1] == "libs":
        cmd_libs(appdir, sys.argv[3:])
    else:
        cmd_licenses(appdir, sys.argv[3:])


if __name__ == "__main__":
    main()

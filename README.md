# AppImage build scripts

Scripts that build Linux applications from source into portable AppImages.

Each script builds inside a Debian 12 container, so the AppImage runs on any
x86_64 distro with glibc 2.36 or newer: Debian 12, Ubuntu 22.10+, Fedora 37+,
Arch, openSUSE Tumbleweed and the like. Source archives and tools are pinned
to exact versions and checked against SHA-256 hashes before use.

| App | Script | Version |
|---|---|---|
| [MediaInfo](https://mediaarea.net/en/MediaInfo) (GUI + CLI) | [`mediainfo/build-mediainfo-gui-appimage.sh`](mediainfo/build-mediainfo-gui-appimage.sh) | 26.10 |

## Requirements

- x86_64 Linux
- `podman` (recommended, runs rootless) or `docker`
- `curl` and `sha256sum`

On Arch: `sudo pacman -S podman`.

## Usage

```sh
./mediainfo/build-mediainfo-gui-appimage.sh
```

The AppImage is written to `~/Desktop`. Run it to open the GUI, or pass
`--cli` for the command-line tool:

```sh
./MediaInfo-26.10-x86_64.AppImage                   # GUI
./MediaInfo-26.10-x86_64.AppImage --cli video.mkv   # CLI
```

Settings, all optional:

| Variable | Default | Meaning |
|---|---|---|
| `WORK_DIR` | `~/.cache/mediainfo-appimage` | Downloads and build files |
| `OUT_DIR` | `~/Desktop` | Where the AppImage goes |
| `CONTAINER_ENGINE` | `podman`, else `docker` | Container tool to use |

Downloads are cached in `WORK_DIR/cache` and reused only while their hash
still matches. Delete `WORK_DIR` to start over.

## How the AppImages are built

- **Old base, new hosts.** glibc is backward compatible: a program built
  against an older glibc runs on newer ones, not the other way round. Building
  on Debian 12 sets the floor at glibc 2.36.
- **Libraries.** The app's shared libraries are bundled, except those the host
  must provide: glibc, the C++ runtime, graphics drivers, and X11 and font
  libraries. Bundled binaries find their libraries through `RUNPATH`, not
  `LD_LIBRARY_PATH`, so programs launched from the app don't inherit them.
  The build fails if any bundled library has an unresolved dependency.
- **Pins.** Source archives, `appimagetool` and the AppImage runtime are pinned
  by version and SHA-256, and the Debian base image by digest. Debian packages
  are installed with apt, which checks their signatures.
- **Licenses.** Each AppImage carries the app's license files and the Debian
  copyright file of every bundled library under `usr/share/licenses`.

## Updating a pin

Change the version in the script's pin block, download the new archive, and
replace its hash with the output of `sha256sum`.

## License

The scripts are released into the public domain under [The Unlicense](LICENSE).
The applications they build keep their own licenses.

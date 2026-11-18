# AppImage build scripts

Scripts that build Linux applications from source into portable AppImages.

Each script builds inside a Debian container, so the AppImage runs on any
x86_64 distro with the same or a newer glibc. Source archives and tools are
pinned to exact versions and checked against SHA-256 hashes before use.

| App | Script | Version | Built on | Runs on |
|---|---|---|---|---|
| [MediaInfo](https://mediaarea.net/en/MediaInfo) (GUI + CLI) | [`mediainfo/build-mediainfo-gui-appimage.sh`](mediainfo/build-mediainfo-gui-appimage.sh) | 26.10 | Debian 12 | glibc 2.36+: Debian 12, Ubuntu 22.10+, Fedora 37+, Arch |
| [Mousam](https://github.com/amit9838/mousam) (weather) | [`mousam/build-mousam-appimage.sh`](mousam/build-mousam-appimage.sh) | 3.0.0 | Debian 13 | glibc 2.41+: Debian 13, Ubuntu 25.04+, Fedora 42+, Arch |

Mousam needs libadwaita 1.6 or newer, which older Debian releases don't have,
so it is built on Debian 13 and carries its own Python, GTK 4 and libadwaita.
Small fixes on top of a release live in `<app>/patches/` and are applied in
order; the build stops if one no longer applies.

## Downloads

Prebuilt AppImages are on the
[Releases](https://github.com/bsd-source/appimage-build-scripts/releases) page,
one release per app version (tags like `mousam-3.0.0`). Each comes with a
`.sha256` file:

```sh
sha256sum -c Mousam-3.0.0-x86_64.AppImage.sha256
chmod +x Mousam-3.0.0-x86_64.AppImage
./Mousam-3.0.0-x86_64.AppImage
```

To build one yourself, read on.

## Requirements

- x86_64 Linux
- `podman` (recommended, runs rootless) or `docker`
- `curl` and `sha256sum`

On Arch: `sudo pacman -S podman`.

## Usage

```sh
./mediainfo/build-mediainfo-gui-appimage.sh
./mousam/build-mousam-appimage.sh
```

The AppImage is written to `~/Desktop`. The MediaInfo AppImage opens the GUI,
or runs the command-line tool with `--cli`:

```sh
./MediaInfo-26.10-x86_64.AppImage --cli video.mkv
```

Settings, all optional:

| Variable | Default | Meaning |
|---|---|---|
| `WORK_DIR` | `~/.cache/appimage-build/<app>` | Downloads and build files |
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

## Layout

| Path | Contents |
|---|---|
| `<app>/build-<app>-appimage.sh` | One script per app: pins, the container build, the AppRun launcher |
| `lib/common.sh` | Shared shell helpers: checked downloads, running the container, packing |
| `lib/bundle.py` | Copies shared libraries into the AppDir, sets RUNPATHs, checks that everything resolves, collects Debian copyright files |

Each script runs twice: on the host it downloads and checks the sources, then
starts itself in the container with `--in-container` to build the AppDir, and
finally packs the AppImage on the host.

## Updating a pin

Change the version in the script's pin block, download the new archive, and
replace its hash with the output of `sha256sum`.

## License

The scripts are released into the public domain under [The Unlicense](LICENSE).
The applications they build keep their own licenses.

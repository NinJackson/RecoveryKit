# RecoveryKit — failing-drive imaging for service jobs

One command images a dying external/TDM drive onto a job drive, surviving
dropouts, reboots, and disk renumbering.

## GUI (modern Macs)

Open `RecoveryKit.app` (double-click). Pick a method, the source disk, the
destination job volume, set a job label, hit **Run in Terminal** — the
method opens in Terminal where you type the sudo password and watch live
progress. The app tails the job's log file at the bottom. First run asks
permission to control Terminal: allow it.

The **Image file** field (with **Browse…**) points the extract/carve methods
at any recovered `.img` — handy when it isn't named by the kit convention or
lives elsewhere. Leave it blank to use the job's `<label>.img`. It's passed as
`--image`; methods that don't take an image ignore it.

The **Source disk** menu lists attached external disks (re-scanned every
10 s; the destination's own disk is never offered) and passes the choice
as `--device`. Leave it on **Auto-detect** for drives that aren't up yet —
the imaging engine then waits for a new disk to appear, which is the
normal workflow for intermittent TDM patients. After the first contact
the engine re-finds the patient by GPT DiskUUID anyway, so dropouts and
renumbering don't care which way you started.

### Adding recovery methods

Drop an executable `NN_name.sh` into `methods/` and hit Refresh — it
appears in the GUI, no app rebuild needed. Contract:

- Header lines `# NAME: <menu title>` and `# DESC: <one-line description>`.
- Optional `# ACCEPTS: image` — declares the method takes a `--image <path>`
  (a specific `.img`). The GUIs then offer the image picker for it; methods
  without the header don't see it. The kit's image consumers (`20_`, `30_`)
  honor `--image`, falling back to `DEST/LABEL.img` when it's blank.
- Gets called as `sudo bash <script> --dest "/Volumes/<job>" --label <label>`
  (plus `--device`/`--image` when set, and anything in "Extra args"); ignore
  flags you don't use.
- Log to `$DEST/$LABEL*.log` so the GUI's log pane picks it up.
- Lower `NN_` prefixes sort first in the menu. Current methods:
  `10_` image with ddrescue, `20_` extract files from a readable image,
  `30_` carve files from an unreadable image, `90_` remove fstab guards.

Rebuild the app after editing `gui/main.swift`: `bash gui/build.sh`.

## Dependencies

RecoveryKit keeps third-party tools in `tools/bin/` so the scripts do not need
system-wide installs. Methods automatically run:

```
bash tools/install_dependencies.sh --require <tool>
```

before they look up their tool. You can also preflight everything manually:

```
bash tools/install_dependencies.sh --all
```

The installer first uses existing bundled binaries, then copies tools already
on `PATH`, then tries Homebrew if it is installed, then falls back to upstream
downloads where practical. PhotoRec is downloaded from CGSecurity's portable
TestDisk/PhotoRec macOS archive. GNU ddrescue is built from GNU source when a
compiler and `lzip` are available; otherwise the installer tells you exactly
which binary to place in `tools/bin/`.

## GUI on old macOS (10.14.6 Mojave and up)

`RecoveryKit.app` is an arm64 Swift build and won't run on Intel Mojave.
For old bench Macs use the **classic GUI** instead:

```
open ~/RecoveryKit/rescue_gui_classic.command
```

Double-click it in Finder (first launch: right-click → Open, to clear
Gatekeeper). It's pure `bash` + `osascript` + Terminal — no compiled code,
no Swift runtime — so the one file runs unchanged from 10.14.6 to current.
Native dialogs collect method / destination / source disk / label, then the
chosen method runs with `sudo` right in that Terminal window with live
ddrescue output. It reads the same `methods/` folder, so methods you add
show up in both GUIs.

### What makes the kit run on 10.14.6

- **ddrescue is a universal binary** (`x86_64` + `arm64`, x86_64 slice built
  with `-mmacosx-version-min=10.14`). Same `tools/bin/ddrescue` runs on Intel
  Mojave and Apple Silicon. Rebuild the Intel slice: see `gui/build.sh` notes
  and `~/TDM_Recovery/build/`.
- **Plist reads are portable.** Scalars use `plutil -extract` and fall back to
  `/usr/libexec/PlistBuddy` (older `plutil` lacks `-extract … -o -`); disk and
  partition lists are parsed from `diskutil`'s text output, not the `-plist`
  `WholeDisks` / `AllDisksAndPartitions` keys.
- **Shell is bash 3.2-safe** — the version Apple ships everywhere, Mojave
  included (it's also what `/bin/bash` is on this machine).
- **Dependency bootstrap is local.** Missing tools are installed into
  `tools/bin/`; the scripts do not require `/usr/local` or `/opt/homebrew` to
  be writable. On Mojave, the PhotoRec fallback uses CGSecurity's Intel macOS
  archive, and ddrescue can be copied from PATH/Homebrew or built from source
  when Command Line Tools plus `lzip` are present.

> Untested on real 10.14.6 hardware from this build machine — it's written to
> the documented Mojave behavior and verified on macOS 26. Validate on the
> actual bench Mac with a throwaway disk before trusting a customer drive.

## Quick start (CLI)

```
sudo bash /Users/service/RecoveryKit/rescue_disk.sh --dest "/Volumes/12345 - Customer" --label customer2017
```

Start the script first, then attach/power-cycle the patient drive — it waits.
For an Intel Mac in Target Disk Mode: customer machine on its own power
adapter, fully off, power on holding **T**, replug the Thunderbolt cable once
the TDM symbol shows. Re-run the same command any time: the `.map` file
resumes exactly where it stopped.

## Doctrine (learned the hard way)

1. **Never mount a failing drive.** `mount_apfs` of a corrupt volume
   kernel-panicked this host (`kern_apfs_reflock` over-release in apfs.kext).
   The script images raw blocks only, and writes `/etc/fstab` `noauto` guards
   so diskarbitration won't fsck/auto-mount the patient on re-attach.
   Remove guards when the job is done: `sudo bash rescue_disk.sh --cleanup-fstab`.
2. **Image first, recover second.** Pass 1 (`--no-scrape`) grabs all easy
   blocks fast — dying drives degrade with power-on time, so good areas come
   first. Later cycles scrape/retry the bad spots.
3. **Never trust disk numbers.** The patient re-enumerates under different
   identifiers across attaches; the script re-finds it by GPT DiskUUID, then
   by exact byte size.
4. **If macOS asks to Initialize a disk: click Ignore.** Never Initialize.
5. Keep nothing important in `/tmp` — wiped every boot (and panics happen).

## After imaging

Work only from the image; the patient can go back on the shelf.

```
hdiutil attach -imagekey diskimage-class=CRawDiskImage -readonly -nomount IMG
diskutil list                      # find the synthesized container
diskutil mount readOnly diskNsM    # mount volumes from the image
```

### Opening / reading a recovered image

- **Image the OS can read** → *Extract files from image* (`20_`). Attaches
  read-only and rsyncs the files out, preserving names and folders. Note this
  mounts the image's filesystem, which carries the same apfs.kext panic risk
  as the original drive if the image is corrupt — only use it on images that
  attach cleanly.
- **Image the OS CANNOT read** (corrupt/partial filesystem — mount fails or
  would panic) → *Recover files from UNREADABLE image (carve)* (`30_`). This
  is the answer when "open it normally" doesn't work. PhotoRec scans the raw
  image byte-by-byte and reconstructs files from their content signatures into
  `DEST/carved/` — it never mounts anything and never invokes the kernel
  filesystem driver, so there's nothing to fail or panic. It recovers file
  **content by type** (jpg, png, pdf, docx, …); original filenames and folder
  structure are lost (that information lived in the unreadable metadata). When
  in doubt, prefer carving — it's the safe path.

If mounting the image's APFS volume misbehaves (same apfs.kext code path), do
it right after a fresh boot with no other jobs running, use the carve method
instead, or fall back to `apfs-fuse` / professional tools against the image.

`tools/bin/` holds GNU ddrescue 1.29 + ddrescuelog and PhotoRec 7.2 as
**universal binaries** (`x86_64` + `arm64`, linking only system libs) built
from source (Homebrew on this Mac has broken
/usr/local permissions). Source tarballs and build scripts:
`~/TDM_Recovery/build/` and `~/TDM_Recovery/*.sh`. To rebuild the Intel slice:
`./configure CXX=clang++ CXXFLAGS="-arch x86_64 -mmacosx-version-min=10.14 -O2"
LDFLAGS="-arch x86_64 -mmacosx-version-min=10.14"` then `lipo -create` the two
arch builds.

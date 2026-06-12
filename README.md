# RecoveryKit — failing-drive imaging for service jobs

One command images a dying external/TDM drive onto a job drive, surviving
dropouts, reboots, and disk renumbering.

## GUI (modern Macs)

Open `RecoveryKit.app` (double-click). Pick a method, the source disk, the
destination job volume, set a job label, hit **Run in Terminal** — the
method opens in Terminal where you type the sudo password and watch live
progress. The app tails the job's log file at the bottom. First run asks
permission to control Terminal: allow it.

The app is **job-aware**: the **Job** menu lists jobs already on the selected
drive (newest first, preselected so you continue rather than fork a job;
"— new job —" generates a collision-free label). The **Job state** strip
shows what exists for the selected job (image/hash, recovered files, triage,
delivery, plus ⚙️ RUN ACTIVE when a lock shows something running), and the
**Next:** line suggests the next pipeline step — "Select suggested" picks it
in the Method menu. Every **Run** opens a pre-flight summary first, with
computed warnings: placeholder-sized source, image won't fit on the
destination, run resumes an existing image, missing image for extract/carve,
and which fstab guard lines a cleanup will touch. The classic GUI shows the
same kind of confirmation dialog before executing.

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
  `05_` probe patient (read-only diagnostics), `10_` image with ddrescue,
  `15_` verify image (SHA-256 + map health), `20_` extract from a readable
  image (mounts it), `25_` extract WITHOUT mounting (Sleuth Kit — names and
  folders, zero kernel-mount risk), `30_` carve an unreadable image,
  `35_` deduplicate recovered output, `40_` triage carved files into user
  data vs junk, `42_` rescue real photos from an earlier triage's junk tier
  (dimension-based re-screen into `triage/rescued/` for a human eyeball),
  `45_` organize photos by EXIF date, `60_` package customer
  delivery (manifest + README), `70_` generate the final job report,
  `80_` archive job artifacts with hash verification, `90_` remove fstab
  guards (label-scoped).

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

## Field notes — diagnosing "uninitialized" USB drives

A USB-SATA enclosure that shows a tiny disk with no partition map usually
means the bridge's SATA handshake failed — the patient never answered ATA
IDENTIFY. Signatures and probes:

- **ASMedia bridges (ASMT 2235/2115/1153E, USB id `174c:55aa`) report a
  placeholder LUN of exactly 40961 × 512 B = 21.0 MB when no disk
  identifies.** Disk Utility shows "uninitialized ASMT xxxx Media". This is
  the bridge talking, not the drive — nothing is mountable, initializing it
  writes nothing useful, and macOS cannot reach the drive behind it.
- Probe commands (no root): `diskutil info diskN` (MediaName/size),
  `ioreg -p IOUSB -l -w0 | grep -iE 'Product Name|idVendor|idProduct'`
  (bridge identity), `ioreg -c IOSCSIPeripheralDeviceNub -l -w0 | grep -iE
  'Vendor Identification|Product Identification'` (what SCSI identity the
  bridge fabricates), and `tools/new_disk_watch.sh` to catch real
  enumeration the moment it happens.
- **A tiny capacity that persists on direct SATA is the drive's own ROM-mode
  IDENTIFY, not a bridge artifact** (confirmed on a bricked Silicon Power A55:
  ~20 MB behind two ASMedia bridges AND on a native AHCI port). Controller
  answering IDENTIFY with placeholder capacity = recoverable presentation;
  read the model string (`system_profiler SPSerialATADataType`) to identify
  the controller family and pick the loader path.
- Same placeholder in two different enclosures ⇒ the drive is the problem.
  macOS userspace cannot send ATA/SCSI passthrough over USB — verified
  upstream: smartmontools issue #254, closed wontfix ("cannot be fixed in
  smartctl"); Apple's stack claims USB disks exclusively. So ATA-level
  interrogation (true IDENTIFY, SMART) needs direct SATA on a Linux/Windows
  bench machine or PC-3000. A Linux VM with USB passthrough works only for
  healthy-ish drives — macOS probes/attempts mounting before the VM can
  capture the device, which is unacceptable on dying media.
- Bricked-SSD IDENTIFY triage (direct SATA, hot-plug, Linux `hdparm -I`):
  identifies as **"SATAFIRM S11"** = Phison PS3111 ROM fallback, FTL dead,
  data intact → PC-3000/DFL loader+translator imaging. **Silicon string**
  (SM2258XT/SM2259XT) or tiny capacity (0.12 MB/2 MB/1 GB/1023 MB) = SMI or
  Maxio ROM/panic mode → same loader approach (pin-short to safe mode).
  **Total silence / brief-then-gone** = SMI "Keep BSY" or Maxio init loop —
  USB bridges mask BSY, so such drives look dead behind any enclosure.
  NEVER run vendor MP tools (Phison MPALL/SATA Tool, SMI MPTool, repairS11):
  they rebuild an EMPTY FTL — data is unrecoverable afterwards.
- Power-on-idle "soak" (power cable ONLY, no data; ~20-30 min on, 30 s off,
  repeat) is data-safe and documented for post-power-loss housekeeping
  recovery, but does NOT fix ROM-mode/placeholder bricks; minimize total
  power-on time on degrading drives.

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

### Triaging carve output (user data vs junk)

Carving produces hundreds of thousands of files, most of them OS noise. The
*Triage carved files* method (`40_`) classifies everything into
`DEST/triage/{user_data,review,junk}/<category>/` using **hardlinks** —
originals stay untouched in `recovered.N/`, and the sorted tree costs almost
no extra disk space. It also writes `DEST/LABEL.triage.tsv` (one row per file:
path, tier, category, reason, size) and prints a summary.

Heuristics (single-pass Perl classifier — fast even at 300k+ files, stock on
every macOS including 10.14; "v2" rules come from a full audit of a real
306k-file job):

- **jpg/tiff**: camera EXIF make (Apple/Canon/Nikon/…) in the header → user
  photo — but `Copyright <vendor>` strings are ignored (Photos-library
  derivatives embed "Copyright Apple Inc." and are not camera originals);
  EXIF + ≥256 KB → user photo; ≥2 MB without EXIF → review. **EXIF-less
  jpgs ≥50 KB → `review/image_derivatives`** (SOF-decoded dims in the reason):
  PhotoStream renditions, X-rays/scans and edited exports live there, and on
  a partially-encrypted disk they can be the only surviving copies. `<32 KB`
  → thumbnail junk. Multi-MB tiffs whose header claims icon dims (≤256 px)
  are over-carved UI assets → junk.
- **png**: parses IHDR dimensions; **≥500 KB → `user_data/screenshots`**
  (user screenshots/scans — OS resources at the same pixel dims stay under
  500 KB); ≥600 px min-side → review; corrupt dims (0 or >20k px) → junk;
  else UI-asset junk.
- **sqlite**: `.tables` scanned for user-content schemas (Photos ZASSET,
  iMessage chat/message, WhatsApp/Messenger threads, Notes, Contacts,
  Calendar, Mail, call history) → user database; unreadable+large → review.
- **video**: mov/mp4/m4v/3gp without a `moov`/`moof` atom (head or tail) →
  `review/truncated_media` — unplayable fragments, possible repair
  candidates (untrunc + a reference clip from the same camera).
- **audio**: tagged (ID3/iTunes `©nam` atoms) → user music; untagged ≥2 MB →
  review; untagged short clips → junk (app SFX/TTS cache — a real music
  library carves out tagged).
- **documents**: pdf/docx/xlsx/iWork/psd → user data, except sub-20 KB PDFs
  (vector/icon assets) → review; rtf and .ai → review (app localization
  text and clip-art masquerade as documents); csv → review (mostly
  misdetected fragments).
- **truncated carves**: 4–32 KB "camera format" files (heic/dng/raw) → junk;
  plists ≥2 MB → `junk/carve_noise` (signature misfires on encrypted-region
  noise — on one job these were 71% of all junk bytes).
- **vcf/ics**: Apple TipCard vcards and event-less VALARM fragments → junk;
  real contact cards and calendars → user data.
- **txt**: license/markup/code markers → junk; free text → review.
- Unknown extensions and large archives → review.

Triage is advisory: spot-check `review/` (especially `image_derivatives/`)
before telling a customer something is gone. For jobs triaged with the v1
classifier, run `42_` — it re-screens `junk/image_cache` by pixel dimensions
into `triage/rescued/{phone_screen,hires,camera,derivative}/` buckets for
a fast human pass (on the audit job this recovered vet X-rays, registration
screenshots and family photos that v1 had filed as junk).

`tools/bin/` holds GNU ddrescue 1.29 + ddrescuelog and PhotoRec 7.2 as
**universal binaries** (`x86_64` + `arm64`, linking only system libs) built
from source (Homebrew on this Mac has broken
/usr/local permissions). Source tarballs and build scripts:
`~/TDM_Recovery/build/` and `~/TDM_Recovery/*.sh`. To rebuild the Intel slice:
`./configure CXX=clang++ CXXFLAGS="-arch x86_64 -mmacosx-version-min=10.14 -O2"
LDFLAGS="-arch x86_64 -mmacosx-version-min=10.14"` then `lipo -create` the two
arch builds.

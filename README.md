# RecoveryKit — failing-drive imaging for service jobs

One command images a dying external/TDM drive onto a job drive, surviving
dropouts, reboots, and disk renumbering.

## GUI

Open `RecoveryKit.app` (double-click). Pick a method, the source disk, the
destination job volume, set a job label, hit **Run in Terminal** — the
method opens in Terminal where you type the sudo password and watch live
progress. The app tails the job's log file at the bottom. First run asks
permission to control Terminal: allow it.

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
- Gets called as `sudo bash <script> --dest "/Volumes/<job>" --label <label>`
  plus whatever the tech typed in "Extra args"; ignore flags you don't use.
- Log to `$DEST/$LABEL*.log` so the GUI's log pane picks it up.
- Lower `NN_` prefixes sort first in the menu. Current methods:
  `10_` image with ddrescue, `20_` extract files from the image,
  `90_` remove fstab guards when a job closes.

Rebuild the app after editing `gui/main.swift`: `bash gui/build.sh`.

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

If mounting the image's APFS volume also misbehaves (same apfs.kext code
path), do it right after a fresh boot with no other jobs running, or fall
back to `apfs-fuse` / professional tools against the image file.

`tools/bin/` holds GNU ddrescue 1.29 + ddrescuelog built from source
(Homebrew on this Mac has broken /usr/local permissions). Source tarballs
and build scripts: `~/TDM_Recovery/build/` and `~/TDM_Recovery/*.sh`.

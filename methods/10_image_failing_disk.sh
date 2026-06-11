#!/bin/bash
# NAME: Image failing disk (ddrescue)
# DESC: Waits for the failing disk, blocks automount/fsck, images raw blocks to DEST/LABEL.img. Resumes automatically across dropouts, reboots, and renumbering. Power-cycle the patient after starting.
# REQUIRES_ROOT: yes
exec bash "$(cd "$(dirname "$0")/.." && pwd)/rescue_disk.sh" "$@"

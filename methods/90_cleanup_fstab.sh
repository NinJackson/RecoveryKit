#!/bin/bash
# NAME: Remove fstab guards (job done)
# DESC: Deletes this kit's noauto guard lines from /etc/fstab once a job is closed. Run after the customer's data is safe.
# REQUIRES_ROOT: yes
# Forward args so the GUI's --label scopes the cleanup to this job's guards.
exec bash "$(cd "$(dirname "$0")/.." && pwd)/rescue_disk.sh" --cleanup-fstab "$@"

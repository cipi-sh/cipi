#!/bin/bash
#############################################
# Cipi Migration 5.11.2
#
# On servers with sudo-rs (Ubuntu 26.04: 0.2.13) the panel whitelist of
# 5.11.0 was refused — "too many items in list": one rule of ~138 commands —
# so the migrations put the previous one back and the panel got "sudo: I'm
# sorry www-data…" for metrics. The whitelist is now written as rules of at
# most 40 commands, checked before it is put in place. This runs the 5.11.0
# steps again — all idempotent — with the new writer.
#############################################
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Migration 5.11.2 — panel sudoers split into rules sudo-rs accepts..."
bash "${here}/5.11.0.sh"
echo "Migration 5.11.2 complete"

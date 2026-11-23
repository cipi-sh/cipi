#!/bin/bash
#############################################
# Cipi Migration 5.11.1
#
# A 5.11.0 migration that did not finish — interrupted while apt was busy,
# before the 5.11.0 fix — left the panel's sudoers without the metrics
# commands ("sudo: I'm sorry www-data…" in the Metrics tab), and possibly
# no sqlite3 or collector. Every step of 5.11.0 is idempotent: run it again.
# From now on self-update refreshes the panel sudoers on every update.
#############################################
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Migration 5.11.1 — completing 5.11.0 (sqlite3, collector, panel sudoers)..."
bash "${here}/5.11.0.sh"
echo "Migration 5.11.1 complete"

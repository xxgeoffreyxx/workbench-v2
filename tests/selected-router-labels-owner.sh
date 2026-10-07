#!/usr/bin/env bash
# Stable path for the run's red-3 command: it resolves from the repo root or the run dir's attached tests/.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Scripts/selected-router-labels-owner.sh" "$@"

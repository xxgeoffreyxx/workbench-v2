#!/usr/bin/env bash
set -euo pipefail

# Helga's task-test preflight invokes an attached shell test without arguments.
# Keep that entry executable after it is copied into the run's tests directory.
readonly SOURCE_ROOT=/Users/geoffmccaleb/workbench-v2-router-labels-20261006
export WORKBENCH_SOURCE_DIR="$SOURCE_ROOT"
export WORKBENCH_OWNER_EVIDENCE_DIR="${WORKBENCH_OWNER_EVIDENCE_DIR:-$HOME/model-trials-data/reports/trials-recovery-20261006/workbench-qa-test-entry-v1/$(date -u +%Y%m%dT%H%M%SZ)-$$}"
exec bash "$SOURCE_ROOT/Scripts/selected-router-labels-owner.sh" \
  test-router-labels WORKBENCH-SELECTED-NAMES

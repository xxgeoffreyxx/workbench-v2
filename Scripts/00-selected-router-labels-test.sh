#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="${WORKBENCH_SOURCE_DIR:-${HOSAKA_HELGA_SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
export WORKBENCH_SOURCE_DIR="$SOURCE_ROOT"
# RouterTests exercises live router titles, resident names, and offline aliases.
# The inline coverage annotation belongs to this real package-test command.
bash "$SOURCE_ROOT/Scripts/selected-router-labels-owner.sh" test-router-labels # acceptance:WORKBENCH-SELECTED-NAMES (testRouterLabelsOverrideCanonicalDisplayTitles, testResidentModelsFromHealth, testReadyCanonicalMetadataSurvivesOfflineAliases)

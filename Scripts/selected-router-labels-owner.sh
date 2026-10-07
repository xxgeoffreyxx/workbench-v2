#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${WORKBENCH_SOURCE_DIR:-}" ]]; then
  SOURCE_DIR="$(cd "$WORKBENCH_SOURCE_DIR" && pwd)"
else
  SOURCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

EVIDENCE_DIR="${WORKBENCH_OWNER_EVIDENCE_DIR:-$HOME/model-trials-data/reports/trials-recovery-20261006/workbench-selected-labels-owner-v1}"
INSTALLED_APP="${WORKBENCH_INSTALLED_APP:-/Applications/Workbench.app}"
DERIVED_DATA="${WORKBENCH_DERIVED_DATA:-$EVIDENCE_DIR/build/DerivedData}"
LOG_DIR="$EVIDENCE_DIR/logs"
BUILD_DIR="$EVIDENCE_DIR/build"
BACKUP_DIR="$EVIDENCE_DIR/backups"
PRODUCTION_DIR="$EVIDENCE_DIR/production"
CANDIDATE_APP="$DERIVED_DATA/Build/Products/Debug/Workbench.app"
NATIVE_UI_VERIFIER="${WORKBENCH_NATIVE_UI_VERIFIER:-$HOME/model-trials-data/reports/trials-recovery-20261006/worker-integration-v1/native-ui-verification/verify.py}"
EXPECTED_NATIVE_UI_VERIFIER_SHA256="309513d01bad8767b79c0fcfcfa73e15df3ea2571bf397071c2684974d692181"

EXPECTED_BUNDLE_ID="me.mccaleb.Workbench"
EXPECTED_VERSION="2.0"
EXPECTED_BUILD="31"
EXPECTED_TEAM_ID="45CY38F39L"
BASELINE_REF="${WORKBENCH_BASELINE_REF:-dfaeae2034bc3e3eb6817328ee98a6fe34218f40}"

mkdir -p "$LOG_DIR" "$BUILD_DIR" "$BACKUP_DIR" "$PRODUCTION_DIR"

usage() {
  printf '%s\n' "usage: $0 inspect|localhost|deploy|production|test-clean-scope|test-rollback|test-signed-binding|test-router-labels WORKBENCH-SELECTED-NAMES|test-native-ui-verifier-relocation|sha256"
}

stamp() {
  date -u '+%Y%m%dT%H%M%SZ'
}

log_run() {
  local name="$1"
  shift
  printf '%s\n' "$*" >"$LOG_DIR/$name.command.txt"
  "$@" >"$LOG_DIR/$name.stdout.log" 2>"$LOG_DIR/$name.stderr.log"
}

log_optional() {
  local name="$1"
  shift
  printf '%s\n' "$*" >"$LOG_DIR/$name.command.txt"
  "$@" >"$LOG_DIR/$name.stdout.log" 2>"$LOG_DIR/$name.stderr.log"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

require_source_root() {
  [[ -d "$SOURCE_DIR/Warden.xcodeproj" ]] || {
    printf '%s\n' "source root does not contain Warden.xcodeproj: $SOURCE_DIR" >&2
    exit 1
  }
}

require_bundle_identity() {
  local app="$1"
  local label="$2"
  local bundle version build
  bundle="$(plist_value "$app" CFBundleIdentifier)"
  version="$(plist_value "$app" CFBundleShortVersionString)"
  build="$(plist_value "$app" CFBundleVersion)"
  [[ "$bundle" == "$EXPECTED_BUNDLE_ID" ]] || { printf '%s\n' "$label bundle id mismatch: $bundle" >&2; return 1; }
  [[ "$version" == "$EXPECTED_VERSION" ]] || { printf '%s\n' "$label version mismatch: $version" >&2; return 1; }
  [[ "$build" == "$EXPECTED_BUILD" ]] || { printf '%s\n' "$label build mismatch: $build" >&2; return 1; }
}

require_signature() {
  local app="$1"
  local label="$2"
  log_optional "$label-codesign-verify" codesign --verify --deep --strict --verbose=2 "$app" || return 1
  log_optional "$label-codesign-details" codesign -dv --verbose=4 "$app" || return 1
  grep -F "Identifier=$EXPECTED_BUNDLE_ID" "$LOG_DIR/$label-codesign-details.stderr.log" >/dev/null || return 1
  grep -F "TeamIdentifier=$EXPECTED_TEAM_ID" "$LOG_DIR/$label-codesign-details.stderr.log" >/dev/null || return 1
  grep -F "flags=0x10000(runtime)" "$LOG_DIR/$label-codesign-details.stderr.log" >/dev/null || return 1
}

installed_signing_identity() {
  local identity
  identity="$(grep -F 'Authority=Apple Development:' "$LOG_DIR/installed-codesign-details.stderr.log" | head -1 | sed 's/^Authority=//')"
  if [[ -z "$identity" ]]; then
    identity="${WORKBENCH_CODESIGN_IDENTITY:-}"
  fi
  [[ -n "$identity" ]] || { printf '%s\n' "no installed Apple Development signing authority found; set WORKBENCH_CODESIGN_IDENTITY" >&2; exit 1; }
  printf '%s\n' "$identity"
}

export_installed_entitlements() {
  local raw="$EVIDENCE_DIR/installed-entitlements.raw"
  local plist="$EVIDENCE_DIR/installed-entitlements.plist"
  codesign -d --entitlements :- "$INSTALLED_APP" >"$raw" 2>&1 || true
  python3 - "$raw" "$plist" <<'PY'
import pathlib, sys
raw = pathlib.Path(sys.argv[1]).read_text()
out = pathlib.Path(sys.argv[2])
start = raw.find("<?xml")
out.write_text(raw[start:] if start >= 0 else "")
PY
}

verify_source_scope_and_hashes() {
  require_source_root
  local expected_branch="$EVIDENCE_DIR/branch-files.expected"
  local actual_branch="$EVIDENCE_DIR/branch-files.actual"
  local expected_dirty="$EVIDENCE_DIR/dirty-files.expected"
  local actual_dirty="$EVIDENCE_DIR/dirty-files.actual"
  local hashes="$EVIDENCE_DIR/source-hashes.actual"
  local head
  head="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
  git -C "$SOURCE_DIR" diff --quiet HEAD -- || { printf '%s\n' "source tree has unstaged changes; commit reviewed source first" >&2; exit 1; }
  [[ -z "$(git -C "$SOURCE_DIR" ls-files --others --exclude-standard)" ]] || { printf '%s\n' "source tree has untracked files; commit reviewed source first" >&2; exit 1; }
  cat >"$expected_dirty" <<'EOF'
EOF
  : >"$actual_dirty"
  diff -u "$expected_dirty" "$actual_dirty" >"$LOG_DIR/dirty-scope.diff"
  cat >"$expected_branch" <<'EOF'
.gitignore
Scripts/selected-router-labels-owner.sh
WorkbenchKit/Sources/WorkbenchKit/Router/RouterModels.swift
WorkbenchKit/Sources/WorkbenchKit/Skills/Skill.swift
WorkbenchKit/Sources/WorkbenchKit/Skills/SkillCatalog.swift
WorkbenchKit/Tests/WorkbenchKitTests/RouterTests.swift
hosaka.config.yaml
EOF
  git -C "$SOURCE_DIR" diff --name-only "$BASELINE_REF...HEAD" | sort >"$actual_branch"
  diff -u "$expected_branch" "$actual_branch" >"$LOG_DIR/branch-scope.diff"
  (
    cd "$SOURCE_DIR"
    shasum -a 256 .gitignore \
      Scripts/selected-router-labels-owner.sh \
      WorkbenchKit/Sources/WorkbenchKit/Router/RouterModels.swift \
      WorkbenchKit/Sources/WorkbenchKit/Skills/Skill.swift \
      WorkbenchKit/Sources/WorkbenchKit/Skills/SkillCatalog.swift \
      WorkbenchKit/Tests/WorkbenchKitTests/RouterTests.swift \
      hosaka.config.yaml
  ) >"$hashes"
  cat >"$EVIDENCE_DIR/source-hashes.expected" <<'EOF'
__GITIGNORE_HASH__  .gitignore
__OWNER_SCRIPT_HASH__  Scripts/selected-router-labels-owner.sh
0ec0e42b56b0a2b05493baf57cdf9c69b6f137c5c86953a0a48d9b460a9e4ec9  WorkbenchKit/Sources/WorkbenchKit/Router/RouterModels.swift
78fae7bd7cbd96d827da77313fb8197fcf21e65740fac731d5612afbc89eed84  WorkbenchKit/Sources/WorkbenchKit/Skills/Skill.swift
786bde62e7cdf3496af7892c6bfe8a40b007fec9080c042d98cb6c6da3e97249  WorkbenchKit/Sources/WorkbenchKit/Skills/SkillCatalog.swift
1bbea05e39a1743aae47f833abfe5cbc008120b58f6d428672b721b305d65780  WorkbenchKit/Tests/WorkbenchKitTests/RouterTests.swift
__HOSAKA_CONFIG_HASH__  hosaka.config.yaml
EOF
  local owner_hash config_hash
  local gitignore_hash
  gitignore_hash="$(shasum -a 256 "$SOURCE_DIR/.gitignore" | awk '{print $1}')"
  owner_hash="$(shasum -a 256 "$SOURCE_DIR/Scripts/selected-router-labels-owner.sh" | awk '{print $1}')"
  config_hash="$(shasum -a 256 "$SOURCE_DIR/hosaka.config.yaml" | awk '{print $1}')"
  perl -0pi -e "s/__GITIGNORE_HASH__/$gitignore_hash/g; s/__OWNER_SCRIPT_HASH__/$owner_hash/g; s/__HOSAKA_CONFIG_HASH__/$config_hash/g" "$EVIDENCE_DIR/source-hashes.expected"
  diff -u "$EVIDENCE_DIR/source-hashes.expected" "$hashes" >"$LOG_DIR/source-hashes.diff"
  cat >"$EVIDENCE_DIR/source-binding.json" <<EOF
{"head":"$head","baseline":"$BASELINE_REF","gitignore_sha256":"$gitignore_hash","owner_script_sha256":"$owner_hash","hosaka_config_sha256":"$config_hash"}
EOF
}

inspect_installed() {
  require_bundle_identity "$INSTALLED_APP" installed
  require_signature "$INSTALLED_APP" installed
  export_installed_entitlements
  {
    printf 'timestamp=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'installed_app=%s\n' "$INSTALLED_APP"
    printf 'bundle_id=%s\n' "$(plist_value "$INSTALLED_APP" CFBundleIdentifier)"
    printf 'version=%s\n' "$(plist_value "$INSTALLED_APP" CFBundleShortVersionString)"
    printf 'build=%s\n' "$(plist_value "$INSTALLED_APP" CFBundleVersion)"
    shasum -a 256 "$INSTALLED_APP/Contents/MacOS/Workbench" "$INSTALLED_APP/Contents/Info.plist" "$INSTALLED_APP/Contents/_CodeSignature/CodeResources"
    ps -axo pid,lstart,comm,args | grep -F "$INSTALLED_APP/Contents/MacOS/Workbench" | grep -v grep || true
  } >"$EVIDENCE_DIR/installed-provenance-$(stamp).txt"
}

run_localhost() {
  verify_source_scope_and_hashes
  log_run swift-test /usr/bin/swift test --package-path "$SOURCE_DIR/WorkbenchKit"
  log_run xcodebuild-warden /usr/bin/xcodebuild -project "$SOURCE_DIR/Warden.xcodeproj" -scheme Warden -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build
  [[ -d "$CANDIDATE_APP" ]] || { printf '%s\n' "candidate app missing: $CANDIDATE_APP" >&2; exit 1; }
  require_bundle_identity "$CANDIDATE_APP" candidate || exit 1
  shasum -a 256 "$CANDIDATE_APP/Contents/MacOS/Workbench" "$CANDIDATE_APP/Contents/Info.plist" >"$EVIDENCE_DIR/candidate-app-sha256.txt"
  local exe_hash info_hash head
  exe_hash="$(shasum -a 256 "$CANDIDATE_APP/Contents/MacOS/Workbench" | awk '{print $1}')"
  info_hash="$(shasum -a 256 "$CANDIDATE_APP/Contents/Info.plist" | awk '{print $1}')"
  head="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
  cat >"$EVIDENCE_DIR/candidate-binding.json" <<EOF
{"source_head":"$head","baseline":"$BASELINE_REF","candidate_app":"$CANDIDATE_APP","executable_sha256":"$exe_hash","info_plist_sha256":"$info_hash"}
EOF
}

require_router_idle() {
  local health="$EVIDENCE_DIR/router-health-predeploy.json"
  curl -fsS http://127.0.0.1:8110/health >"$health"
  python3 - "$health" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
if data.get("ok") is not True:
    raise SystemExit("router health is not ok")
active = data.get("active_requests")
if not isinstance(active, int):
    raise SystemExit("router active_requests is missing or not an integer")
if active != 0:
    raise SystemExit(f"router active_requests is {active}, refusing Workbench restart")
models = data.get("models") or {}
expected = {
    "ornith": ("m1max", "Qwen3.5-9B-6bit", "Qwen3.5-9B Q6 (M1 Max)"),
    "qwen27": ("m2max", "Qwen3.8-27B-4bit", "Qwen3.8-27B Q4 (M2 Max)"),
}
for key, (host, model, label) in expected.items():
    row = models.get(key) or {}
    if row.get("host") != host or row.get("model") != model or row.get("label") != label or row.get("ready") is not True:
        raise SystemExit(f"router route {key} not ready with expected identity")
PY
}

observe_running_app() {
  ps -axo pid,lstart,comm,args | grep -F "$INSTALLED_APP/Contents/MacOS/Workbench" | grep -v grep || true
}

quit_exact_current_app_if_running() {
  local observed="$EVIDENCE_DIR/deploy-running-observation.txt"
  observe_running_app >"$observed"
  if [[ ! -s "$observed" ]]; then
    return 0
  fi
  local count
  count="$(wc -l <"$observed" | tr -d ' ')"
  [[ "$count" == "1" ]] || { printf '%s\n' "multiple Workbench app processes observed; refusing restart" >&2; exit 1; }
  local line pid dow mon day tod year start
  line="$(cat "$observed")"
  read -r pid dow mon day tod year _ <<<"$line"
  start="$dow $mon $day $tod $year"
  ps -p "$pid" -o lstart= | grep -F "$start" >/dev/null || { printf '%s\n' "Workbench PID/start changed before quit" >&2; exit 1; }
  /usr/bin/osascript -e 'tell application id "me.mccaleb.Workbench" to quit' >"$LOG_DIR/quit-workbench.stdout.log" 2>"$LOG_DIR/quit-workbench.stderr.log" || true
  for _ in $(seq 1 30); do
    if ! ps -p "$pid" -o lstart= 2>/dev/null | grep -F "$start" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  printf '%s\n' "Workbench did not quit cleanly; no install performed" >&2
  exit 1
}

sign_candidate() {
  local staged="$BUILD_DIR/signed-candidate-$(stamp).app"
  rm -rf "$staged"
  log_run stage-candidate ditto "$CANDIDATE_APP" "$staged"
  local identity
  identity="${WORKBENCH_CODESIGN_IDENTITY:-$(installed_signing_identity)}"
  local entitlements="$EVIDENCE_DIR/installed-entitlements.plist"
  if [[ -s "$entitlements" ]]; then
    log_run sign-candidate codesign --force --deep --options runtime --entitlements "$entitlements" --sign "$identity" "$staged"
  else
    log_run sign-candidate codesign --force --deep --options runtime --sign "$identity" "$staged"
  fi
  require_bundle_identity "$staged" signed-candidate
  require_signature "$staged" signed-candidate
  bind_signed_candidate "$staged"
  printf '%s\n' "$staged" >"$EVIDENCE_DIR/signed-candidate-path.txt"
}

restore_backup_files() {
  local backup="$1"
  if [[ -d "$backup" ]]; then
    rm -rf "$INSTALLED_APP"
    ditto "$backup" "$INSTALLED_APP" || true
  fi
}

reopen_workbench() {
  if [[ -n "${WORKBENCH_OWNER_OPEN_STUB:-}" ]]; then
    printf '%s\n' "open -a Workbench" >>"$WORKBENCH_OWNER_OPEN_STUB"
    return 0
  fi
  /usr/bin/open -a Workbench >/dev/null 2>&1 || true
}

restore_backup_and_reopen() {
  local backup="$1"
  restore_backup_files "$backup"
  reopen_workbench
}

run_deploy() {
  [[ -d "$CANDIDATE_APP" ]] || { printf '%s\n' "run localhost first; missing $CANDIDATE_APP" >&2; exit 1; }
  require_router_idle
  verify_source_scope_and_hashes
  revalidate_candidate_binding
  require_bundle_identity "$INSTALLED_APP" installed || exit 1
  require_signature "$INSTALLED_APP" installed || exit 1
  export_installed_entitlements
  require_bundle_identity "$CANDIDATE_APP" candidate || exit 1
  sign_candidate
  local staged
  staged="$(cat "$EVIDENCE_DIR/signed-candidate-path.txt")"
  quit_exact_current_app_if_running
  local backup="$BACKUP_DIR/Workbench-installed-$(stamp).app"
  log_run backup-installed ditto "$INSTALLED_APP" "$backup"
  require_bundle_identity "$backup" backup || exit 1
  require_signature "$backup" backup || exit 1
  shasum -a 256 "$backup/Contents/MacOS/Workbench" "$backup/Contents/Info.plist" "$backup/Contents/_CodeSignature/CodeResources" >"$EVIDENCE_DIR/backup-sha256.txt"
  rm -rf "$INSTALLED_APP"
  if ! ditto "$staged" "$INSTALLED_APP" >"$LOG_DIR/install-candidate.stdout.log" 2>"$LOG_DIR/install-candidate.stderr.log"; then
    restore_backup_and_reopen "$backup"
    exit 1
  fi
  if ! require_bundle_identity "$INSTALLED_APP" installed-after || ! require_signature "$INSTALLED_APP" installed-after; then
    restore_backup_and_reopen "$backup"
    exit 1
  fi
  verify_installed_matches_signed_candidate "$staged" || {
    restore_backup_and_reopen "$backup"
    exit 1
  }
  if ! /usr/bin/open -a Workbench >"$LOG_DIR/reopen-workbench.stdout.log" 2>"$LOG_DIR/reopen-workbench.stderr.log"; then
    restore_backup_and_reopen "$backup"
    exit 1
  fi
  for _ in $(seq 1 30); do
    if observe_running_app | grep -F "$INSTALLED_APP/Contents/MacOS/Workbench" >/dev/null; then
      printf '%s\n' "$backup" >"$EVIDENCE_DIR/last-backup-path.txt"
      return 0
    fi
    sleep 1
  done
  restore_backup_and_reopen "$backup"
  printf '%s\n' "Workbench did not reopen from installed app; backup restored" >&2
  exit 1
}

run_production() {
  require_bundle_identity "$INSTALLED_APP" installed || exit 1
  require_signature "$INSTALLED_APP" installed-production || exit 1
  verify_installed_matches_signed_candidate_binding || exit 1
  require_native_ui_verifier
  curl -fsS http://127.0.0.1:8110/health >"$PRODUCTION_DIR/router-health.json"
  python3 "$NATIVE_UI_VERIFIER" --phase models --out "$PRODUCTION_DIR/workbench-m1-label" \
    --route-id ornith --model Qwen3.5-9B-6bit --host m1max --display-label "Qwen3.5-9B Q6 (M1 Max)"
  python3 "$NATIVE_UI_VERIFIER" --phase models --out "$PRODUCTION_DIR/workbench-m2-label" \
    --route-id qwen27 --model Qwen3.8-27B-4bit --host m2max --display-label "Qwen3.8-27B Q4 (M2 Max)"
}

require_native_ui_verifier() {
  [[ -x "$NATIVE_UI_VERIFIER" ]] || { printf '%s\n' "missing native UI verifier: $NATIVE_UI_VERIFIER" >&2; return 1; }
  local verifier_hash
  verifier_hash="$(shasum -a 256 "$NATIVE_UI_VERIFIER" | awk '{print $1}')"
  [[ "$verifier_hash" == "$EXPECTED_NATIVE_UI_VERIFIER_SHA256" ]] || {
    printf '%s\n' "native UI verifier hash mismatch: $verifier_hash" >&2
    return 1
  }
}

bind_signed_candidate() {
  local staged="$1"
  local unsigned="$EVIDENCE_DIR/candidate-binding.json"
  [[ -s "$unsigned" ]] || { printf '%s\n' "missing unsigned candidate binding" >&2; return 1; }
  python3 - "$unsigned" "$staged" "$EVIDENCE_DIR/signed-candidate-binding.json" <<'PY'
import json, hashlib, pathlib, sys
unsigned = json.loads(pathlib.Path(sys.argv[1]).read_text())
staged = pathlib.Path(sys.argv[2])
out = pathlib.Path(sys.argv[3])
def h(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
payload = {
    "source_head": unsigned["source_head"],
    "baseline": unsigned["baseline"],
    "unsigned_executable_sha256": unsigned["executable_sha256"],
    "unsigned_info_plist_sha256": unsigned["info_plist_sha256"],
    "signed_candidate_app": str(staged),
    "signed_executable_sha256": h(staged / "Contents/MacOS/Workbench"),
    "signed_info_plist_sha256": h(staged / "Contents/Info.plist"),
    "signed_code_resources_sha256": h(staged / "Contents/_CodeSignature/CodeResources"),
}
out.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
}

revalidate_candidate_binding() {
  local binding="$EVIDENCE_DIR/candidate-binding.json"
  [[ -s "$binding" ]] || { printf '%s\n' "missing candidate-binding.json; run localhost first" >&2; exit 1; }
  python3 - "$binding" "$SOURCE_DIR" "$CANDIDATE_APP" <<'PY'
import json, hashlib, pathlib, subprocess, sys
binding = json.loads(pathlib.Path(sys.argv[1]).read_text())
source = pathlib.Path(sys.argv[2])
candidate = pathlib.Path(sys.argv[3])
head = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
if binding.get("source_head") != head:
    raise SystemExit("candidate source head does not match current HEAD")
def h(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
if binding.get("executable_sha256") != h(candidate / "Contents/MacOS/Workbench"):
    raise SystemExit("candidate executable hash changed since localhost")
if binding.get("info_plist_sha256") != h(candidate / "Contents/Info.plist"):
    raise SystemExit("candidate Info.plist hash changed since localhost")
PY
}

verify_installed_matches_signed_candidate() {
  local staged="$1"
  python3 - "$INSTALLED_APP" "$staged" <<'PY'
import hashlib, pathlib, sys
installed = pathlib.Path(sys.argv[1])
staged = pathlib.Path(sys.argv[2])
for rel in ("Contents/MacOS/Workbench", "Contents/Info.plist", "Contents/_CodeSignature/CodeResources"):
    left = hashlib.sha256((installed / rel).read_bytes()).hexdigest()
    right = hashlib.sha256((staged / rel).read_bytes()).hexdigest()
    if left != right:
        raise SystemExit(f"installed {rel} does not match signed candidate")
PY
}

verify_installed_matches_signed_candidate_binding() {
  local binding="$EVIDENCE_DIR/signed-candidate-binding.json"
  [[ -s "$binding" ]] || { printf '%s\n' "missing candidate-binding.json" >&2; return 1; }
  python3 - "$binding" "$INSTALLED_APP" <<'PY'
import json, hashlib, pathlib, sys
binding = json.loads(pathlib.Path(sys.argv[1]).read_text())
installed = pathlib.Path(sys.argv[2])
checks = {
    "Contents/MacOS/Workbench": "signed_executable_sha256",
    "Contents/Info.plist": "signed_info_plist_sha256",
    "Contents/_CodeSignature/CodeResources": "signed_code_resources_sha256",
}
for rel, key in checks.items():
    actual = hashlib.sha256((installed / rel).read_bytes()).hexdigest()
    if actual != binding.get(key):
        raise SystemExit(f"installed {rel} does not match signed candidate binding")
PY
}

make_minimal_app() {
  local app="$1"
  local executable_text="$2"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/_CodeSignature"
  cat >"$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$EXPECTED_BUNDLE_ID</string>
<key>CFBundleShortVersionString</key><string>$EXPECTED_VERSION</string>
<key>CFBundleVersion</key><string>$EXPECTED_BUILD</string>
</dict></plist>
EOF
  printf '%s\n' "$executable_text" >"$app/Contents/MacOS/Workbench"
  printf '%s\n' 'codesign-placeholder' >"$app/Contents/_CodeSignature/CodeResources"
}

run_test_clean_scope() {
  local root="$EVIDENCE_DIR/tests/clean-scope"
  rm -rf "$root"
  mkdir -p "$root/repo"
  (
    cd "$root/repo"
    git init -q
    mkdir -p WorkbenchKit/Sources/WorkbenchKit/Router WorkbenchKit/Sources/WorkbenchKit/Skills WorkbenchKit/Tests/WorkbenchKitTests Scripts Warden.xcodeproj
    touch Warden.xcodeproj/project.pbxproj
    printf '%s\n' a >.gitignore
    printf '%s\n' b >WorkbenchKit/Sources/WorkbenchKit/Router/RouterModels.swift
    printf '%s\n' c >WorkbenchKit/Sources/WorkbenchKit/Skills/Skill.swift
    printf '%s\n' d >WorkbenchKit/Sources/WorkbenchKit/Skills/SkillCatalog.swift
    printf '%s\n' e >WorkbenchKit/Tests/WorkbenchKitTests/RouterTests.swift
    printf '%s\n' f >hosaka.config.yaml
    printf '%s\n' g >Scripts/selected-router-labels-owner.sh
    git add .
    git -c user.name=fixture -c user.email=fixture@example.com commit -q -m baseline
    local baseline
    baseline="$(git rev-parse HEAD)"
    printf '%s\n' aa >.gitignore
    printf '%s\n' bb >WorkbenchKit/Sources/WorkbenchKit/Router/RouterModels.swift
    printf '%s\n' cc >WorkbenchKit/Sources/WorkbenchKit/Skills/Skill.swift
    printf '%s\n' dd >WorkbenchKit/Sources/WorkbenchKit/Skills/SkillCatalog.swift
    printf '%s\n' ee >WorkbenchKit/Tests/WorkbenchKitTests/RouterTests.swift
    printf '%s\n' ff >hosaka.config.yaml
    printf '%s\n' gg >Scripts/selected-router-labels-owner.sh
    git add .
    git -c user.name=fixture -c user.email=fixture@example.com commit -q -m candidate
    WORKBENCH_BASELINE_REF="$baseline" WORKBENCH_OWNER_EVIDENCE_DIR="$root/evidence" WORKBENCH_SOURCE_DIR="$root/repo" bash "$0" test-clean-scope-inner
  )
  printf '%s\n' "clean scope fixture passed" >"$root/result.txt"
}

run_test_clean_scope_inner() {
  require_source_root
  local expected="$EVIDENCE_DIR/expected"
  local actual="$EVIDENCE_DIR/actual"
  mkdir -p "$EVIDENCE_DIR" "$LOG_DIR"
  cat >"$expected" <<'EOF'
.gitignore
Scripts/selected-router-labels-owner.sh
WorkbenchKit/Sources/WorkbenchKit/Router/RouterModels.swift
WorkbenchKit/Sources/WorkbenchKit/Skills/Skill.swift
WorkbenchKit/Sources/WorkbenchKit/Skills/SkillCatalog.swift
WorkbenchKit/Tests/WorkbenchKitTests/RouterTests.swift
hosaka.config.yaml
EOF
  git -C "$SOURCE_DIR" diff --name-only "$BASELINE_REF...HEAD" | sort >"$actual"
  diff -u "$expected" "$actual" >"$LOG_DIR/test-clean-scope.diff"
  git -C "$SOURCE_DIR" diff --quiet HEAD --
  [[ -z "$(git -C "$SOURCE_DIR" ls-files --others --exclude-standard)" ]]
}

run_test_rollback() {
  local root="$EVIDENCE_DIR/tests/rollback"
  rm -rf "$root"
  mkdir -p "$root"
  local installed="$root/Workbench.app"
  local backup="$root/backup.app"
  local bad="$root/bad.app"
  make_minimal_app "$installed" "installed-ok"
  make_minimal_app "$backup" "backup-ok"
  make_minimal_app "$bad" "bad-candidate"
  if ! require_bundle_identity "$bad" valid-before-mutation; then
    printf '%s\n' "valid candidate fixture did not pass identity predicate" >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.example.NotWorkbench" "$bad/Contents/Info.plist"
  if require_bundle_identity "$bad" invalid-after-mutation; then
    printf '%s\n' "invalid candidate fixture did not fail identity predicate" >&2
    exit 1
  fi
  INSTALLED_APP="$installed"
  rm -rf "$INSTALLED_APP"
  ditto "$bad" "$INSTALLED_APP"
  local open_stub="$root/open-stub.log"
  WORKBENCH_OWNER_OPEN_STUB="$open_stub"
  if ! require_bundle_identity "$INSTALLED_APP" installed-after; then
    restore_backup_files "$backup"
  fi
  [[ ! -e "$open_stub" ]] || { printf '%s\n' "fixture pure restore unexpectedly reopened Workbench" >&2; exit 1; }
  restore_backup_and_reopen "$backup"
  grep -F "open -a Workbench" "$open_stub" >/dev/null
  cmp "$backup/Contents/MacOS/Workbench" "$INSTALLED_APP/Contents/MacOS/Workbench" >"$root/cmp.log"
  printf '%s\n' "rollback fixture passed" >"$root/result.txt"
}

run_test_signed_binding() {
  local root="$EVIDENCE_DIR/tests/signed-binding"
  rm -rf "$root"
  mkdir -p "$root/unsigned.app" "$root/signed.app" "$root/evidence"
  make_minimal_app "$root/unsigned.app" "unsigned-bytes"
  make_minimal_app "$root/signed.app" "signed-bytes"
  cat >"$root/evidence/candidate-binding.json" <<EOF
{"source_head":"fixture-head","baseline":"fixture-base","candidate_app":"$root/unsigned.app","executable_sha256":"$(shasum -a 256 "$root/unsigned.app/Contents/MacOS/Workbench" | awk '{print $1}')","info_plist_sha256":"$(shasum -a 256 "$root/unsigned.app/Contents/Info.plist" | awk '{print $1}')"}
EOF
  EVIDENCE_DIR="$root/evidence"
  bind_signed_candidate "$root/signed.app"
  python3 - "$root/evidence/signed-candidate-binding.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
if data["signed_executable_sha256"] == data["unsigned_executable_sha256"]:
    raise SystemExit("fixture did not prove signed bytes differ from unsigned bytes")
PY
  printf '%s\n' "signed binding fixture passed" >"$root/result.txt"
}

run_test_router_labels() {
  [[ "${1:-}" == "WORKBENCH-SELECTED-NAMES" ]] || {
    printf '%s\n' "usage: $0 test-router-labels WORKBENCH-SELECTED-NAMES" >&2
    exit 2
  }
  local verifier="$BUILD_DIR/router-labels-verify.sh"
  cat >"$verifier" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "WORKBENCH-SELECTED-NAMES" ]] || exit 2
/usr/bin/swift test --package-path "$2/WorkbenchKit"
SH
  chmod +x "$verifier"
  printf '%s\n' "bash $verifier WORKBENCH-SELECTED-NAMES $SOURCE_DIR" >"$LOG_DIR/router-labels-swift-test.command.txt"
  bash "$verifier" WORKBENCH-SELECTED-NAMES "$SOURCE_DIR" >"$LOG_DIR/router-labels-swift-test.stdout.log" 2>"$LOG_DIR/router-labels-swift-test.stderr.log"
  cat "$LOG_DIR/router-labels-swift-test.stdout.log"
  cat "$LOG_DIR/router-labels-swift-test.stderr.log" >&2
}

run_test_native_ui_verifier_relocation() {
  local root="$EVIDENCE_DIR/tests/native-ui-verifier-relocation"
  rm -rf "$root"
  mkdir -p "$root"
  local relocated="$root/verify.py"
  cp "$HOME/model-trials-data/reports/trials-recovery-20261006/worker-integration-v1/native-ui-verification/verify.py" "$relocated"
  chmod +x "$relocated"
  WORKBENCH_NATIVE_UI_VERIFIER="$relocated"
  NATIVE_UI_VERIFIER="$relocated"
  require_native_ui_verifier
  printf 'mutation\n' >>"$relocated"
  if require_native_ui_verifier; then
    printf '%s\n' "mutated native UI verifier was accepted" >&2
    exit 1
  fi
  printf '%s\n' "native UI verifier relocation fixture passed" >"$root/result.txt"
}

write_sha256() {
  (
    cd "$EVIDENCE_DIR"
    find . -maxdepth 2 -type f \
      ! -name SHA256SUMS \
      ! -path './build/*' \
      ! -path './backups/*' \
      ! -path './production/*' \
      -print | sort | xargs shasum -a 256
  ) >"$EVIDENCE_DIR/SHA256SUMS"
}

case "${1:-}" in
  inspect) inspect_installed ;;
  localhost) run_localhost ;;
  deploy) run_deploy ;;
  production) run_production ;;
  test-clean-scope) run_test_clean_scope ;;
  test-clean-scope-inner) run_test_clean_scope_inner ;;
  test-rollback) run_test_rollback ;;
  test-signed-binding) run_test_signed_binding ;;
  test-router-labels) shift; run_test_router_labels "$@" ;;
  test-native-ui-verifier-relocation) run_test_native_ui_verifier_relocation ;;
  sha256) write_sha256 ;;
  *) usage; exit 2 ;;
esac

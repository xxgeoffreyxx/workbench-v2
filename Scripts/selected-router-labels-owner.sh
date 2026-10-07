#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${WORKBENCH_SOURCE_DIR:-}" ]]; then
  SOURCE_DIR="$(cd "$WORKBENCH_SOURCE_DIR" && pwd)"
else
  SOURCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

EVIDENCE_DIR="${WORKBENCH_OWNER_EVIDENCE_DIR:-$HOME/Library/Application Support/Workbench/command-owner}"
INSTALLED_APP="${WORKBENCH_INSTALLED_APP:-/Applications/Workbench.app}"
DERIVED_DATA="${WORKBENCH_DERIVED_DATA:-$EVIDENCE_DIR/build/DerivedData}"
LOG_DIR="$EVIDENCE_DIR/logs"
BUILD_DIR="$EVIDENCE_DIR/build"
BACKUP_DIR="$EVIDENCE_DIR/backups"
PRODUCTION_DIR="$EVIDENCE_DIR/production"
CANDIDATE_APP="$DERIVED_DATA/Build/Products/Release/Workbench.app"
ACCEPTANCE_INPUT="${WORKBENCH_ACCEPTANCE_INPUT:-}"

EXPECTED_BUNDLE_ID="me.mccaleb.Workbench"
EXPECTED_VERSION="2.0"
EXPECTED_BUILD="31"
EXPECTED_TEAM_ID="45CY38F39L"

mkdir -p "$LOG_DIR" "$BUILD_DIR" "$BACKUP_DIR" "$PRODUCTION_DIR"

usage() {
  printf '%s\n' "usage: $0 inspect|localhost|deploy|production|test-clean-scope|test-rollback|test-signed-binding|test-router-labels|test-component-entitlements|test-acceptance-required|sha256"
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
  python3 - "$SOURCE_DIR" "$EVIDENCE_DIR/source-scope.json" "${1:-check}" "$ACCEPTANCE_INPUT" <<'PYCODE'
import hashlib, json, os, pathlib, subprocess, sys
source, output, action, acceptance_path = sys.argv[1:]
source, output = pathlib.Path(source), pathlib.Path(output)
def git(*args):
    return subprocess.check_output(['git','-C',str(source),*args])
if git('status','--porcelain','--untracked-files=all').strip():
    raise SystemExit('source must be clean and committed before binding')
head=git('rev-parse','HEAD').decode().strip()
tree=git('rev-parse','HEAD^{tree}').decode().strip()
files={}
for raw in git('ls-files','-z').split(b'\0'):
    if not raw: continue
    rel=os.fsdecode(raw); path=source/rel
    payload=b'symlink:'+os.fsencode(os.readlink(path)) if path.is_symlink() else path.read_bytes()
    files[rel]=hashlib.sha256(payload).hexdigest()
acceptance=None
if acceptance_path:
    path=pathlib.Path(acceptance_path).resolve()
    raw=path.read_bytes(); data=json.loads(raw)
    if set(data)!= {'version','routes','native_ui_verifier'} or data['version']!=1:
        raise SystemExit('unsupported run-owned acceptance input schema')
    if not isinstance(data['routes'],list) or not data['routes']:
        raise SystemExit('acceptance routes must be a nonempty list')
    seen=set()
    for row in data['routes']:
        if set(row)!= {'route_id','host','model','display_label'} or any(not isinstance(v,str) or not v for v in row.values()):
            raise SystemExit('invalid acceptance route')
        if row['route_id'] in seen: raise SystemExit('duplicate acceptance route')
        seen.add(row['route_id'])
    verifier=data['native_ui_verifier']
    if set(verifier)!= {'path','sha256'} or not isinstance(verifier['path'],str) or not isinstance(verifier['sha256'],str):
        raise SystemExit('invalid native verifier binding')
    vp=pathlib.Path(verifier['path'])
    if not vp.is_file() or not os.access(vp,os.X_OK) or hashlib.sha256(vp.read_bytes()).hexdigest()!=verifier['sha256']:
        raise SystemExit('native verifier bytes do not match acceptance input')
    acceptance={'path':str(path),'sha256':hashlib.sha256(raw).hexdigest()}
binding={'version':1,'source_head':head,'source_tree':tree,'files':files,'acceptance_input':acceptance}
if action=='record':
    output.write_text(json.dumps(binding,indent=2,sort_keys=True)+'\n')
elif action=='check':
    if json.loads(output.read_text())!=binding:
        raise SystemExit('source or run acceptance input changed since localhost binding')
else: raise SystemExit('unknown source binding action')
PYCODE
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
  require_acceptance_input
  verify_source_scope_and_hashes record
  log_run swift-test /usr/bin/swift test --package-path "$SOURCE_DIR/WorkbenchKit"
  log_run xcodebuild-warden /usr/bin/xcodebuild -project "$SOURCE_DIR/Warden.xcodeproj" -scheme Warden -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO build
  [[ -d "$CANDIDATE_APP" ]] || { printf '%s\n' "candidate app missing: $CANDIDATE_APP" >&2; exit 1; }
  require_bundle_identity "$CANDIDATE_APP" candidate || exit 1
  shasum -a 256 "$CANDIDATE_APP/Contents/MacOS/Workbench" "$CANDIDATE_APP/Contents/Info.plist" >"$EVIDENCE_DIR/candidate-app-sha256.txt"
  macho_manifest_control snapshot "$CANDIDATE_APP" "$EVIDENCE_DIR/unsigned-macho-manifest.json"
  local exe_hash info_hash head source_hash macho_hash
  macho_hash="$(shasum -a 256 "$EVIDENCE_DIR/unsigned-macho-manifest.json" | awk '{print $1}')"
  exe_hash="$(shasum -a 256 "$CANDIDATE_APP/Contents/MacOS/Workbench" | awk '{print $1}')"
  info_hash="$(shasum -a 256 "$CANDIDATE_APP/Contents/Info.plist" | awk '{print $1}')"
  head="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
  source_hash="$(shasum -a 256 "$EVIDENCE_DIR/source-scope.json" | awk '{print $1}')"
  cat >"$EVIDENCE_DIR/candidate-binding.json" <<EOF
{"source_head":"$head","source_binding_sha256":"$source_hash","candidate_app":"$CANDIDATE_APP","executable_sha256":"$exe_hash","info_plist_sha256":"$info_hash","unsigned_macho_manifest_sha256":"$macho_hash"}
EOF
}

require_router_idle() {
  local health="$EVIDENCE_DIR/router-health-predeploy.json"
  curl -fsS http://127.0.0.1:8110/health >"$health"
  python3 - "$health" "$ACCEPTANCE_INPUT" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
if data.get("ok") is not True:
    raise SystemExit("router health is not ok")
active = data.get("active_requests")
if not isinstance(active, int):
    raise SystemExit("router active_requests is missing or not an integer")
if active != 0:
    raise SystemExit(f"router active_requests is {active}, refusing Workbench restart")
if sys.argv[2]:
    acceptance=json.loads(pathlib.Path(sys.argv[2]).read_text())
    for expected in acceptance['routes']:
        row=(data.get('models') or {}).get(expected['route_id']) or {}
        if row.get('host')!=expected['host'] or row.get('model')!=expected['model'] or row.get('label')!=expected['display_label'] or row.get('ready') is not True:
            raise SystemExit(f"router route {expected['route_id']} not ready with accepted identity")
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

macho_manifest_control() {
  python3 - "$@" <<'PYMACHO'
import hashlib,json,os,pathlib,plistlib,sys
mode,app_arg,manifest_arg=sys.argv[1:4]
app=pathlib.Path(app_arg).resolve();manifest=pathlib.Path(manifest_arg)
magic={bytes.fromhex(x) for x in ['cffaedfe','cefaedfe','feedfacf','feedface','cafebabe','bebafeca','cafebabf','bfbafeca']}
files={};aliases={}
for base in [app/'Contents/MacOS',app/'Contents/Frameworks']:
 for root,dirs,names in os.walk(base,followlinks=False):
  root=pathlib.Path(root)
  for name in dirs+names:
   p=root/name
   if p.is_symlink():
    target=p.resolve(strict=True)
    if not target.is_relative_to(app):raise SystemExit('escaping app symlink: '+str(p))
    aliases[str(p.relative_to(app))]=str(target.relative_to(app))
  dirs[:]=[n for n in dirs if not (root/n).is_symlink()]
  for name in names:
   p=root/name
   if p.is_symlink():continue
   with p.open('rb') as f:header=f.read(4)
   if header not in magic:continue
   rel=str(p.relative_to(app))
   if name.endswith('.debug.dylib') or name=='__preview.dylib':raise SystemExit('Debug/preview Mach-O rejected: '+rel)
   files[rel]={'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'size':p.stat().st_size}
info=plistlib.loads((app/'Contents/Info.plist').read_bytes());main='Contents/MacOS/'+info['CFBundleExecutable']
if main not in files:raise SystemExit('main executable is not a physical Mach-O')
actual={'version':1,'main':main,'files':files,'aliases':aliases}
if mode=='snapshot':manifest.write_text(json.dumps(actual,sort_keys=True,indent=2)+'\n')
elif mode=='verify':
 if actual!=json.loads(manifest.read_text()):raise SystemExit('full Mach-O bytes/layout changed')
elif mode=='layout':
 expected=json.loads(manifest.read_text())
 if set(files)!=set(expected['files']) or aliases!=expected['aliases'] or main!=expected['main']:raise SystemExit('unexpected candidate Mach-O component/layout')
else:raise SystemExit('unknown Mach-O manifest mode')
PYMACHO
}

component_signature_control() {
  python3 - "$@" <<'PYCODE'
import base64, hashlib, json, os, pathlib, plistlib, re, subprocess, sys
mode, app_arg, manifest_arg = sys.argv[1:4]
app=pathlib.Path(app_arg).resolve(); manifest=pathlib.Path(manifest_arg)
def invoke(args):
    r=subprocess.run(['codesign',*args],capture_output=True)
    if r.returncode: raise RuntimeError('codesign failed: '+r.stderr.decode(errors='replace'))
    return (r.stdout+r.stderr).decode(errors='replace')
def components():
    roots=[app/'Contents/MacOS',app/'Contents/Frameworks']
    bundles={app}
    for nested in roots:
        for root, dirs, files in os.walk(nested,followlinks=False):
            root=pathlib.Path(root)
            dirs[:]=[d for d in dirs if not (root/d).is_symlink()]
            if root.suffix in {'.app','.xpc','.framework'}: bundles.add(root)
    excluded=set()
    for bundle in bundles:
        candidates=[bundle/'Contents/Info.plist',bundle/'Resources/Info.plist']
        info=next((x for x in candidates if x.is_file()),None)
        if info:
            executable=plistlib.loads(info.read_bytes()).get('CFBundleExecutable')
            if executable:
                for x in [bundle/'Contents/MacOS'/executable,bundle/executable]:
                    if x.exists(): excluded.add(x.resolve())
    found=set(bundles)
    for nested in roots:
        for root, dirs, files in os.walk(nested,followlinks=False):
            root=pathlib.Path(root); dirs[:]=[d for d in dirs if not (root/d).is_symlink()]
            for name in files:
                path=root/name
                if path.is_symlink() or path.resolve() in excluded: continue
                magic=path.read_bytes()[:4]
                if magic in (b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xfe\xed\xfa\xce',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca',b'\xca\xfe\xba\xbf',b'\xbf\xba\xfe\xca'):
                    found.add(path)
    return sorted(str(p.relative_to(app)) for p in found)
def signature(rel):
    details=invoke(['-d','--verbose=4',str(app/rel)])
    def field(key):
        return next((x[len(key)+1:] for x in details.splitlines() if x.startswith(key+'=')),None)
    flags=re.search(r'flags=(0x[0-9a-fA-F]+)',details)
    raw=invoke(['-d','--entitlements',':-',str(app/rel)])
    start=raw.find('<?xml'); end=raw.find('</plist>',start)
    ent=None if start<0 else plistlib.dumps(plistlib.loads(raw[start:end+8].encode()),sort_keys=True)
    identifier,team=field('Identifier'),field('TeamIdentifier')
    if not identifier or not flags or team is None: raise RuntimeError('missing component signature identity: '+rel)
    adhoc=field('Signature')=='adhoc'
    if not adhoc and team=='not set': raise RuntimeError('unsupported unsigned component identity: '+rel)
    return {'path':rel,'identifier':identifier,'team':team,'adhoc':adhoc,'flags':flags.group(1),
            'entitlements_base64':None if ent is None else base64.b64encode(ent).decode(),
            'entitlements_sha256':None if ent is None else hashlib.sha256(ent).hexdigest()}
def snapshot():
    return {'version':1,'components':[signature(rel) for rel in components()]}
if mode=='snapshot':
    manifest.write_text(json.dumps(snapshot(),indent=2,sort_keys=True)+'\n')
elif mode=='verify':
    if snapshot()!=json.loads(manifest.read_text()): raise RuntimeError('component identity or entitlements changed')
elif mode=='sign':
    expected=json.loads(manifest.read_text()); identity=sys.argv[4]
    if components()!=sorted(row['path'] for row in expected['components']): raise RuntimeError('candidate component set changed')
    rows=sorted(expected['components'],key=lambda row:(-len(pathlib.PurePath(row['path']).parts),row['path']))
    # The outer app is always last, after every nested helper/bundle/framework.
    rows=[row for row in rows if row['path']!='.']+[row for row in rows if row['path']=='.']
    for index,row in enumerate(rows):
        signer='-' if row['adhoc'] else identity
        args=['--force','--options',row['flags'],'--identifier',row['identifier'],'--sign',signer]
        if row['entitlements_base64'] is not None:
            ent=manifest.parent/f'component-{index}-entitlements.plist'
            ent.write_bytes(base64.b64decode(row['entitlements_base64']))
            args+=['--entitlements',str(ent)]
        invoke([*args,str(app/row['path'])])
    if snapshot()!=expected: raise RuntimeError('signed component identity or entitlements changed')
else: raise RuntimeError('unknown component signature mode')
PYCODE
}

verify_component_entitlements() {
  component_signature_control verify "$1" "$2"
}

sign_candidate() {
  local staged="$BUILD_DIR/signed-candidate-$(stamp).app"
  rm -rf "$staged"
  log_run stage-candidate ditto "$CANDIDATE_APP" "$staged"
  local identity manifest
  identity="${WORKBENCH_CODESIGN_IDENTITY:-$(installed_signing_identity)}"
  manifest="$EVIDENCE_DIR/installed-component-entitlements.json"
  macho_manifest_control snapshot "$INSTALLED_APP" "$EVIDENCE_DIR/installed-macho-layout.json"
  macho_manifest_control layout "$staged" "$EVIDENCE_DIR/installed-macho-layout.json"
  component_signature_control snapshot "$INSTALLED_APP" "$manifest"
  component_signature_control sign "$staged" "$manifest" "$identity"
  require_bundle_identity "$staged" signed-candidate
  require_signature "$staged" signed-candidate
  macho_manifest_control snapshot "$staged" "$EVIDENCE_DIR/signed-macho-manifest.json"
  bind_signed_candidate "$staged"
  printf '%s\n' "$staged" >"$EVIDENCE_DIR/signed-candidate-path.txt"
}

restore_backup_files() {
  local backup="$1"
  [[ -d "$backup" && ! -L "$backup" ]] || { printf '%s\n' "rollback failed: missing or unsafe backup $backup" >&2; return 1; }
  local restore_root staged displaced
  restore_root="$(mktemp -d "$(dirname "$INSTALLED_APP")/.Workbench-restore.XXXXXX")" || return 1
  staged="$restore_root/Workbench.app"
  displaced="$restore_root/displaced.app"
  if ! ditto "$backup" "$staged" >"$LOG_DIR/rollback-stage.stdout.log" 2>"$LOG_DIR/rollback-stage.stderr.log"; then
    printf '%s\n' "rollback failed: backup staging copy failed; installed app preserved" >&2
    rm -rf "$restore_root"
    return 1
  fi
  if ! require_bundle_identity "$staged" rollback-staged || ! require_signature "$staged" rollback-staged || ! compare_backup_copy "$backup" "$staged"; then
    printf '%s\n' "rollback failed: staged backup validation failed; installed app preserved" >&2
    rm -rf "$restore_root"
    return 1
  fi
  if [[ -e "$INSTALLED_APP" ]]; then
    if ! rename_app_directory "$INSTALLED_APP" "$displaced"; then
      printf '%s\n' "rollback failed: could not preserve current app before swap" >&2
      rm -rf "$restore_root"
      return 1
    fi
  fi
  if ! rename_app_directory "$staged" "$INSTALLED_APP"; then
    printf '%s\n' "rollback failed: staged app swap failed" >&2
    if [[ -d "$displaced" ]] && ! rename_app_directory "$displaced" "$INSTALLED_APP"; then
      printf '%s\n' "rollback failed: prior app retained at $displaced; automatic restore could not complete" >&2
      return 1
    fi
    rm -rf "$restore_root"
    return 1
  fi
  rm -rf "$restore_root"
}

compare_backup_copy() {
  python3 - "$1" "$2" <<'PY'
import hashlib, pathlib, sys
backup, staged = map(pathlib.Path, sys.argv[1:])
for rel in ("Contents/MacOS/Workbench", "Contents/Info.plist", "Contents/_CodeSignature/CodeResources"):
    if hashlib.sha256((backup / rel).read_bytes()).digest() != hashlib.sha256((staged / rel).read_bytes()).digest():
        raise SystemExit(f"rollback staged bytes differ: {rel}")
PY
}

rename_app_directory() {
  # Same-filesystem rename cannot silently nest an app inside an existing directory.
  python3 - "$1" "$2" <<'PY'
import os, sys
os.rename(sys.argv[1], sys.argv[2])
PY
}

reopen_workbench() {
  # Open the installed bundle by path: `open -a` can resolve a backup or DerivedData copy.
  if [[ -n "${WORKBENCH_OWNER_OPEN_STUB:-}" ]]; then
    printf '%s\n' "open $INSTALLED_APP" >>"$WORKBENCH_OWNER_OPEN_STUB" || return 1
    return 0
  fi
  /usr/bin/open "$INSTALLED_APP" >>"$LOG_DIR/reopen-workbench.stdout.log" 2>>"$LOG_DIR/reopen-workbench.stderr.log" || return 1
  wait_for_installed_process
}

wait_for_installed_process() {
  for _ in $(seq 1 30); do
    if observe_running_app | grep -F "$INSTALLED_APP/Contents/MacOS/Workbench" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  printf '%s\n' "installed Workbench process did not appear at $INSTALLED_APP" >&2
  return 1
}

require_acceptance_input() {
  [[ -n "$ACCEPTANCE_INPUT" && -s "$ACCEPTANCE_INPUT" ]] || {
    printf '%s\n' "WORKBENCH_ACCEPTANCE_INPUT is required for localhost, deploy and production" >&2
    exit 1
  }
}

restore_backup_and_reopen() {
  local backup="$1"
  restore_backup_files "$backup" || return 1
  reopen_workbench || { printf '%s\n' "rollback failed: restored app did not reopen" >&2; return 1; }
}

restore_displaced_files() {
  local backup="$1"
  local root="${LAST_CANDIDATE_SWAP_ROOT:-}"
  [[ -n "$root" && -d "$root/displaced.app" ]] || { printf '%s\n' "rollback failed: displaced original app is unavailable" >&2; return 1; }
  local displaced="$root/displaced.app" rejected="$root/rejected.app"
  require_bundle_identity "$displaced" displaced-original || return 1
  require_signature "$displaced" displaced-original || return 1
  compare_backup_copy "$backup" "$displaced" || return 1
  if [[ -e "$INSTALLED_APP" ]] && ! rename_app_directory "$INSTALLED_APP" "$rejected"; then
    printf '%s\n' "rollback failed: cannot preserve rejected candidate; original retained at $displaced" >&2
    return 1
  fi
  if ! rename_app_directory "$displaced" "$INSTALLED_APP"; then
    printf '%s\n' "rollback failed: cannot rename original back; original retained at $displaced" >&2
    if [[ -d "$rejected" ]] && ! rename_app_directory "$rejected" "$INSTALLED_APP"; then
      printf '%s\n' "rollback failed: rejected candidate retained at $rejected" >&2
    fi
    return 1
  fi
  rm -rf "$root"
  LAST_CANDIDATE_SWAP_ROOT=""
}

restore_displaced_and_reopen() {
  restore_displaced_files "$1" || return 1
  reopen_workbench || { printf '%s\n' "rollback failed: original restored but did not reopen" >&2; return 1; }
}

install_candidate_files() {
  local candidate="$1" backup="$2"
  LAST_CANDIDATE_SWAP_ROOT=""
  local root staged
  root="$(mktemp -d "$(dirname "$INSTALLED_APP")/.Workbench-install.XXXXXX")" || return 1
  staged="$root/Workbench.app"
  if ! ditto "$candidate" "$staged" >"$LOG_DIR/install-candidate.stdout.log" 2>"$LOG_DIR/install-candidate.stderr.log"; then
    printf '%s\n' "install failed: candidate staging copy failed; original app preserved" >&2
    rm -rf "$root"
    return 1
  fi
  if ! require_bundle_identity "$staged" install-staged || ! require_signature "$staged" install-staged || ! compare_backup_copy "$candidate" "$staged"; then
    printf '%s\n' "install failed: staged candidate validation failed; original app preserved" >&2
    rm -rf "$root"
    return 1
  fi
  if ! compare_backup_copy "$backup" "$INSTALLED_APP" || ! require_bundle_identity "$INSTALLED_APP" original-before-swap || ! require_signature "$INSTALLED_APP" original-before-swap; then
    printf '%s\n' "install failed: original app changed before swap" >&2
    rm -rf "$root"
    return 1
  fi
  if ! rename_app_directory "$INSTALLED_APP" "$root/displaced.app"; then
    printf '%s\n' "install failed: could not preserve original app before swap" >&2
    rm -rf "$root"
    return 1
  fi
  LAST_CANDIDATE_SWAP_ROOT="$root"
  if ! rename_app_directory "$staged" "$INSTALLED_APP"; then
    printf '%s\n' "install failed: candidate rename swap failed" >&2
    restore_displaced_files "$backup" || { printf '%s\n' "install and original restoration failed; preserved original at $root/displaced.app" >&2; return 1; }
    return 1
  fi
  printf '%s\n' "$root" >"$EVIDENCE_DIR/candidate-swap-path.txt" || { restore_displaced_files "$backup" || return 1; return 1; }
}

run_deploy() {
  require_acceptance_input
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
  local backup="$BACKUP_DIR/Workbench-installed-$(stamp).app"
  log_run backup-installed ditto "$INSTALLED_APP" "$backup"
  require_bundle_identity "$backup" backup || exit 1
  require_signature "$backup" backup || exit 1
  shasum -a 256 "$backup/Contents/MacOS/Workbench" "$backup/Contents/Info.plist" "$backup/Contents/_CodeSignature/CodeResources" >"$EVIDENCE_DIR/backup-sha256.txt"
  quit_exact_current_app_if_running
  if ! install_candidate_files "$staged" "$backup"; then
    if [[ -d "$INSTALLED_APP" ]] && compare_backup_copy "$backup" "$INSTALLED_APP"; then
      reopen_workbench || printf '%s\n' "install failed: original preserved but did not reopen" >&2
    else
      printf '%s\n' "install failed: original retained at ${LAST_CANDIDATE_SWAP_ROOT:-unknown}/displaced.app" >&2
    fi
    exit 1
  fi
  if ! require_bundle_identity "$INSTALLED_APP" installed-after || ! require_signature "$INSTALLED_APP" installed-after; then
    restore_displaced_and_reopen "$backup" || { printf '%s\n' "installed validation and original restoration failed" >&2; exit 1; }
    exit 1
  fi
  verify_installed_matches_signed_candidate "$staged" || {
    restore_displaced_and_reopen "$backup" || { printf '%s\n' "installed binding and original restoration failed" >&2; exit 1; }
    exit 1
  }
  if ! verify_component_entitlements "$INSTALLED_APP" "$EVIDENCE_DIR/installed-component-entitlements.json"; then
    restore_displaced_and_reopen "$backup" || { printf '%s\n' "component validation and original restoration failed" >&2; exit 1; }
    exit 1
  fi
  if reopen_workbench; then
    printf '%s\n' "$backup" >"$EVIDENCE_DIR/last-backup-path.txt"
    rm -rf "$LAST_CANDIDATE_SWAP_ROOT"
    LAST_CANDIDATE_SWAP_ROOT=""
    return 0
  fi
  restore_displaced_and_reopen "$backup" || { printf '%s\n' "Workbench did not reopen and original restoration failed" >&2; exit 1; }
  printf '%s\n' "Workbench did not reopen from candidate; original app restored and reopened" >&2
  exit 1
}

run_production() {
  require_acceptance_input
  verify_source_scope_and_hashes
  require_bundle_identity "$INSTALLED_APP" installed || exit 1
  require_signature "$INSTALLED_APP" installed-production || exit 1
  verify_installed_matches_signed_candidate_binding || exit 1
  verify_component_entitlements "$INSTALLED_APP" "$EVIDENCE_DIR/installed-component-entitlements.json" || exit 1
  [[ -n "$(observe_running_app)" ]] || { printf '%s\n' "installed Workbench is not running" >&2; return 1; }
  if [[ -n "$ACCEPTANCE_INPUT" ]]; then
    curl -fsS http://127.0.0.1:8110/health >"$PRODUCTION_DIR/router-health.json"
    python3 - "$ACCEPTANCE_INPUT" "$PRODUCTION_DIR" <<'PYCODE'
import json, pathlib, subprocess, sys
acceptance=json.loads(pathlib.Path(sys.argv[1]).read_text())
for row in acceptance['routes']:
    subprocess.run([sys.executable,acceptance['native_ui_verifier']['path'],'--phase','models','--out',str(pathlib.Path(sys.argv[2])/('workbench-'+row['host']+'-label')),
       '--route-id',row['route_id'],'--model',row['model'],'--host',row['host'],'--display-label',row['display_label']],check=True)
PYCODE
  fi
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
    "source_binding_sha256": unsigned["source_binding_sha256"],
    "unsigned_macho_manifest_sha256": unsigned["unsigned_macho_manifest_sha256"],
    "signed_macho_manifest_sha256": h(out.parent / "signed-macho-manifest.json"),
    "installed_macho_layout_sha256": h(out.parent / "installed-macho-layout.json"),
    "component_manifest_sha256": h(out.parent / "installed-component-entitlements.json"),
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
  macho_manifest_control verify "$CANDIDATE_APP" "$EVIDENCE_DIR/unsigned-macho-manifest.json" || return 1
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
if binding.get("source_binding_sha256") != h(pathlib.Path(sys.argv[1]).parent / "source-scope.json"):
    raise SystemExit("source/acceptance manifest changed since localhost")
if binding.get("unsigned_macho_manifest_sha256") != h(pathlib.Path(sys.argv[1]).parent / "unsigned-macho-manifest.json"):
    raise SystemExit("unsigned Mach-O manifest binding changed")
if binding.get("executable_sha256") != h(candidate / "Contents/MacOS/Workbench"):
    raise SystemExit("candidate executable hash changed since localhost")
if binding.get("info_plist_sha256") != h(candidate / "Contents/Info.plist"):
    raise SystemExit("candidate Info.plist hash changed since localhost")
PY
}

verify_installed_matches_signed_candidate() {
  local staged="$1"
  macho_manifest_control verify "$INSTALLED_APP" "$EVIDENCE_DIR/signed-macho-manifest.json" || return 1
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
  macho_manifest_control verify "$INSTALLED_APP" "$EVIDENCE_DIR/signed-macho-manifest.json" || return 1
  python3 - "$binding" "$INSTALLED_APP" "$SOURCE_DIR" <<'PY'
import json, hashlib, pathlib, subprocess, sys
binding = json.loads(pathlib.Path(sys.argv[1]).read_text())
installed = pathlib.Path(sys.argv[2])
head=subprocess.check_output(['git','-C',sys.argv[3],'rev-parse','HEAD'],text=True).strip()
if binding.get('source_head')!=head:
    raise SystemExit('installed candidate binding is for a different source HEAD')
for name,key in [('source-scope.json','source_binding_sha256'),('installed-component-entitlements.json','component_manifest_sha256'),('unsigned-macho-manifest.json','unsigned_macho_manifest_sha256'),('signed-macho-manifest.json','signed_macho_manifest_sha256'),('installed-macho-layout.json','installed_macho_layout_sha256')]:
    if hashlib.sha256((pathlib.Path(sys.argv[1]).parent/name).read_bytes()).hexdigest()!=binding.get(key):
        raise SystemExit(f'bound {name} changed after signing')
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
<key>CFBundleExecutable</key><string>Workbench</string>
<key>CFBundleIdentifier</key><string>$EXPECTED_BUNDLE_ID</string>
<key>CFBundleShortVersionString</key><string>$EXPECTED_VERSION</string>
<key>CFBundleVersion</key><string>$EXPECTED_BUILD</string>
</dict></plist>
EOF
  printf '\317\372\355\376%s\n' "$executable_text" >"$app/Contents/MacOS/Workbench"
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
    printf '%s\n' h >Scripts/00-selected-router-labels-test.sh
    git add .
    git -c user.name=fixture -c user.email=fixture@example.com commit -q -m baseline
    printf '%s\n' aa >.gitignore
    printf '%s\n' bb >WorkbenchKit/Sources/WorkbenchKit/Router/RouterModels.swift
    printf '%s\n' cc >WorkbenchKit/Sources/WorkbenchKit/Skills/Skill.swift
    printf '%s\n' dd >WorkbenchKit/Sources/WorkbenchKit/Skills/SkillCatalog.swift
    printf '%s\n' ee >WorkbenchKit/Tests/WorkbenchKitTests/RouterTests.swift
    printf '%s\n' ff >hosaka.config.yaml
    printf '%s\n' gg >Scripts/selected-router-labels-owner.sh
    printf '%s\n' hh >Scripts/00-selected-router-labels-test.sh
    printf '%s\n' future >FutureFeature.swift
    git add .
    git -c user.name=fixture -c user.email=fixture@example.com commit -q -m candidate
    WORKBENCH_ACCEPTANCE_INPUT="" WORKBENCH_OWNER_EVIDENCE_DIR="$root/evidence" WORKBENCH_SOURCE_DIR="$root/repo" bash "$SCRIPT_DIR/selected-router-labels-owner.sh" test-clean-scope-inner
  )
  printf '%s\n' "clean scope fixture passed" >"$root/result.txt"
}

run_test_clean_scope_inner() {
  verify_source_scope_and_hashes record
  verify_source_scope_and_hashes check
  printf '%s\n' 'later feature edit' >>"$SOURCE_DIR/WorkbenchKit/Sources/WorkbenchKit/Router/RouterModels.swift"
  if verify_source_scope_and_hashes check; then
    printf '%s\n' 'dirty source mutation was accepted' >&2; exit 1
  fi
  git -C "$SOURCE_DIR" add .
  git -C "$SOURCE_DIR" -c user.name=fixture -c user.email=fixture@example.com commit -q -m 'future source edit'
  if verify_source_scope_and_hashes check; then
    printf '%s\n' 'changed source head was accepted against old binding' >&2; exit 1
  fi
  verify_source_scope_and_hashes record
  verify_source_scope_and_hashes check
  local input="$EVIDENCE_DIR/acceptance-fixture.json" verifier="$EVIDENCE_DIR/native-verifier-fixture.py"
  printf '%s\n' '#!/usr/bin/env python3' 'raise SystemExit(0)' >"$verifier"
  chmod +x "$verifier"
  python3 - "$input" "$verifier" <<'PYCODE'
import hashlib,json,pathlib,sys
verifier=pathlib.Path(sys.argv[2])
pathlib.Path(sys.argv[1]).write_text(json.dumps({'version':1,'routes':[
 {'route_id':'ornith','host':'m1max','model':'Qwen3.5-9B-6bit','display_label':'Qwen3.5-9B Q6 (M1 Max)'},
 {'route_id':'qwen27','host':'m2max','model':'Qwen3.8-27B-4bit','display_label':'Qwen3.8-27B Q4 (M2 Max)'}],
 'native_ui_verifier':{'path':str(verifier),'sha256':hashlib.sha256(verifier.read_bytes()).hexdigest()}}))
PYCODE
  ACCEPTANCE_INPUT="$input"
  verify_source_scope_and_hashes record
  verify_source_scope_and_hashes check
  curl() {
    python3 - "$input" <<'PYCODE'
import json,pathlib,sys
rows=json.loads(pathlib.Path(sys.argv[1]).read_text())['routes']
print(json.dumps({'ok':True,'active_requests':0,'models':{r['route_id']:{'host':r['host'],'model':r['model'],'label':r['display_label'],'ready':True} for r in rows}}))
PYCODE
  }
  require_router_idle
  curl() { printf '%s\n' '{"ok":true,"active_requests":0,"models":{}}'; }
  if require_router_idle; then
    printf '%s\n' 'missing accepted router identities were accepted' >&2; exit 1
  fi
  printf '\n' >>"$input"
  if verify_source_scope_and_hashes check; then
    printf '%s\n' 'acceptance input byte mutation was accepted' >&2; exit 1
  fi
  verify_source_scope_and_hashes record
  printf '%s\n' '# drift' >>"$verifier"
  if verify_source_scope_and_hashes check; then
    printf '%s\n' 'native verifier mutation was accepted' >&2; exit 1
  fi
}

run_test_rollback() (
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
  local rollback_fixture_root="$root"
  require_signature() { [[ "$1" == "$rollback_fixture_root/"* ]] && [[ -f "$1/Contents/_CodeSignature/CodeResources" ]]; }
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
  grep -Fx "open $INSTALLED_APP" "$open_stub" >/dev/null || { printf '%s\n' "rollback reopen did not target the installed bundle path" >&2; exit 1; }
  if grep -F "open -a" "$open_stub" >/dev/null; then printf '%s\n' "rollback reopen used name-based open -a" >&2; exit 1; fi
  cmp "$backup/Contents/MacOS/Workbench" "$INSTALLED_APP/Contents/MacOS/Workbench" >"$root/cmp.log"
  # All overrides are confined to this fixture subprocess; real deployment keeps native signature checks.
  local force_restore_copy_failure=1
  local force_candidate_copy_failure=1
  local candidate_good="$root/good-candidate.app"
  make_minimal_app "$candidate_good" "good-candidate"
  ditto() {
    if [[ "${force_restore_copy_failure:-0}" == 1 && "$1" == "$backup" ]]; then return 73; fi
    if [[ "${force_candidate_copy_failure:-0}" == 1 && "$1" == "$candidate_good" ]]; then return 73; fi
    command ditto "$@"
  }
  if install_candidate_files "$candidate_good" "$backup"; then
    printf '%s\n' "candidate staging copy failure was swallowed" >&2; exit 1
  fi
  cmp "$backup/Contents/MacOS/Workbench" "$INSTALLED_APP/Contents/MacOS/Workbench"
  if restore_backup_files "$backup"; then
    printf '%s\n' "restore copy failure was swallowed" >&2; exit 1
  fi
  cmp "$backup/Contents/MacOS/Workbench" "$INSTALLED_APP/Contents/MacOS/Workbench"
  force_restore_copy_failure=0
  force_candidate_copy_failure=0
  install_candidate_files "$candidate_good" "$backup"
  cmp "$candidate_good/Contents/MacOS/Workbench" "$INSTALLED_APP/Contents/MacOS/Workbench"
  restore_displaced_files "$backup"
  cmp "$backup/Contents/MacOS/Workbench" "$INSTALLED_APP/Contents/MacOS/Workbench"
  local original_rename
  original_rename="$(declare -f rename_app_directory)"
  rename_app_directory() {
    if [[ "$1" == "$rollback_fixture_root/".Workbench-install.*/Workbench.app && "$2" == "$INSTALLED_APP" ]]; then return 75; fi
    python3 - "$1" "$2" <<'PY'
import os, sys
os.rename(sys.argv[1], sys.argv[2])
PY
  }
  if install_candidate_files "$candidate_good" "$backup"; then
    printf '%s\n' "candidate rename swap failure was swallowed" >&2; exit 1
  fi
  cmp "$backup/Contents/MacOS/Workbench" "$INSTALLED_APP/Contents/MacOS/Workbench"
  eval "$original_rename"
  if restore_backup_files "$bad"; then
    printf '%s\n' "invalid backup identity was accepted" >&2; exit 1
  fi
  cmp "$backup/Contents/MacOS/Workbench" "$INSTALLED_APP/Contents/MacOS/Workbench"
  if restore_backup_files "$root/missing-backup.app"; then
    printf '%s\n' "missing backup was accepted" >&2; exit 1
  fi
  cmp "$backup/Contents/MacOS/Workbench" "$INSTALLED_APP/Contents/MacOS/Workbench"
  local original_open
  original_open="$(declare -f reopen_workbench)"
  reopen_workbench() { return 74; }
  if restore_backup_and_reopen "$backup"; then
    printf '%s\n' "rollback reopen failure was swallowed" >&2; exit 1
  fi
  eval "$original_open"
  printf '%s\n' "rollback fixture passed" >"$root/result.txt"
)

run_test_signed_binding() {
  local root="$EVIDENCE_DIR/tests/signed-binding"
  rm -rf "$root"
  mkdir -p "$root/unsigned.app" "$root/signed.app" "$root/evidence"
  make_minimal_app "$root/unsigned.app" "unsigned-bytes"
  make_minimal_app "$root/signed.app" "signed-bytes"
  printf '%s\n' '{}' >"$root/evidence/source-scope.json"
  printf '%s\n' '{"components":[]}' >"$root/evidence/installed-component-entitlements.json"
  macho_manifest_control snapshot "$root/unsigned.app" "$root/evidence/unsigned-macho-manifest.json"
  macho_manifest_control snapshot "$root/signed.app" "$root/evidence/signed-macho-manifest.json"
  cp "$root/evidence/signed-macho-manifest.json" "$root/evidence/installed-macho-layout.json"
  cat >"$root/evidence/candidate-binding.json" <<EOF
{"unsigned_macho_manifest_sha256":"$(shasum -a 256 "$root/evidence/unsigned-macho-manifest.json" | awk '{print $1}')","source_head":"fixture-head","source_binding_sha256":"$(shasum -a 256 "$root/evidence/source-scope.json" | awk '{print $1}')","candidate_app":"$root/unsigned.app","executable_sha256":"$(shasum -a 256 "$root/unsigned.app/Contents/MacOS/Workbench" | awk '{print $1}')","info_plist_sha256":"$(shasum -a 256 "$root/unsigned.app/Contents/Info.plist" | awk '{print $1}')"}
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

run_test_component_entitlements() (
  local root="$EVIDENCE_DIR/tests/component-entitlements"
  rm -rf "$root"
  mkdir -p "$root/bin" "$root/app/Contents/Frameworks"
  python3 - "$root" <<'PYCODE'
import json, pathlib, plistlib, sys
root=pathlib.Path(sys.argv[1]); app=root/'app'
framework=app/'Contents/Frameworks/Sparkle.framework'
components=[(app,'me.mccaleb.Workbench',False,{'com.apple.security.device.audio-input':True}),
 (framework,'org.sparkle-project.Sparkle',False,None),
 (framework/'Autoupdate','Autoupdate-55554944af1d0cb0c3a837279eee9443bacac077',True,{'com.apple.application-identifier':'org.sparkle-project.Sparkle.Autoupdate'}),
 (framework/'Updater.app','org.sparkle-project.Sparkle.Updater',True,{}),
 (framework/'XPCServices/Downloader.xpc','org.sparkle-project.DownloaderService',True,{}),
 (framework/'XPCServices/Installer.xpc','org.sparkle-project.InstallerLauncher',True,{})]
for path,identifier,adhoc,ent in components:
    if path.name=='Autoupdate':
        path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(b'\xcf\xfa\xed\xfecontrol')
        meta=path.with_suffix('.fixture-signature.json')
    else:
        path.mkdir(parents=True,exist_ok=True)
        info=path/'Resources/Info.plist' if path.suffix=='.framework' else path/'Contents/Info.plist'
        info.parent.mkdir(parents=True,exist_ok=True)
        info.write_bytes(plistlib.dumps({'CFBundleExecutable':path.stem}))
        exe=path/path.stem if path.suffix=='.framework' else path/'Contents/MacOS'/path.stem
        exe.parent.mkdir(parents=True,exist_ok=True);exe.write_bytes(b'\xcf\xfa\xed\xfecontrol')
        meta=path/'.fixture-signature.json'
    meta.write_text(json.dumps({'identifier':identifier,'adhoc':adhoc,'team':'not set' if adhoc else '45CY38F39L','flags':'0x10002' if adhoc else '0x10000','entitlements':ent}))
(root/'bin/codesign').write_text('''#!/usr/bin/env python3
import json,os,pathlib,plistlib,sys
args=sys.argv[1:];p=pathlib.Path(args[-1]);meta=p/'.fixture-signature.json' if p.is_dir() else p.with_suffix('.fixture-signature.json');data=json.loads(meta.read_text())
if '--force' in args:
 with open(os.environ['WB_FIXTURE_SIGN_LOG'],'a') as f:f.write(json.dumps(args)+'\\n')
 data['identifier']=args[args.index('--identifier')+1];signer=args[args.index('--sign')+1];data['adhoc']=signer=='-';data['team']='not set' if signer=='-' else '45CY38F39L';data['flags']=args[args.index('--options')+1]
 data['entitlements']=plistlib.loads(pathlib.Path(args[args.index('--entitlements')+1]).read_bytes()) if '--entitlements' in args else None
 if os.environ.get('WB_FIXTURE_CORRUPT_COMPONENT') and p.name=='Downloader.xpc':data['entitlements']['unexpected-main-entitlement']=True
 meta.write_text(json.dumps(data));sys.exit(0)
if '--entitlements' in args:
 if data['entitlements'] is not None:sys.stdout.buffer.write(plistlib.dumps(data['entitlements']))
else:
 print('Identifier='+data['identifier']);print('TeamIdentifier='+data['team']);print('flags='+data['flags']);print('Signature=adhoc' if data['adhoc'] else 'Authority=Apple Development: Fixture')
''')
(root/'bin/codesign').chmod(0o755)
PYCODE
  export PATH="$root/bin:$PATH" WB_FIXTURE_SIGN_LOG="$root/sign-log.jsonl"
  component_signature_control snapshot "$root/app" "$root/expected.json"
  component_signature_control sign "$root/app" "$root/expected.json" 'Apple Development: Fixture'
  component_signature_control verify "$root/app" "$root/expected.json"
  python3 - "$root" <<'PYCODE'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]);rows=[json.loads(x) for x in (root/'sign-log.jsonl').read_text().splitlines()]
expected=json.loads((root/'expected.json').read_text())['components']
assert len(rows)==len(expected)==6
assert pathlib.Path(rows[-1][-1])==root/'app'
for row in rows:
    assert '--deep' not in row
    rel=str(pathlib.Path(row[-1]).relative_to(root/'app'));pin=next(x for x in expected if x['path']==rel)
    assert row[row.index('--sign')+1]==('-' if pin['adhoc'] else 'Apple Development: Fixture')
    assert row[row.index('--identifier')+1]==pin['identifier']
    for parent in rows:
        if pathlib.Path(row[-1])!=pathlib.Path(parent[-1]) and pathlib.Path(row[-1]).is_relative_to(pathlib.Path(parent[-1])):
            assert rows.index(row)<rows.index(parent)
PYCODE
  macho_manifest_control snapshot "$root/app" "$root/macho.json"
  local sign_log_before
  sign_log_before="$(shasum -a 256 "$root/sign-log.jsonl" | awk '{print $1}')"
  printf '\317\372\355\376unexpected' >"$root/app/Contents/MacOS/unexpected.dylib"
  if component_signature_control sign "$root/app" "$root/expected.json" 'Apple Development: Fixture'; then
    printf '%s\n' 'unexpected Mach-O signing accepted' >&2; exit 1
  fi
  [[ "$(shasum -a 256 "$root/sign-log.jsonl" | awk '{print $1}')" == "$sign_log_before" ]] || { printf '%s\n' 'unexpected component was signed before rejection' >&2; exit 1; }
  if macho_manifest_control layout "$root/app" "$root/macho.json"; then
    printf '%s\n' 'unexpected Mach-O layout accepted' >&2; exit 1
  fi
  rm "$root/app/Contents/MacOS/unexpected.dylib"
  macho_manifest_control verify "$root/app" "$root/macho.json"
  printf x >>"$root/app/Contents/Frameworks/Sparkle.framework/Autoupdate"
  if macho_manifest_control verify "$root/app" "$root/macho.json"; then
    printf '%s\n' 'nested Mach-O mutation accepted' >&2; exit 1
  fi
  export WB_FIXTURE_CORRUPT_COMPONENT=1
  if component_signature_control sign "$root/app" "$root/expected.json" 'Apple Development: Fixture'; then
    printf '%s\n' 'component entitlement drift was accepted' >&2; exit 1
  fi
  if component_signature_control verify "$root/app" "$root/expected.json"; then
    printf '%s\n' 'installed component entitlement drift was accepted' >&2; exit 1
  fi
  (
    # Exercise the actual post-install rollback branch with only fixture paths.
    CANDIDATE_APP="$root/candidate.app"
    INSTALLED_APP="$root/app"
    mkdir -p "$CANDIDATE_APP"
    ln -s app "$INSTALLED_APP/Contents/MacOS/Workbench"
    require_router_idle() { :; }
    require_acceptance_input() { :; }
    verify_source_scope_and_hashes() { :; }
    revalidate_candidate_binding() { :; }
    require_bundle_identity() { :; }
    require_signature() { :; }
    export_installed_entitlements() { :; }
    sign_candidate() {
      printf '%s\n' "$CANDIDATE_APP" >"$EVIDENCE_DIR/signed-candidate-path.txt"
      cp "$root/expected.json" "$EVIDENCE_DIR/installed-component-entitlements.json"
    }
    ditto() { cp -R "$1" "$2"; }
    quit_exact_current_app_if_running() { :; }
    install_candidate_files() { :; }
    verify_installed_matches_signed_candidate() { :; }
    restore_displaced_and_reopen() { printf '%s\n' restored >"$root/drift-rollback.txt"; }
    # Backup hash enumeration is independent of signature fixture metadata.
    mkdir -p "$INSTALLED_APP/Contents/_CodeSignature"
    printf '%s\n' fixture >"$INSTALLED_APP/Contents/_CodeSignature/CodeResources"
    if (run_deploy); then
      printf '%s\n' 'component drift did not abort deploy' >&2; exit 1
    fi
    [[ "$(cat "$root/drift-rollback.txt")" == restored ]]
  )
  printf '%s\n' 'component signer, identity, entitlement and ordering controls passed' >"$root/result.txt"
)

run_test_router_labels() {
  [[ -z "${1:-}" || "${1:-}" == "WORKBENCH-SELECTED-NAMES" ]] || {
    printf '%s\n' "usage: $0 test-router-labels [task-criterion]" >&2
    exit 2
  }
  local verifier="$BUILD_DIR/router-labels-verify.sh"
  cat >"$verifier" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
/usr/bin/swift test --package-path "$1/WorkbenchKit"
SH
  chmod +x "$verifier"
  printf '%s\n' "bash $verifier $SOURCE_DIR" >"$LOG_DIR/router-labels-swift-test.command.txt"
  bash "$verifier" "$SOURCE_DIR" >"$LOG_DIR/router-labels-swift-test.stdout.log" 2>"$LOG_DIR/router-labels-swift-test.stderr.log"
  cat "$LOG_DIR/router-labels-swift-test.stdout.log"
  cat "$LOG_DIR/router-labels-swift-test.stderr.log" >&2
}

run_test_acceptance_required() {
  local phase out
  for phase in localhost deploy production; do
    out="$(mktemp -d)"
    if WORKBENCH_ACCEPTANCE_INPUT="" WORKBENCH_OWNER_EVIDENCE_DIR="$out" bash "$SCRIPT_DIR/selected-router-labels-owner.sh" "$phase" >"$out/stdout.log" 2>"$out/stderr.log"; then
      printf '%s\n' "$phase ran without WORKBENCH_ACCEPTANCE_INPUT" >&2; exit 1
    fi
    grep -F "WORKBENCH_ACCEPTANCE_INPUT is required" "$out/stderr.log" >/dev/null || { printf '%s\n' "$phase failed for a reason other than missing acceptance input" >&2; cat "$out/stderr.log" >&2; exit 1; }
    rm -rf "$out"
  done
  printf '%s\n' "acceptance input required for localhost, deploy, production: PASS"
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
  test-component-entitlements) run_test_component_entitlements ;;
  test-acceptance-required) run_test_acceptance_required ;;
  test-router-labels) shift; run_test_router_labels "$@" ;;
  sha256) write_sha256 ;;
  *) usage; exit 2 ;;
esac

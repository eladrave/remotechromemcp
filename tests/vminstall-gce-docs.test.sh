#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_literal() {
  local file=$1
  local literal=$2
  grep -Fq -- "$literal" "$file" ||
    fail "$file is missing: $literal"
}

require_regex() {
  local file=$1
  local regex=$2
  grep -Eiq -- "$regex" "$file" ||
    fail "$file does not satisfy: $regex"
}

assert_before() {
  local file=$1
  local first=$2
  local second=$3
  local first_line second_line
  first_line="$(grep -n -m1 -F -- "$first" "$file" | cut -d: -f1)"
  second_line="$(grep -n -m1 -F -- "$second" "$file" | cut -d: -f1)"
  [[ -n $first_line && -n $second_line && $first_line -lt $second_line ]] ||
    fail "$file must place '$first' before '$second'"
}

assert_safe_content() {
  local file=$1
  local production_domain_re='(^|[^/[:alnum:].-])([[:alnum:]-]+\.)*elad'"rave"'\.com([^[:alnum:].-]|$)'
  local hex_token_re='(^|[^[:xdigit:]])[[:xdigit:]]{64}([^[:xdigit:]]|$)'

  if grep -Eqi "$production_domain_re" "$file"; then
    fail "$file contains a forbidden deployment hostname"
  fi
  if grep -Eq "$hex_token_re" "$file"; then
    fail "$file contains a bearer-token candidate"
  fi
  if grep -Eiq '(MCP_TOKEN|MCP_PASSWORD|LOGIN_PASSWORD|PASSWORD)[[:space:]]*[:=][[:space:]]*["'\'']?[[:alnum:]_.!@#$%^&*+-]{8,}' "$file"; then
    fail "$file contains a literal secret assignment"
  fi

  while IFS= read -r url; do
    local host
    host=${url#*://}
    host=${host%%/*}
    case "$host" in
      github.com|raw.githubusercontent.com) ;;
      *) fail "$file contains a repository URL on an unapproved host: $host" ;;
    esac
  done < <(grep -Eo 'https://[^[:space:]`")>]*/eladrave/remotechromemcp[^[:space:]`")>]*' "$file" || true)
}

gce_doc=docs/gce-manual.md
vm_doc=docs/vm-install.md
packager=scripts/package-release.sh

[[ -f $gce_doc ]] || fail "$gce_doc is missing"
[[ -f $vm_doc ]] || fail "$vm_doc is missing"
[[ -x $packager ]] || fail "$packager is missing or not executable"
if grep -Eq 'trap[[:space:]]+cleanup[[:space:]]+EXIT[[:space:]]+(HUP|INT|TERM)' "$packager"; then
  fail 'packager must route signals to a forced nonzero exit before EXIT cleanup'
fi
require_regex "$packager" 'trap cleanup EXIT'
require_regex "$packager" 'trap .*package_signal.* HUP'
require_regex "$packager" 'trap .*package_signal.* INT'
require_regex "$packager" 'trap .*package_signal.* TERM'
require_literal .gitignore '.release-staging/'
require_literal "$packager" '/usr/bin/flock -x "$publication_lock_fd"'
require_literal "$packager" \
  '/usr/bin/python3 -I -S - "$staged_dist" "$dist_dir"'
require_regex "$packager" \
  'unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONINSPECT PYTHONUSERBASE'
assert_before "$packager" '/usr/bin/flock -x "$publication_lock_fd"' \
  'status --porcelain'

gce_headings=(
  'Prerequisites'
  'Reserve a Static IP'
  'Create the Service Account'
  'Create the Backup Bucket'
  'Create and Attach the Persistent Disk'
  'Create the VM'
  'Open Ports 80 and 443'
  'Prepare the Data Disk'
  'Run the Interactive Installer'
  'Verify HTTPS and MCP'
  'Configure GCS Backup'
  'Reboot and Restore Test'
)
for heading in "${gce_headings[@]}"; do
  require_regex "$gce_doc" "^##[[:space:]]+$heading$"
done

gce_literals=(
  'compute.googleapis.com'
  'storage.googleapis.com'
  'roles/storage.objectUser'
  '--uniform-bucket-level-access'
  '--public-access-prevention'
  '--machine-type=e2-standard-2'
  '--image-family=ubuntu-2404-lts-amd64'
  '--image-project=ubuntu-os-cloud'
  '--type=pd-balanced'
  '--size=50GB'
  'device-name="${DISK_NAME}"'
  '--tags=remote-chrome-server'
  '--target-tags=remote-chrome-server'
  '--allow=tcp:80,tcp:443'
  '/dev/disk/by-id/google-remote-chrome-data'
  'findmnt'
  'lsblk'
  'blkid'
  'mkfs.ext4'
  '/etc/fstab'
  'UUID='
  'mount -a'
  'gcloud compute ssh'
)
for literal in "${gce_literals[@]}"; do
  require_literal "$gce_doc" "$literal"
done
require_regex "$gce_doc" 'Type the exact resolved device path'
require_regex "$gce_doc" 'only.*(format|mkfs).*(empty|contains no data)|(format|mkfs).*only.*(empty|contains no data)'
require_regex "$gce_doc" '(back up|backup).*/etc/fstab'
require_regex "$gce_doc" '(restore|roll[[:space:]-]?back).*/etc/fstab'
require_regex "$gce_doc" 'never (guess|assume).*(device|disk)'
if grep -Fq -- '--action=ALLOW' "$gce_doc"; then
  fail "$gce_doc combines --action with --allow; gcloud requires exactly one"
fi
assert_before "$gce_doc" 'findmnt' 'mkfs.ext4'
assert_before "$gce_doc" 'lsblk' 'mkfs.ext4'
assert_before "$gce_doc" 'blkid' 'mkfs.ext4'

quick_command='curl -fsSL https://raw.githubusercontent.com/eladrave/remotechromemcp/master/vminstall/install.sh | sudo sh'
pinned_command='curl -fsSL https://raw.githubusercontent.com/eladrave/remotechromemcp/v1.0.0/vminstall/install.sh | sudo sh -s -- --version v1.0.0'
require_literal "$vm_doc" "$quick_command"
require_literal "$vm_doc" "$pinned_command"
if grep -Eq \
  'raw[.]githubusercontent[.]com/eladrave/remotechromemcp/master/vminstall/install[.]sh.*--version[[:space:]]+v[0-9]+\.[0-9]+\.[0-9]+' \
  "$vm_doc" skills/remote-chrome-mcp/SKILL.md; then
  fail 'pinned or production guidance must never execute the moving master bootstrap'
fi

vm_concepts=(
  'Ubuntu 22.04'
  'Ubuntu 24.04'
  'Debian 12'
  'x86_64'
  'DNS'
  'TCP 80'
  'TCP 443'
  'domain'
  'certificate email'
  'data directory'
  'GCS'
  'MCP URL'
  'sudo remote-chrome status'
  'sudo remote-chrome credentials'
  'sudo remote-chrome update'
  'sudo remote-chrome backup'
  'sudo remote-chrome restore'
  'sudo remote-chrome uninstall'
  'never formats disks'
  'never changes firewall'
)
for concept in "${vm_concepts[@]}"; do
  require_literal "$vm_doc" "$concept"
done
require_regex "$vm_doc" 'existing.*(proxy|port 443|port 80).*(stop|fail|conflict)'
require_regex "$vm_doc" 'pinned.*(tag|release asset).*(exist|publish)|not live.*(tag|asset)'
require_regex "$vm_doc" 'uninstall.*preserv'

for file in "$gce_doc" "$vm_doc" skills/remote-chrome-mcp/SKILL.md; do
  assert_safe_content "$file"
done

package_tmp="$(mktemp -d)"
trap 'rm -rf "$package_tmp"' EXIT

init_package_repo() {
  local destination=$1
  shift
  mkdir -p "$destination/scripts"
  cp "$packager" "$destination/scripts/package-release.sh"
  chmod +x "$destination/scripts/package-release.sh"
  git -C "$destination" init -q
  git -C "$destination" config user.name 'Release Contract'
  git -C "$destination" config user.email release-contract@example.test
  printf 'release payload\n' >"$destination/payload.txt"
  printf 'dist/\n.release-staging/\n' >"$destination/.gitignore"
  git -C "$destination" add scripts/package-release.sh payload.txt .gitignore
  git -C "$destination" commit -qm 'release fixture'
  local fixture_tag
  for fixture_tag in "$@"; do
    git -C "$destination" tag -a "$fixture_tag" -m "$fixture_tag"
  done
}

inject_post_exchange_corruption() {
  local destination=$1
  sed -i \
    '0,/^publish_dist_exchange$/s//publish_dist_exchange\nif [[ ${FAKE_CORRUPT_AFTER_EXCHANGE:-0} == 1 ]]; then printf "corrupt\\n" >>"$archive"; fi/' \
    "$destination/scripts/package-release.sh"
}

retag_package_repo() {
  local destination=$1
  shift
  git -C "$destination" add scripts/package-release.sh
  git -C "$destination" commit -qm 'inject publication fault'
  local fixture_tag
  for fixture_tag in "$@"; do
    git -C "$destination" tag -fa "$fixture_tag" -m "$fixture_tag" >/dev/null
  done
}

package_repo="$package_tmp/repo"
init_package_repo "$package_repo" v1.0.0
grep -Fq '/usr/bin/mktemp -d "$staging_root/' \
  "$package_repo/scripts/package-release.sh" ||
  fail 'release staging must be a same-filesystem sibling of dist inside the repository'

"$package_repo/scripts/package-release.sh" v1.0.0 >"$package_tmp/output"
archive="$package_repo/dist/remotechromemcp-v1.0.0.tar.gz"
checksum="$archive.sha256"
[[ -f $archive && -f $checksum ]] || fail 'packager did not produce the exact asset pair'
(cd "$package_repo/dist" && sha256sum -c "$(basename "$checksum")") >/dev/null ||
  fail 'packager checksum does not verify'
checksum_line="$(<"$checksum")"
[[ $checksum_line =~ ^[0-9a-f]{64}[[:space:]][[:space:]]remotechromemcp-v1\.0\.0\.tar\.gz$ ]] ||
  fail 'checksum line must be lowercase SHA-256, two spaces, and exact basename'
first_archive_member="$(tar -tzf "$archive" | sed -n '1p')"
[[ $first_archive_member == remotechromemcp-v1.0.0/* ]] ||
  fail 'archive prefix is not deterministic'
first_hash="$(sha256sum "$archive" | cut -d' ' -f1)"
first_archive_identity=$(stat -c '%i:%s:%Y' "$archive")
first_checksum_identity=$(stat -c '%i:%s:%Y' "$checksum")
cp "$archive" "$package_tmp/original-archive"
cp "$checksum" "$package_tmp/original-checksum"

fake_bin="$package_tmp/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'mv attempted\n' >"$FAKE_MV_MARKER"
kill -KILL "$PPID"
exit 137
EOF
chmod +x "$fake_bin/mv"
if ! PATH="$fake_bin:$PATH" FAKE_MV_MARKER="$package_tmp/mv-marker" \
  "$package_repo/scripts/package-release.sh" v1.0.0 >/dev/null 2>&1; then
  fail 'identical immutable package pair must succeed without replacement'
fi
[[ ! -e $package_tmp/mv-marker ]] ||
  fail 'identical immutable package pair attempted a move'
[[ $(sha256sum "$archive" | cut -d' ' -f1) == "$first_hash" ]] ||
  fail 'identical immutable package pair changed archive bytes'
(cd "$package_repo/dist" &&
  sha256sum -c "$(basename "$checksum")") >/dev/null ||
  fail 'identical immutable package pair damaged its checksum'
[[ $(stat -c '%i:%s:%Y' "$archive") == "$first_archive_identity" &&
   $(stat -c '%i:%s:%Y' "$checksum") == "$first_checksum_identity" ]] ||
  fail 'identical immutable package pair changed published file identity'

rm "$checksum"
incomplete_archive_hash=$(sha256sum "$archive")
if "$package_repo/scripts/package-release.sh" v1.0.0 >/dev/null 2>&1; then
  fail 'packager accepted an incomplete existing release pair'
fi
[[ ! -e $checksum && $(sha256sum "$archive") == "$incomplete_archive_hash" ]] ||
  fail 'incomplete existing pair rejection mutated published output'
cp "$package_tmp/original-checksum" "$checksum"

printf '%064d  %s\n' 0 "$(basename "$archive")" >"$checksum"
invalid_archive_hash=$(sha256sum "$archive")
invalid_checksum_hash=$(sha256sum "$checksum")
if "$package_repo/scripts/package-release.sh" v1.0.0 >/dev/null 2>&1; then
  fail 'packager accepted an invalid existing checksum'
fi
[[ $(sha256sum "$archive") == "$invalid_archive_hash" &&
   $(sha256sum "$checksum") == "$invalid_checksum_hash" ]] ||
  fail 'invalid existing checksum rejection mutated published output'
cp "$package_tmp/original-checksum" "$checksum"

printf 'different immutable archive\n' >"$archive"
(cd "$package_repo/dist" &&
  sha256sum "$(basename "$archive")" >"$(basename "$checksum")")
different_archive_hash=$(sha256sum "$archive")
different_checksum_hash=$(sha256sum "$checksum")
if "$package_repo/scripts/package-release.sh" v1.0.0 >/dev/null 2>&1; then
  fail 'packager accepted a different valid pair for an immutable tag'
fi
[[ $(sha256sum "$archive") == "$different_archive_hash" &&
   $(sha256sum "$checksum") == "$different_checksum_hash" ]] ||
  fail 'different immutable pair rejection mutated published output'
cp "$package_tmp/original-archive" "$archive"
cp "$package_tmp/original-checksum" "$checksum"

crash_repo="$package_tmp/crash-repo"
init_package_repo "$crash_repo" v1.0.0
crash_bin="$package_tmp/crash-bin"
mkdir "$crash_bin"
cat >"$crash_bin/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
/usr/bin/python3 "$@"
if [[ ${FAKE_EXCHANGE_CRASH:-0} == 1 ]]; then
  printf 'exchange completed\n' >"$FAKE_EXCHANGE_MARKER"
  kill -KILL "$FAKE_PACKAGE_CRASH_PID"
  exit 137
fi
EOF
chmod +x "$crash_bin/python3"
sed -i \
  's|/usr/bin/python3 -I -S - "$staged_dist" "$dist_dir"|'\
"$crash_bin"'/python3 -I -S - "$staged_dist" "$dist_dir"|' \
  "$crash_repo/scripts/package-release.sh"
sed -i '/^umask 077$/a export FAKE_PACKAGE_CRASH_PID=$BASHPID' \
  "$crash_repo/scripts/package-release.sh"
git -C "$crash_repo" add scripts/package-release.sh
git -C "$crash_repo" commit -qm 'inject controlled publication crash'
git -C "$crash_repo" tag -fa v1.0.0 -m v1.0.0 >/dev/null
"$crash_repo/scripts/package-release.sh" v1.0.0 >/dev/null
crash_archive="$crash_repo/dist/remotechromemcp-v1.0.0.tar.gz"
crash_checksum="$crash_archive.sha256"
crash_expected_hash=$(sha256sum "$crash_archive" | cut -d' ' -f1)
rm "$crash_archive" "$crash_checksum"
if FAKE_EXCHANGE_CRASH=1 \
  FAKE_EXCHANGE_MARKER="$package_tmp/exchange-marker" \
  "$crash_repo/scripts/package-release.sh" v1.0.0 >/dev/null 2>&1; then
  fail 'post-publication SIGKILL fixture unexpectedly reported success'
fi
[[ -f $package_tmp/exchange-marker ]] ||
  fail 'post-publication SIGKILL fixture did not reach the atomic exchange'
[[ -f $crash_archive && -f $crash_checksum ]] ||
  fail 'post-publication SIGKILL left an incomplete first release pair'
[[ $(sha256sum "$crash_archive" | cut -d' ' -f1) == "$crash_expected_hash" ]] ||
  fail 'post-publication SIGKILL changed first-publication archive bytes'
(cd "$crash_repo/dist" &&
  sha256sum -c "$(basename "$crash_checksum")") >/dev/null ||
  fail 'post-publication SIGKILL left an invalid first release pair'
if ! find "$crash_repo/.release-staging" -mindepth 1 -maxdepth 1 \
  -type d -print -quit | grep -q .; then
  fail 'post-publication SIGKILL fixture did not retain crash residue'
fi
if ! "$crash_repo/scripts/package-release.sh" v1.0.0 >/dev/null 2>&1; then
  fail 'the first rerun after a post-exchange crash must recover automatically'
fi
[[ -d $crash_repo/.release-staging && ! -L $crash_repo/.release-staging ]] ||
  fail 'release recovery must retain one bounded real staging namespace'
if find "$crash_repo/.release-staging" -mindepth 1 -print -quit |
   grep -q .; then
  fail 'release recovery must reap validated crash residue'
fi
(cd "$crash_repo/dist" &&
  sha256sum -c "$(basename "$crash_checksum")") >/dev/null ||
  fail 'post-crash rerun damaged the published pair'

printf 'unexpected\n' >"$crash_repo/.release-staging/operator-file"
if "$crash_repo/scripts/package-release.sh" v1.0.0 >/dev/null 2>&1; then
  fail 'release recovery must reject unexpected staging namespace entries'
fi
[[ -f $crash_repo/.release-staging/operator-file ]] ||
  fail 'release recovery must not delete an unvalidated staging entry'

symlink_repo="$package_tmp/symlink-staging-repo"
init_package_repo "$symlink_repo" v1.0.0
symlink_escape="$package_tmp/symlink-staging-escape"
mkdir "$symlink_escape"
printf 'preserve\n' >"$symlink_escape/sentinel"
ln -s "$symlink_escape" "$symlink_repo/.release-staging"
if "$symlink_repo/scripts/package-release.sh" v1.0.0 >/dev/null 2>&1; then
  fail 'release recovery must reject a symlinked staging namespace'
fi
[[ $(<"$symlink_escape/sentinel") == preserve ]] ||
  fail 'staging namespace rejection must not mutate a symlink target'

hostile_repo="$package_tmp/hostile-python-repo"
init_package_repo "$hostile_repo"
cat >"$hostile_repo/ctypes.py" <<'PY'
import os
open(os.environ["MALICIOUS_PYTHON_MARKER"], "a").write("cwd ctypes\n")
raise RuntimeError("cwd ctypes loaded")
PY
cat >"$hostile_repo/sitecustomize.py" <<'PY'
import os
open(os.environ["MALICIOUS_PYTHON_MARKER"], "a").write("cwd sitecustomize\n")
PY
git -C "$hostile_repo" add ctypes.py sitecustomize.py
git -C "$hostile_repo" commit -qm 'hostile cwd modules'
git -C "$hostile_repo" tag -a v1.0.0 -m v1.0.0
hostile_path="$package_tmp/hostile-pythonpath"
mkdir "$hostile_path"
cat >"$hostile_path/ctypes.py" <<'PY'
import os
open(os.environ["MALICIOUS_PYTHON_MARKER"], "a").write("path ctypes\n")
raise RuntimeError("PYTHONPATH ctypes loaded")
PY
cat >"$hostile_path/sitecustomize.py" <<'PY'
import os
open(os.environ["MALICIOUS_PYTHON_MARKER"], "a").write("path sitecustomize\n")
PY
hostile_marker="$package_tmp/hostile-python-loaded"
(
  cd "$hostile_repo"
  PYTHONPATH="$hostile_path" PYTHONSTARTUP="$hostile_path/sitecustomize.py" \
    MALICIOUS_PYTHON_MARKER="$hostile_marker" \
    ./scripts/package-release.sh v1.0.0 >/dev/null
)
[[ ! -e $hostile_marker ]] ||
  fail 'isolated release publication loaded an attacker-controlled Python module'
(cd "$hostile_repo/dist" &&
  sha256sum -c remotechromemcp-v1.0.0.tar.gz.sha256) >/dev/null ||
  fail 'isolated Python publication did not produce a valid release pair'

noop_repo="$package_tmp/noop-python-repo"
init_package_repo "$noop_repo" v1.0.0
noop_python="$package_tmp/noop-python"
cat >"$noop_python" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$noop_python"
sed -i \
  's|/usr/bin/python3 -I -S - "$staged_dist" "$dist_dir"|'\
"$noop_python"' -I -S - "$staged_dist" "$dist_dir"|' \
  "$noop_repo/scripts/package-release.sh"
git -C "$noop_repo" add scripts/package-release.sh
git -C "$noop_repo" commit -qm 'inject no-op exchange interpreter'
git -C "$noop_repo" tag -fa v1.0.0 -m v1.0.0 >/dev/null
if "$noop_repo/scripts/package-release.sh" v1.0.0 \
  >"$package_tmp/noop-output" 2>/dev/null; then
  fail 'packager reported success when the atomic exchange did not occur'
fi
[[ ! -e $noop_repo/dist/remotechromemcp-v1.0.0.tar.gz ]] ||
  fail 'no-op exchange fixture unexpectedly published an archive'
[[ ! -s $package_tmp/noop-output ]] ||
  fail 'failed post-exchange verification must not print success paths'

rollback_repo="$package_tmp/rollback-repo"
init_package_repo "$rollback_repo" v1.0.0
inject_post_exchange_corruption "$rollback_repo"
retag_package_repo "$rollback_repo" v1.0.0
if FAKE_CORRUPT_AFTER_EXCHANGE=1 \
  "$rollback_repo/scripts/package-release.sh" v1.0.0 \
  >"$package_tmp/rollback-output" 2>"$package_tmp/rollback-error"; then
  fail 'packager accepted a corrupted pair after a real exchange'
fi
grep -Fq 'failed verification and was rolled back' \
  "$package_tmp/rollback-error" ||
  fail 'successful publication rollback was not reported'
[[ ! -s $package_tmp/rollback-output ]] ||
  fail 'rolled-back publication must not print success paths'
if find "$rollback_repo/dist" -mindepth 1 -print -quit | grep -q .; then
  fail 'first-publication rollback must restore the prior empty dist'
fi
if find "$rollback_repo/.release-staging" -mindepth 1 -print -quit |
  grep -q .; then
  fail 'confirmed rollback must remove the rejected candidate'
fi
"$rollback_repo/scripts/package-release.sh" v1.0.0 >/dev/null ||
  fail 'a confirmed first-publication rollback must allow an immediate rerun'
(cd "$rollback_repo/dist" &&
  sha256sum -c remotechromemcp-v1.0.0.tar.gz.sha256) >/dev/null ||
  fail 'immediate rerun after rollback did not publish a valid pair'

existing_rollback_repo="$package_tmp/existing-rollback-repo"
init_package_repo "$existing_rollback_repo" v1.0.0 v2.0.0
inject_post_exchange_corruption "$existing_rollback_repo"
retag_package_repo "$existing_rollback_repo" v1.0.0 v2.0.0
"$existing_rollback_repo/scripts/package-release.sh" v1.0.0 >/dev/null
existing_v1_archive="$existing_rollback_repo/dist/remotechromemcp-v1.0.0.tar.gz"
existing_v1_checksum="$existing_v1_archive.sha256"
existing_v1_hash=$(sha256sum "$existing_v1_archive")
existing_v1_checksum_hash=$(sha256sum "$existing_v1_checksum")
if FAKE_CORRUPT_AFTER_EXCHANGE=1 \
  "$existing_rollback_repo/scripts/package-release.sh" v2.0.0 \
  >/dev/null 2>"$package_tmp/existing-rollback-error"; then
  fail 'packager accepted a corrupted second release pair'
fi
[[ $(sha256sum "$existing_v1_archive") == "$existing_v1_hash" &&
   $(sha256sum "$existing_v1_checksum") == "$existing_v1_checksum_hash" ]] ||
  fail 'rollback must preserve an existing release pair byte-for-byte'
(cd "$existing_rollback_repo/dist" &&
  sha256sum -c remotechromemcp-v1.0.0.tar.gz.sha256) >/dev/null ||
  fail 'rollback damaged the existing release checksum pair'
[[ ! -e $existing_rollback_repo/dist/remotechromemcp-v2.0.0.tar.gz &&
   ! -e $existing_rollback_repo/dist/remotechromemcp-v2.0.0.tar.gz.sha256 ]] ||
  fail 'rollback left the rejected second release at the public path'
"$existing_rollback_repo/scripts/package-release.sh" v2.0.0 >/dev/null
(cd "$existing_rollback_repo/dist" &&
  sha256sum -c remotechromemcp-v1.0.0.tar.gz.sha256 &&
  sha256sum -c remotechromemcp-v2.0.0.tar.gz.sha256) >/dev/null ||
  fail 'rerun after existing-pair rollback did not preserve both releases'

rollback_exchange_repo="$package_tmp/rollback-exchange-failure-repo"
init_package_repo "$rollback_exchange_repo" v1.0.0
inject_post_exchange_corruption "$rollback_exchange_repo"
rollback_exchange_python="$package_tmp/rollback-exchange-python"
cat >"$rollback_exchange_python" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ ! -f $FAKE_EXCHANGE_COUNT ]] || count=$(<"$FAKE_EXCHANGE_COUNT")
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_EXCHANGE_COUNT"
[[ $count -ne 2 ]] || exit 73
exec /usr/bin/python3 "$@"
EOF
chmod +x "$rollback_exchange_python"
sed -i \
  's|/usr/bin/python3 -I -S - "$staged_dist" "$dist_dir"|'\
"$rollback_exchange_python"' -I -S - "$staged_dist" "$dist_dir"|' \
  "$rollback_exchange_repo/scripts/package-release.sh"
retag_package_repo "$rollback_exchange_repo" v1.0.0
if FAKE_CORRUPT_AFTER_EXCHANGE=1 \
  FAKE_EXCHANGE_COUNT="$package_tmp/rollback-exchange-count" \
  "$rollback_exchange_repo/scripts/package-release.sh" v1.0.0 \
  >"$package_tmp/rollback-exchange-output" \
  2>"$package_tmp/rollback-exchange-error"; then
  fail 'packager accepted a failed rollback exchange'
fi
grep -Fq 'Release rollback could not be confirmed' \
  "$package_tmp/rollback-exchange-error" ||
  fail 'rollback exchange failure must fail loudly'
grep -Fq 'Recovery material retained at:' \
  "$package_tmp/rollback-exchange-error" ||
  fail 'rollback exchange failure must report its exact recovery path'
grep -Fq 'Do not delete this directory' \
  "$package_tmp/rollback-exchange-error" ||
  fail 'rollback exchange failure must provide preservation instructions'
rollback_exchange_recovery=$(sed -n \
  's/^Recovery material retained at: //p' \
  "$package_tmp/rollback-exchange-error" | tail -1)
[[ -d $rollback_exchange_recovery &&
   -f $rollback_exchange_recovery/RECOVERY_REQUIRED ]] ||
  fail 'rollback exchange failure must retain marked bounded recovery material'
[[ ! -s $package_tmp/rollback-exchange-output ]] ||
  fail 'failed rollback exchange must not print success paths'

rollback_verify_repo="$package_tmp/rollback-verification-failure-repo"
init_package_repo "$rollback_verify_repo" v1.0.0
inject_post_exchange_corruption "$rollback_verify_repo"
sed -i \
  '/^verify_prior_dist() {$/a \  [[ ${FAKE_ROLLBACK_VERIFY_FAIL:-0} != 1 ]] || return 1' \
  "$rollback_verify_repo/scripts/package-release.sh"
retag_package_repo "$rollback_verify_repo" v1.0.0
grep -Fq 'FAKE_ROLLBACK_VERIFY_FAIL' \
  "$rollback_verify_repo/scripts/package-release.sh" ||
  fail 'rollback verification fault was not injected'
if FAKE_CORRUPT_AFTER_EXCHANGE=1 FAKE_ROLLBACK_VERIFY_FAIL=1 \
  "$rollback_verify_repo/scripts/package-release.sh" v1.0.0 \
  >"$package_tmp/rollback-verify-output" \
  2>"$package_tmp/rollback-verify-error"; then
  fail 'packager accepted an unconfirmed rollback verification'
fi
grep -Fq 'Release rollback could not be confirmed' \
  "$package_tmp/rollback-verify-error" ||
  fail 'rollback verification failure must fail loudly'
rollback_verify_recovery=$(sed -n \
  's/^Recovery material retained at: //p' \
  "$package_tmp/rollback-verify-error" | tail -1)
[[ -d $rollback_verify_recovery &&
   -f $rollback_verify_recovery/RECOVERY_REQUIRED ]] ||
  fail 'rollback verification failure must retain marked recovery material'
[[ ! -s $package_tmp/rollback-verify-output ]] ||
  fail 'unconfirmed rollback verification must not print success paths'
if "$rollback_verify_repo/scripts/package-release.sh" v1.0.0 \
  >/dev/null 2>"$package_tmp/retained-recovery-error"; then
  fail 'automatic recovery must not delete explicitly retained material'
fi
grep -Fq "$rollback_verify_recovery" "$package_tmp/retained-recovery-error" ||
  fail 'later runs must report the retained recovery path without deleting it'
[[ -d $rollback_verify_recovery &&
   -f $rollback_verify_recovery/RECOVERY_REQUIRED ]] ||
  fail 'later runs must preserve unconfirmed recovery material'

dirty_tracked_repo="$package_tmp/dirty-tracked-repo"
init_package_repo "$dirty_tracked_repo" v1.0.0
printf 'dirty tracked\n' >>"$dirty_tracked_repo/payload.txt"
if "$dirty_tracked_repo/scripts/package-release.sh" v1.0.0 >/dev/null 2>&1; then
  fail 'packager accepted a dirty tracked file'
fi

dirty_untracked_repo="$package_tmp/dirty-untracked-repo"
init_package_repo "$dirty_untracked_repo" v1.0.0
printf 'dirty untracked\n' >"$dirty_untracked_repo/untracked.txt"
if "$dirty_untracked_repo/scripts/package-release.sh" v1.0.0 >/dev/null 2>&1; then
  fail 'packager accepted an untracked file'
fi

missing_tag_repo="$package_tmp/missing-tag-repo"
init_package_repo "$missing_tag_repo"
if "$missing_tag_repo/scripts/package-release.sh" v1.0.0 \
  >"$package_tmp/missing-tag-output" 2>"$package_tmp/missing-tag-error"; then
  fail 'packager accepted a missing release tag'
fi
grep -Fq 'Release tag does not exist' "$package_tmp/missing-tag-error" ||
  fail 'missing-tag fixture failed before reaching tag validation'

mismatch_repo="$package_tmp/tag-mismatch-repo"
init_package_repo "$mismatch_repo" v1.0.0
printf 'later commit\n' >>"$mismatch_repo/payload.txt"
git -C "$mismatch_repo" add payload.txt
git -C "$mismatch_repo" commit -qm 'commit after tag'
if "$mismatch_repo/scripts/package-release.sh" v1.0.0 \
  >"$package_tmp/mismatch-output" 2>"$package_tmp/mismatch-error"; then
  fail 'packager accepted a tag that does not bind the current commit'
fi
grep -Fq 'does not bind the current commit' "$package_tmp/mismatch-error" ||
  fail 'tag-mismatch fixture failed before reaching commit validation'

concurrent_repo="$package_tmp/concurrent-repo"
init_package_repo "$concurrent_repo" v2.0.0 v3.0.0
concurrent_gate="$package_tmp/concurrent-gate"
mkdir "$concurrent_gate"
concurrent_wrapper="$package_tmp/concurrent-wrapper"
cat >"$concurrent_wrapper" <<EOF
#!/usr/bin/env bash
set -euo pipefail
version=\$1
touch "$concurrent_gate/ready.\$version"
while [[ ! -e "$concurrent_gate/go" ]]; do /bin/sleep 0.01; done
exec "$concurrent_repo/scripts/package-release.sh" "\$version"
EOF
chmod +x "$concurrent_wrapper"
for concurrent_version in v2.0.0 v3.0.0; do
  (
    set +e
    "$concurrent_wrapper" "$concurrent_version" \
      >"$package_tmp/$concurrent_version.out" \
      2>"$package_tmp/$concurrent_version.err"
    printf '%s\n' "$?" >"$package_tmp/$concurrent_version.status"
  ) &
done
for _ in {1..500}; do
  [[ $(find "$concurrent_gate" -name 'ready.*' | wc -l) -eq 2 ]] && break
  /bin/sleep 0.01
done
[[ $(find "$concurrent_gate" -name 'ready.*' | wc -l) -eq 2 ]] ||
  fail 'concurrent release workers did not reach the deterministic barrier'
touch "$concurrent_gate/go"
wait
for concurrent_version in v2.0.0 v3.0.0; do
  [[ $(<"$package_tmp/$concurrent_version.status") == 0 ]] ||
    fail "serialized publication failed for $concurrent_version"
  concurrent_checksum="remotechromemcp-$concurrent_version.tar.gz.sha256"
  (cd "$concurrent_repo/dist" &&
    sha256sum -c "$concurrent_checksum") >/dev/null ||
    fail "concurrent publication lost or damaged $concurrent_version"
done

printf 'PASS: guided VM, GCE, release, and safety contracts\n'

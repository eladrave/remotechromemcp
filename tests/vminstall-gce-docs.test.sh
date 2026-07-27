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
package_repo="$package_tmp/repo"
mkdir -p "$package_repo/scripts"
cp "$packager" "$package_repo/scripts/package-release.sh"
chmod +x "$package_repo/scripts/package-release.sh"
grep -Fq 'mktemp -d "$repo_dir/' "$package_repo/scripts/package-release.sh" ||
  fail 'release staging must be a same-filesystem sibling of dist inside the repository'
grep -Fq '/usr/bin/python3 - "$staged_dist" "$dist_dir"' \
  "$package_repo/scripts/package-release.sh" ||
  fail 'atomic publication must use the trusted system Python interpreter'
git -C "$package_repo" init -q
git -C "$package_repo" config user.name 'Release Contract'
git -C "$package_repo" config user.email release-contract@example.test
printf 'release payload\n' >"$package_repo/payload.txt"
printf 'dist/\n' >"$package_repo/.gitignore"
git -C "$package_repo" add scripts/package-release.sh payload.txt .gitignore
git -C "$package_repo" commit -qm 'release fixture'
git -C "$package_repo" tag -a v1.0.0 -m v1.0.0

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

crash_bin="$package_tmp/crash-bin"
mkdir "$crash_bin"
cat >"$crash_bin/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
/usr/bin/python3 "$@"
if [[ ${FAKE_EXCHANGE_CRASH:-0} == 1 ]]; then
  printf 'exchange completed\n' >"$FAKE_EXCHANGE_MARKER"
  kill -KILL "$PPID"
  exit 137
fi
EOF
chmod +x "$crash_bin/python3"
sed -i \
  's|/usr/bin/python3 - "$staged_dist" "$dist_dir"|'\
"$crash_bin"'/python3 - "$staged_dist" "$dist_dir"|' \
  "$package_repo/scripts/package-release.sh"
git -C "$package_repo" add scripts/package-release.sh
git -C "$package_repo" commit -qm 'inject controlled publication crash'
git -C "$package_repo" tag -fa v1.0.0 -m v1.0.0
rm "$archive" "$checksum"
"$package_repo/scripts/package-release.sh" v1.0.0 >/dev/null
crash_expected_hash=$(sha256sum "$archive" | cut -d' ' -f1)
rm "$archive" "$checksum"
if FAKE_EXCHANGE_CRASH=1 \
  FAKE_EXCHANGE_MARKER="$package_tmp/exchange-marker" \
  "$package_repo/scripts/package-release.sh" v1.0.0 >/dev/null 2>&1; then
  fail 'post-publication SIGKILL fixture unexpectedly reported success'
fi
[[ -f $package_tmp/exchange-marker ]] ||
  fail 'post-publication SIGKILL fixture did not reach the atomic exchange'
[[ -f $archive && -f $checksum ]] ||
  fail 'post-publication SIGKILL left an incomplete first release pair'
[[ $(sha256sum "$archive" | cut -d' ' -f1) == "$crash_expected_hash" ]] ||
  fail 'post-publication SIGKILL changed first-publication archive bytes'
(cd "$package_repo/dist" &&
  sha256sum -c "$(basename "$checksum")") >/dev/null ||
  fail 'post-publication SIGKILL left an invalid first release pair'

printf 'dirty tracked\n' >>"$package_repo/payload.txt"
if "$package_repo/scripts/package-release.sh" v1.0.0 >/dev/null 2>&1; then
  fail 'packager accepted a dirty tracked file'
fi
git -C "$package_repo" checkout -q -- payload.txt
printf 'dirty untracked\n' >"$package_repo/untracked.txt"
if "$package_repo/scripts/package-release.sh" v1.0.0 >/dev/null 2>&1; then
  fail 'packager accepted an untracked file'
fi
rm "$package_repo/untracked.txt"

git -C "$package_repo" tag -d v1.0.0 >/dev/null
if "$package_repo/scripts/package-release.sh" v1.0.0 >/dev/null 2>&1; then
  fail 'packager accepted a missing release tag'
fi
[[ $(sha256sum "$archive" | cut -d' ' -f1) == "$crash_expected_hash" ]] ||
  fail 'failed packaging damaged the prior archive'
(cd "$package_repo/dist" && sha256sum -c "$(basename "$checksum")") >/dev/null ||
  fail 'failed packaging damaged the prior checksum pair'

git -C "$package_repo" tag -a v1.0.0 -m v1.0.0
printf 'later commit\n' >>"$package_repo/payload.txt"
git -C "$package_repo" add payload.txt
git -C "$package_repo" commit -qm 'commit after tag'
if "$package_repo/scripts/package-release.sh" v1.0.0 >/dev/null 2>&1; then
  fail 'packager accepted a tag that does not bind the current commit'
fi

printf 'PASS: guided VM, GCE, release, and safety contracts\n'

#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

test_root="$(mktemp -d /tmp/remote-chrome-vminstall-bootstrap.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
[[ -d "$test_root" && "$test_root" == /tmp/* ]] ||
  fail 'test root must be a real directory beneath /tmp'

dash -n vminstall/install.sh 2>/dev/null ||
  fail 'vminstall/install.sh must parse under dash'

help_output="$(dash vminstall/install.sh --help)"
grep -Fq -- '--version' <<<"$help_output" ||
  fail 'bootstrap help must document --version'
grep -Fq -- '--domain' <<<"$help_output" ||
  fail 'bootstrap must pass installer arguments through'

missing_version_output="$test_root/missing-version.out"
if dash vminstall/install.sh --version >"$missing_version_output" 2>&1; then
  fail 'missing --version value must fail'
fi
grep -Fq 'requires a value' "$missing_version_output" ||
  fail 'missing version failure must be actionable'

archive_source="$test_root/archive-source"
fake_bin="$test_root/fake-bin"
capture_args="$test_root/installer.args"
capture_archive="$test_root/installer.archive"
extraction_marker="$test_root/extracted-installer-ran"
curl_log="$test_root/curl.log"
sha_log="$test_root/sha256sum.log"
archive_file="$test_root/release.tar.gz"
checksum_file="$test_root/release.tar.gz.sha256"
hostile_fixture="$test_root/hostile-fixtures"
mkdir -p "$archive_source/remotechromemcp-fixture/vminstall" "$fake_bin"
mkdir "$hostile_fixture"

cat >"$archive_source/remotechromemcp-fixture/vminstall/installer-main.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${REMOTE_CHROME_CAPTURE_ARGS:?}"
: "${REMOTE_CHROME_CAPTURE_ARCHIVE:?}"
: "${REMOTE_CHROME_EXTRACTION_MARKER:?}"
: "${REMOTE_CHROME_RELEASE_ARCHIVE:?}"
[[ -f "$REMOTE_CHROME_RELEASE_ARCHIVE" ]]
printf '%s\n' "$@" >"$REMOTE_CHROME_CAPTURE_ARGS"
printf '%s\n' "${REMOTE_CHROME_RELEASE_ARCHIVE##*/}" \
  >"$REMOTE_CHROME_CAPTURE_ARCHIVE"
printf 'executed\n' >"$REMOTE_CHROME_EXTRACTION_MARKER"
EOF
chmod +x "$archive_source/remotechromemcp-fixture/vminstall/installer-main.sh"
tar -czf "$archive_file" -C "$archive_source" remotechromemcp-fixture
archive_hash="$(sha256sum "$archive_file" | awk '{print $1}')"
printf '%s  %s\n' \
  "$archive_hash" remotechromemcp-v1.0.0.tar.gz >"$checksum_file"

export BOOTSTRAP_HOSTILE_FIXTURE="$hostile_fixture"
export BOOTSTRAP_ABSOLUTE_ESCAPE="$test_root/bootstrap-absolute-escape"
export REMOTE_CHROME_EXTRACTION_MARKER="$extraction_marker"
python3 <<'PY'
import io
import os
import tarfile

root = os.environ["BOOTSTRAP_HOSTILE_FIXTURE"]

def add_file(archive, name, content=b"fixture\n"):
    info = tarfile.TarInfo(name)
    info.size = len(content)
    info.mode = 0o755 if name.endswith("installer-main.sh") else 0o644
    archive.addfile(info, io.BytesIO(content))

def base_archive(path):
    archive = tarfile.open(path, "w:gz")
    add_file(
        archive,
        "remotechromemcp-fixture/vminstall/installer-main.sh",
        b"#!/usr/bin/env bash\nprintf 'hostile installer ran\\n' >"
        + os.environ["REMOTE_CHROME_EXTRACTION_MARKER"].encode()
        + b"\n",
    )
    return archive

with base_archive(os.path.join(root, "absolute.tar.gz")) as archive:
    add_file(archive, os.environ["BOOTSTRAP_ABSOLUTE_ESCAPE"])

with base_archive(os.path.join(root, "traversal.tar.gz")) as archive:
    add_file(archive, "remotechromemcp-fixture/../../bootstrap-traversal")

with base_archive(os.path.join(root, "symlink-arrow.tar.gz")) as archive:
    info = tarfile.TarInfo("remotechromemcp-fixture/vminstall/escape-link")
    info.type = tarfile.SYMTYPE
    info.linkname = "../../../outside -> harmless"
    archive.addfile(info)

with base_archive(os.path.join(root, "hardlink-arrow.tar.gz")) as archive:
    info = tarfile.TarInfo("remotechromemcp-fixture/vminstall/escape-hardlink")
    info.type = tarfile.LNKTYPE
    info.linkname = "../../outside link to harmless"
    archive.addfile(info)

with base_archive(os.path.join(root, "device.tar.gz")) as archive:
    info = tarfile.TarInfo("remotechromemcp-fixture/vminstall/device")
    info.type = tarfile.CHRTYPE
    info.devmajor = 1
    info.devminor = 3
    archive.addfile(info)

with base_archive(os.path.join(root, "fifo.tar.gz")) as archive:
    info = tarfile.TarInfo("remotechromemcp-fixture/vminstall/fifo")
    info.type = tarfile.FIFOTYPE
    archive.addfile(info)

with base_archive(os.path.join(root, "newline.tar.gz")) as archive:
    add_file(archive, "remotechromemcp-fixture/newline\nmember")

with base_archive(os.path.join(root, "control.tar.gz")) as archive:
    add_file(archive, "remotechromemcp-fixture/control-\x01-member")
PY

cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
set -eu

output=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output)
      output=$2
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url=$1
      shift
      ;;
  esac
done

[ -n "$output" ] && [ -n "$url" ]
printf '%s\n' "$url" >>"$REMOTE_CHROME_CURL_LOG"
case "$url" in
  *.sha256)
    cp "$REMOTE_CHROME_FAKE_CHECKSUM" "$output"
    ;;
  *)
    cp "$REMOTE_CHROME_FAKE_ARCHIVE" "$output"
    ;;
esac
EOF

cat >"$fake_bin/sha256sum" <<'EOF'
#!/bin/sh
set -eu

printf '%s\n' "$*" >>"$REMOTE_CHROME_SHA_LOG"
exec /usr/bin/sha256sum "$@"
EOF
chmod +x "$fake_bin/curl" "$fake_bin/sha256sum"

run_bootstrap() {
  rm -f \
    "$capture_args" "$capture_archive" "$extraction_marker" \
    "$curl_log" "$sha_log"
  env \
    PATH=/usr/bin:/bin \
    REMOTE_CHROME_TEST_ROOT="$test_root" \
    REMOTE_CHROME_FAKE_BIN="$fake_bin" \
    REMOTE_CHROME_FAKE_ARCHIVE="${REMOTE_CHROME_FAKE_ARCHIVE_OVERRIDE:-$archive_file}" \
    REMOTE_CHROME_FAKE_CHECKSUM="${REMOTE_CHROME_FAKE_CHECKSUM_OVERRIDE:-$checksum_file}" \
    REMOTE_CHROME_CURL_LOG="$curl_log" \
    REMOTE_CHROME_SHA_LOG="$sha_log" \
    REMOTE_CHROME_CAPTURE_ARGS="$capture_args" \
    REMOTE_CHROME_CAPTURE_ARCHIVE="$capture_archive" \
    REMOTE_CHROME_EXTRACTION_MARKER="$extraction_marker" \
    dash vminstall/install.sh "$@"
}

literal_metacharacters="\$(touch $test_root/injected); * ? [x] \$HOME \"quoted\""
master_output="$(
  printf 'piped stdin must not become prompt input\n' |
    run_bootstrap \
    --domain 'chrome example.com' \
    --email "$literal_metacharacters"
)"

[[ -f "$extraction_marker" ]] ||
  fail 'bootstrap must extract and invoke the archived Bash installer'
grep -Fxq 'remotechromemcp-master.tar.gz' "$capture_archive" ||
  fail 'bootstrap must hand the downloaded master archive to the installer'
grep -Fiq 'unpinned' <<<"$master_output" ||
  fail 'master installs must be labeled as unpinned'
cat >"$test_root/master-expected.args" <<EOF
--domain
chrome example.com
--email
$literal_metacharacters
EOF
diff -u "$test_root/master-expected.args" "$capture_args" ||
  fail 'bootstrap must preserve spaces and shell metacharacters literally'
[[ ! -e "$test_root/injected" ]] ||
  fail 'bootstrap must never evaluate forwarded installer arguments'
grep -Fqx \
  'https://github.com/eladrave/remotechromemcp/archive/refs/heads/master.tar.gz' \
  "$curl_log" ||
  fail 'master must download the unpinned branch archive URL'
[[ "$(wc -l <"$curl_log")" -eq 1 ]] ||
  fail 'master must perform exactly one download'
[[ ! -e "$sha_log" ]] ||
  fail 'master must be explicitly unpinned and skip checksum verification'

pinned_data_dir="$test_root/data dir; \$(touch $test_root/pinned-injected)"
run_bootstrap \
  --version v1.0.0 \
  --data-dir "$pinned_data_dir" \
  --non-interactive
cat >"$test_root/pinned-expected.args" <<EOF
--version
v1.0.0
--data-dir
$pinned_data_dir
--non-interactive
EOF
diff -u "$test_root/pinned-expected.args" "$capture_args" ||
  fail 'pinned release arguments must be forwarded literally'
grep -Fxq 'remotechromemcp-v1.0.0.tar.gz' "$capture_archive" ||
  fail 'bootstrap must hand the checksummed pinned archive to the installer'
grep -Fqx \
  'https://github.com/eladrave/remotechromemcp/releases/download/v1.0.0/remotechromemcp-v1.0.0.tar.gz' \
  "$curl_log" ||
  fail 'pinned release must download the versioned archive asset'
grep -Fqx \
  'https://github.com/eladrave/remotechromemcp/releases/download/v1.0.0/remotechromemcp-v1.0.0.tar.gz.sha256' \
  "$curl_log" ||
  fail 'pinned release must download the versioned checksum asset'
[[ "$(wc -l <"$curl_log")" -eq 2 ]] ||
  fail 'pinned release must download exactly the archive and checksum'
grep -Fq -- '-c' "$sha_log" ||
  fail 'pinned release must verify its archive with sha256sum -c'
[[ ! -e "$test_root/pinned-injected" ]] ||
  fail 'pinned release forwarding must not evaluate shell syntax'

bad_checksum="$test_root/bad-release.tar.gz.sha256"
printf '%064d  %s\n' 0 remotechromemcp-v1.0.0.tar.gz >"$bad_checksum"
set +e
REMOTE_CHROME_FAKE_CHECKSUM_OVERRIDE="$bad_checksum" \
  run_bootstrap --version v1.0.0 --non-interactive \
    >"$test_root/bad-checksum.stdout" 2>"$test_root/bad-checksum.stderr"
bad_checksum_status=$?
set -e
[[ "$bad_checksum_status" -ne 0 ]] ||
  fail 'pinned release must fail when checksum verification fails'
[[ ! -e "$capture_args" && ! -e "$extraction_marker" ]] ||
  fail 'checksum failure must stop before extraction or installer mutation'

alternate_checksum="$test_root/alternate-release.tar.gz.sha256"
empty_hash="$(printf '' | sha256sum | awk '{print $1}')"
valid_hash="$(sha256sum "$archive_file" | awk '{print $1}')"
for manifest_case in alternate extra malformed; do
  case "$manifest_case" in
    alternate)
      printf '%s  installer.args\n' "$empty_hash" \
        >"$alternate_checksum"
      ;;
    extra)
      {
        printf '%s  remotechromemcp-v1.0.0.tar.gz\n' "$valid_hash"
        printf '%s  installer.args\n' "$empty_hash"
      } >"$alternate_checksum"
      ;;
    malformed)
      printf '%s  remotechromemcp-v1.0.0.tar.gz\n' not-a-sha256 \
        >"$alternate_checksum"
      ;;
  esac
  set +e
  REMOTE_CHROME_FAKE_CHECKSUM_OVERRIDE="$alternate_checksum" \
    run_bootstrap --version v1.0.0 --non-interactive \
      >"$test_root/manifest-$manifest_case.stdout" \
      2>"$test_root/manifest-$manifest_case.stderr"
  manifest_status=$?
  set -e
  [[ $manifest_status -ne 0 ]] ||
    fail "bootstrap must reject a $manifest_case checksum manifest"
  [[ ! -e "$capture_args" && ! -e "$extraction_marker" ]] ||
    fail "$manifest_case checksum manifest must fail before extraction or installer execution"
done

for hostile_case in \
  absolute traversal symlink-arrow hardlink-arrow device fifo newline control; do
  set +e
  REMOTE_CHROME_FAKE_ARCHIVE_OVERRIDE="$hostile_fixture/$hostile_case.tar.gz" \
    run_bootstrap --non-interactive \
      >"$test_root/hostile-$hostile_case.stdout" \
      2>"$test_root/hostile-$hostile_case.stderr"
  hostile_status=$?
  set -e
  [[ $hostile_status -ne 0 ]] ||
    fail "bootstrap must reject a $hostile_case archive before extraction"
  [[ ! -e "$capture_args" && ! -e "$extraction_marker" ]] ||
    fail "$hostile_case archive must fail before installer execution"
  [[ ! -e "$BOOTSTRAP_ABSOLUTE_ESCAPE" &&
     ! -e "$test_root/bootstrap-traversal" ]] ||
    fail "$hostile_case archive must not write outside the extraction root"
done

newline_arg="$(printf 'first line\nsecond line')"
rm -f "$capture_args" "$extraction_marker" "$curl_log" "$sha_log"
set +e
run_bootstrap --domain "$newline_arg" \
  >"$test_root/newline.stdout" 2>"$test_root/newline.stderr"
newline_status=$?
set -e
[[ "$newline_status" -ne 0 ]] ||
  fail 'newline-containing arguments must be rejected'
grep -Fq 'arguments may not contain newlines' "$test_root/newline.stderr" ||
  fail 'newline rejection must explain the argument boundary'
[[ ! -e "$curl_log" && ! -e "$capture_args" ]] ||
  fail 'newline-containing arguments must fail before download or installer mutation'

printf 'PASS: portable bootstrap download, extraction, and argument contracts\n'

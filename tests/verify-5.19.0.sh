#!/bin/bash
# 5.19.0: backups set up and managed from the panel too.
#  - cipi backup configure sets backups up on this server (5.19.1: no "default
#    bucket" — S3 buckets and SFTP servers are destinations on a par, offered
#    right after at a terminal; 5.19.0's --bucket= flags make the S3 one "s3"); the bucket is reached before anything is saved; nothing to
#    ask without a terminal is said, not crashed on;
#  - S3 destinations from the panel: the secret key on standard input only
#    (--secret-stdin), never on a command line; --json never answers it;
#  - a key or a secret with a line break or a space is refused: the default
#    bucket's are written to /root/.aws/credentials;
#  - from the panel the local and temp folders are not set (root chmods them);
#  - cipi backup key show --raw (logged, notified), key rotate;
#  - every change of destinations, settings or key notified (backup_config);
#  - the sudoers for all of it, '*' last;
#  - cipi help backup: destinations in one place, no `backup sftp`;
#  - cipi self-update policy --verify=on: signed releases are not available yet.
# aws, crontab and sftp are stubs; the vault is a folder of files.
# Run from repo root: bash tests/verify-5.19.0.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0; FAIL=0
pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
TMP=$(mktemp -d) && [[ -n "$TMP" && -d "$TMP" ]] || exit 1
trap 'rm -rf "${TMP:?}"' EXIT
echo "=== Cipi 5.19.0 regression checks ==="
lastjson() { awk '/^\{/ {buf=""} {buf = buf $0 "\n"} END {printf "%s", buf}'; }   # the last JSON document of an output

v=$(tr -d "[:space:]" < "${ROOT}/version.md"); [[ "$(printf "%s\n%s\n" 5.19.0 "$v" | sort -V | head -1)" == 5.19.0 ]] && pass "version.md >= 5.19.0" || fail "version.md"
grep -q '^## \[5.19.0\]' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG 5.19.0" || fail "CHANGELOG"
for f in "${ROOT}/cipi" "${LIB}/backup.sh" "${LIB}/self-update.sh" "${LIB}/cipi-api-sudoers.sh" "${LIB}/common.sh"; do
    bash -n "$f" && pass "$(basename "$f") parses" || fail "$(basename "$f") parse"
done

echo "--- backup configure: flags, the bucket reached first"
B="${TMP}/bk"; mkdir -p "$B/bin" "$B/cfg" "$B/log" "$B/aws" "$B/local"
# aws as a stand-in: the bucket "nope" refuses; what it was given is logged (never printed).
cat > "$B/bin/aws" <<'STUB'
#!/bin/bash
echo "key=${AWS_ACCESS_KEY_ID:-} secret=${AWS_SECRET_ACCESS_KEY:-} args=$*" >> "$AWS_LOG"
case "$*" in *s3://nope*) echo "An error occurred (InvalidAccessKeyId): The AWS Access Key Id you provided does not exist" >&2; exit 254 ;; esac
exit 0
STUB
printf '#!/bin/bash\nexit 0\n' > "$B/bin/crontab"
chmod +x "$B/bin/aws" "$B/bin/crontab"
BK() {   # <function and args> — the backup library with a vault of files
    PATH="$B/bin:$PATH" AWS_LOG="$B/aws.log" CIPI_LIB="$LIB" CIPI_CONFIG="$B/cfg" CIPI_LOG="$B/log" CIPI_AWS_DIR="$B/aws" BACKUP_DEFAULT_LOCAL="$B/local" \
    bash -c 'source "$CIPI_LIB/common.sh" 2>/dev/null; RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
        vault_read() { cat "$CIPI_CONFIG/$1" 2>/dev/null; }; vault_write() { local t; t=$(mktemp "$CIPI_CONFIG/.vw.XXXXXX") && cat > "$t" && mv "$t" "$CIPI_CONFIG/$1"; }
        log_action() { echo "$*" >> "$CIPI_LOG/actions.log"; }; hostname() { echo web1; }
        cipi_notify() { echo "NOTIFY $1 [$3]" >> "$CIPI_LOG/notify.log"; }; notify_now() { echo now; }
        source "$CIPI_LIB/backup.sh"; "$@"' _ "$@" 2>&1
}

out=$(BK backup_command configure < /dev/null); [[ "$(jq -c '[.local_dir, .bucket, .profiles.default.destinations]' "$B/cfg/backup.json")" == "[\"$B/local\",\"\",[\"local\"]]" ]] && grep -q 'Backups set up on this server' <<< "$out" && [[ -d "$B/local" ]] \
    && pass "configure without a terminal: backups on this server, the nightly profile kept here — nothing asked" || fail "configure blind: ${out}"
grep -q '\[backup_config\]' "$B/log/notify.log" && pass "…the first setup notified" || fail "first setup notify"
out=$(BK backup_command configure --local-only < /dev/null); [[ "$(jq -r '.local_dir' "$B/cfg/backup.json")" == "$B/local" ]] && grep -q 'Backups set up' <<< "$out" \
    && pass "configure --local-only (5.19.0's): the same" || fail "local only: ${out}"

echo "--- 5.19.0's configure --bucket=…: the S3 destination named s3, like any other"
out=$(printf 'sEcReT/+=xyz\n' | BK backup_command configure --bucket=acme-backups --key=AKIAEXAMPLE --secret-stdin --endpoint=https://fsn1.your-objectstorage.com)
[[ "$(jq -r '[.bucket, .aws_key, .aws_secret, .endpoint_url, .region] | @tsv' "$B/cfg/backup.json")" == $'acme-backups\tAKIAEXAMPLE\tsEcReT/+=xyz\thttps://fsn1.your-objectstorage.com\teu-central-1' ]] \
    && [[ ! -e "$B/aws/credentials" ]] && ! grep -q 'sEcReT' <<< "$out" && grep -q 'key=AKIAEXAMPLE secret=sEcReT/+=xyz args=s3 --region eu-central-1 --endpoint-url https://fsn1.your-objectstorage.com ls s3://acme-backups' "$B/aws.log" \
    && pass "configure --bucket= --secret-stdin: destination add s3 — reached with its keys, then saved; no /root/.aws written; the secret never printed" || fail "configure bucket: ${out} / $(cat "$B/aws.log")"
[[ "$(jq -c '.profiles.default.destinations' "$B/cfg/backup.json")" == '["local"]' ]] && pass "…the profiles as they were" || fail "profile changed"
before=$(cat "$B/cfg/backup.json")
out=$(printf 'other\n' | BK backup_command configure --bucket=nope --key=AKIAEXAMPLE --secret-stdin)
[[ "$(cat "$B/cfg/backup.json")" == "$before" ]] && grep -q 'S3 connection failed — nothing saved' <<< "$out" \
    && pass "a bucket that refuses the keys: nothing saved" || fail "configure refused: ${out}"
out=$(BK backup_command configure --region=eu-west-1 < /dev/null); [[ "$(jq -r '[.bucket, .aws_secret, .region] | @tsv' "$B/cfg/backup.json")" == $'acme-backups\tsEcReT/+=xyz\teu-west-1' ]] \
    && pass "configure --region= alone: the bucket s3 changed, the rest kept, the secret too" || fail "configure partial: ${out}"
out=$(printf 'ab\ncredential_process = /tmp/x\n' | BK backup_command configure --bucket=acme-backups --key=AKIAEXAMPLE --secret-stdin)
[[ "$(jq -r '.aws_secret' "$B/cfg/backup.json")" == ab ]] || fail "stdin secret: more than its first line was taken"
for bad in 'has space' "quo'te" 'tab	here'; do
    out=$(printf '%s\n' "$bad" | BK backup_command configure --bucket=acme-backups --key=AKIAEXAMPLE --secret-stdin)
    grep -q 'Invalid' <<< "$out" || fail "configure took secret ${bad}: ${out}"
done
out=$(BK backup_command configure --bucket=acme-backups $'--key=AK\ncredential_process=/tmp/x' < /dev/null); grep -q 'Invalid access key' <<< "$out" || fail "configure took a key with a line break: ${out}"
[[ "$(jq -r '.aws_secret' "$B/cfg/backup.json")" == ab ]] && pass "a key or a secret with a line break, a space or a quote: refused" || fail "bad creds saved"
out=$(SUDO_USER=www-data BK backup_command configure --bucket=acme-backups --key=AKIAEXAMPLE --secret=plain < /dev/null); grep -q 'From the panel a secret key comes on standard input' <<< "$out" \
    && pass "from the panel a secret on the command line is refused" || fail "www-data --secret=: ${out}"
out=$(SUDO_USER=www-data BK backup_command configure --local-dir=/etc < /dev/null); grep -q "set at the server's shell" <<< "$out" && [[ "$(jq -r '.local_dir' "$B/cfg/backup.json")" == "$B/local" ]] \
    && pass "from the panel the local folder is not set (root makes it 0700: it could be any directory)" || fail "www-data local dir: ${out}"
out=$(BK backup_command configure --local-dir=../etc < /dev/null); grep -q 'Invalid local directory' <<< "$out" && pass "a local folder that is not an absolute path: refused" || fail "local dir rel: ${out}"
out=$(BK backup_command configure --json < /dev/null | lastjson); [[ "$(jq -c '[.configured, .profile_created]' <<< "$out")" == '[true,false]' ]] && pass "configure --json: the answer alone on stdout" || fail "configure json: ${out}"

echo "--- a first setup with a bucket: the nightly profile kept here and sent there"
F="${TMP}/fresh"; mkdir -p "$F/cfg" "$F/log" "$F/local"
BKF() { PATH="$B/bin:$PATH" AWS_LOG="$B/aws.log" CIPI_LIB="$LIB" CIPI_CONFIG="$F/cfg" CIPI_LOG="$F/log" CIPI_AWS_DIR="$F/aws" BACKUP_DEFAULT_LOCAL="$F/local" BACKUP_SFTP_KEY_DIR="$F/keys" \
    bash -c 'source "$CIPI_LIB/common.sh" 2>/dev/null; RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
        vault_read() { cat "$CIPI_CONFIG/$1" 2>/dev/null; }; vault_write() { local t; t=$(mktemp "$CIPI_CONFIG/.vw.XXXXXX") && cat > "$t" && mv "$t" "$CIPI_CONFIG/$1"; }
        log_action() { echo "$*" >> "$CIPI_LOG/actions.log"; }; hostname() { echo web1; }
        cipi_notify() { echo "NOTIFY $1 [$3]" >> "$CIPI_LOG/notify.log"; }; notify_now() { echo now; }
        source "$CIPI_LIB/backup.sh"; "$@"' _ "$@" 2>&1; }
out=$(printf 'k2\n' | BKF backup_command configure --bucket=acme-first --key=AKIAFIRST --secret-stdin)
[[ "$(jq -c '[.bucket, .profiles.default.destinations]' "$F/cfg/backup.json")" == '["acme-first",["local","s3"]]' ]] && pass "configure --bucket= on a new server: the profile 'default' to local and s3" || fail "fresh bucket: ${out}"

echo "--- at a terminal: this server first, then S3 and/or SFTP"
if command -v script >/dev/null 2>&1; then
    I="${TMP}/tty"; mkdir -p "$I/cfg" "$I/log" "$I/local" "$I/bin"
    cp "$B/bin/aws" "$B/bin/crontab" "$I/bin/"
    printf '#!/bin/bash\nf=""; c=x; while [[ $# -gt 0 ]]; do case "$1" in -f) f="$2"; shift ;; -C) c="$2"; shift ;; esac; shift; done\necho P > "$f"; echo "ssh-ed25519 AAAATestKey ${c}" > "${f}.pub"\n' > "$I/bin/ssh-keygen"
    printf '#!/bin/bash\necho "Connection refused" >&2; exit 255\n' > "$I/bin/sftp"; chmod +x "$I/bin/"*
    cat > "$I/run.sh" <<RUN
export PATH="$I/bin:\$PATH" AWS_LOG="$I/aws.log" CIPI_LIB="$LIB" CIPI_CONFIG="$I/cfg" CIPI_LOG="$I/log" BACKUP_DEFAULT_LOCAL="$I/local" BACKUP_SFTP_KEY_DIR="$I/keys"
source "\$CIPI_LIB/common.sh" 2>/dev/null
vault_read() { cat "\$CIPI_CONFIG/\$1" 2>/dev/null; }; vault_write() { local t; t=\$(mktemp "\$CIPI_CONFIG/.vw.XXXXXX") && cat > "\$t" && mv "\$t" "\$CIPI_CONFIG/\$1"; }
log_action() { :; }; cipi_notify() { :; }; notify_now() { echo now; }
source "\$CIPI_LIB/backup.sh"; backup_command configure
RUN
    # local dir, temp dir; s3: name, bucket, key, secret, region, endpoint, send default there;
    # sftp: name, host, port, user, folder, send default there, no test; then no more.
    printf '\n\n2\n\nacme-tty\nAKIATTY\nsEcReTtTy\n\n\ny\n3\n\nbox.example.com\n23\nbackup\ncipi\ny\nn\n1\n' | script -qc "bash $I/run.sh" /dev/null > "$I/out" 2>&1
    [[ "$(jq -c '[.bucket, .sftp_destinations.sftp.host, .sftp_destinations.sftp.port, .profiles.default.destinations]' "$I/cfg/backup.json" 2>/dev/null)" == '["acme-tty","box.example.com",23,["local","s3","sftp"]]' ]] \
        && grep -q 'Send the backups somewhere else too' "$I/out" \
        && pass "configure at a terminal: this server, then an S3 bucket and an SFTP server, the nightly profile sent to both" || fail "configure tty: $(sed 's/\x1b\[[0-9;]*m//g' "$I/out" | tail -30) / $(cat "$I/cfg/backup.json" 2>/dev/null)"
else
    pass "configure at a terminal: skipped (no script(1))"
fi
grep -A6 '^_bk_read_secret()' "${LIB}/backup.sh" | grep -q 'read -rs input' && grep -q '_bk_read_secret "Secret Access Key" s' "${LIB}/backup.sh" && pass "the secret is read without being shown" || fail "secret read"

echo "--- S3 buckets and SFTP servers on a par"
out=$(printf 'dEsTsEcReT\n' | SUDO_USER=www-data BK _bk_destination_command add offsite --bucket=acme-offsite --key=AKIAOTHER --region=eu-central-1 --endpoint=https://s3.eu-central-003.backblazeb2.com --secret-stdin --json)
[[ "$(jq -c . <<< "$out" 2>/dev/null)" == '{"name":"offsite","type":"s3","bucket":"acme-offsite","region":"eu-central-1","endpoint":"https://s3.eu-central-003.backblazeb2.com"}' ]] \
    && [[ "$(jq -r '.s3_destinations.offsite.aws_secret' "$B/cfg/backup.json")" == dEsTsEcReT ]] && ! grep -q 'dEsTsEcReT\|AKIAOTHER' <<< "$out" \
    && pass "destination add --secret-stdin --json from the panel: tested, saved; the answer has neither the secret nor the key" || fail "s3 add: ${out}"
out=$(printf 'nEw\n' | SUDO_USER=www-data BK _bk_destination_command edit offsite --secret-stdin --json); [[ "$(jq -r '.s3_destinations.offsite.aws_secret' "$B/cfg/backup.json")" == nEw ]] && [[ "$(jq -r '.bucket' <<< "$out")" == acme-offsite ]] \
    && pass "destination edit --secret-stdin: a new secret, the rest kept" || fail "s3 edit secret: ${out}"
out=$(SUDO_USER=www-data BK _bk_destination_command edit offsite --region=us-east-1 --json < /dev/null); [[ "$(jq -r '[.s3_destinations.offsite.aws_secret, .s3_destinations.offsite.region] | @tsv' "$B/cfg/backup.json")" == $'nEw\tus-east-1' ]] \
    && pass "destination edit without a secret: the secret kept" || fail "s3 edit keep: ${out}"
out=$(SUDO_USER=www-data BK _bk_destination_command add leak --bucket=x1 --key=k --secret=s < /dev/null); grep -q 'From the panel a secret key comes on standard input' <<< "$out" && ! jq -e '.s3_destinations.leak' "$B/cfg/backup.json" >/dev/null \
    && pass "destination add --secret= from the panel: refused, nothing saved" || fail "s3 add www-data inline: ${out}"
out=$(printf '\n' | BK _bk_destination_command add empty --bucket=x1 --key=k --secret-stdin < /dev/null); grep -q 'empty secret\|nothing on standard input' <<< "$out" && ! jq -e '.s3_destinations.empty' "$B/cfg/backup.json" >/dev/null \
    && pass "--secret-stdin with nothing to read: refused" || fail "stdin empty: ${out}"
out=$(BK _bk_destination_command add shellmade --bucket=acme-shell --key=AKIASHELL --secret=fromshell --json < /dev/null); [[ "$(jq -r '.s3_destinations.shellmade.aws_secret' "$B/cfg/backup.json")" == fromshell ]] \
    && pass "at the server's shell --secret= still works" || fail "shell secret: ${out}"
out=$(SUDO_USER=www-data BK _bk_destination_command remove shellmade < /dev/null); ! jq -e '.s3_destinations.shellmade' "$B/cfg/backup.json" >/dev/null && pass "the panel removes an S3 destination no profile uses" || fail "remove s3: ${out}"
out=$(SUDO_USER=www-data BK _bk_destination_command edit s3 --region=eu-south-1 --json < /dev/null); [[ "$(jq -r '[.bucket, .region, .aws_secret] | @tsv' "$B/cfg/backup.json")" == $'acme-backups\teu-south-1\tab' ]] \
    && pass "destination edit s3: the bucket named s3 is edited like any other" || fail "edit s3: ${out}"
out=$(SUDO_USER=www-data BK _bk_destination_command remove s3 < /dev/null); [[ "$(jq -r '.bucket' "$B/cfg/backup.json")" == "" ]] && jq -e '.profiles.default' "$B/cfg/backup.json" >/dev/null \
    && pass "destination remove s3 (no profile uses it): gone, like any other" || fail "remove s3: ${out}"
out=$(printf 'sTwO\n' | SUDO_USER=www-data BK _bk_destination_command add s3 --bucket=acme-again --key=AKIATWO --secret-stdin --use=default --json)
[[ "$(jq -c '[.bucket, .aws_secret, .profiles.default.destinations]' "$B/cfg/backup.json")" == '["acme-again","sTwO",["local","s3"]]' && "$(jq -r '.name' <<< "$out")" == s3 ]] \
    && pass "destination add s3 --use=default: an S3 bucket named s3, the profile sent there too" || fail "add s3: ${out}"
out=$(SUDO_USER=www-data BK _bk_destination_command remove s3 < /dev/null); grep -q 'still used by: default' <<< "$out" && pass "…and a destination a profile uses is not removed, s3 like the others" || fail "remove used s3: ${out}"
cat > "$B/bin/ssh-keygen" <<'STUB'
#!/bin/bash
f=""; c=x; while [[ $# -gt 0 ]]; do case "$1" in -f) f="$2"; shift ;; -C) c="$2"; shift ;; esac; shift; done
echo "PRIVATE" > "$f"; echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey ${c}" > "${f}.pub"
STUB
chmod +x "$B/bin/ssh-keygen"
out=$(SUDO_USER=www-data BACKUP_SFTP_KEY_DIR="$B/keys" BK _bk_destination_command add box --type=sftp --host=u1.your-storagebox.de --port=23 --user=u1 --path=cipi --use=default,nope --json < /dev/null | lastjson)
[[ "$(jq -c '.profiles.default.destinations' "$B/cfg/backup.json")" == '["local","s3","box"]' && "$(jq -r '.public_key' <<< "$out" 2>/dev/null)" == ssh-ed25519* ]] \
    && pass "destination add --type=sftp --use=default: the SFTP server, the profile sent there too (a profile that does not exist is said, not made)" || fail "sftp use: ${out}"
out=$(BK _bk_destination_command add s3x --type=sftp --host=h --user=u < /dev/null); out2=$(BK _bk_destination_command edit s3 --type=sftp --host=h --user=u < /dev/null)
grep -q "'s3' is kept for an S3 bucket" <<< "$out2" && pass "an SFTP server is not called s3" || fail "sftp s3 name: ${out2}"
st=$(BK _bk_status_json 2>/dev/null | lastjson || true)
[[ -z "$st" ]] || { jq -e '[.destinations[] | select(.name == "s3") | .default] == [false]' <<< "$st" >/dev/null && pass "status: no destination is 'the default'" || fail "status default: ${st}"; }
! grep -q 'default bucket' "${LIB}/backup.sh" <(sed -n '/backup|backups|s3)/,/^            ;;/p' "${ROOT}/cipi") && pass "no 'default bucket' left in the backups library and its help" || fail "default bucket mention: $(grep -n 'default bucket' "${LIB}/backup.sh" | head -3)"

echo "--- the encryption key"
out=$(BK _bk_key_command show --raw); [[ "$out" == "$(cat "$B/cfg/.backup_key" 2>/dev/null)" && -n "$out" ]] && grep -q 'NOTIFY Backup encryption key shown on web1 \[credentials_show\]' "$B/log/notify.log" \
    && grep -q 'BACKUP KEY SHOWN (root)' "$B/log/actions.log" \
    && pass "key show --raw: the key and nothing else — logged and notified" || fail "key raw: ${out} / $(ls -a "$B/cfg")"
old=$(cat "$B/cfg/.backup_key"); out=$(SUDO_USER=www-data BK _bk_key_command rotate < /dev/null); [[ "$(cat "$B/cfg/.backup_key")" != "$old" ]] && ls "$B/cfg"/.backup_key.* >/dev/null 2>&1 \
    && pass "key rotate from the panel: a new key, the old one kept for the old runs" || fail "rotate: ${out}"
SUDO_USER=www-data BK _bk_key_command show --raw >/dev/null; grep -q 'BACKUP KEY SHOWN (the panel)' "$B/log/actions.log" && pass "…shown from the panel: the log says so" || fail "key show by panel"

echo "--- the owner hears of every change of where archives go"
N="$B/log/notify.log"
grep -q 'NOTIFY Backup settings changed on web1 \[backup_config\]' "$N" && [[ "$(grep -c '\[backup_config\]' "$N")" -ge 6 ]] \
    && pass "configure, destination add|edit|remove, key rotate: notified (backup_config)" || fail "backup_config notifications: $(cat "$N")"
grep -q '^backup_config|Security|' "${LIB}/notifications.sh" && pass "backup_config is a Security trigger" || fail "backup_config trigger"
! grep -q 'dEsTsEcReT\|sEcReT\|nEw$\|sTwO' "$N" && pass "…never with a secret in it" || fail "a notification carries a secret"

echo "--- the panel's sudoers"
S="${TMP}/sudoers"
sed -n '/^www-data ALL/,/^SUDOEOF/p' "${LIB}/cipi-api-sudoers.sh" | sed '$d' > "$S"
for rule in 'backup configure \*' 'backup destination add \*' 'backup destination edit \*' 'backup destination remove \*' 'backup key show --raw' 'backup key rotate' 'backup prune' 'backup prune \*' 'backup sftp \*'; do
    grep -qE "/usr/local/bin/cipi ${rule}, \\\\\$" "$S" || fail "sudoers: missing 'cipi ${rule//\\/}'"
done
pass "configure, destination add|edit|remove, key show --raw and rotate, prune — the panel's"
for no in 'backup fetch' 'backup key show,' 'backup key \*' 'backup \*'; do
    grep -qE "/usr/local/bin/cipi ${no}" "$S" && fail "sudoers: '${no//\\/}' must not be there"
done
pass "not there: fetch, key show without --raw, any backup command"
! grep -E '\* [^,\\]' "$S" | grep -q . && pass "'*' is the last argument everywhere (sudo-rs)" || fail "a rule has something after '*'"

echo "--- cipi help backup"
n1=$(grep -n "backup|backups|s3)" "${ROOT}/cipi" | head -1 | cut -d: -f1)
n2=$(awk -v s="$n1" 'NR>s && /^            ;;/ {print NR; exit}' "${ROOT}/cipi")
H=$(sed -n "${n1},${n2}p" "${ROOT}/cipi")
! grep -q 'cipi backup sftp' <<< "$H" && grep -q '"cipi backup destination add <name>"    "Add one — an S3 bucket or an SFTP server, flags below"' <<< "$H" && grep -q 'An S3 bucket (AWS' <<< "$H" && grep -q 'An SFTP server (a VPS' <<< "$H" \
    && grep -q 'Set up backups on this server' <<< "$H" && grep -q -- '--use=PROFILE' <<< "$H" && ! grep -qi 'default bucket' <<< "$H" \
    && pass "help: backups on this server first; S3 buckets and SFTP servers on a par, one list of commands; no default bucket" || fail "help backup"

echo "--- self-update: signed releases are not available yet"
SU="${TMP}/su"; mkdir -p "$SU/cfg" "$SU/log" "$SU/opt"
printf '# Cipi release signers\n# none yet\n' > "$SU/opt/release-signers"
SUH() {
    CIPI_LIB="$LIB" CIPI_CONFIG="$SU/cfg" CIPI_LOG="$SU/log" CIPI_SHIPPED_SIGNERS="$SU/opt/release-signers" CIPI_SELFUPDATE_DELAY_CRON="$SU/cron" CIPI_VERSION=5.19.0 \
    bash -c 'source "$CIPI_LIB/common.sh" 2>/dev/null; RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
        vault_read() { cat "$CIPI_CONFIG/$1" 2>/dev/null; }; vault_write() { local t; t=$(mktemp "$CIPI_CONFIG/.vw.XXXXXX") && cat > "$t" && mv "$t" "$CIPI_CONFIG/$1"; }
        log_action() { :; }; cipi_notify() { :; }
        source "$CIPI_LIB/self-update.sh"; "$@"' _ "$@" 2>&1
}
out=$(SUH selfupdate_policy --verify=on --fingerprint=SHA256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa < /dev/null); rc=$?
grep -q 'Signed releases are not available yet' <<< "$out" && grep -q 'cipi self-update policy --delay=12h' <<< "$out" && [[ ! -e "$SU/cfg/selfupdate.json" ]] \
    && pass "--verify=on: signed releases are not available yet — said, with the delay to use; nothing changed" || fail "verify not available: rc=${rc} ${out}"
out=$(SUH selfupdate_policy --json); [[ "$(jq -c '[.signed_releases, .verify]' <<< "$out")" == '[false,false]' ]] && pass "policy --json: signed_releases false (what the panel reads)" || fail "json signed_releases: ${out}"
out=$(SUH selfupdate_policy); grep -q 'signed releases are not available yet' <<< "$out" && pass "policy: the status says it too" || fail "policy text: ${out}"
printf 'releases@cipi.sh namespaces="git" ssh-ed25519 AAAAkeyOne\n' > "$SU/opt/release-signers"
out=$(SUH selfupdate_policy --json); [[ "$(jq -r '.signed_releases' <<< "$out")" == true ]] && pass "…true as soon as a release ships a signer" || fail "json signed_releases true: ${out}"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]

#!/bin/bash
# 5.19.2: the .env as it is.
#  - a value followed by blanks or a comment is read without them: "x"   was
#    read as "x" with its quotes (and ses   with its blanks), so the panel
#    showed them and saved them inside new quotes — "\"x\"   ";
#  - cipi app env <app> --raw: the file as it is (comments, blank lines,
#    spaces); --raw --json: {app, text};
#  - cipi app env <app> --stdin: the whole file from standard input, written
#    byte for byte — nothing parsed, quoted, trimmed or moved. Nothing, more
#    than 64 KB or a NUL byte: refused, the file as it was;
#  - the panel's sudoers already allow `app env *`.
# The app's home is a folder under $TMP; app_as runs the command as it is
# (as the app user on a server: tested there by hand).
# Run from repo root: bash tests/verify-5.19.2.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0; FAIL=0
pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
TMP=$(mktemp -d) && [[ -n "$TMP" && -d "$TMP" ]] || exit 1
trap 'rm -rf "${TMP:?}"' EXIT
echo "=== Cipi 5.19.2 regression checks ==="

v=$(tr -d "[:space:]" < "${ROOT}/version.md"); [[ "$(printf "%s\n%s\n" 5.19.2 "$v" | sort -V | head -1)" == 5.19.2 ]] && pass "version.md >= 5.19.2" || fail "version.md"
grep -q '^## \[5.19.2\]' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG 5.19.2" || fail "CHANGELOG"
for f in "${ROOT}/cipi" "${LIB}/app.sh" "${LIB}/common.sh"; do
    bash -n "$f" && pass "$(basename "$f") parses" || fail "$(basename "$f") parse"
done

fn() { sed -n "/^${2}() {/,/^}/p" "${LIB}/${1}"; }
H="${TMP}/home"; mkdir -p "${H}/shop/shared"
E="${H}/shop/shared/.env"
cat > "${TMP}/run.sh" <<RUN
set -euo pipefail
RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
error()   { echo "[ERROR] \$*" >&2; }
success() { echo "ok: \$*"; }
log_action() { echo "\$*" >> "${TMP}/actions.log"; }
app_exists() { [[ "\$1" == shop ]]; }
app_get() { case "\$2" in custom) echo false ;; runtime) echo php ;; esac; }
app_as() { local app="\$1"; shift; ( cd / && "\$@" ); }
_app_own_check() { :; }
$(for f in app_sh app_of_path _app_file_op app_read app_write; do fn common.sh "$f"; done)
$(for f in _env_valid_key _env_escape_value _env_value _env_read_key _env_to_json _env_set_key _env_unset_key _env_line_key _env_reorder _app_env_write_raw app_env; do fn app.sh "$f"; done | sed "s#/home/#${H}/#g")
"\$@"
RUN
run() { bash "${TMP}/run.sh" "$@"; }

echo "--- values followed by blanks or a comment"
printf '%s\n' \
    'APP_NAME=SportGrid' '' '# Mail' \
    'MAIL_MAILER=ses   ' \
    'MAIL_FROM_ADDRESS="noreply@sportgrid.it"   ' \
    'MAIL_FROM_NAME="${APP_NAME}"' \
    'AWS_SES_REGION=eu-north-1   # Stockholm' \
    'Q="a \"b\" c\\d" # quoted' \
    "S='p#ss \"x\"'   # single" \
    'EMPTY=' 'EMPTYQ=""   ' 'C= # only a comment' 'H=abc#def' \
    'export E2 = "spaced"  ' > "$E"
j=$(run _env_to_json "$E" 2>&1)
[[ "$(jq -r '[.MAIL_MAILER, .MAIL_FROM_ADDRESS, .AWS_SES_REGION] | join("|")' <<< "$j")" == 'ses|noreply@sportgrid.it|eu-north-1' ]] \
    && pass "\"x\"   is x, ses   is ses, a bare value ends at a blank and #" || fail "trailing: ${j}"
[[ "$(jq -r '.MAIL_FROM_NAME' <<< "$j")" == '${APP_NAME}' ]] && pass "\${APP_NAME} read as it is written" || fail "interpolation: ${j}"
[[ "$(jq -r '.Q' <<< "$j")" == 'a "b" c\d' && "$(jq -r '.S' <<< "$j")" == 'p#ss "x"' ]] \
    && pass "double quotes take \\\" and \\\\ back, single quotes keep # and \" — the comment after them dropped" || fail "quotes: ${j}"
[[ "$(jq -c '[.EMPTY, .EMPTYQ, .C, .H, .E2]' <<< "$j")" == '["","","","abc#def","spaced"]' ]] \
    && pass "empty, \"\" with blanks, only a comment, a # inside a word, export with spaces" || fail "edges: ${j}"
[[ "$(run _env_read_key "$E" MAIL_FROM_ADDRESS)" == 'noreply@sportgrid.it' && "$(run _env_read_key "$E" MAIL_MAILER)" == 'ses' ]] \
    && pass "_env_read_key (--get) reads them the same way" || fail "read_key"

echo "--- read, then written by --set: no quotes pile up"
for k in MAIL_MAILER MAIL_FROM_ADDRESS MAIL_FROM_NAME Q S; do
    val=$(run _env_read_key "$E" "$k"); run _env_set_key "$E" "$k" "$val"
    [[ "$(run _env_read_key "$E" "$k")" == "$val" ]] || fail "${k}: ${val} came back as $(run _env_read_key "$E" "$k")"
done
grep -qx 'MAIL_MAILER=ses' "$E" && grep -qx 'MAIL_FROM_ADDRESS=noreply@sportgrid.it' "$E" && ! grep -q '\\"noreply' "$E" \
    && pass "MAIL_MAILER=ses, MAIL_FROM_ADDRESS=noreply@sportgrid.it — not \"ses   \", not \"\\\"noreply…\\\"   \"" || fail "set: $(cat "$E")"

echo "--- cipi app env --raw"
printf 'APP_NAME=SportGrid\n\n# Mail\nMAIL_MAILER=ses      # aligned\r\nMAIL_FROM_NAME="${APP_NAME}"\n\n\nLAST=1' > "${TMP}/orig.env"
cp "${TMP}/orig.env" "$E"; chmod 640 "$E"
run app_env shop --raw > "${TMP}/raw.out" 2>&1
cmp -s "${TMP}/raw.out" "${TMP}/orig.env" && pass "--raw: byte for byte — comments, blank lines, spaces, a CR, no newline at the end" || fail "raw: $(od -c "${TMP}/raw.out" | head -5)"
run app_env shop --raw --json > "${TMP}/raw.json" 2>&1
[[ "$(jq -r .app "${TMP}/raw.json")" == shop ]] && jq -j .text "${TMP}/raw.json" | cmp -s - "${TMP}/orig.env" \
    && pass "--raw --json: {app, text}, the text the file" || fail "raw json: $(cat "${TMP}/raw.json")"
printf 'A=1\n\n\n' > "$E"
[[ "$(run app_env shop --raw | od -An -c | tr -d ' \n')" == 'A=1\n\n\n' ]] && pass "…the newlines at the end too" || fail "raw tail newlines"

echo "--- cipi app env --stdin"
printf 'OLD=1\n' > "$E"; chmod 600 "$E"; ino=$(ls -i "$E" | awk '{print $1}'); : > "${TMP}/actions.log"
out=$(run app_env shop --stdin < "${TMP}/orig.env" 2>&1); r=$?
[[ $r -eq 0 ]] && cmp -s "$E" "${TMP}/orig.env" && grep -q 'updated' <<< "$out" \
    && pass "--stdin: the file is what was given, byte for byte" || fail "stdin: r=${r} ${out} / $(od -c "$E" | head -3)"
[[ "$(stat -c '%a' "$E" 2>/dev/null || stat -f '%Lp' "$E")" == 640 && "$(ls -i "$E" | awk '{print $1}')" == "$ino" ]] \
    && pass "…640, in place (the same inode)" || fail "mode/inode"
grep -qx 'ENV UPDATED: shop (whole file)' "${TMP}/actions.log" && pass "…logged" || fail "log: $(cat "${TMP}/actions.log")"
printf 'A="x y"   \n' | run app_env shop --stdin --json > "${TMP}/w.json" 2>&1
[[ "$(jq -r .text "${TMP}/w.json")" == 'A="x y"   ' ]] && pass "--stdin --json: the text written, blanks after the quote kept" || fail "stdin json: $(cat "${TMP}/w.json")"

cp "${TMP}/orig.env" "$E"
out=$(run app_env shop --stdin < /dev/null 2>&1); r=$?
[[ $r -ne 0 ]] && grep -q 'Nothing on standard input' <<< "$out" && cmp -s "$E" "${TMP}/orig.env" && pass "nothing on stdin: refused, the file as it was" || fail "empty: ${out}"
out=$(head -c 70000 /dev/zero | tr '\0' a | run app_env shop --stdin 2>&1); r=$?
[[ $r -ne 0 ]] && grep -q 'too long' <<< "$out" && cmp -s "$E" "${TMP}/orig.env" && pass "more than 64 KB: refused" || fail "big: ${out}"
out=$(head -c 65536 /dev/zero | tr '\0' a | run app_env shop --stdin 2>&1); r=$?
[[ $r -eq 0 && "$(wc -c < "$E" | tr -d ' ')" == 65536 ]] && pass "64 KB exactly: written" || fail "64k: ${out}"
cp "${TMP}/orig.env" "$E"
out=$(printf 'A=1\0B=2\n' | run app_env shop --stdin 2>&1); r=$?
[[ $r -ne 0 ]] && grep -q 'NUL' <<< "$out" && cmp -s "$E" "${TMP}/orig.env" && pass "a NUL byte: refused" || fail "nul: ${out}"
for extra in --show --get=A --set=A=1 --unset=A --order=A; do
    out=$(run app_env shop --stdin "$extra" < "${TMP}/orig.env" 2>&1) && fail "--stdin ${extra} accepted"
done
for extra in --set=A=1 --order=A; do
    out=$(run app_env shop --raw "$extra" 2>&1) && fail "--raw ${extra} accepted"
done
cmp -s "$E" "${TMP}/orig.env" && pass "--raw/--stdin with --show, --get, --set, --unset or --order: refused" || fail "combined"

echo "--- the rest"
for f in _env_read_key _env_to_json _env_apply_group; do
    fn app.sh "$f" | sed -n 2p | grep -q 'app_call "\$_o" "[^"]*_env_value' || fail "${f} does not take _env_value to the app user"
done
[[ "$FAIL" -eq 0 ]] && pass "the functions that read a value take _env_value with them (app_call)"
grep -q 'cipi app env <app> --raw' "${ROOT}/cipi" && grep -q 'cipi app env <app> --stdin' "${ROOT}/cipi" && pass "cipi help app: --raw and --stdin" || fail "help"
grep -q '/usr/local/bin/cipi app env \*' "${LIB}/cipi-api-sudoers.sh" && pass "the panel's sudoers: app env * (--raw, --stdin included)" || fail "sudoers"

echo
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]

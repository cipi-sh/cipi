#!/bin/bash
# 5.14.0: the panel's Firewall tab.
#  - `cipi firewall status --json`: UFW rules read from ufw's own files
#    (an IPv4 rule and its IPv6 twin are one), fail2ban (threshold, jails,
#    bans) and CrowdSec (engine, bouncer, allowlist, decisions, what would
#    stop an enable) in one read;
#  - `firewall remove`, `block`, `unblock`; `allow --proto`; `deny --from`,
#    ahead of every allow; the SSH port, 80 and 443 never closed to everyone
#    or removed, a block never taking in this SSH session, a Zero Trust lock
#    never undone — --force gets past them at the shell, never from the panel;
#  - `ban unban` matches the whole address and takes nothing but one;
#  - `crowdsec enable` from the panel: checks hold, --allow allowlists it;
#  - the panel's sudoers, and compliance reading the GUI's 2FA policy;
#  - `cipi package`: the wider catalog (browsershot, fonts-cjk, avif, pdftk,
#    libreoffice, pandoc, tesseract), install and remove from the panel, and a
#    removal that takes nothing another package needs. apt, dpkg and apt-mark
#    are one Python model of installed packages, marks and dependencies.
# ufw, fail2ban-client, cscli, systemctl and sshd are stubs: ufw keeps its
# "### tuple ###" lines the way ufw 0.36 writes them.
# Run from repo root: bash tests/verify-5.14.0.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0; FAIL=0
pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
TMP=$(mktemp -d) && [[ -n "$TMP" && -d "$TMP" ]] || exit 1
trap 'rm -rf "${TMP:?}"' EXIT
echo "=== Cipi 5.14.0 regression checks ==="

v=$(tr -d "[:space:]" < "${ROOT}/version.md"); [[ "$(printf "%s\n%s\n" 5.14.0 "$v" | sort -V | head -1)" == 5.14.0 ]] && pass "version.md >= 5.14.0" || fail "version.md"
grep -q '^## \[5.14.0\]' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG 5.14.0" || fail "CHANGELOG"
for f in "${ROOT}/cipi" "${LIB}/firewall.sh" "${LIB}/ban.sh" "${LIB}/crowdsec.sh" "${LIB}/cipi-api-sudoers.sh" "${LIB}/compliance.sh" "${LIB}/completion.sh"; do
    bash -n "$f" && pass "$(basename "$f") parses" || fail "$(basename "$f") parse"
done
command -v python3 >/dev/null 2>&1 || { echo "  (python3 not installed: the ufw stub cannot run)"; echo "=== ${PASS} passed, ${FAIL} failed ==="; [[ $FAIL -eq 0 ]]; exit; }
command -v jq >/dev/null 2>&1 || { echo "  (jq not installed)"; exit 1; }

# ── stubs ────────────────────────────────────────────────────
B="${TMP}/bin"; U="${TMP}/ufw"; mkdir -p "$B" "$U"
cat > "${B}/ufw" <<'STUB'
#!/usr/bin/env python3
# ufw 0.36 as far as Cipi uses it: rules kept as "### tuple ###" lines.
import os, sys, binascii
d = os.environ["FIREWALL_UFW_DIR"]
with open(os.path.join(d, "calls.log"), "a") as fh:
    fh.write(" ".join(sys.argv[1:]) + "\n")
args = [a for a in sys.argv[1:] if a not in ("--force", "--dry-run")]
def load(fam):
    p = os.path.join(d, "user.rules" if fam == 4 else "user6.rules")
    return [l.rstrip("\n") for l in open(p)] if os.path.exists(p) else []
def save(fam, rules):
    p = os.path.join(d, "user.rules" if fam == 4 else "user6.rules")
    with open(p, "w") as fh:
        fh.write("*filter\n### RULES ###\n")
        for r in rules:
            fh.write(r + "\n-A ufw-user-input -j ACCEPT\n\n")
        fh.write("### END RULES ###\nCOMMIT\n")
def tuples(fam): return [l for l in load(fam) if l.startswith("### tuple ### ")]
def parse(action, spec):
    comment = ""
    if "comment" in spec:
        i = spec.index("comment"); comment = spec[i + 1]; spec = spec[:i]
    src, port, proto = "any", "any", "any"
    if spec and spec[0] == "from":
        src = spec[1]; rest = spec[2:]
        if rest[:2] == ["to", "any"]: rest = rest[2:]
        if rest[:1] == ["port"]: port = rest[1]; rest = rest[2:]
        if rest[:1] == ["proto"]: proto = rest[1]
    else:
        if "/" in spec[0]: port, proto = spec[0].split("/")
        else: port = spec[0]
    if ":" in port and proto == "any":
        print("ERROR: Must specify 'tcp' or 'udp' with multiple ports"); sys.exit(1)
    fams = [6] if ":" in src.split("/")[0] else ([4] if "." in src else [4, 6])
    out = {}
    for fam in fams:
        anyaddr = "0.0.0.0/0" if fam == 4 else "::/0"
        t = "### tuple ### %s %s %s %s any %s in" % (action, proto, port, anyaddr, src if src != "any" else anyaddr)
        if comment: t += " comment=" + binascii.hexlify(comment.encode()).decode()
        out[fam] = t
    return out
def strip_comment(t): return t.split(" comment=")[0]
cmd = args[0] if args else ""
if cmd == "status":
    print("Status: active")
    if len(args) > 1 and args[1] == "verbose":
        print("Logging: on (low)\nDefault: deny (incoming), allow (outgoing), disabled (routed)\nNew profiles: skip")
    sys.exit(0)
if cmd in ("allow", "deny"):
    for fam, t in sorted(parse(cmd, args[1:]).items()):
        rs = tuples(fam); sfx = " (v6)" if fam == 6 else ""
        if any(strip_comment(r) == strip_comment(t) for r in rs): print("Skipping adding existing rule" + sfx); continue
        save(fam, rs + [t]); print("Rule added" + sfx)
    sys.exit(0)
if cmd in ("prepend", "insert"):
    if cmd == "prepend" and os.environ.get("UFW_NO_PREPEND"):
        print("ERROR: Invalid syntax"); sys.exit(1)
    spec = args[1:] if cmd == "prepend" else args[2:]
    for fam, t in sorted(parse(spec[0], spec[1:]).items()):
        rs = tuples(fam); sfx = " (v6)" if fam == 6 else ""
        if any(strip_comment(r) == strip_comment(t) for r in rs): print("Skipping inserting existing rule" + sfx); continue
        save(fam, [t] + rs); print("Rule inserted" + sfx)
    sys.exit(0)
if cmd == "delete":
    for fam, t in sorted(parse(args[1], args[2:]).items()):
        rs = tuples(fam); sfx = " (v6)" if fam == 6 else ""
        keep = [r for r in rs if strip_comment(r) != strip_comment(t)]
        if len(keep) == len(rs): print("Could not delete non-existent rule" + sfx); continue
        save(fam, keep); print("Rule deleted" + sfx)
    sys.exit(0)
print("ERROR: unknown " + cmd); sys.exit(1)
STUB
cat > "${B}/fail2ban-client" <<'STUB'
#!/bin/bash
echo "$*" >> "${FIREWALL_UFW_DIR}/f2b.log"
case "$*" in
    "status")        printf 'Status\n|- Number of jail:\t2\n`- Jail list:\trecidive, sshd\n' ;;
    "status sshd")   printf 'Status for the jail: sshd\n|- Filter\n|  |- Currently failed:\t2\n|  |- Total failed:\t40\n|  `- File list:\t/var/log/auth.log\n`- Actions\n   |- Currently banned:\t2\n   |- Total banned:\t9\n   `- Banned IP list:\t11.2.3.45 198.51.100.20\n' ;;
    "status recidive") printf 'Status for the jail: recidive\n|- Filter\n|  |- Currently failed:\t0\n`- Actions\n   |- Currently banned:\t0\n   |- Total banned:\t1\n   `- Banned IP list:\t\n' ;;
    "get sshd maxretry") echo 3 ;;
    "get sshd findtime") echo 3600 ;;
    "get sshd bantime")  echo 86400 ;;
    *) : ;;
esac
STUB
cat > "${B}/systemctl" <<'STUB'
#!/bin/bash
case "$*" in
    *is-active*fail2ban*) exit 0 ;;
    *is-active*crowdsec-firewall-bouncer*) [[ -n "${CS:-}" ]] && exit 0; exit 3 ;;
    *is-active*cipi-crowdsec-rescue*) exit 3 ;;
    *is-active*crowdsec*) [[ -n "${CS:-}" ]] && exit 0; exit 3 ;;
    "cat crowdsec.service"|"cat crowdsec-firewall-bouncer.service") [[ -n "${CS:-}" ]] && exit 0; exit 1 ;;
    *) exit 1 ;;
esac
STUB
cat > "${B}/cscli" <<'STUB'
#!/bin/bash
echo "$*" >> "${FIREWALL_UFW_DIR}/cscli.log"
case "$*" in
    "decisions list -o json") echo '[{"decisions":[{"value":"203.0.113.66","scope":"Ip","type":"ban","scenario":"crowdsecurity/ssh-bf","origin":"crowdsec","duration":"3h59m"}]}]' ;;
    "decisions list --ip 203.0.113.66 -o json") echo '[{"decisions":[{"value":"203.0.113.66"}]}]' ;;
    "decisions list --ip "*) echo 'null' ;;
esac
STUB
printf '#!/bin/bash\n[[ "$1" == -T ]] && printf "port %%s\\nport 22\\n" "${SSHD_PORT:-22}"\n' > "${B}/sshd"
chmod +x "${B}/"*

export FIREWALL_UFW_DIR="$U" FIREWALL_F2B_ATTEMPTS="${TMP}/f2b/cipi-attempts.local"
export CIPI_LIB="$LIB" CIPI_CONFIG="${TMP}/cfg" CIPI_LOG="${TMP}/log"
mkdir -p "$CIPI_CONFIG" "$CIPI_LOG" "${TMP}/f2b"
RUNC=$(printf 'set -euo pipefail\nRED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""\nsource "$CIPI_LIB/common.sh"\nsource "$CIPI_LIB/firewall.sh"\nsource "$CIPI_LIB/ban.sh"\n')
fw() { PATH="${B}:${PATH}" bash -c "${RUNC}"$'\nfirewall_command "$@"' fw "$@" 2>&1; }
ban() { PATH="${B}:${PATH}" bash -c "${RUNC}"$'\nban_command "$@"' ban "$@" 2>&1; }

# A server as setup.sh leaves it, plus what Cipi's own features add.
PATH="${B}:${PATH}" ufw allow 22/tcp >/dev/null; PATH="${B}:${PATH}" ufw allow 80/tcp >/dev/null; PATH="${B}:${PATH}" ufw allow 443/tcp >/dev/null
PATH="${B}:${PATH}" ufw allow from 203.0.113.5 to any port 9100 proto tcp comment 'cipi metrics' >/dev/null
PATH="${B}:${PATH}" ufw allow from 2001:db8::7 to any port 9100 proto tcp comment 'cipi metrics' >/dev/null
grep -q '^### tuple ### allow tcp 9100 0.0.0.0/0 any 203.0.113.5 in comment=63697069206d657472696373$' "${U}/user.rules" && pass "stub writes tuples as ufw does (comment in hex)" || fail "stub tuple"

# ── allow ────────────────────────────────────────────────────
o=$(fw allow 8080); r=$?
[[ $r -eq 0 && "$o" == *"Allowed 8080/tcp"* ]] && pass "allow 8080" || fail "allow: ${o}"
o=$(fw allow 8080); [[ "$o" == *"Already allowed"* ]] && pass "…twice: already allowed" || fail "allow twice: ${o}"
o=$(fw allow --from=10.0.0.0/8 5432); r=$?
[[ $r -eq 0 ]] && grep -q 'allow from 10.0.0.0/8 to any port 5432 proto tcp' "${U}/calls.log" && pass "allow --from (option first)" || fail "allow --from: ${o}"
o=$(fw allow 6000:6010 --proto=udp); [[ $? -eq 0 ]] && grep -q '^allow 6000:6010/udp$' "${U}/calls.log" && pass "allow a range, udp" || fail "range: ${o}"
for bad in 0 65536 '22;id' '-1' '8000:7000' '80,443' 'ssh'; do
    o=$(fw allow "$bad"); r=$?
    [[ $r -ne 0 && "$o" == *"Not a port"* ]] || { fail "allow '${bad}' accepted: ${o}"; continue; }
done && pass "allow refuses 0, 65536, '22;id', -1, 8000:7000, 80,443, ssh"
o=$(fw allow 8081 --from='1.2.3.4;id'); [[ $? -ne 0 && "$o" == *"Not an IP"* ]] && pass "allow refuses a --from that is not an address" || fail "bad from: ${o}"
o=$(fw allow 8081 --proto=icmp); [[ $? -ne 0 ]] && pass "allow refuses --proto=icmp" || fail "proto: ${o}"
o=$(fw allow 0080); grep -q '^allow 80/tcp$' "${U}/calls.log" && pass "leading zeros dropped (0080 → 80)" || fail "zeros"

# ── status --json ────────────────────────────────────────────
s=$(fw status --json); r=$?
if [[ $r -eq 0 ]] && jq -e . >/dev/null 2>&1 <<< "$s"; then pass "status --json is JSON"; else fail "status (exit ${r}): ${s}"; s='{}'; fi
[[ "$(jq -r '.ufw.active, .ufw.default_incoming, .ufw.default_outgoing' <<< "$s" | paste -sd' ' -)" == "true deny allow" ]] && pass "…UFW active, default deny in / allow out" || fail "ufw header: $(jq -c .ufw <<< "$s" | head -c 200)"
[[ "$(jq -c '.protected_ports' <<< "$s")" == '[22,80,443]' ]] && pass "…protected ports 22, 80, 443" || fail "protected: $(jq -c .protected_ports <<< "$s")"
r22=$(jq -c '.ufw.rules[] | select(.port == "22")' <<< "$s")
[[ "$(jq -r '[.family, .kind, .protected, .removable] | join(" ")' <<< "$r22")" == "both port true false" ]] && pass "…22: one rule for IPv4 and IPv6, protected, not removable" || fail "22: ${r22}"
r8080=$(jq -c '.ufw.rules[] | select(.port == "8080")' <<< "$s")
[[ "$(jq -r '[.action, .proto, .from, .family, .kind, .protected, .removable] | join(" ")' <<< "$r8080")" == "allow tcp any both port false true" ]] && pass "…8080: removable" || fail "8080: ${r8080}"
m=$(jq -c '[.ufw.rules[] | select(.port == "9100")]' <<< "$s")
[[ "$(jq -r 'map([.from, .family, .comment, .managed_by, .removable] | join(" ")) | join(" | ")' <<< "$m")" == "203.0.113.5 v4 cipi metrics metrics false | 2001:db8::7 v6 cipi metrics metrics false" ]] \
    && pass "…comments decoded; a Cipi feature's rules are its own (not removable)" || fail "9100: ${m}"
[[ "$(jq -r '.ufw.rules[] | select(.port == "5432") | [.from, .family, .removable] | join(" ")' <<< "$s")" == "10.0.0.0/8 v4 true" ]] && pass "…a source-restricted rule" || fail "5432"
[[ "$(jq -r '[.ufw.rules[].port] | join(",")' <<< "$s")" == "22,80,443,9100,8080,5432,6000:6010,9100" ]] && pass "…in ufw's order (IPv4 first, then the IPv6-only rules, as ufw status lists them)" || fail "order: $(jq -r '[.ufw.rules[].port] | join(",")' <<< "$s")"
f=$(jq -c .fail2ban <<< "$s")
[[ "$(jq -r '[.running, .attempts, .attempts_default, (.attempts_custom|tostring), .findtime, .bantime] | join(" ")' <<< "$f")" == "true 3 3 null 3600 86400" ]] && pass "…fail2ban threshold and timings" || fail "f2b: ${f}"
[[ "$(jq -r '.jails[] | select(.jail == "sshd") | [.count, .total, .failed, (.banned | join(","))] | join(" ")' <<< "$f")" == "2 9 2 11.2.3.45,198.51.100.20" ]] && pass "…sshd jail with its bans" || fail "jail: ${f}"
[[ "$(jq -r '.jails[] | select(.jail == "recidive") | [.count, (.banned | length)] | join(" ")' <<< "$f")" == "0 0" ]] && pass "…an empty jail has no bans" || fail "recidive: ${f}"
[[ "$(jq -r '.crowdsec | [.installed, .running, (.decisions | length)] | join(" ")' <<< "$s")" == "false false 0" ]] && pass "…CrowdSec not installed" || fail "cs: $(jq -c .crowdsec <<< "$s")"
[[ "$(jq -r '.zero_trust | [.lock_http, .lock_ssh] | join(" ")' <<< "$s")" == "false false" ]] && pass "…no Zero Trust lock" || fail "zt"
o=$(fw status); [[ $? -eq 0 && "$o" == *"UFW                 active · default deny incoming"* && "$o" == *"Banned now          2 by fail2ban"* ]] && pass "status (text)" || fail "status text: ${o}"
o=$(fw list --json); [[ "$(jq 'length' <<< "$o" 2>/dev/null)" == "$(jq '.ufw.rules | length' <<< "$s")" ]] && pass "list --json: the same rules" || fail "list --json: ${o}"
o=$(fw attempts --json); [[ "$(jq -r '[.attempts, .default, .running] | join(" ")' <<< "$o" 2>/dev/null)" == "3 3 true" ]] && pass "attempts --json" || fail "attempts --json: ${o}"

# ── the ports this server is reached on ──────────────────────
for p in 22 80 443; do
    o=$(fw remove "$p"); r=$?
    [[ $r -ne 0 && "$o" == *"how this server is reached"* ]] || fail "remove ${p} not refused: ${o}"
done && pass "remove 22 / 80 / 443 refused"
o=$(fw remove 20:30); [[ $? -ne 0 && "$o" == *"how this server is reached"* ]] && pass "…a range that takes in 22 too" || fail "range 20:30: ${o}"
o=$(fw deny 443); [[ $? -ne 0 && "$o" == *"denying it to everyone"* ]] && pass "deny 443 to everyone refused" || fail "deny 443: ${o}"
o=$(SSHD_PORT=2222 fw remove 2222); [[ $? -ne 0 && "$o" == *"how this server is reached"* ]] && pass "…the SSH port sshd really listens on (2222)" || fail "2222: ${o}"
o=$(SUDO_USER=www-data fw remove 443 --force); [[ $? -ne 0 ]] && grep -q 'allow tcp 443 ' "${U}/user.rules" && pass "--force from the panel (sudo as www-data) is ignored" || fail "panel force: ${o}"
o=$(fw remove 443 --force); [[ $? -eq 0 ]] && ! grep -q 'allow tcp 443 ' "${U}/user.rules" && pass "--force at the shell removes it" || fail "shell force: ${o}"
PATH="${B}:${PATH}" ufw allow 443/tcp >/dev/null

# ── remove ───────────────────────────────────────────────────
o=$(fw remove 8080); [[ $? -eq 0 && "$o" == *"Removed: allow 8080/tcp"* ]] && ! grep -q ' 8080 ' "${U}/user.rules" "${U}/user6.rules" && pass "remove 8080: both families" || fail "remove 8080: ${o}"
grep -q -- '--force delete allow 8080/tcp' "${U}/calls.log" && pass "…ufw --force delete (no question)" || fail "delete call"
o=$(fw remove 8080); [[ $? -ne 0 && "$o" == *"No such rule"* ]] && pass "…again: no such rule" || fail "remove twice: ${o}"
o=$(fw remove 5432 --from=10.0.0.0/8); [[ $? -eq 0 ]] && ! grep -q ' 5432 ' "${U}/user.rules" && pass "remove --from" || fail "remove from: ${o}"
o=$(fw remove 6000:6010 --proto=udp); [[ $? -eq 0 ]] && pass "remove a udp range" || fail "remove udp: ${o}"
o=$(fw remove 6000:6010 --proto=any); [[ $? -ne 0 && "$o" == *"always has a protocol"* ]] && pass "…a range with --proto=any refused" || fail "range any: ${o}"
o=$(fw remove 9100 --from=203.0.113.5); [[ $? -eq 0 ]] && pass "remove from the shell may take a Cipi feature's rule (the panel only offers removable ones)" || fail "9100: ${o}"
PATH="${B}:${PATH}" ufw allow 3000 >/dev/null
o=$(fw remove 3000 --proto=any); [[ $? -eq 0 ]] && grep -q -- '--force delete allow 3000$' "${U}/calls.log" && pass "remove --proto=any (a rule made without /tcp)" || fail "proto any: ${o}"
PATH="${B}:${PATH}" ufw allow 4000/tcp >/dev/null; PATH="${B}:${PATH}" ufw allow 4000/udp >/dev/null
o=$(fw remove 4000 --proto=udp); [[ $? -eq 0 ]] && grep -q 'allow tcp 4000 ' "${U}/user.rules" && ! grep -q 'allow udp 4000 ' "${U}/user.rules" && pass "…only the protocol given" || fail "udp only: ${o}"

# ── deny: ahead of every allow ───────────────────────────────
o=$(fw deny 4000); [[ $? -eq 0 ]] && [[ "$(grep -m1 '^### tuple' "${U}/user.rules")" == "### tuple ### deny tcp 4000 0.0.0.0/0 any 0.0.0.0/0 in" ]] && pass "deny goes first (prepend)" || fail "deny first: ${o} / $(grep -m1 '^### tuple' "${U}/user.rules")"
o=$(UFW_NO_PREPEND=1 fw deny 4001); [[ $? -eq 0 ]] && grep -q '^insert 1 deny 4001/tcp$' "${U}/calls.log" && pass "…insert 1 where prepend is missing" || fail "insert fallback: ${o}"
o=$(fw deny 22 --from=198.51.100.0/24); [[ $? -eq 0 ]] && pass "deny 22 to one range" || fail "deny from: ${o}"
o=$(SSH_CLIENT="198.51.100.9 50000 22" fw deny 22 --from=198.51.100.0/24); [[ $? -ne 0 && "$o" == *"this SSH session"* ]] && pass "…not when it takes in this SSH session" || fail "deny self: ${o}"
o=$(fw remove 4000 --deny); [[ $? -eq 0 ]] && ! grep -q 'deny tcp 4000 ' "${U}/user.rules" && pass "remove --deny" || fail "remove deny: ${o}"

# ── block / unblock ──────────────────────────────────────────
o=$(fw block 192.0.2.66); [[ $? -eq 0 && "$o" == *"Blocked 192.0.2.66"* ]] && [[ "$(grep -m1 '^### tuple' "${U}/user.rules")" == "### tuple ### deny any any 0.0.0.0/0 any 192.0.2.66 in" ]] && pass "block: every port, first" || fail "block: ${o}"
o=$(fw block 2001:db8:bad::/48); [[ $? -eq 0 ]] && grep -q 'deny any any ::/0 any 2001:db8:bad::/48 in' "${U}/user6.rules" && ! grep -q 'bad' "${U}/user.rules" && pass "block an IPv6 range (IPv6 rules only)" || fail "block v6: ${o}"
s=$(fw status --json)
[[ "$(jq -r '[.ufw.rules[] | select(.kind == "block") | "\(.from):\(.family):\(.removable)"] | join(" ")' <<< "$s")" == "2001:db8:bad::/48:v6:true 192.0.2.66:v4:true" || "$(jq -r '[.ufw.rules[] | select(.kind == "block") | "\(.from):\(.family):\(.removable)"] | join(" ")' <<< "$s")" == "192.0.2.66:v4:true 2001:db8:bad::/48:v6:true" ]] \
    && pass "…listed as blocks, removable" || fail "blocks: $(jq -c '[.ufw.rules[] | select(.kind == "block")]' <<< "$s")"
o=$(SSH_CLIENT="203.0.113.9 50000 22" fw block 203.0.113.0/24); [[ $? -ne 0 && "$o" == *"203.0.113.9, the address of this SSH session"* ]] && pass "block refuses the range of this SSH session" || fail "block self: ${o}"
o=$(SSH_CLIENT="203.0.113.9 50000 22" SUDO_USER=www-data fw block 203.0.113.0/24 --force); [[ $? -ne 0 ]] && pass "…--force from the panel ignored" || fail "block self panel: ${o}"
for bad in 0.0.0.0/0 10.0.0.0/7 ::/0 2001::/15; do
    o=$(fw block "$bad"); [[ $? -ne 0 && "$o" == *"too wide"* ]] || { fail "block ${bad}: ${o}"; continue; }
done && pass "block refuses /0, /7 (IPv4) and /15 (IPv6)"
for bad in 999.1.1.1 1.2.3.4/33 1.2.3.4/ '-x' 'a:b;id' example.com; do
    o=$(fw block "$bad"); [[ $? -ne 0 && "$o" == *"Not an IP"* ]] || { fail "block '${bad}' accepted: ${o}"; continue; }
done && pass "block refuses 999.1.1.1, /33, a trailing /, an option, shell characters, a hostname"
o=$(fw unblock 192.0.2.66); [[ $? -eq 0 ]] && ! grep -q '192.0.2.66' "${U}/user.rules" && pass "unblock" || fail "unblock: ${o}"
o=$(fw unblock 192.0.2.66); [[ $? -ne 0 && "$o" == *"is not blocked"* ]] && pass "…again: not blocked" || fail "unblock twice: ${o}"

# ── Zero Trust locks ─────────────────────────────────────────
echo '{"lock_http": true, "lock_ssh": false}' > "${CIPI_CONFIG}/zt.json"
o=$(fw allow 443); [[ $? -ne 0 && "$o" == *"Zero Trust keeps 80/443 to Cloudflare"* ]] && pass "allow 443 refused under the HTTP lock" || fail "zt 443: ${o}"
o=$(fw allow 1:1000); [[ $? -ne 0 && "$o" == *"Zero Trust"* ]] && pass "…a range over 80 too" || fail "zt range: ${o}"
o=$(fw allow 443 --from=198.51.100.1); [[ $? -eq 0 ]] && pass "…one address is fine" || fail "zt from: ${o}"
[[ "$(fw status --json | jq -r .zero_trust.lock_http)" == "true" ]] && pass "status reports the lock" || fail "zt status"
echo '{"lock_http": false, "lock_ssh": true}' > "${CIPI_CONFIG}/zt.json"
o=$(fw allow 22); [[ $? -ne 0 && "$o" == *"Zero Trust keeps SSH closed"* ]] && pass "allow 22 refused under the SSH lock" || fail "zt ssh: ${o}"
rm -f "${CIPI_CONFIG}/zt.json"

# ── fail2ban threshold, unban ────────────────────────────────
o=$(fw attempts 5); [[ $? -eq 0 ]] && grep -q '^maxretry = 5$' "$FIREWALL_F2B_ATTEMPTS" && pass "attempts 5" || fail "attempts: ${o}"
[[ "$(fw status --json | jq -r '[.fail2ban.attempts_custom, .fail2ban.attempts_pending] | join(" ")')" == "5 true" ]] && pass "…status: saved 5, fail2ban still runs 3 (pending)" || fail "pending"
o=$(fw attempts default); [[ $? -eq 0 && ! -f "$FIREWALL_F2B_ATTEMPTS" ]] && pass "attempts default" || fail "default: ${o}"
o=$(fw attempts 101); [[ $? -ne 0 ]] && pass "attempts 101 refused" || fail "101"
: > "${U}/f2b.log"
o=$(ban unban 1.2.3.4); [[ "$o" == *"not currently banned"* ]] && ! grep -q unbanip "${U}/f2b.log" && pass "ban unban 1.2.3.4 does not take 11.2.3.45 for it" || fail "unban substring: ${o}"
o=$(ban unban 11.2.3.45); [[ $? -eq 0 ]] && grep -q '^set sshd unbanip 11.2.3.45$' "${U}/f2b.log" && pass "ban unban 11.2.3.45" || fail "unban: ${o}"
o=$(ban unban 198.51.100.2); grep -q 'unbanip 198.51.100.2$' "${U}/f2b.log" && fail "a dot matched any character: ${o}" || pass "…the dots are dots (198.51.100.2 is not 198.51.100.20)"
for bad in '--help' '1.2.3.4;id' 'abc' ''; do
    o=$(ban unban "$bad"); [[ $? -ne 0 ]] || { fail "unban '${bad}' accepted: ${o}"; continue; }
done && pass "ban unban refuses an option, shell characters, a word, nothing"

# ── CrowdSec ─────────────────────────────────────────────────
mkdir -p "${CIPI_CONFIG}"; printf '203.0.113.0/24\n# a comment\n\n' > "${CIPI_CONFIG}/crowdsec-allow.list"
s=$(CS=1 fw status --json)
[[ "$(jq -r '.crowdsec | [.installed, .running, .bouncer] | join(" ")' <<< "$s")" == "true true running" ]] && pass "CrowdSec: engine and bouncer" || fail "cs: $(jq -c .crowdsec <<< "$s")"
[[ "$(jq -c '.crowdsec.allowlist' <<< "$s")" == '["203.0.113.0/24"]' ]] && pass "…the operator's allowlist" || fail "allow: $(jq -c .crowdsec.allowlist <<< "$s")"
[[ "$(jq -r '.crowdsec.decisions[0] | [.ip, .reason, .duration] | join(" ")' <<< "$s")" == "203.0.113.66 crowdsecurity/ssh-bf 3h59m" ]] && pass "…its decisions" || fail "decisions: $(jq -c .crowdsec.decisions <<< "$s")"
jq -e '.crowdsec.ram_required_mb == 512 and (.crowdsec.enable_blockers | type) == "array"' >/dev/null <<< "$s" && pass "…RAM and what would stop an enable" || fail "blockers"
: > "${U}/cscli.log"
o=$(CS=1 ban unban 203.0.113.66); grep -q '^decisions delete --ip 203.0.113.66$' "${U}/cscli.log" && pass "ban unban takes a CrowdSec decision away" || fail "cs unban: ${o}"
o=$(CS=1 ban unban 203.0.113.0/24); grep -q 'decisions list --range 203.0.113.0/24' "${U}/cscli.log" && pass "…a range with --range (CrowdSec only)" || fail "range: ${o}"
grep -q 'if \[\[ "${SUDO_USER:-}" == "www-data" \]\]; then' "${LIB}/crowdsec.sh" && grep -A3 'SUDO_USER:-}" == "www-data"' "${LIB}/crowdsec.sh" | grep -q 'ARG_force=""' \
    && pass "crowdsec enable from the panel drops --force" || fail "crowdsec force"
o=$(PATH="${B}:${PATH}" bash -c "${RUNC}"$'\nsource "$CIPI_LIB/crowdsec.sh"; for n in 2001:db8::/48 10.0.0.1 "a:b;id" "1::/129" "x"; do _crowdsec_valid_net "$n" && echo "ok $n" || echo "no $n"; done' 2>&1)
[[ "$o" == $'ok 2001:db8::/48\nok 10.0.0.1\nno a:b;id\nno 1::/129\nno x' ]] && pass "crowdsec allow: IPv6 is hex digits and colons only" || fail "valid_net: ${o}"

# ── the panel's sudoers ──────────────────────────────────────
o=$(TMPDIR="$TMP" bash -c 'source "$1/cipi-api-sudoers.sh"; cipi_sudoers_check() { return 0; }; install() { cp "$3" "$4"; }; write_cipi_api_sudoers' x "$LIB" 2>&1)
SUD=$(TMPDIR="$TMP" bash -c 'source "$1/cipi-api-sudoers.sh"; cipi_sudoers_check() { return 0; }; install() { cat "$3"; }; write_cipi_api_sudoers' x "$LIB" 2>/dev/null)
for c in 'firewall status --json' 'firewall allow \*' 'firewall remove \*' 'firewall block \*' 'firewall unblock \*' 'firewall attempts \*' 'ban unban \*' 'crowdsec enable \*' 'crowdsec disable --force' 'crowdsec allow \*' 'crowdsec unallow \*'; do
    grep -qE "/usr/local/bin/cipi ${c}(,|$)" <<< "$SUD" || { fail "sudoers: ${c} missing"; continue; }
done && pass "sudoers: firewall status/allow/remove/block/unblock/attempts, ban unban, crowdsec enable/disable --force/allow/unallow"
! grep -qE 'cipi firewall deny|cipi crowdsec rescue|cipi crowdsec disable \*|cipi crowdsec refresh' <<< "$SUD" && pass "…not deny, rescue, refresh, or disable with anything but --force" || fail "sudoers too wide"
if command -v visudo >/dev/null 2>&1; then
    printf '%s\n' "$SUD" > "${TMP}/sudoers.check"; chmod 440 "${TMP}/sudoers.check"
    visudo -c -f "${TMP}/sudoers.check" >/dev/null 2>&1 && pass "…visudo accepts it" || fail "visudo: $(visudo -c -f "${TMP}/sudoers.check" 2>&1 | head -3)"
fi
(( $(grep -c 'NOPASSWD' <<< "$SUD") >= 5 )) && awk '/NOPASSWD/{if (n > 40) bad=1; n=0} {n++} END{if (n > 40) bad=1; exit bad ? 1 : 0}' <<< "$SUD" && pass "…40 commands per rule at most (sudo-rs)" || fail "rule split"

# ── compliance: the GUI's 2FA policy ─────────────────────────
grep -q "SELECT value FROM cipi_settings WHERE key = 'enforce_2fa'" "${LIB}/compliance.sh" && pass "compliance reads enforce_2fa" || fail "compliance"
# The panel's database: the sqlite3 CLI, or PHP's PDO (what compliance falls back to).
sql() {
    if command -v sqlite3 >/dev/null 2>&1; then sqlite3 "$1" "$2"
    else php -r '$p = new PDO("sqlite:" . $argv[1]); $p->exec($argv[2]);' -- "$1" "$2"; fi
}
if command -v sqlite3 >/dev/null 2>&1 || php -m 2>/dev/null | grep -qi pdo_sqlite; then
    G="${TMP}/gui"; mkdir -p "${G}/database"; touch "${G}/artisan"; echo 'DB_CONNECTION=sqlite' > "${G}/.env"
    sql "${G}/database/database.sqlite" "CREATE TABLE users (id INTEGER, name TEXT, email TEXT, two_factor_enabled INTEGER, two_factor_confirmed_at TEXT, created_at TEXT, password TEXT);
        INSERT INTO users VALUES (1,'A','a@x.it',1,NULL,NULL,'h'),(2,'B','b@x.it',0,NULL,NULL,'h');"
    cmp() { bash -c 'set -uo pipefail; RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""; source "$CIPI_LIB/common.sh"; source "$CIPI_LIB/compliance.sh"; CIPI_GUI_ROOT="$1"; _cmp_check_gui_2fa' x "$G" 2>/dev/null; }
    o=$(cmp); [[ "$(jq -r .status <<< "$o")" == fail && "$(jq -r .detail <<< "$o")" == *"Team → Two-factor authentication"* ]] && pass "compliance: a user without 2FA, nothing required → fail, says where to require it" || fail "cmp fail: ${o}"
    sql "${G}/database/database.sqlite" "CREATE TABLE cipi_settings (key TEXT PRIMARY KEY, value TEXT); INSERT INTO cipi_settings VALUES ('enforce_2fa','1');"
    o=$(cmp); [[ "$(jq -r .status <<< "$o")" == warn && "$(jq -r .summary <<< "$o")" == *"required for every GUI account; not set up yet: b@x.it"* ]] && pass "…required by the panel → warn, who is left" || fail "cmp warn: ${o}"
    sql "${G}/database/database.sqlite" "UPDATE users SET two_factor_enabled = 1"
    o=$(cmp); [[ "$(jq -r .status <<< "$o")" == pass && "$(jq -r .summary <<< "$o")" == *"and the panel requires it"* ]] && pass "…everyone, and required → pass" || fail "cmp pass: ${o}"
else
    echo "  (neither sqlite3 nor PHP with pdo_sqlite: the compliance check is not run)"
fi

# ── cipi package: the wider catalog, from the panel too ──────
# apt, dpkg and apt-mark as one model: installed packages with their mark
# (manual/auto), what each package depends on, and what apt has a candidate
# for. Orphans are auto packages nothing installed needs — as apt computes them.
K="${TMP}/pkg"; mkdir -p "${K}/bin" "${K}/lib" "${K}/cfg" "${K}/log"
cp -r "${LIB}/." "${K}/lib/"
cat > "${K}/aptsim" <<'STUB'
#!/usr/bin/env python3
import json, os, sys
K = os.environ["PKG_SIM"]; st = json.load(open(K + "/state.json"))
me = os.path.basename(sys.argv[0]); a = sys.argv[1:]
with open(K + "/calls", "a") as fh: fh.write(me + " " + " ".join(a) + "\n")
inst, deps, avail, bins = st["installed"], st["deps"], st["avail"], st.get("bins", {})
def save(): json.dump(st, open(K + "/state.json", "w"))
def needed(installed):
    keep = {p for p, m in installed.items() if m == "manual"}; todo = list(keep)
    while todo:
        for d in deps.get(todo.pop(), []):
            if d in installed and d not in keep: keep.add(d); todo.append(d)
    return keep
def orphans(installed): return sorted(set(installed) - needed(installed))
def closure(names):
    out, todo = [], list(names)
    while todo:
        p = todo.pop(0)
        if p in inst or p in out: continue
        out.append(p); todo += deps.get(p, [])
    return out
def revdeps(names, installed):
    gone, changed = set(names), True
    while changed:
        changed = False
        for p in installed:
            if p not in gone and any(d in gone for d in deps.get(p, [])): gone.add(p); changed = True
    return gone - set(names)
def binsync():
    for p, bs in bins.items():
        for b in bs:
            f = K + "/bin/" + b
            if p in inst: open(f, "w").write("#!/bin/sh\n"); os.chmod(f, 0o755)
            elif os.path.exists(f): os.remove(f)
if me == "dpkg-query":
    print("installed" if a[-1] in inst else "not-installed", end=""); sys.exit(0 if a[-1] in inst else 1)
if me == "apt-cache":
    n = a[-1]; print(n + ":\n  Installed: (none)\n  Candidate: " + ("1.0-1" if n in avail else "(none)") + "\n  Version table:"); sys.exit(0)
if me == "apt-mark":
    if a[0] == "showmanual":
        for p in a[1:]:
            if inst.get(p) == "manual": print(p)
        sys.exit(0)
    for p in a[1:]:
        if p in inst: inst[p] = a[0]
    save(); sys.exit(0)
opts = [x for x in a if x.startswith("-")]; words = [x for x in a if not x.startswith("-") and not x.startswith("DPkg::")]
sim = "-s" in opts; cmd, names = words[0], words[1:]
if cmd == "update": sys.exit(0)
if cmd == "install":
    if any(n not in avail and n not in inst for n in names): print("E: Unable to locate package"); sys.exit(100)
    new = closure(names)
    if sim:
        for p in new: print("Inst " + p + " (1.0-1 Ubuntu:noble [amd64])")
        print("After this operation, 42.0 MB of additional disk space will be used."); sys.exit(0)
    for p in new: inst[p] = "auto"
    for n in names: inst[n] = "manual"
    save(); binsync(); sys.exit(0)
if cmd in ("purge", "remove"):
    gone = set(n for n in names if n in inst); gone |= revdeps(gone, inst)
    if "--autoremove" in opts:
        rest = {p: m for p, m in inst.items() if p not in gone}; gone |= set(orphans(rest))
    if sim:
        for p in sorted(gone): print("Purg " + p + " [1.0-1]")
        sys.exit(0)
    for p in gone: inst.pop(p, None)
    save(); binsync(); sys.exit(0)
if cmd == "autoremove":
    o = orphans(inst)
    if sim:
        for p in o: print("Remv " + p + " [1.0-1]")
        sys.exit(0)
    for p in o: inst.pop(p, None)
    save(); binsync(); sys.exit(0)
sys.exit(0)
STUB
chmod +x "${K}/aptsim"; for c in apt-get apt-cache dpkg-query apt-mark; do ln -sf ../aptsim "${K}/bin/${c}"; done
printf '#!/bin/bash\necho "Filesystem 1024-blocks Used Available Capacity Mounted"\necho "/dev/sda1 50000000 1000 ${STUB_FREE_KB:-9000000} 1%% /var"\n' > "${K}/bin/df"; chmod +x "${K}/bin/df"
# A server: php-imagick needs libcairo2 (installed as its dependency), an old
# kernel waits for autoremove, and "reports" (an app tool of the admin) needs ffmpeg.
pkg_world() {
    local release="${1:-noble}"
    python3 - "$K" "$release" <<'PY'
import json, sys
K, rel = sys.argv[1], sys.argv[2]
cat = ["libnss3","libnspr4","libdrm2","libxkbcommon0","libxcomposite1","libxdamage1","libxfixes3","libxrandr2","libgbm1",
       "libpango-1.0-0","libcairo2","fonts-liberation","fonts-noto-color-emoji","fonts-noto-cjk","pdftk-java","default-jre-headless",
       "libreoffice-writer-nogui","libreoffice-calc-nogui","libreoffice-core-nogui","pandoc","libavif-bin","ffmpeg","libavcodec",
       "tesseract-ocr","tesseract-ocr-eng","tesseract-ocr-ita","tesseract-ocr-deu","tesseract-ocr-fra","tesseract-ocr-spa",
       "jpegoptim","optipng","pngquant","gifsicle","webp","imagemagick","poppler-utils"]
# 24.04 names the time_t-renamed libraries with t64; a later release may not.
t64 = ["libatk1.0-0","libatk-bridge2.0-0","libcups2","libasound2"]
avail = cat + ([p + "t64" for p in t64] if rel == "noble" else t64)
st = {"installed": {"php8.5-imagick": "manual", "libcairo2": "auto", "linux-image-old": "auto", "reports": "manual", "ffmpeg": "manual", "libavcodec": "auto"},
      "deps": {"php8.5-imagick": ["libcairo2"], "pdftk-java": ["default-jre-headless"], "libreoffice-writer-nogui": ["libreoffice-core-nogui"],
               "libreoffice-calc-nogui": ["libreoffice-core-nogui"], "ffmpeg": ["libavcodec"], "reports": ["ffmpeg"], "tesseract-ocr": ["tesseract-ocr-eng"]},
      "avail": avail,
      "bins": {"pandoc": ["pandoc"], "pdftk-java": ["pdftk"], "libreoffice-core-nogui": ["soffice"], "libavif-bin": ["avifenc"],
               "tesseract-ocr": ["tesseract"], "ffmpeg": ["ffmpeg", "ffprobe"]}}
json.dump(st, open(K + "/state.json", "w"))
PY
    : > "${K}/calls"; rm -f "${K}/bin/pandoc" "${K}/bin/pdftk" "${K}/bin/soffice" "${K}/bin/avifenc" "${K}/bin/tesseract"
    printf '#!/bin/sh\n' > "${K}/bin/ffmpeg"; printf '#!/bin/sh\n' > "${K}/bin/ffprobe"; chmod +x "${K}/bin/ffmpeg" "${K}/bin/ffprobe"
}
cat > "${K}/run.sh" <<RUN
set -euo pipefail
RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""
export CIPI_LIB="${K}/lib" CIPI_CONFIG="${K}/cfg" CIPI_LOG="${K}/log" PKG_SIM="${K}"
export PATH="${K}/bin:\${PATH}"
source "${K}/lib/common.sh"; source "${K}/lib/package.sh"
cipi_notify() { echo "notify \$3" >> "${K}/calls"; }
show_help() { :; }
"\$@"
RUN
pk()  { bash "${K}/run.sh" package_command "$@" </dev/null 2>&1; }
inst() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1]+"/state.json")); print(" ".join(sorted(s["installed"])))' "$K"; }
mark() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1]+"/state.json")); print(s["installed"].get(sys.argv[2],"absent"))' "$K" "$1"; }

eval "$(sed -n '/^_pkg_catalog()/,/^}/p' "${LIB}/package.sh")"
eval "$(grep -E '^_pkg_(ids|apt_for|bins_for|desc_for|kind_for)\(\)' "${LIB}/package.sh")"
ids=" $(_pkg_ids | tr '\n' ' ')"
for want in image-optimizers avif ffmpeg imagemagick poppler-utils browsershot fonts-cjk pdftk libreoffice pandoc tesseract; do
    [[ "$ids" == *" ${want} "* ]] || fail "catalog misses ${want}"
done
[[ "$(_pkg_ids | wc -l | tr -d ' ')" == 11 ]] && pass "catalog: 11 entries (${ids# })" || fail "catalog size: ${ids}"
[[ "$(_pkg_kind_for browsershot)" == libraries && "$(_pkg_kind_for fonts-cjk)" == libraries && "$(_pkg_kind_for pdftk)" == tools ]] \
    && pass "browsershot and fonts-cjk are libraries (nothing on PATH), the rest tools" || fail "kinds"
bad=""; while IFS='|' read -r id apt bins desc; do
    [[ -n "$id" && -n "$apt" && -n "$desc" && "$id" =~ ^[a-z0-9-]+$ ]] || bad="${bad} ${id}"
    for p in $apt; do [[ "$p" =~ ^[a-z0-9.+/-]+$ && "$p" != *snapd* && "$p" != chromium* && "$p" != *wkhtmlto* ]] || bad="${bad} ${p}"; done
done <<< "$(_pkg_catalog)"
[[ -z "$bad" ]] && pass "every entry: an id, apt names, a description; no chromium, snapd or wkhtmltopdf" || fail "catalog entries:${bad}"
grep -q 'libasound2t64/libasound2' "${LIB}/package.sh" && grep -q 'libatk-bridge2.0-0t64/libatk-bridge2.0-0' "${LIB}/package.sh" \
    && pass "the time_t-renamed libraries are listed with both names (24.04, and a release that drops t64)" || fail "t64 alternatives"

o=$(pk install chromium); [[ $? -ne 0 && "$o" == *"snapd"* && "$o" == *"cipi package install browsershot"* ]] && pass "chromium refused, pointing at browsershot" || fail "chromium: ${o}"
o=$(pk install wkhtmltopdf); [[ $? -ne 0 && "$o" == *"archived upstream"* ]] && pass "wkhtmltopdf refused, and why" || fail "wkhtmltopdf: ${o}"
o=$(pk install nginx); [[ $? -ne 0 && "$o" == *"not in the Cipi package allowlist"* ]] && pass "anything else refused" || fail "nginx: ${o}"

pkg_world noble
j=$(pk list --json)
jq -e '.packages | length == 11' <<< "$j" >/dev/null && pass "list --json: 11 entries" || fail "list json: ${j}"
jq -e '.packages[] | select(.id == "browsershot") | .kind == "libraries" and .binaries == [] and .installed == false and .partial == false and (.missing | index("libnss3")) and (.missing | index("libcairo2") | not)' <<< "$j" >/dev/null \
    && pass "…browsershot: libraries, not partial (libcairo2 belongs to php-imagick), missing listed" || fail "browsershot json: $(jq -c '.packages[] | select(.id=="browsershot")' <<< "$j")"
jq -e '.packages[] | select(.id == "ffmpeg") | .installed == true and .binaries == ["ffmpeg","ffprobe"] and .kind == "tools"' <<< "$j" >/dev/null \
    && pass "…ffmpeg: installed, its binaries" || fail "ffmpeg json"

o=$(pk install browsershot); [[ $? -ne 0 && "$o" == *"never implicit: pass --yes"* && "$(mark libnss3)" == absent ]] \
    && pass "install without a terminal and without --yes: refused, nothing installed" || fail "implicit install: ${o}"
o=$(pk install browsershot --yes); r=$?
[[ $r -eq 0 && "$(mark libasound2t64)" == manual && "$(mark libatk-bridge2.0-0t64)" == manual && "$(mark libnss3)" == manual ]] \
    && pass "install browsershot --yes on 24.04: the t64 names" || fail "browsershot noble (${r}): ${o}"
[[ "$o" == *"npm install puppeteer"* && "$o" == *"noSandbox"* && "$o" == *"browsershot installed"* ]] && pass "…and says where Chrome comes from, and the sandbox" || fail "browsershot notes: ${o}"
grep -q "notify package_install" "${K}/calls" && pass "…package_install notified" || fail "notify"
[[ "$(pk list --json | jq -r '.packages[] | select(.id=="browsershot") | .installed')" == true ]] && pass "…then listed as installed" || fail "browsershot state"
[[ "$(pk list --json | jq -r '.packages[] | select(.id=="browsershot") | .packages | index("libasound2t64") != null')" == true ]] && pass "…by the names actually installed" || fail "installed names"

o=$(pk remove browsershot --yes); r=$?
[[ $r -eq 0 && "$(mark libnss3)" == absent && "$(mark libasound2t64)" == absent ]] && pass "remove browsershot: its libraries go" || fail "remove browsershot (${r}): ${o}"
[[ "$(mark libcairo2)" == auto && "$(mark php8.5-imagick)" == manual ]] && pass "…libcairo2 stays: php-imagick needs it (back to a dependency)" || fail "libcairo2: $(mark libcairo2)"
[[ "$(mark linux-image-old)" == auto ]] && pass "…the orphan that was already there is left alone" || fail "old orphan removed"
grep -q "notify package_remove" "${K}/calls" && pass "…package_remove notified" || fail "notify remove"

pkg_world resolute
o=$(pk install browsershot --yes); r=$?
[[ $r -eq 0 && "$(mark libasound2)" == manual && "$(mark libatk-bridge2.0-0)" == manual && "$(mark libasound2t64)" == absent ]] \
    && pass "install browsershot on a release without t64 names: the plain ones" || fail "browsershot resolute (${r}): ${o}"
python3 -c 'import json,sys; p=sys.argv[1]+"/state.json"; s=json.load(open(p)); s["avail"].remove("libgbm1"); json.dump(s,open(p,"w"))' "$K"
pkg_world noble; python3 -c 'import json,sys; p=sys.argv[1]+"/state.json"; s=json.load(open(p)); s["avail"].remove("libgbm1"); json.dump(s,open(p,"w"))' "$K"
o=$(pk install browsershot --yes); [[ $? -ne 0 && "$o" == *"no candidate for: libgbm1"* && "$(mark libnss3)" == absent ]] \
    && pass "a library apt has no candidate for: nothing installed, and which" || fail "no candidate: ${o}"

pkg_world noble
o=$(pk remove browsershot); [[ $? -eq 0 && "$o" == *"not installed"* ]] && pass "remove what is not there: a no-op" || fail "remove absent: ${o}"
o=$(pk install pdftk --yes); [[ $? -eq 0 && "$o" == *"pdftk installed — pdftk available"* && "$(mark default-jre-headless)" == auto ]] && pass "install pdftk: pdftk-java and its Java runtime" || fail "pdftk: ${o}"
o=$(pk remove pdftk --yes); [[ $? -eq 0 && "$(mark pdftk-java)" == absent && "$(mark default-jre-headless)" == absent && "$(mark linux-image-old)" == auto ]] \
    && pass "remove pdftk: with the Java runtime only it needed; older orphans stay" || fail "remove pdftk: ${o}"
o=$(pk install libreoffice --yes); [[ $? -eq 0 && "$o" == *"soffice available"* && "$o" == *"queue worker"* ]] && pass "install libreoffice: soffice, and where to run it" || fail "libreoffice: ${o}"
o=$(pk install tesseract-ocr-ita --yes); [[ $? -eq 0 && "$(mark tesseract-ocr-spa)" == manual ]] && pass "a member name installs its entry (tesseract-ocr-ita → tesseract)" || fail "member: ${o}"
o=$(pk install pandoc --yes); [[ $? -eq 0 && -x "${K}/bin/pandoc" ]] && pass "install pandoc" || fail "pandoc: ${o}"

o=$(pk remove ffmpeg --yes); r=$?
[[ $r -ne 0 && "$o" == *"would also remove: reports"* && "$(mark ffmpeg)" == manual ]] && pass "remove ffmpeg that another package needs: refused, nothing changed" || fail "revdep (${r}): ${o}"
o=$(SUDO_USER=www-data bash "${K}/run.sh" package_command remove ffmpeg --yes --force </dev/null 2>&1); [[ $? -ne 0 && "$(mark ffmpeg)" == manual ]] \
    && pass "…from the panel --force does not get past it" || fail "panel force remove: ${o}"
o=$(pk remove ffmpeg --yes --force); [[ $? -eq 0 && "$(mark ffmpeg)" == absent && "$(mark reports)" == absent && "$(mark libavcodec)" == absent ]] \
    && pass "…at the server --force does, taking what depends on it" || fail "shell force remove: ${o}"

pkg_world noble
o=$(STUB_FREE_KB=1000 SUDO_USER=www-data bash "${K}/run.sh" package_command install pandoc --yes --force </dev/null 2>&1); [[ $? -ne 0 && "$(mark pandoc)" == absent ]] \
    && pass "panel: low disk refuses whatever --force says" || fail "panel disk: ${o}"
o=$(STUB_FREE_KB=1000 bash "${K}/run.sh" package_command install pandoc --force </dev/null 2>&1); [[ $? -eq 0 && "$(mark pandoc)" == manual ]] \
    && pass "shell: --force past the disk check (and the question)" || fail "shell disk: ${o}"
o=$(SUDO_USER=www-data bash "${K}/run.sh" package_command remove pandoc --yes --autoremove </dev/null 2>&1); [[ $? -eq 0 && "$(mark pandoc)" == absent && "$(mark linux-image-old)" == auto ]] \
    && pass "panel: --autoremove ignored, older orphans stay" || fail "panel autoremove: ${o}"
pk install pandoc --yes >/dev/null; o=$(pk remove pandoc --yes --autoremove); [[ $? -eq 0 && "$(mark linux-image-old)" == absent ]] \
    && pass "shell: --autoremove takes the older orphans too" || fail "shell autoremove: ${o}"

pkg_world noble; pk install fonts-cjk --yes >/dev/null
o=$(pk remove fonts-cjk); [[ $? -ne 0 && "$(mark fonts-noto-cjk)" == manual ]] \
    && pass "remove without --yes and no terminal: refused, the library marked manual again" || fail "remove implicit: ${o} / $(mark fonts-noto-cjk)"

sud=$(sed -n '/SUDOEOF/,/^SUDOEOF/p' "${LIB}/cipi-api-sudoers.sh")
grep -q 'cipi package install \*' <<< "$sud" && grep -q 'cipi package remove \*' <<< "$sud" && pass "the panel's sudoers: package install, remove" || fail "sudoers package"
grep -q '_help_note "Libraries and fonts: browsershot' "${ROOT}/cipi" && pass "help: the new entries" || fail "help package"
grep -q 'browsershot fonts-cjk pdftk libreoffice pandoc tesseract' "${LIB}/completion.sh" && pass "completion: the new entries" || fail "completion package"

# ── help, completion ─────────────────────────────────────────
grep -q '_help_cmd "cipi firewall block <ip|cidr>"' "${ROOT}/cipi" && grep -q '_help_cmd "cipi firewall status"' "${ROOT}/cipi" && pass "help: status, block" || fail "help"
grep -q 'sub="status list allow deny remove block unblock attempts"' "${LIB}/completion.sh" && pass "completion" || fail "completion"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]

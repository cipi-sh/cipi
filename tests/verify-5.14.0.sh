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
if me == "dpkg":
    print(st.get("arch", "amd64")); sys.exit(0)
if me == "dpkg-query":
    fmt = next((x for x in a if x.startswith("-f=")), ""); names = [x for x in a if not x.startswith("-")]
    if "${Package}" in fmt:          # one query for many: "name status" per package dpkg knows
        for n in names:
            if n in inst: print(n + " installed")
        sys.exit(0 if all(n in inst for n in names) else 1)
    print("installed" if names[-1] in inst else "not-installed"); sys.exit(0 if names[-1] in inst else 1)
if me == "apt-cache":
    n = a[-1]; print(n + ":\n  Installed: (none)\n  Candidate: " + ("1.0-1" if n in avail else "(none)") + "\n  Version table:"); sys.exit(0)
if me == "apt-mark":
    if a[0] in ("showmanual", "showauto"):
        for p in a[1:]:
            if inst.get(p) == a[0][4:]: print(p)
        sys.exit(0)
    for p in a[1:]:
        if p in inst: inst[p] = a[0]
    save(); sys.exit(0)
opts = [x for x in a if x.startswith("-")]; words = [x for x in a if not x.startswith("-") and "::" not in x]
# A local .deb ("apt-get install ./trivy_0.76.2_amd64.deb") is its package, by name.
words = [os.path.basename(w).split("_")[0] if w.endswith(".deb") else w for w in words]
for w in words:
    if w not in avail and w in st.get("debs", []): avail.append(w)
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
chmod +x "${K}/aptsim"; for c in apt-get apt-cache dpkg-query apt-mark dpkg; do ln -sf ../aptsim "${K}/bin/${c}"; done
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
       "jpegoptim","optipng","pngquant","gifsicle","webp","imagemagick","poppler-utils",
       "nmap","bind9-dnsutils","whois","gitleaks","openjdk-21-jre-headless","java-common","perl","libnet-ssleay-perl",
       "libio-socket-ssl-perl","libxml-writer-perl","ruby","ruby-dev","build-essential","gcc","zlib1g-dev","python3-venv"]
# 24.04 names the time_t-renamed libraries with t64; a later release may not.
t64 = ["libatk1.0-0","libatk-bridge2.0-0","libcups2","libasound2","libcurl4"]
avail = cat + ([p + "t64" for p in t64] if rel == "noble" else t64)
st = {"installed": {"php8.5-imagick": "manual", "libcairo2": "auto", "linux-image-old": "auto", "reports": "manual", "ffmpeg": "manual", "libavcodec": "auto",
                    "ubuntu-standard": "manual", "bind9-dnsutils": "auto", "perl": "auto"},
      "debs": ["trivy"],
      "deps": {"php8.5-imagick": ["libcairo2"], "pdftk-java": ["default-jre-headless"], "libreoffice-writer-nogui": ["libreoffice-core-nogui"],
               "libreoffice-calc-nogui": ["libreoffice-core-nogui"], "ffmpeg": ["libavcodec"], "reports": ["ffmpeg"], "tesseract-ocr": ["tesseract-ocr-eng"],
               "ubuntu-standard": ["bind9-dnsutils", "perl"], "openjdk-21-jre-headless": ["java-common"], "build-essential": ["gcc"], "ruby-dev": ["ruby"]},
      "avail": avail,
      "bins": {"pandoc": ["pandoc"], "pdftk-java": ["pdftk"], "libreoffice-core-nogui": ["soffice"], "libavif-bin": ["avifenc"],
               "tesseract-ocr": ["tesseract"], "ffmpeg": ["ffmpeg", "ffprobe"], "nmap": ["nmap"], "bind9-dnsutils": ["dig"],
               "whois": ["whois"], "gitleaks": ["gitleaks"], "trivy": ["trivy"]}}
json.dump(st, open(K + "/state.json", "w"))
PY
    : > "${K}/calls"; rm -f "${K}/bin/pandoc" "${K}/bin/pdftk" "${K}/bin/soffice" "${K}/bin/avifenc" "${K}/bin/tesseract" "${K}/bin/nmap" "${K}/bin/whois" "${K}/bin/gitleaks" "${K}/bin/trivy"
    printf '#!/bin/sh\n' > "${K}/bin/dig"; chmod +x "${K}/bin/dig"
    rm -rf "${K}/opt" "${K}/localbin"; mkdir -p "${K}/localbin"
    printf '#!/bin/sh\n' > "${K}/bin/ffmpeg"; printf '#!/bin/sh\n' > "${K}/bin/ffprobe"; chmod +x "${K}/bin/ffmpeg" "${K}/bin/ffprobe"
}
cat > "${K}/run.sh" <<RUN
set -euo pipefail
RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""
export CIPI_LIB="${K}/lib" CIPI_CONFIG="${K}/cfg" CIPI_LOG="${K}/log" PKG_SIM="${K}"
export PATH="${K}/bin:${K}/localbin:\${PATH}"
source "${K}/lib/common.sh"; source "${K}/lib/package.sh"
# The fixed paths of the upstream entries, here.
_pkg_up_root()   { printf '%s' "${K}/opt"; }
_pkg_up_bindir() { printf '%s' "${K}/localbin"; }
_pkg_python()    { printf '%s' "${K}/pystub"; }
_pkg_lock_file() { printf '%s' "${K}/lock"; }
[[ -f "${K}/pins.sh" ]] && source "${K}/pins.sh"
cipi_notify() { echo "notify \$3" >> "${K}/calls"; }
show_help() { :; }
"\$@"
RUN
pk()  { bash "${K}/run.sh" package_command "$@" </dev/null 2>&1; }
inst() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1]+"/state.json")); print(" ".join(sorted(s["installed"])))' "$K"; }
mark() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1]+"/state.json")); print(s["installed"].get(sys.argv[2],"absent"))' "$K" "$1"; }

source "${LIB}/package.sh"
ids=" $(_pkg_ids | tr '\n' ' ')"
for want in image-optimizers avif ffmpeg imagemagick poppler-utils browsershot fonts-cjk pdftk libreoffice pandoc tesseract \
            sec-recon sec-gitleaks sec-nuclei sec-zap sec-nikto sec-wpscan sec-trivy sec-semgrep sec-checkov; do
    [[ "$ids" == *" ${want} "* ]] || fail "catalog misses ${want}"
done
[[ "$(_pkg_ids | wc -l | tr -d ' ')" == 20 ]] && pass "catalog: 20 entries, 7 of them upstream (${ids# })" || fail "catalog size: ${ids}"
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
jq -e '.packages | length == 20' <<< "$j" >/dev/null && pass "list --json: 20 entries" || fail "list json: ${j}"
jq -e '[.packages[] | select(.source == "ubuntu")] | length == 13' <<< "$j" >/dev/null && jq -e '.packages[] | select(.id == "sec-zap") | .source == "upstream" and .version == "2.17.0" and .installed_version == null and .outdated == false and .binaries == ["zap.sh"] and .missing == ["zap.sh"]' <<< "$j" >/dev/null \
    && pass "…source, version, installed_version, outdated: 13 from Ubuntu, sec-zap upstream 2.17.0" || fail "list json upstream: $(jq -c '.packages[] | select(.id=="sec-zap")' <<< "$j")"
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

# ── cipi package: the sec entries, upstream ones pinned ───────
# The pins of the release itself: every download has its hash, every git tag
# its commit. An entry without one cannot be installed — this fails until
# scripts/package-pins.sh has filled it, so a release cannot ship without.
nopin=""; badpin=""
while IFS='|' read -r id method ver _deps _build _cmds _desc; do
    case "$method" in
        zip|tar|deb|git)
            for arch in amd64 arm64; do
                pin=$(_pkg_up_pin "$id" "$arch"); url="${pin%%|*}"; h="${pin#*|}"
                if [[ -z "$pin" || -z "$h" ]]; then nopin="${nopin} ${id}/${arch}"; continue; fi
                if [[ "$method" == git ]]; then [[ "$h" =~ ^[0-9a-f]{40}$ ]] || badpin="${badpin} ${id}"
                else [[ "$h" =~ ^[0-9a-f]{64}$ && "$url" == https://*"${ver}"* ]] || badpin="${badpin} ${id}/${arch}"; fi
            done ;;
        venv|gem) [[ "$ver" =~ ^[0-9]+(\.[0-9]+)+$ ]] || badpin="${badpin} ${id}" ;;
        *) badpin="${badpin} ${id}(method ${method})" ;;
    esac
done <<< "$(_pkg_upstream)"
[[ -z "$badpin" ]] && pass "upstream pins are well-formed: https URLs of the pinned version, SHA-256, git commits" || fail "pins:${badpin}"
[[ -z "$nopin" ]] && pass "every upstream download has its pin" \
    || fail "no pin for:${nopin} — run scripts/package-pins.sh (needs network) and commit the result"
[[ "$(_pkg_up_pin sec-zap amd64)" == *"|efe799aaa3627db683b43f00c9c210aea0b75c00cc8f0a0f0434d12bb3ddde5a" \
   && "$(_pkg_up_pin sec-nikto arm64)" == *"|d201dac320fc5187eac75e723dd07a716196ec5a" \
   && "$(_pkg_up_pin sec-trivy arm64)" == *"/trivy_0.76.2_Linux-ARM64.deb|0c576cd78352a2084435d393ea31565a3637cc129dd052c422f1e72fd678ee76" ]] \
    && pass "…ZAP 2.17.0 (ZapVersions.xml), Nikto 2.6.1 (tag commit), Trivy 0.76.2 (the release's checksums)" || fail "known pins"
! _pkg_pins | cut -d'|' -f3 | grep -qv '^https://github\.com/' && pass "…every download is a GitHub release asset or tag (they stay where they are)" || fail "a pin outside github.com: $(_pkg_pins | cut -d'|' -f3 | grep -v '^https://github.com/')"

# The test's own world: a mirror for curl, git, gem and pip that make what
# the real ones would, and pins for the mirror's files.
M="${K}/mirror"; mkdir -p "$M/zap/ZAP_2.17.0"
printf '#!/bin/sh\necho nuclei\n' > "$M/nuclei"; chmod +x "$M/nuclei"; (cd "$M" && zip -q nuclei_3.11.1_linux_amd64.zip nuclei)
printf '#!/bin/sh\necho zap\n' > "$M/zap/ZAP_2.17.0/zap.sh"; chmod +x "$M/zap/ZAP_2.17.0/zap.sh"; tar -czf "$M/ZAP_2.17.0_Linux.tar.gz" -C "$M/zap" ZAP_2.17.0
printf 'not really a deb\n' > "$M/trivy_0.76.2_amd64.deb"
sha() { sha256sum "$1" | cut -c1-64; }
write_pins() {
    cat > "${K}/pins.sh" <<PINS
_pkg_pins() {
    cat <<'EOF'
sec-nuclei|amd64|https://mirror.test/nuclei_3.11.1_linux_amd64.zip|${1:-$(sha "$M/nuclei_3.11.1_linux_amd64.zip")}
sec-zap|all|https://mirror.test/ZAP_2.17.0_Linux.tar.gz|$(sha "$M/ZAP_2.17.0_Linux.tar.gz")
sec-nikto|all|https://mirror.test/nikto.git|d201dac320fc5187eac75e723dd07a716196ec5a
sec-trivy|amd64|https://mirror.test/trivy_0.76.2_amd64.deb|$(sha "$M/trivy_0.76.2_amd64.deb")
EOF
}
PINS
}
write_pins
cat > "${K}/bin/curl" <<'STUB'
#!/bin/bash
out=""; url=""
while [[ $# -gt 0 ]]; do case "$1" in -o) out="$2"; shift 2 ;; --proto|--retry|--retry-delay|--connect-timeout) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
echo "curl ${url}" >> "${PKG_SIM}/calls"
[[ "$url" == https://* && -f "${PKG_SIM}/mirror/${url##*/}" ]] || exit 22
cp "${PKG_SIM}/mirror/${url##*/}" "$out"
STUB
cat > "${K}/bin/git" <<'STUB'
#!/bin/bash
if [[ "$1" == "-C" ]]; then cat "${PKG_SIM}/git-head"; exit 0; fi
dest="${*: -1}"; mkdir -p "${dest}/program" "${dest}/.git"; printf 'print "nikto\\n";\n' > "${dest}/program/nikto.pl"
echo "git $*" >> "${PKG_SIM}/calls"
STUB
cat > "${K}/bin/gem" <<'STUB'
#!/bin/bash
echo "gem $*" >> "${PKG_SIM}/calls"
dir=""; bindir=""; while [[ $# -gt 0 ]]; do case "$1" in --install-dir) dir="$2"; shift 2 ;; --bindir) bindir="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "$bindir"; printf '#!/bin/sh\necho wpscan\n' > "${bindir}/wpscan"; chmod +x "${bindir}/wpscan"
STUB
cat > "${K}/pystub" <<'STUB'
#!/bin/bash
# python3 -m venv DIR: a pip that "installs" NAME==VERSION as DIR/bin/NAME
d="${*: -1}"; mkdir -p "${d}/bin"
cat > "${d}/bin/pip" <<PIP
#!/bin/bash
echo "pip \$*" >> "${PKG_SIM}/calls"
n="\${*: -1}"; printf '#!/bin/sh\n' > "${d}/bin/\${n%%==*}"; chmod +x "${d}/bin/\${n%%==*}"
PIP
chmod +x "${d}/bin/pip"
STUB
chmod +x "${K}/bin/curl" "${K}/bin/git" "${K}/bin/gem" "${K}/pystub"
echo d201dac320fc5187eac75e723dd07a716196ec5a > "${K}/git-head"
upj() { pk list --json | jq -c --arg i "$1" '.packages[] | select(.id == $i)'; }

pkg_world noble
jq -e '.installed == false and .partial == false and (.missing | index("nmap")) and (.missing | index("bind9-dnsutils") | not)' <<< "$(upj sec-recon)" >/dev/null \
    && pass "sec-recon on a server whose image has dig: not installed, not partial" || fail "sec-recon before: $(upj sec-recon)"
o=$(pk remove recon --yes); [[ $? -eq 0 && "$o" == *"sec-recon is not installed"* && "$(mark bind9-dnsutils)" == auto ]] && pass "a sec- entry answers to its name without the prefix (recon)" || fail "recon: ${o}"
o=$(pk install nmap --yes); [[ $? -eq 0 && "$(mark nmap)" == manual && "$(mark whois)" == manual && "$(mark bind9-dnsutils)" == auto ]] \
    && pass "sec-recon (asked as nmap): nmap and whois from Ubuntu; dig, already there for ubuntu-standard, stays its" || fail "sec-recon: ${o}"
o=$(pk remove sec-recon --yes); [[ $? -eq 0 && "$(mark nmap)" == absent && "$(mark whois)" == absent && "$(mark bind9-dnsutils)" == auto ]] \
    && pass "…removed: what it installed goes, dig stays (a tool another package pulled in is not the entry's)" || fail "sec-recon remove: ${o} / $(mark bind9-dnsutils)"

o=$(pk install nuclei); [[ $? -ne 0 && "$o" == *"never implicit"* && ! -e "${K}/opt/sec-nuclei" ]] && pass "upstream: nothing without --yes when there is no terminal" || fail "implicit upstream: ${o}"
o=$(pk install nuclei --yes); r=$?
[[ $r -eq 0 && "$(readlink "${K}/opt/sec-nuclei/current")" == 3.11.1 && "$(readlink "${K}/localbin/nuclei")" == "${K}/opt/sec-nuclei/current/nuclei" && -x "${K}/localbin/nuclei" ]] \
    && pass "install nuclei → sec-nuclei 3.11.1: in /opt/cipi/packages/sec-nuclei/3.11.1, current → it, linked into /usr/local/bin" || fail "nuclei (${r}): ${o}"
[[ "$o" == *"SHA-256 matches the pin"* && "$o" == *"hackly:check-binaries"* ]] && grep -q 'pin=' "${K}/opt/sec-nuclei/3.11.1/.cipi-package" \
    && pass "…the download checked against its pin, recorded with it" || fail "nuclei pin output: ${o}"
jq -e '.installed and .source == "upstream" and .installed_version == "3.11.1" and .outdated == false and .missing == []' <<< "$(upj sec-nuclei)" >/dev/null \
    && pass "…listed installed, upstream, 3.11.1" || fail "nuclei json: $(upj sec-nuclei)"
o=$(pk install sec-nuclei --yes); [[ $? -eq 0 && "$o" == *"already installed"* ]] && pass "…a second install is a no-op" || fail "nuclei again: ${o}"

mv "${K}/opt/sec-nuclei/3.11.1" "${K}/opt/sec-nuclei/3.10.0"; ln -sfn 3.10.0 "${K}/opt/sec-nuclei/current"
jq -e '.installed == false and .outdated and .installed_version == "3.10.0" and .version == "3.11.1" and .missing == []' <<< "$(upj sec-nuclei)" >/dev/null \
    && pass "an older version: outdated, not installed" || fail "outdated json: $(upj sec-nuclei)"
[[ "$(pk list)" == *"3.10.0 installed, 3.11.1 available"* ]] && pass "…and the list says so" || fail "outdated text"
o=$(pk install sec-nuclei --yes); [[ $? -eq 0 && "$(readlink "${K}/opt/sec-nuclei/current")" == 3.11.1 && ! -e "${K}/opt/sec-nuclei/3.10.0" && "$o" == *"replaces  3.10.0"* ]] \
    && pass "…install updates it: the new version, current swapped, the old one gone" || fail "update: ${o}"
o=$(pk remove nuclei --yes); [[ $? -eq 0 && ! -e "${K}/opt/sec-nuclei" && ! -e "${K}/localbin/nuclei" && "$o" == *"sec-nuclei removed"* ]] \
    && pass "remove: the directory and the link" || fail "remove nuclei: ${o}"
grep -q "notify package_remove" "${K}/calls" && pass "…package_remove notified" || fail "notify upstream remove"

cp "$M/nuclei_3.11.1_linux_amd64.zip" "$M/good.zip"; printf 'tampered' >> "$M/nuclei_3.11.1_linux_amd64.zip"
o=$(pk install nuclei --yes); r=$?
[[ $r -ne 0 && "$o" == *"Checksum mismatch"* && ! -e "${K}/opt/sec-nuclei/current" && ! -e "${K}/localbin/nuclei" && -z "$(ls -A "${K}/opt/sec-nuclei" 2>/dev/null)" ]] \
    && pass "a download that does not match its pin: refused, nothing left behind" || fail "mismatch (${r}): ${o}"
mv "$M/good.zip" "$M/nuclei_3.11.1_linux_amd64.zip"
write_pins " "; sed -i 's/| $/|/' "${K}/pins.sh"; : > "${K}/calls"
o=$(pk install nuclei --yes); [[ $? -ne 0 && "$o" == *"no verified checksum for sec-nuclei 3.11.1 (amd64)"* ]] && ! grep -q "^curl " "${K}/calls" \
    && pass "no pin: refused, nothing downloaded" || fail "no pin: ${o}"
write_pins

printf '#!/bin/sh\n' > "${K}/localbin/nuclei"; chmod +x "${K}/localbin/nuclei"
o=$(pk install nuclei --yes); [[ $? -ne 0 && "$o" == *"not installed by Cipi"* && ! -L "${K}/localbin/nuclei" ]] \
    && pass "a nuclei Cipi did not install (Hackly's own script): left alone" || fail "foreign: ${o}"
o=$(SUDO_USER=www-data bash "${K}/run.sh" package_command install nuclei --yes --force </dev/null 2>&1); [[ $? -ne 0 && ! -L "${K}/localbin/nuclei" ]] \
    && pass "…the panel's --force does not replace it" || fail "panel force foreign: ${o}"
o=$(pk install nuclei --yes --force); [[ $? -eq 0 && -L "${K}/localbin/nuclei" ]] && pass "…--force at the server's shell does" || fail "shell force foreign: ${o}"

pkg_world noble
o=$(pk install zap --yes); r=$?
[[ $r -eq 0 && "$(mark openjdk-21-jre-headless)" == manual && -x "${K}/localbin/zap.sh" && "$(readlink -f "${K}/localbin/zap.sh")" == "${K}/opt/sec-zap/2.17.0/zap.sh" ]] \
    && pass "sec-zap: the tarball unpacked, a Java runtime from Ubuntu, zap.sh linked" || fail "zap (${r}): ${o}"
grep -q '^apt=openjdk-21-jre-headless$' "${K}/opt/sec-zap/2.17.0/.cipi-package" && pass "…the runtime recorded as installed for it" || fail "zap record"
o=$(pk remove sec-zap --yes); [[ $? -eq 0 && "$(mark openjdk-21-jre-headless)" == absent && "$(mark java-common)" == absent && "$(mark linux-image-old)" == auto && ! -e "${K}/localbin/zap.sh" ]] \
    && pass "…removed with its Java runtime; older orphans stay" || fail "zap remove: ${o}"

o=$(pk install nikto --yes); [[ $? -eq 0 && "$(mark libxml-writer-perl)" == manual && -x "${K}/localbin/nikto" ]] \
    && grep -q "program/nikto.pl" "${K}/opt/sec-nikto/2.6.1/cipi-bin/nikto" && [[ ! -e "${K}/opt/sec-nikto/2.6.1/src/.git" ]] \
    && pass "sec-nikto: the 2.6.1 tag at its pinned commit, a perl wrapper, Perl modules from Ubuntu" || fail "nikto: ${o}"
[[ "$(mark perl)" == manual ]] && grep -q '^apt=.*perl' "${K}/opt/sec-nikto/2.6.1/.cipi-package" \
    && pass "…perl, there only as a dependency of ubuntu-standard, is kept for it too" || fail "perl hold: $(mark perl)"
pk remove nikto --yes >/dev/null
[[ "$(mark perl)" == auto && "$(mark libxml-writer-perl)" == absent ]] && pass "…and goes back to a dependency when nikto is removed (ubuntu-standard still needs it)" || fail "perl release: $(mark perl)"
echo 0000000000000000000000000000000000000000 > "${K}/git-head"
o=$(pk install nikto --yes); [[ $? -ne 0 && "$o" == *"not the pinned d201dac"* && ! -e "${K}/opt/sec-nikto/2.6.1" ]] \
    && pass "…a tag that moved to another commit: refused" || fail "nikto commit: ${o}"
echo d201dac320fc5187eac75e723dd07a716196ec5a > "${K}/git-head"

# Java that is there for pdftk: sec-zap keeps it, so removing pdftk does not take it away.
pkg_world noble
python3 -c 'import json,sys; p=sys.argv[1]+"/state.json"; s=json.load(open(p)); s["deps"]["default-jre-headless"]=["openjdk-21-jre-headless"]; json.dump(s,open(p,"w"))' "$K"
pk install pdftk --yes >/dev/null
[[ "$(mark openjdk-21-jre-headless)" == auto ]] || fail "world: java should come with pdftk"
o=$(pk install sec-zap --yes); [[ $? -eq 0 && "$(mark openjdk-21-jre-headless)" == manual ]] && grep -q '^apt=openjdk-21-jre-headless$' "${K}/opt/sec-zap/2.17.0/.cipi-package" \
    && pass "a Java runtime that came with pdftk: sec-zap keeps it for itself too" || fail "hold java: ${o} / $(mark openjdk-21-jre-headless)"
pk remove pdftk --yes >/dev/null
[[ "$(mark openjdk-21-jre-headless)" == manual && -x "${K}/localbin/zap.sh" ]] && pass "…removing pdftk leaves ZAP its Java" || fail "pdftk took java: $(mark openjdk-21-jre-headless)"

# A repair that fails keeps the record; a first install that fails leaves nothing.
rm -f "${K}/localbin/zap.sh"
[[ "$(upj sec-zap | jq -c '[.partial, .missing]')" == '[true,["zap.sh"]]' ]] && pass "a command that is gone: partial, and which" || fail "partial json: $(upj sec-zap)"
mkdir -p "${K}/opt/sec-zap/.work-2.17.0-999"; mv "$M/ZAP_2.17.0_Linux.tar.gz" "$M/zap.keep"
o=$(pk install sec-zap --yes); r=$?
[[ $r -ne 0 && "$o" == *"repairs   2.17.0"* ]] && grep -q '^apt=openjdk-21-jre-headless$' "${K}/opt/sec-zap/2.17.0/.cipi-package" && [[ ! -e "${K}/opt/sec-zap/.work-2.17.0-999" ]] \
    && pass "a repair whose download fails: still there, incomplete, with its record; the leftovers of a killed install are gone" || fail "repair fail (${r}): ${o}"
o=$(pk remove sec-zap --yes); [[ $? -eq 0 && "$(mark openjdk-21-jre-headless)" == absent && ! -e "${K}/opt/sec-zap" ]] \
    && pass "…and remove still takes its Java away" || fail "remove after failed repair: ${o}"
o=$(pk install sec-zap --yes); r=$?
[[ $r -ne 0 && "$(mark openjdk-21-jre-headless)" == absent && "$(mark java-common)" == absent && "$o" == *"was not installed"* && ! -e "${K}/opt/sec-zap/current" ]] \
    && pass "a first install whose download fails: the Java apt installed for it goes back" || fail "fresh fail (${r}): ${o} / $(mark openjdk-21-jre-headless)"
mv "$M/zap.keep" "$M/ZAP_2.17.0_Linux.tar.gz"
[[ -e "${K}/lock" ]] && grep -q '_pkg_lock; _pkg_install' "${LIB}/package.sh" && grep -q 'apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Use-Pty=0 "\$@" 9>&-' "${LIB}/package.sh" \
    && pass "install and remove take a lock, which apt's children do not inherit" || fail "lock"
( flock 8; sleep 3 ) 8>"${K}/lock" &
sleep 0.3; SECONDS=0; o=$(pk install pandoc --yes); r=$?; wait
[[ $r -eq 0 && $SECONDS -ge 2 && "$(mark pandoc)" == manual ]] && pass "…a second command waits for the first, then runs" || fail "lock wait (${r}, ${SECONDS}s): ${o}"
! grep -qE 'CIPI_PKG_ROOT|CIPI_PKG_BIN|PKG_PYTHON' "${LIB}/package.sh" && pass "where upstream entries live is not read from the environment" || fail "env overrides in package.sh"

pkg_world noble
o=$(pk install wpscan --yes); r=$?
[[ $r -eq 0 && "$(mark ruby)" == manual && "$(mark ruby-dev)" == absent && "$(mark build-essential)" == absent && "$(mark gcc)" == absent && -x "${K}/localbin/wpscan" ]] \
    && [[ "$o" == *"WPScan is not open source"* ]] && pass "sec-wpscan: built with ruby-dev and build-essential, which are gone after; Ruby stays; its licence is said" || fail "wpscan (${r}): ${o} / ruby-dev $(mark ruby-dev) gcc $(mark gcc)"
grep -q "GEM_HOME=${K}/opt/sec-wpscan/3.8.28" "${K}/opt/sec-wpscan/3.8.28/cipi-bin/wpscan" && grep -q "gem install .*wpscan -v 3.8.28" "${K}/calls" \
    && pass "…wpscan 3.8.28 in a gem home of its own, behind a wrapper" || fail "wpscan gem home"
o=$(pk install semgrep --yes); [[ $? -eq 0 && "$(mark python3-venv)" == manual && -x "${K}/localbin/semgrep" ]] && grep -q "pip install .*semgrep==1.185.0" "${K}/calls" \
    && pass "sec-semgrep: semgrep==1.185.0 in a virtualenv of its own" || fail "semgrep: ${o}"
grep -q "^PATH=\"${K}/opt/sec-semgrep/1.185.0/bin:\$PATH\" exec ${K}/opt/sec-semgrep/1.185.0/bin/semgrep \"\$@\"\$" "${K}/opt/sec-semgrep/1.185.0/cipi-bin/semgrep" \
    && [[ "$(readlink "${K}/localbin/semgrep")" == "${K}/opt/sec-semgrep/current/cipi-bin/semgrep" ]] \
    && pass "…started through a wrapper with its virtualenv first on PATH (pysemgrep, semgrep-core are its own)" || fail "semgrep wrapper: $(cat "${K}/opt/sec-semgrep/1.185.0/cipi-bin/semgrep" 2>&1)"
o=$(pk install sec-trivy --yes); [[ $? -eq 0 && "$(mark trivy)" == manual && "$(upj sec-trivy | jq -r .installed)" == true ]] \
    && pass "sec-trivy: the pinned .deb, installed by apt" || fail "trivy: ${o}"
o=$(pk remove trivy --yes); [[ $? -eq 0 && "$(mark trivy)" == absent ]] && pass "…and purged by apt" || fail "trivy remove: ${o}"
pkg_world noble; python3 -c 'import json,sys; p=sys.argv[1]+"/state.json"; s=json.load(open(p)); s["installed"]["trivy"]="manual"; json.dump(s,open(p,"w"))' "$K"
o=$(pk install trivy --yes); [[ $? -ne 0 && "$o" == *"trivy (apt)"* ]] && pass "a trivy apt has from elsewhere (Aqua's repository): left alone" || fail "foreign deb: ${o}"
o=$(pk install chromium-browser 2>&1); [[ "$o" != *"sec-"*"installed"* ]] && pass "…and resolving names never turns an unknown one into a sec entry" || fail "resolve"

sud=$(sed -n '/SUDOEOF/,/^SUDOEOF/p' "${LIB}/cipi-api-sudoers.sh")
grep -q 'cipi package install \*' <<< "$sud" && grep -q 'cipi package remove \*' <<< "$sud" && pass "the panel's sudoers: package install, remove" || fail "sudoers package"
grep -q '_help_note "Libraries and fonts: browsershot' "${ROOT}/cipi" && pass "help: the new entries" || fail "help package"
grep -q 'browsershot fonts-cjk pdftk libreoffice pandoc tesseract' "${LIB}/completion.sh" && pass "completion: the new entries" || fail "completion package"

# ── help, completion ─────────────────────────────────────────
grep -q '_help_cmd "cipi firewall block <ip|cidr>"' "${ROOT}/cipi" && grep -q '_help_cmd "cipi firewall status"' "${ROOT}/cipi" && pass "help: status, block" || fail "help"
grep -q 'sub="status list allow deny remove block unblock attempts"' "${LIB}/completion.sh" && pass "completion" || fail "completion"

# ── cipi nginx show|set|reset: an app's own directives ───────
# nginx and systemctl are stubs: `nginx -t` reads the files the vhosts
# include and calls a line starting with `boom` an unknown directive.
echo "-- nginx: an app's own directives"
NG="${TMP:?}/ngx"; mkdir -p "$NG/sites" "$NG/bin" "$NG/cfg" "$NG/log"
printf '%s\n' '{"shop":{"domain":"shop.test","aliases":[],"php":"8.4"},"docs":{"domain":"docs.test","custom":"true","docroot":"public","php":"8.4"},"front":{"domain":"front.test","php":"8.4","redirect":{"enabled":true,"to":"https://new.test","code":301}}}' > "$NG/apps.json"
cat > "$NG/bin/nginx" <<NGINXSTUB
#!/bin/bash
[[ "\${1:-}" == "-t" ]] || exit 0
[[ -f "$NG/broken" ]] && { echo "nginx: [emerg] unexpected end of file in /etc/nginx/nginx.conf:9" >&2; exit 1; }
rc=0
for v in "$NG"/sites/*; do
    [[ -f "\$v" ]] || continue
    while IFS= read -r inc; do
        [[ -f "\$inc" ]] || { echo "nginx: [emerg] open() \"\$inc\" failed (2: No such file or directory)" >&2; rc=1; continue; }
        n=\$(grep -n '^boom' "\$inc" | head -1 | cut -d: -f1)
        [[ -n "\$n" ]] && { echo "nginx: [emerg] unknown directive \"boom\" in \$inc:\$n" >&2; rc=1; }
    done < <(sed -n 's/^ *include \(.*\/custom\/.*\);\$/\1/p' "\$v")
done
(( rc == 0 )) && echo "nginx: configuration file /etc/nginx/nginx.conf test is successful" >&2
exit \$rc
NGINXSTUB
printf '#!/bin/bash\necho "$*" >> "%s/systemctl.log"\n' "$NG" > "$NG/bin/systemctl"
chmod +x "$NG/bin/nginx" "$NG/bin/systemctl"
cat > "$NG/h.sh" <<NGINXHARNESS
export CIPI_LIB="${LIB}" CIPI_CONFIG="$NG/cfg" CIPI_LOG="$NG/log" PATH="$NG/bin:\$PATH"
RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
source "${LIB}/common.sh" 2>/dev/null
vault_read() { cat "$NG/apps.json"; }
vault_write() { local t; t=\$(cat); printf '%s\n' "\$t" > "$NG/apps.json"; }
ensure_apps_json_api_access() { :; }; _ensure_nginx_octane_map() { :; }
app_log_dir_ensure() { :; }; app_log_links_default() { :; }
cipi_notify() { :; }; log_action() { echo "\$*" >> "$NG/actions.log"; }; curl() { return 0; }
source "${LIB}/routes.sh"
source "${LIB}/nginx.sh"
eval "\$(declare -f _create_nginx_vhost _create_nginx_vhost_http _nginx_vhost_tls nginx_custom_show | sed 's|/etc/nginx/sites-available/|$NG/sites/|g')"
_nginx_custom_dir() { echo "$NG/custom"; }
NGINXHARNESS
NH="source '$NG/h.sh';"
ngx() { bash -c "$NH nginx_command \"\$@\"" _ "$@" 2>&1; }
ngx_api() { SUDO_USER=www-data bash -c "$NH nginx_command \"\$@\"" _ "$@" 2>&1; }
b64() { printf '%s' "$1" | base64 -w0; }
for a in shop docs front; do bash -c "$NH _create_nginx_vhost $a $a.test 8.4" >/dev/null 2>&1; done
[[ -s "$NG/sites/shop" ]] && ! grep -q '/custom/' "$NG/sites/shop" && pass "nginx: no directives, no include in the vhost" || fail "nginx: an include without directives, or no vhost"
out=$(ngx show shop); grep -q 'No directives of its own' <<< "$out" && pass "nginx show: says there are none" || fail "nginx show empty: ${out}"
[[ "$(ngx show shop --json | jq -r '[.app, .config, .active, .bytes] | @tsv')" == $'shop\t\tfalse\t0' ]] && pass "nginx show --json: empty, not active" || fail "nginx show --json empty"

GOOD='client_max_body_size 512M;
location ^~ /downloads/ {
    add_header Cache-Control "public, max-age=31536000, immutable";
    access_log off;
}'
printf '%s\n' "$GOOD" > "$NG/good.conf"
out=$(ngx set shop --file="$NG/good.conf"); rc=$?
[[ $rc -eq 0 ]] && grep -q "saved and live" <<< "$out" && pass "nginx set --file: saved" || fail "nginx set: ${out}"
grep -qF "    include $NG/custom/shop.conf;" "$NG/sites/shop" && pass "nginx set: the vhost includes the app's file" || fail "nginx set: no include"
[[ "$(grep -n 'include .*custom/shop.conf' "$NG/sites/shop" | cut -d: -f1)" -lt "$(grep -n '^    location / {' "$NG/sites/shop" | head -1 | cut -d: -f1)" ]] && pass "nginx set: inside the server block, before location /" || fail "nginx set: include misplaced"
[[ "$(cat "$NG/custom/shop.conf")" == "$GOOD" ]] && pass "nginx set: the file holds the text as given" || fail "nginx set: file content"
[[ "$(jq -r '.shop.nginx_custom' "$NG/apps.json" | base64 -d)" == "$GOOD" ]] && pass "nginx set: kept in apps.json" || fail "nginx set: apps.json"
grep -q '^reload nginx' "$NG/systemctl.log" && pass "nginx set: nginx reloaded" || fail "nginx set: no reload"
[[ "$(ngx show shop --json | jq -r '[.active, (.config | length > 20)] | @tsv')" == $'true\ttrue' ]] && pass "nginx show --json: the text, active" || fail "nginx show --json after set"
grep -q 'No change' <<< "$(ngx set shop --file="$NG/good.conf")" && pass "nginx set: the same text twice changes nothing" || fail "nginx set: no-change"
bash -c "$NH _create_nginx_vhost shop shop.test 8.4" >/dev/null 2>&1
grep -qF "include $NG/custom/shop.conf;" "$NG/sites/shop" && pass "nginx: the directives survive a regeneration of the vhost" || fail "nginx: lost at regeneration"
printf '%s\n' 'gzip_static on;' | bash -c "$NH nginx_command set docs --file=-" >/dev/null 2>&1
grep -qF "include $NG/custom/docs.conf;" "$NG/sites/docs" && pass "nginx set --file=-: stdin, a custom app's vhost" || fail "nginx set stdin/custom"
ngx set front --file="$NG/good.conf" >/dev/null
grep -qF "include $NG/custom/front.conf;" "$NG/sites/front" && grep -q 'return 301' "$NG/sites/front" && pass "nginx: included under an app-wide redirect too" || fail "nginx: app redirect vhost"

# nginx refuses: nothing changes, and its reason is shown without the path
reloads=$(wc -l < "$NG/systemctl.log")
printf 'expires 1d;\nboom now;\n' > "$NG/bad.conf"
out=$(ngx set shop --file="$NG/bad.conf"); rc=$?
[[ $rc -ne 0 ]] && grep -q 'nginx refused the directives' <<< "$out" && pass "nginx set: refused by nginx -t" || fail "nginx set bad: rc=${rc} ${out}"
grep -q 'line 2: unknown directive "boom"' <<< "$out" && ! grep -q "$NG/custom" <<< "$out" && pass "nginx set: nginx's reason, by line, without the path" || fail "nginx reason: ${out}"
[[ "$(cat "$NG/custom/shop.conf")" == "$GOOD" && "$(jq -r '.shop.nginx_custom' "$NG/apps.json" | base64 -d)" == "$GOOD" ]] && pass "nginx set: refused, the file and apps.json are as before" || fail "nginx set: not reverted"
[[ "$(wc -l < "$NG/systemctl.log")" == "$reloads" ]] && pass "nginx set: refused, nginx not reloaded" || fail "nginx set: reloaded a refused config"
touch "$NG/broken"; out=$(ngx set shop --file="$NG/bad.conf"); rc=$?; rm -f "$NG/broken"
[[ $rc -ne 0 ]] && grep -q 'already invalid' <<< "$out" && [[ "$(cat "$NG/custom/shop.conf")" == "$GOOD" ]] && pass "nginx set: a configuration already broken is not touched" || fail "nginx preflight: ${out}"

# from the API: a subset, and never a file of the server
out=$(ngx_api set shop --file=/etc/shadow); [[ $? -ne 0 ]] && grep -q 'for the terminal' <<< "$out" && pass "API: --file refused" || fail "API --file: ${out}"
out=$(ngx_api edit shop); [[ $? -ne 0 ]] && grep -q 'for a terminal' <<< "$out" && pass "API: edit refused" || fail "API edit: ${out}"
out=$(ngx edit shop < /dev/null); [[ $? -ne 0 ]] && grep -q 'needs a terminal' <<< "$out" && pass "nginx edit: needs a terminal" || fail "edit no tty: ${out}"
out=$(ngx_api set shop --content-b64="$(b64 "$GOOD
expires 7d;")"); [[ $? -eq 0 ]] && grep -q 'expires 7d' "$NG/custom/shop.conf" && pass "API: allowed directives are saved" || fail "API set good: ${out}"
api_refused() {   # <text> <what>
    local o r; o=$(ngx_api set shop --content-b64="$(b64 "$1")"); r=$?
    if [[ $r -ne 0 ]] && grep -q 'Not accepted from the API' <<< "$o" && grep -q 'expires 7d' "$NG/custom/shop.conf"; then pass "API refuses: $2"; else fail "API took: $2 — ${o}"; fi
}
api_refused 'access_log /etc/cron.d/x;' "access_log to a path"
api_refused 'error_log /tmp/x;' "error_log"
api_refused '"error_log" /tmp/x;' "a quoted directive name"
api_refused 'include /etc/shadow;' "include"
api_refused 'server_name other.test;' "server_name"
api_refused 'listen 8080;' "listen"
api_refused 'location /x { proxy_pass http://127.0.0.1:6379; }' "proxy_pass"
api_refused 'location ~ \.php$ { fastcgi_pass unix:/run/php/other.sock; }' "fastcgi_pass"
api_refused 'root /etc;' "root outside the app"
api_refused 'alias /home/other/current/;' "alias in another app"
api_refused 'alias /home/shop/../other/;' "alias with .."
api_refused 'root /home/shop/$arg_x;' "root with a variable"
api_refused '}
server { listen 80; server_name other.test; }' "closing the server block"
api_refused '# {
}
listen 81;' "a brace hidden in a comment"
api_refused 'return 200 "x' "an open quote"
api_refused 'ssl_certificate /etc/cipi/x.pem;' "ssl_certificate"
api_refused 'auth_basic_user_file /etc/shadow;' "auth_basic_user_file"
api_refused 'made_up_directive on;' "a directive nobody listed"
out=$(ngx set shop --file="$NG/good.conf" --strict); [[ $? -eq 0 ]] && pass "nginx set --strict: the API's check, from the terminal" || fail "--strict good: ${out}"
printf 'access_log /var/log/x.log;\n' > "$NG/root.conf"
out=$(ngx set shop --file="$NG/root.conf" --strict); [[ $? -ne 0 ]] && pass "nginx set --strict: refuses what the API would" || fail "--strict bad"
out=$(ngx set shop --file="$NG/root.conf"); [[ $? -eq 0 ]] && grep -q 'access_log /var/log/x.log' "$NG/custom/shop.conf" && pass "nginx set at the terminal: the whole language" || fail "root set: ${out}"
out=$(ngx_api set shop --content-b64='not base64!'); [[ $? -ne 0 ]] && pass "API: --content-b64 must be base64" || fail "b64 check"
head -c 40000 /dev/zero | tr '\0' '#' > "$NG/big.conf"
out=$(ngx set shop --file="$NG/big.conf"); [[ $? -ne 0 ]] && grep -q 'too long' <<< "$out" && pass "nginx set: 32 KB at most" || fail "size: ${out}"
printf 'expires 1d;\001\n' > "$NG/ctl.conf"
out=$(ngx set shop --file="$NG/ctl.conf"); [[ $? -ne 0 ]] && grep -q 'control character' <<< "$out" && pass "nginx set: no control characters" || fail "control char: ${out}"

out=$(ngx_api reset shop); [[ $? -eq 0 ]] && [[ ! -e "$NG/custom/shop.conf" ]] && ! grep -q 'custom/shop.conf' "$NG/sites/shop" && [[ "$(jq -r '.shop | has("nginx_custom")' "$NG/apps.json")" == "false" ]] && pass "nginx reset: the file, the include and the setting are gone" || fail "nginx reset: ${out}"
grep -q 'no directives of its own' <<< "$(ngx reset shop)" && pass "nginx reset: nothing to remove is not an error" || fail "nginx reset twice"
out=$(ngx_api set shop --content-b64=""); [[ $? -eq 0 ]] && pass "API: an empty text is accepted (nothing to keep)" || fail "empty b64: ${out}"
out=$(ngx show nosuchapp); [[ $? -ne 0 ]] && grep -q 'not found' <<< "$out" && pass "nginx show: unknown app" || fail "unknown app: ${out}"
grep -q 'NGINX CUSTOM SET: shop' "$NG/actions.log" && grep -q 'NGINX CUSTOM RESET: shop' "$NG/actions.log" && pass "nginx: changes are logged" || fail "nginx: no log"
grep -q '"$(_nginx_custom_file "$app")"; reload_nginx' "${LIB}/app.sh" && pass "app delete removes the app's directives file" || fail "app delete keeps the file"
sud=$(sed -n '/SUDOEOF/,/^SUDOEOF/p' "${LIB}/cipi-api-sudoers.sh")
grep -q 'cipi nginx show \*' <<< "$sud" && grep -q 'cipi nginx set \*' <<< "$sud" && grep -q 'cipi nginx reset \*' <<< "$sud" && ! grep -q 'cipi nginx edit\|cipi nginx upgrade\|cipi nginx default-server' <<< "$sud" && pass "the panel's sudoers: nginx show, set, reset — nothing else of nginx" || fail "sudoers nginx"
grep -q '_help_cmd "cipi nginx edit <app>"' "${ROOT}/cipi" && grep -q 'sub="show edit set reset real-ip default-server upgrade security"' "${LIB}/completion.sh" && pass "help and completion: nginx show, edit, set, reset" || fail "help nginx"
bash -n "${LIB}/nginx-lint.sh" && sed -n "/<<'CIPINGINXLINT'/,/^CIPINGINXLINT\$/p" "${LIB}/nginx-lint.sh" | sed '1d;$d' | python3 -c "import ast, sys; ast.parse(sys.stdin.read())" 2>/dev/null && pass "nginx-lint.sh parses, and so does the Python in it" || fail "lint compile"
[[ ! -e "${LIB}/cipi-nginx-lint.py" ]] && ! ls "${LIB}"/*.py 2>/dev/null | grep -q nginx && pass "the check is in a lib/*.sh: self-update of any version installs it" || fail "the lint is a file self-update does not copy"
printf '%s' 'if ($http_user_agent ~* "(bot|crawler)") { return 403; }
location ~* \.(?:jpg|png)$ { expires 30d; }
types { application/wasm wasm; }
set $x "${host}y";
location @missing { return 404 "gone; really {no}"; }' | bash -c "source '${LIB}/nginx-lint.sh'; _nginx_custom_lint shop" >/dev/null && pass "lint: if, regex locations, types, \${var}, braces in quotes" || fail "lint good"

# ── deploy audit: the commit's subject, read from the app's clone ──
echo "-- deploy audit: commit subjects"
if command -v git >/dev/null 2>&1; then
    CT="${TMP:?}/ct"; mkdir -p "$CT/home/shop" "$CT/log"
    git init -q --bare "$CT/home/shop/.dep/repo" && git init -q "$CT/work"
    ( cd "$CT/work" && git config user.email t@t && git config user.name T \
        && echo 1 > a && git add a && git commit -q -m "Fix checkout tax rounding" \
        && echo 2 > a && git commit -q -am "$(printf 'feat: <b>bold</b> \033[31mred\033[0m\n\nbody')" \
        && echo 3 > a && git commit -q -am "$(head -c 300 /dev/zero | tr '\0' x)" \
        && git -c push.negotiate=false push -q "$CT/home/shop/.dep/repo" HEAD:refs/heads/main ) >/dev/null 2>&1
    S1=$(git -C "$CT/work" rev-parse HEAD~2); S2=$(git -C "$CT/work" rev-parse HEAD~1); S3=$(git -C "$CT/work" rev-parse HEAD)
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ'); i=0
    for c in "$S1" "$S2" "$S3" 0123456789abcdef0123456789abcdef01234567 ""; do
        i=$((i + 1)); printf '{"seq":%d,"ts":"%s","app":"shop","event":"published","release":"%d","commit":"%s"}\n' "$i" "$now" "$i" "$c"
    done > "$CT/log/deploys.jsonl"
    cat > "$CT/run.sh" <<AUDITRUN
set -uo pipefail
CIPI_LOG="$CT/log"; error() { echo "ERR \$*" >&2; }; warn() { echo "WARN \$*" >&2; }
app_as() { shift; ( cd / && "\$@" ); }
eval "\$(sed -n '/^_deploy_commit_subjects() {/,/^}/p;/^_deploy_audit_show() {/,/^}/p' "${LIB}/deploy.sh")"
_deploy_app_home() { echo "$CT/home/\$1"; }
ARG_json=true ARG_days=90 _deploy_audit_show shop
AUDITRUN
    js=$(bash "$CT/run.sh" 2>&1)
    [[ "$(jq -r '.[0].subject' <<< "$js")" == "Fix checkout tax rounding" ]] && pass "audit --json: each record carries its commit's subject" || fail "audit subject: ${js:0:200}"
    [[ "$(jq -r '.[1].subject' <<< "$js")" == "feat: <b>bold</b>  [31mred [0m" ]] && pass "audit --json: the first line only, control characters taken out" || fail "audit subject 2: $(jq -c '.[1].subject' <<< "$js")"
    [[ "$(jq -r '.[2].subject | length' <<< "$js")" == "200" ]] && pass "audit --json: a subject is cut at 200 characters" || fail "audit subject length"
    [[ "$(jq -c '[.[3], .[4]] | map(has("subject"))' <<< "$js")" == "[false,false]" ]] && pass "audit --json: a commit the clone does not have, or no commit: no subject" || fail "audit missing commit"
    [[ "$(jq -r 'length' <<< "$js")" == "5" && "$(jq -r '.[0] | has("seq") and has("commit")' <<< "$js")" == "true" ]] && pass "audit --json: the records are otherwise as they were" || fail "audit records changed"
    mv "$CT/home/shop/.dep" "$CT/home/shop/.dep-x"
    [[ "$(bash "$CT/run.sh" 2>&1 | jq -c 'map(has("subject")) | any')" == "false" ]] && pass "audit --json: without a clone, the records and no subject" || fail "audit without clone"
else
    echo "  (git not installed: commit subjects not checked)"
fi

# ── cipi nginx real-ip: the visitor's address behind Cloudflare ──
# curl answers with a list of Cloudflare's ranges; nginx, systemctl and
# fail2ban-client are stubs. Every path Zero Trust's code writes is redirected.
echo "-- nginx real-ip: behind Cloudflare"
RI="${TMP:?}/realip"; mkdir -p "$RI/bin" "$RI/nginx/conf.d" "$RI/cron" "$RI/f2b" "$RI/ips" "$RI/cfg" "$RI/log"
printf '%s\n' '{"result":{"ipv4_cidrs":["173.245.48.0/20","103.21.244.0/22"],"ipv6_cidrs":["2400:cb00::/32"]},"success":true}' > "$RI/cf.json"
cat > "$RI/bin/curl" <<CURLSTUB
#!/bin/bash
echo "\$*" >> "$RI/curl.log"
[[ -f "$RI/offline" ]] && exit 6
cat "$RI/cf.json"
CURLSTUB
cat > "$RI/bin/nginx" <<NGINXSTUB2
#!/bin/bash
[[ "\${1:-}" == "-t" ]] || exit 0
if [[ -f "$RI/broken" ]] || { [[ -f "$RI/refuse-realip" ]] && [[ -f "$RI/nginx/conf.d/cipi-cloudflare-realip.conf" ]]; }; then
    echo "nginx: [emerg] \"real_ip_header\" directive is duplicate in $RI/nginx/conf.d/cipi-cloudflare-realip.conf:3" >&2
    exit 1
fi
echo "nginx: configuration file test is successful" >&2
NGINXSTUB2
cat > "$RI/bin/systemctl" <<SYSTEMCTLSTUB
#!/bin/bash
echo "\$*" >> "$RI/systemctl.log"
if [[ "\$1" == "is-active" ]]; then
    for a in "\$@"; do [[ -f "$RI/active-\$a" ]] && exit 0; done
    exit 3
fi
exit 0
SYSTEMCTLSTUB
printf '#!/bin/bash\necho "$*" >> "%s/f2b.log"\n' "$RI" > "$RI/bin/fail2ban-client"
chmod +x "$RI/bin/"*
echo '{}' > "$RI/zt.json"
cat > "$RI/h.sh" <<REALIPHARNESS
export CIPI_LIB="${LIB}" CIPI_CONFIG="$RI/cfg" CIPI_LOG="$RI/log" PATH="$RI/bin:\$PATH"
export ZT_REALIP="$RI/nginx/conf.d/cipi-cloudflare-realip.conf" ZT_F2B="$RI/f2b/cipi-zt.conf" ZT_IPS_DIR="$RI/ips"
export ZT_CS_WL="$RI/crowdsec/s02-enrich/cipi-cloudflare-whitelists.yaml" ZT_CRON="$RI/cron/cipi-zt" NGINX_REALIP_CRON="$RI/cron/cipi-nginx-realip"
RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
source "${LIB}/common.sh" 2>/dev/null
vault_read() { cat "$RI/\$1" 2>/dev/null; }
vault_write() { cat > "$RI/\$1"; }
cipi_notify() { :; }; log_action() { echo "\$*" >> "$RI/actions.log"; }; log_event() { :; }
source "${LIB}/nginx.sh"
REALIPHARNESS
RH="source '$RI/h.sh';"
rip() { bash -c "$RH nginx_command real-ip \"\$@\"" _ "$@" 2>&1 < /dev/null; }
CONF="$RI/nginx/conf.d/cipi-cloudflare-realip.conf"

[[ "$(rip status --json | jq -c '[.enabled, .provider, .ranges]')" == '[false,null,0]' ]] && pass "real-ip status: off" || fail "real-ip status off: $(rip status --json)"
grep -q 'cipi nginx real-ip cloudflare' <<< "$(rip status)" && pass "real-ip status: says how to turn it on" || fail "real-ip status text"
out=$(rip cloudflare); rc=$?
[[ $rc -eq 0 ]] && grep -q "takes the visitor's address from Cloudflare (3 ranges" <<< "$out" && pass "real-ip cloudflare: on" || fail "real-ip enable: ${out}"
grep -qx 'real_ip_header CF-Connecting-IP;' "$CONF" && grep -qx 'set_real_ip_from 173.245.48.0/20;' "$CONF" && grep -qx 'set_real_ip_from 2400:cb00::/32;' "$CONF" && [[ "$(grep -c '^set_real_ip_from ' "$CONF")" == 3 ]] \
    && pass "real-ip: CF-Connecting-IP is believed from Cloudflare's IPv4 and IPv6 ranges, and from nowhere else" || fail "real-ip conf: $(cat "$CONF" 2>&1)"
grep -q 'api.cloudflare.com/client/v4/ips' "$RI/curl.log" && ! grep -qi 'authorization\|bearer' "$RI/curl.log" && pass "real-ip: the ranges are Cloudflare's public list, no token" || fail "real-ip fetch"
grep -q 'ignoreip = 127.0.0.1/8 ::1 173.245.48.0/20 103.21.244.0/22 2400:cb00::/32' "$RI/f2b/cipi-zt.conf" && pass "real-ip: fail2ban never bans Cloudflare's ranges" || fail "real-ip fail2ban"
grep -q 'cipi nginx real-ip refresh' "$RI/cron/cipi-nginx-realip" && pass "real-ip: the ranges are refreshed every night" || fail "real-ip cron"
grep -q '^reload nginx' "$RI/systemctl.log" && pass "real-ip: nginx reloaded" || fail "real-ip reload"
[[ "$(rip status --json | jq -c '[.enabled, .provider, .header, .kept_by, .ranges, .nightly_refresh]')" == '[true,"cloudflare","CF-Connecting-IP","real-ip",3,true]' ]] && pass "real-ip status --json: on, Cloudflare, 3 ranges" || fail "real-ip status on: $(rip status --json)"
grep -q 'Already on' <<< "$(rip cloudflare)" && pass "real-ip cloudflare twice: already on, ranges refreshed" || fail "real-ip twice"

# Cloudflare adds a range; the server is offline at the next refresh, then back.
printf '%s\n' '{"result":{"ipv4_cidrs":["173.245.48.0/20","103.21.244.0/22","104.16.0.0/13"],"ipv6_cidrs":["2400:cb00::/32"]}}' > "$RI/cf.json"
touch "$RI/offline"; rip refresh >/dev/null; rm -f "$RI/offline"
[[ "$(grep -c '^set_real_ip_from ' "$CONF")" == 3 ]] && pass "real-ip refresh: offline, the previous ranges stay" || fail "real-ip refresh offline"
rip refresh >/dev/null
[[ "$(grep -c '^set_real_ip_from ' "$CONF")" == 4 ]] && grep -q '104.16.0.0/13' "$RI/f2b/cipi-zt.conf" && pass "real-ip refresh: a new range reaches nginx and fail2ban" || fail "real-ip refresh"

# off: asked for when a ban could then hit Cloudflare itself
touch "$RI/active-fail2ban"
out=$(rip off); rc=$?
[[ $rc -ne 0 ]] && grep -q 'Pass --yes' <<< "$out" && grep -q 'could ban Cloudflare itself' <<< "$out" && [[ -s "$CONF" ]] && pass "real-ip off: says what it risks, and needs --yes without a terminal" || fail "real-ip off guard: ${out}"
out=$(rip off --yes); rc=$?
[[ $rc -eq 0 ]] && [[ ! -e "$CONF" && ! -e "$RI/f2b/cipi-zt.conf" && ! -e "$RI/cron/cipi-nginx-realip" ]] && pass "real-ip off --yes: the nginx file, the fail2ban list and the nightly refresh are gone" || fail "real-ip off: ${out}"
[[ "$(rip status --json | jq -r .enabled)" == "false" ]] && grep -q 'already off' <<< "$(rip off --yes)" && pass "real-ip off twice: already off" || fail "real-ip off twice"
grep -q 'nothing to refresh' <<< "$(rip refresh)" && [[ ! -e "$CONF" ]] && pass "real-ip refresh while off writes nothing" || fail "real-ip refresh off"
rm -f "$RI/active-fail2ban"

# nginx refuses, or was already broken: nothing is left behind
touch "$RI/refuse-realip"; out=$(rip cloudflare); rc=$?; rm -f "$RI/refuse-realip"
[[ $rc -ne 0 ]] && grep -q 'nginx refused the configuration' <<< "$out" && grep -q 'directive is duplicate' <<< "$out" && [[ ! -e "$CONF" && ! -e "$RI/cron/cipi-nginx-realip" ]] && pass "real-ip: refused by nginx -t, the file is taken back and nginx's reason shown" || fail "real-ip refused: ${out}"
touch "$RI/broken"; out=$(rip cloudflare); rc=$?; rm -f "$RI/broken"
[[ $rc -ne 0 ]] && grep -q 'already invalid' <<< "$out" && [[ ! -e "$CONF" ]] && pass "real-ip: a configuration already broken is not touched" || fail "real-ip preflight: ${out}"
rm -f "$RI/ips/v4" "$RI/ips/v6"; touch "$RI/offline"; out=$(rip cloudflare); rc=$?; rm -f "$RI/offline"
[[ $rc -ne 0 ]] && grep -q "Could not fetch Cloudflare's ranges" <<< "$out" && [[ ! -e "$CONF" ]] && pass "real-ip: no ranges to trust, nothing written" || fail "real-ip offline: ${out}"
printf 'set_real_ip_from 10.0.0.0/8;\nreal_ip_header X-Forwarded-For;\n' > "$RI/nginx/conf.d/proxy.conf"
out=$(rip cloudflare); rc=$?
[[ $rc -ne 0 ]] && grep -q 'Cipi did not write' <<< "$out" && [[ ! -e "$CONF" ]] && [[ "$(rip status --json | jq -c '[.enabled, .provider, .kept_by]')" == '[true,null,"other"]' ]] && pass "real-ip: a real_ip configuration of someone else is left alone, and said" || fail "real-ip other: ${out}"
rm -f "$RI/nginx/conf.d/proxy.conf"

# with Zero Trust: one file for both
rip cloudflare >/dev/null; echo '{"enabled":true}' > "$RI/zt.json"
[[ "$(rip status --json | jq -r .kept_by)" == "both" ]] && pass "real-ip with Zero Trust: kept by both" || fail "real-ip both"
out=$(rip off --yes); rc=$?
[[ $rc -eq 0 ]] && grep -q "stays on until 'cipi zt disable'" <<< "$out" && [[ -s "$CONF" ]] && [[ "$(rip status --json | jq -r .kept_by)" == "zero-trust" ]] && pass "real-ip off under Zero Trust: the tunnel needs it, it stays" || fail "real-ip off zt: ${out}"
echo '{}' > "$RI/zt.json"
grep -q 'if \[\[ -f "$NGINX_REALIP_CRON" \]\]; then' "${LIB}/zt.sh" && grep -A4 'if \[\[ -f "$NGINX_REALIP_CRON" \]\]; then' "${LIB}/zt.sh" | grep -q 'rm -f "$ZT_CRON"$' && pass "cipi zt disable leaves Cloudflare's real_ip when real-ip turned it on" || fail "zt disable would remove real-ip"
grep -q 'cipi nginx real-ip cloudflare' "${LIB}/crowdsec.sh" && grep -q 'cipi nginx real-ip cloudflare' "${LIB}/firewall.sh" && pass "CrowdSec's refusal behind a proxy names the command" || fail "crowdsec hint"
grep -q '_help_cmd "cipi nginx real-ip cloudflare"' "${ROOT}/cipi" && grep -q 'real-ip)        sub="cloudflare status refresh off"' "${LIB}/completion.sh" && pass "help and completion: nginx real-ip" || fail "help real-ip"
# 5.15.0 lets the panel's Firewall tab run it, each form spelled out (verify-5.15.0.sh).
sud=$(sed -n '/SUDOEOF/,/^SUDOEOF/p' "${LIB}/cipi-api-sudoers.sh"); grep -qE 'real-ip (\*|off,|off$)' <<< "$sud" && fail "the panel's sudoers reach real-ip too widely" || pass "real-ip in the panel's sudoers: only its spelled-out forms"

# ── a server whose port 3306 runs MySQL: messages say mysql ──
echo "-- db: the engine a message names"
dbshown() {   # <flavor> <engine> [always] — with SUDO_USER from the environment
    bash -c "db_mysql_flavor() { echo '$1'; }; $(sed -n '/^_db_engine_shown() {/,/^}/p' "${LIB}/db.sh"); _db_engine_shown '$2' '${3:-}'"
}
[[ "$(dbshown mysql mariadb)" == "mysql" && "$(dbshown mariadb mariadb)" == "mariadb" && "$(dbshown mysql pgsql)" == "pgsql" ]] && pass "db messages: mysql on a server that runs MySQL, the id everywhere else" || fail "db engine shown"
[[ "$(SUDO_USER=www-data dbshown mysql mariadb)" == "mariadb" && "$(SUDO_USER=www-data dbshown mysql mariadb always)" == "mysql" ]] && pass "db messages: through the API the id its parser reads; a notification says mysql" || fail "db engine shown via API"
grep -qF 'Engine: ${CYAN}$(_db_engine_shown "$engine")${NC}  Database: ${CYAN}${name}${NC}' "${LIB}/db.sh" && ! grep -q 'Engine: ${CYAN}${engine}${NC}' "${LIB}/db.sh" && pass "db create: the line that said 'Engine: mariadb' on MySQL" || fail "db create line"
[[ "$(grep -c '_db_engine_shown "$engine"' "${LIB}/db.sh")" -ge 17 ]] && pass "db list, link, delete, backup, restore, password: the same word" || fail "db other messages"
bash -c "$(sed -n '/^db_normalize_engine() {/,/^}/p' "${LIB}/db.sh"); [[ \"\$(db_normalize_engine mysql)\" == mariadb ]]" && pass "--engine=mysql is the name the messages use" || fail "normalize mysql"

# ── cipi help: the commands in alphabetical order ────────────
echo "-- help: alphabetical order"
HC="${TMP:?}/helpcipi"; mkdir -p "$HC"
sed "s|readonly CIPI_LIB=\"/opt/cipi/lib\"|readonly CIPI_LIB=\"${LIB}\"|" "${ROOT}/cipi" > "$HC/cipi"
hp=$(CIPI_NO_PAGER=1 COLUMNS=120 bash "$HC/cipi" help 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | sed -n '/^Available commands:$/,$p')
alone=$(awk '/^ [a-z]/{exit} /^  [a-z]/{print $1}' <<< "$hp")
[[ "$(wc -l <<< "$alone")" -ge 5 && "$alone" == "$(LC_ALL=C sort <<< "$alone")" ]] && grep -qx 'status' <<< "$alone" \
    && pass "cipi help: the commands that stand alone, in alphabetical order" || fail "help standalone order: $(tr '\n' ' ' <<< "$alone")"
ns=$(grep '^ [a-z]' <<< "$hp" | sed 's/^ //')
[[ "$(wc -l <<< "$ns")" -ge 40 && "$ns" == "$(LC_ALL=C sort <<< "$ns")" && "$(sort -u <<< "$ns" | wc -l)" == "$(wc -l <<< "$ns")" ]] \
    && pass "cipi help: the namespaces in alphabetical order, each once ($(wc -l <<< "$ns"))" || fail "help namespace order: $(tr '\n' ' ' <<< "$ns")"
bad=$(LC_ALL=C awk '
    /^ [a-z]/ { ns = $1; prev = ""; next }
    ns != "" && /^  [a-z]/ {
        name = substr($0, 3); sub(/  +.*$/, "", name)
        if (name !~ ("^" ns "( |$)")) print ns ": " name " is not of this namespace"
        if (prev != "" && name < prev) print ns ": " name " after " prev
        prev = name
    }' <<< "$hp")
[[ -z "$bad" ]] && pass "cipi help: inside a namespace, its own commands, in alphabetical order" || fail "help order inside a namespace: $(head -5 <<< "$bad" | tr '\n' ';')"
n=$(grep -c '^  [a-z]' <<< "$hp")
(( n > 300 )) && [[ "$(grep '^  [a-z]' <<< "$hp" | sort -u | wc -l)" == "$n" ]] && pass "cipi help: still every command, each once (${n})" || fail "help lost or doubled commands (${n})"
grep -qE '^  nginx real-ip cloudflare  ' <<< "$hp" && grep -qE '^  nginx show  ' <<< "$hp" && pass "cipi help: nginx real-ip and nginx show are in the list" || fail "help: nginx entries"
tl=$(bash "$HC/cipi" help nope 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | sed -n 's/^  Topics: //p' | tr ' ' '\n' | grep .)
[[ "$(wc -l <<< "$tl")" -ge 40 && "$tl" == "$(LC_ALL=C sort <<< "$tl")" ]] && pass "unknown help topic: the topics in alphabetical order" || fail "topics order: $(tr '\n' ' ' <<< "$tl")"
first=$(CIPI_NO_PAGER=1 bash "$HC/cipi" help all 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -m1 -A1 '^ [A-Z]' | head -1)
[[ "$first" == " Server" ]] && pass "cipi help all keeps its own order: the server first" || fail "help all starts with: ${first}"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]

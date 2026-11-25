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
#  - the panel's sudoers, and compliance reading the GUI's 2FA policy.
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

# ── help, completion ─────────────────────────────────────────
grep -q '_help_cmd "cipi firewall block <ip|cidr>"' "${ROOT}/cipi" && grep -q '_help_cmd "cipi firewall status"' "${ROOT}/cipi" && pass "help: status, block" || fail "help"
grep -q 'sub="status list allow deny remove block unblock attempts"' "${LIB}/completion.sh" && pass "completion" || fail "completion"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]

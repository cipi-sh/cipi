#!/bin/bash
#############################################
# Cipi Migration 4.3.0
# - Upgrade fail2ban: progressive banning,
#   recidive jail, stricter limits
#############################################

set -e

echo "Upgrading fail2ban configuration..."

cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 86400
findtime = 3600
maxretry = 3
banaction = iptables-multiport
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 604800

[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
maxretry = 3

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
bantime = 604800
findtime = 86400
maxretry = 3
EOF

systemctl restart fail2ban

echo "Migration 4.3.0 complete"

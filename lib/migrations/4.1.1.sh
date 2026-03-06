#!/bin/bash
#############################################
# Cipi Migration 4.1.1
# - PAM auth notifications (sudo + SSH login alerts)
#############################################

set -e

echo "Setting up PAM auth notifications..."

if [[ -x /usr/local/bin/cipi-auth-notify ]]; then
    if ! grep -q 'cipi-auth-notify' /etc/pam.d/sudo 2>/dev/null; then
        echo 'session optional pam_exec.so seteuid /usr/local/bin/cipi-auth-notify' >> /etc/pam.d/sudo
        echo "  PAM sudo notification added"
    else
        echo "  PAM sudo notification already configured — skip"
    fi
    if ! grep -q 'cipi-auth-notify' /etc/pam.d/sshd 2>/dev/null; then
        echo 'session optional pam_exec.so seteuid /usr/local/bin/cipi-auth-notify' >> /etc/pam.d/sshd
        echo "  PAM sshd notification added"
    else
        echo "  PAM sshd notification already configured — skip"
    fi
    echo "PAM auth notifications configured"
else
    echo "cipi-auth-notify not found — skip (will be installed on next self-update)"
fi

echo "Migration 4.1.1 complete"

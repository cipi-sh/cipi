#!/bin/sh
#############################################
# Cipi — the server's SSH keys, for sshd
#
# sshd runs this (AuthorizedKeysCommand, as the cipi user) when someone logs in
# as an app user, and accepts any key it prints. It prints the keys of the cipi
# user — the ones `cipi ssh list|add|remove` manages — so whoever administers
# the server can open a shell as any app with the key they already use, whether
# or not that app accepts SSH from outside.
#
# Read at every login: a key removed with `cipi ssh remove` stops working for
# the apps in the same moment, and there is no copy to keep in step.
#
# Those keys already reach root (cipi has sudo): this hands out nothing new.
# Installed as /usr/local/bin/cipi-ssh-keys, root:root 0755 — sshd refuses a
# command that anyone else can write.
#############################################
f=/home/cipi/.ssh/authorized_keys
[ -r "$f" ] || exit 0
exec cat "$f"

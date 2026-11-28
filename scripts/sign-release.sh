#!/bin/bash
#############################################
# Sign a Cipi release: an annotated tag v<version> on the commit of the
# branch, signed with the maintainer's SSH key, pushed to origin.
#
# Servers with `cipi self-update policy --verify=on` install a release only
# when this tag exists, points at the tip of the branch they update from, and
# is signed by a key of their release-signers. Run it after the release is
# merged into `latest`, from a checkout of that commit:
#
#   git checkout latest && git pull
#   scripts/sign-release.sh ~/.ssh/cipi_release_signing.pub
#
# The key's public half must be in release-signers (and its fingerprint on
# cipi.sh) before the first release it signs. Keep the private half off
# GitHub — a hardware key (ssh-keygen -t ed25519-sk) is best: an account
# that is taken over cannot sign.
#############################################
set -euo pipefail

key="${1:-}"
[[ -n "$key" && -f "$key" ]] || { echo "Usage: scripts/sign-release.sh <signing key .pub>" >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)"
version=$(tr -d '[:space:]' < version.md)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version.md: '${version}' is not a version" >&2; exit 1; }
tag="v${version}"
[[ -z "$(git status --porcelain)" ]] || { echo "The working tree is not clean" >&2; exit 1; }
grep -qF "$(awk '{print $2}' "$key")" release-signers || { echo "That key is not in release-signers: servers would refuse what it signs" >&2; exit 1; }

git -c gpg.format=ssh -c "user.signingkey=${key}" tag -s "$tag" -m "Cipi ${version}"
git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile=release-signers verify-tag "$tag"
git push origin "refs/tags/${tag}"
echo "Signed and pushed ${tag} ($(git rev-parse --short "${tag}^{commit}"))"

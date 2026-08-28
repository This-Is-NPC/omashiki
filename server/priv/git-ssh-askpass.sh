#!/bin/sh
# Host-side OpenSSH SSH_ASKPASS helper for Omashiki git remotes.
# Reads the passphrase from the Omashiki process environment, never from argv.
set -eu
printf '%s\n' "${OMASHIKI_GIT_ASKPASS_PASSPHRASE}"

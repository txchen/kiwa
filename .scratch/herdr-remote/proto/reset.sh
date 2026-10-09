#!/usr/bin/env bash
# Stop the remote-side Kiwa and Herdr servers so each run starts fresh.
. /tmp/rproto/remote/env.sh
kiwa kill-server >/dev/null 2>&1 || true
herdr server stop >/dev/null 2>&1 || true
sleep 0.5
rm -rf "$XDG_STATE_HOME"/herdr "$XDG_STATE_HOME"/kiwa
rm -rf "$XDG_CONFIG_HOME"/herdr/session*

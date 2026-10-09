#!/usr/bin/env bash
# Builds an isolated "remote host" on 127.0.0.1: a user-mode sshd on :2222,
# separate HOMEs for the local and remote sides, and an ssh alias `lagbox`
# that goes through lagproxy.py on :2223.
set -euo pipefail
P=$(cd "$(dirname "$0")" && pwd)
R=/tmp/rproto
[ -f "$R/etc/sshd.pid" ] && kill "$(cat "$R/etc/sshd.pid")" 2>/dev/null || true
rm -rf "$R"
mkdir -p "$R"/{remote,local}/.ssh "$R"/run/{remote,local} "$R"/etc
chmod 700 "$R"/run/*
ssh-keygen -q -t ed25519 -N '' -f "$R/etc/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$R/local/.ssh/id_ed25519"
cp "$R/local/.ssh/id_ed25519.pub" "$R/etc/authorized_keys"
chmod 600 "$R/etc/authorized_keys"

cat >"$R/remote/env.sh" <<EOF
export HOME=$R/remote XDG_RUNTIME_DIR=$R/run/remote XDG_CONFIG_HOME=$R/remote/.config
export XDG_STATE_HOME=$R/remote/.state XDG_DATA_HOME=$R/remote/.data
export PATH=$P/bin:$P/kiwa-out/bin:/usr/bin:/bin SHELL=/bin/bash TERM=\${TERM:-xterm-256color}
EOF
printf "PS1='\$ '\nunset PROMPT_COMMAND\n" >"$R/remote/.bashrc"
cp "$R/remote/.bashrc" "$R/local/.bashrc"
for side in remote local; do
  mkdir -p "$R/$side/.config/herdr"
  echo 'onboarding = false' >"$R/$side/.config/herdr/config.toml"
done

cat >"$R/etc/sshd_config" <<EOF
Port 2222
ListenAddress 127.0.0.1
HostKey $R/etc/host_key
AuthorizedKeysFile $R/etc/authorized_keys
PidFile $R/etc/sshd.pid
UsePAM no
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PrintMotd no
PrintLastLog no
AcceptEnv TERM COLORTERM
ForceCommand $R/remote/entry.sh
EOF

cat >"$R/remote/entry.sh" <<'ENTRY'
#!/bin/bash
. /tmp/rproto/remote/env.sh
cd "$HOME"
exec /bin/bash -c "${SSH_ORIGINAL_COMMAND:-exec /bin/bash -i}"
ENTRY
chmod +x "$R/remote/entry.sh"
cat >"$R/local/.ssh/config" <<EOF
Host lagbox
  HostName 127.0.0.1
  Port 2223
  User $(id -un)
  IdentityFile $R/local/.ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
EOF
chmod 600 "$R/local/.ssh/config"

cat >"$R/local/env.sh" <<EOF
export HOME=$R/local XDG_RUNTIME_DIR=$R/run/local XDG_CONFIG_HOME=$R/local/.config
export XDG_STATE_HOME=$R/local/.state XDG_DATA_HOME=$R/local/.data
export PATH=$P/bin:$P/kiwa-out/bin:/usr/bin:/bin SHELL=/bin/bash
EOF
/usr/bin/sshd -f "$R/etc/sshd_config" -E "$R/etc/sshd.log"
echo "sshd pid $(cat "$R/etc/sshd.pid")"

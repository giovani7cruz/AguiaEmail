#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST=/opt/aguia/email
test "$(id -u)" = 0 || { echo 'Execute como root.'; exit 1; }
id aguia >/dev/null
test -x "$ROOT/bin/AguiaEmail"
test -r /etc/ssl/certs/ca-certificates.crt
install -d -o aguia -g aguia -m 750 "$DEST"
if test -e "$DEST/AguiaEmail"; then
  cp -p "$DEST/AguiaEmail" "$DEST/AguiaEmail.bak-$(date +%Y%m%d%H%M%S)"
  systemctl stop aguia-email
fi
install -o aguia -g aguia -m 755 "$ROOT/bin/AguiaEmail" "$DEST/AguiaEmail"
if ! test -f "$DEST/email.ini"; then
  install -o aguia -g aguia -m 600 "$ROOT/deploy/email.ini.linux" "$DEST/email.ini"
fi
runuser -u aguia -- "$DEST/AguiaEmail" "$DEST/email.ini" --verificar
install -m 644 "$ROOT/deploy/aguia-email.service" /etc/systemd/system/aguia-email.service
systemctl daemon-reload
systemctl enable --now aguia-email
systemctl is-active aguia-email


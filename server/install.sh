#!/bin/bash
# Ubuntu/Debian + systemd. Read this file before running it as root.
set -euo pipefail
umask 077
if [ "$(id -u)" != 0 ]; then
  echo 'Запусти: sudo bash server/install.sh' >&2
  exit 1
fi
nikita_source="$(cd "$(dirname "$0")" && pwd)"
read -r -p 'Домен архива (A/AAAA уже указывает на этот VPS): ' nikita_domain
if [[ ! "$nikita_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || [[ "$nikita_domain" != *.* ]]; then
  echo 'Нужен домен, например archive.example.com, без https:// и пути.' >&2
  exit 1
fi
apt-get update
apt-get install -y python3 python3-venv caddy ca-certificates
if ! id nikita-archive >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/nikita-archive --shell /usr/sbin/nologin nikita-archive
fi
install -d -m 700 -o nikita-archive -g nikita-archive /var/lib/nikita-archive
install -d -m 755 /opt/nikita-archive
python3 -m venv /opt/nikita-archive/venv
/opt/nikita-archive/venv/bin/pip install --disable-pip-version-check "$nikita_source"
chgrp -R nikita-archive /opt/nikita-archive/venv
chmod -R g+rX,o-rwx /opt/nikita-archive/venv
if [ ! -f /var/lib/nikita-archive/config.json ]; then
  runuser -u nikita-archive -- /opt/nikita-archive/venv/bin/nikita-archive configure
fi
runuser -u nikita-archive -- /opt/nikita-archive/venv/bin/nikita-archive login

install -m 644 "$nikita_source/nikita-archive.service" /etc/systemd/system/nikita-archive.service
install -d -m 755 /etc/caddy
nikita_caddy_backup="$(mktemp /etc/caddy/Caddyfile.nikita-backup.XXXXXX)"
cp -p /etc/caddy/Caddyfile "$nikita_caddy_backup"
nikita_snippet=/etc/caddy/nikita-archive.caddy
if [ -f "$nikita_snippet" ]; then
  cp -p "$nikita_snippet" "${nikita_snippet}.previous"
fi
cat > "$nikita_snippet" <<CADDY
$nikita_domain {
    reverse_proxy 127.0.0.1:8765
}
CADDY
chmod 644 "$nikita_snippet"
if ! grep -Fqx 'import /etc/caddy/nikita-archive.caddy' /etc/caddy/Caddyfile; then
  printf '\nimport /etc/caddy/nikita-archive.caddy\n' >> /etc/caddy/Caddyfile
fi
if ! caddy validate --config /etc/caddy/Caddyfile; then
  cp -p "$nikita_caddy_backup" /etc/caddy/Caddyfile
  if [ -f "${nikita_snippet}.previous" ]; then
    cp -p "${nikita_snippet}.previous" "$nikita_snippet"
  fi
  echo 'Caddy не принял конфигурацию; основной файл восстановлен из резервной копии.' >&2
  exit 1
fi
systemctl daemon-reload
systemctl enable --now nikita-archive
systemctl enable caddy
systemctl reload-or-restart caddy
echo
echo 'В Никита → VPS и VoiceChanger включи интеграцию и сохрани:'
echo "Адрес: https://$nikita_domain"
echo 'Ключ доступа (не публикуй):'
runuser -u nikita-archive -- /opt/nikita-archive/venv/bin/nikita-archive show-token
echo 'Затем нажми «Проверить и синхронизировать».'
echo 'Порты 80/443 должны быть доступны для HTTPS; API 8765 доступен только на самом VPS.'

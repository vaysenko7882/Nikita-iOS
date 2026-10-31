#!/bin/bash
# Ubuntu/Debian + systemd. Read this file before running it as root.
set -euo pipefail
umask 077
if [ "$(id -u)" != 0 ]; then
  echo 'Запусти: sudo bash server/install.sh' >&2
  exit 1
fi
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
nikita_source="$(cd "$(dirname "$0")" && pwd)"
nikita_domain=""
nikita_session=""
nikita_reuse_session=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reuse-session) nikita_reuse_session=1; shift ;;
    --domain|--session)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "Для $1 нужно значение." >&2
        exit 2
      fi
      if [ "$1" = --domain ]; then nikita_domain="$2"; else nikita_session="$2"; fi
      shift 2
      ;;
    *) echo 'Параметры: --domain домен [--session /путь/my_account.session | --reuse-session]' >&2; exit 2 ;;
  esac
done
if [ "$nikita_reuse_session" = 1 ]; then
  if [ -n "$nikita_session" ] || [ ! -f /var/lib/nikita-archive/config.json ]; then
    echo '--reuse-session требует уже установленный архив и не совмещается с --session.' >&2
    exit 2
  fi
fi
if [ -n "$nikita_session" ] && { [ ! -f "$nikita_session" ] || [ ! -r "$nikita_session" ]; }; then
  echo 'Файл сессии не найден или недоступен. Укажи его полный путь на VPS.' >&2
  exit 1
fi
if [ -z "$nikita_domain" ]; then
  read -r -p 'Домен архива (A/AAAA уже указывает на этот VPS): ' nikita_domain
fi
if [[ ! "$nikita_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || [[ "$nikita_domain" != *.* ]]; then
  echo 'Нужен домен, например archive.example.com, без https:// и пути.' >&2
  exit 1
fi
apt-get update
apt-get install -y python3 python3-venv ca-certificates
if ! apt-cache show caddy >/dev/null 2>&1; then
  # Minimal Ubuntu images may omit Universe. Use Caddy's official signed
  # repository without changing the server's Ubuntu repository selection.
  # https://caddyserver.com/docs/install#debian-ubuntu-raspbian
  apt-get install -y curl gnupg debian-keyring debian-archive-keyring apt-transport-https
  nikita_caddy_repo="$(mktemp -d)"
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key -o "$nikita_caddy_repo/key.asc"
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt -o "$nikita_caddy_repo/caddy-stable.list"
  gpg --batch --yes --dearmor --output "$nikita_caddy_repo/key.gpg" "$nikita_caddy_repo/key.asc"
  install -m 644 "$nikita_caddy_repo/key.gpg" /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  install -m 644 "$nikita_caddy_repo/caddy-stable.list" /etc/apt/sources.list.d/caddy-stable.list
  rm -f "$nikita_caddy_repo/key.asc" "$nikita_caddy_repo/key.gpg" "$nikita_caddy_repo/caddy-stable.list"
  rmdir "$nikita_caddy_repo"
  apt-get update
fi
apt-get install -y caddy
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
nikita_resume_service=0
nikita_import_dir=""
nikita_import_kept=0
nikita_cleanup() {
  nikita_exit_status=$?
  if [ -n "$nikita_import_dir" ] && [ "$nikita_import_kept" = 0 ]; then
    rm -rf -- "$nikita_import_dir"
  fi
  if [ "$nikita_exit_status" -ne 0 ] && [ "$nikita_resume_service" = 1 ]; then
    systemctl start nikita-archive || true
  fi
}
trap nikita_cleanup EXIT

if [ -n "$nikita_session" ]; then
  # A consistent SQLite backup also includes committed WAL data. The source
  # remains private/read-only; the non-root service receives its own copy.
  nikita_import_dir="$(mktemp -d /var/lib/nikita-archive/session-import.XXXXXX)"
  /opt/nikita-archive/venv/bin/python -m nikita_archive.session_files "$nikita_session" "$nikita_import_dir/telegram.session"
  chown -R nikita-archive:nikita-archive "$nikita_import_dir"
fi
if systemctl is-active --quiet nikita-archive; then
  systemctl stop nikita-archive
  nikita_resume_service=1
fi
if [ -n "$nikita_session" ]; then
  nikita_import_kept=1
  runuser -u nikita-archive -- /opt/nikita-archive/venv/bin/nikita-archive use-session "$nikita_import_dir/telegram.session"
elif [ "$nikita_reuse_session" = 1 ]; then
  nikita_existing_session="$(/opt/nikita-archive/venv/bin/python -c 'import json; from pathlib import Path; p=Path(json.load(open("/var/lib/nikita-archive/config.json"))["session_path"]); print(p if p.suffix == ".session" else Path(str(p)+".session"))')"
  runuser -u nikita-archive -- /opt/nikita-archive/venv/bin/nikita-archive use-session "$nikita_existing_session"
else
  runuser -u nikita-archive -- /opt/nikita-archive/venv/bin/nikita-archive login
fi

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
systemctl enable nikita-archive
systemctl restart nikita-archive
nikita_resume_service=0
systemctl enable caddy
systemctl reload-or-restart caddy
echo
echo 'В Никита → VPS и VoiceChanger включи интеграцию и сохрани:'
echo "Адрес: https://$nikita_domain"
echo 'Ключ доступа (не публикуй):'
runuser -u nikita-archive -- /opt/nikita-archive/venv/bin/nikita-archive show-token
echo 'Затем нажми «Проверить и синхронизировать».'
echo 'Порты 80/443 должны быть доступны для HTTPS; API 8765 доступен только на самом VPS.'


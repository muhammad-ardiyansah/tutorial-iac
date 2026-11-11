#!/usr/bin/env bash
# sync.sh - kirim folder config/ ke satu lingkungan dengan rsync lewat SSH.
# Pemakaian: ./sync.sh <dev|prod> [-n|--dry-run] [-d|--delete] [-r|--reload] [-y|--yes]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "Pemakaian: $0 <dev|prod> [-n|--dry-run] [-d|--delete] [-r|--reload] [-y|--yes]"
  echo -n "Lingkungan yang tersedia:"
  for f in "$ROOT"/envs/*.env; do echo -n " $(basename "$f" .env)"; done
  echo
  exit 1
}

[[ $# -lt 1 ]] && usage
TARGET_ENV="$1"
shift
ENV_FILE="$ROOT/envs/$TARGET_ENV.env"
[[ -f "$ENV_FILE" ]] || { echo "GAGAL: file $ENV_FILE tidak ada."; usage; }

# Muat REMOTE_HOST, REMOTE_USER, REMOTE_DIR dari envs/<lingkungan>.env
# shellcheck source=/dev/null
source "$ENV_FILE"
: "${REMOTE_HOST:?REMOTE_HOST belum diisi di $ENV_FILE}"
REMOTE_USER="${REMOTE_USER:-deploy}"
REMOTE_DIR="${REMOTE_DIR:-/opt/app/config}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
LOCAL_DIR="$ROOT/config/"

DRY_RUN=false
DELETE=false
RELOAD=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=true ;;
    -d|--delete)  DELETE=true ;;
    -r|--reload)  RELOAD=true ;;
    -y|--yes)     ASSUME_YES=true ;;
    -h|--help)    usage ;;
    *) echo "Opsi tidak dikenal: $1"; usage ;;
  esac
  shift
done

# Server harus selalu cermin dari isi Git, bukan isi laptop.
if [[ -n "$(git -C "$ROOT" status --porcelain -- config/)" ]]; then
  echo "GAGAL: ada perubahan di config/ yang belum di-commit."
  exit 1
fi

# Pengaman untuk production: minta konfirmasi eksplisit.
if [[ "$TARGET_ENV" == "prod" ]] && ! $DRY_RUN && ! $ASSUME_YES; then
  read -r -p "Terapkan ke PRODUCTION ($REMOTE_HOST)? Ketik 'prod' untuk lanjut: " answer
  [[ "$answer" == "prod" ]] || { echo "Dibatalkan."; exit 1; }
fi

RSYNC_OPTS=(-avz --checksum -e "ssh -i $SSH_KEY")
$DRY_RUN && RSYNC_OPTS+=(--dry-run)
$DELETE  && RSYNC_OPTS+=(--delete)

echo ">> [$TARGET_ENV] Sinkronisasi $LOCAL_DIR -> $REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR"
rsync "${RSYNC_OPTS[@]}" "$LOCAL_DIR" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR"

if $RELOAD && ! $DRY_RUN; then
  echo ">> [$TARGET_ENV] Reload layanan"
  ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_HOST" \
    "sudo nginx -t && sudo systemctl reload nginx && sudo systemctl restart redis-server"
fi

echo ">> [$TARGET_ENV] Selesai (commit: $(git -C "$ROOT" rev-parse --short HEAD))"

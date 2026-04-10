#!/bin/bash
# =============================================================================
# ERPNext Production Restore Script
# Uses native bench restore with --with-public-files / --with-private-files
# Includes the critical DB permission grant fix for MariaDB access denied issue
# =============================================================================

set -euo pipefail

set -a
source .env
set +a
# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------
COMPOSE_FILE="${COMPOSE_FILE}"
BACKEND_SERVICE="${BACKEND_SERVICE}"
DB_SERVICE="${DB_SERVICE}" # MariaDB service name in compose
SITE_NAME="${SITE_NAME}"
BACKUP_BASE_DIR="${BACKUP_BASE_DIR}"
BENCH_BACKUP_PATH="/home/frappe/frappe-bench/sites/${SITE_NAME}/private/backups"
LOG_FILE="${BACKUP_BASE_DIR}/logs/restore.log"

# MariaDB root credentials — needed for the permission grant fix
MYSQL_ROOT_USER="${MYSQL_ROOT_USER}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}" # REQUIRED — set via env or .env file

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
die() {
	log "ERROR: $*"
	exit 1
}
warn() { log "WARN: $*"; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

confirm() {
	local prompt="$1"
	read -r -p "${prompt} [yes/NO]: " answer
	[[ "$answer" == "yes" ]] || die "Aborted by user."
}

usage() {
	cat <<EOF
Usage: $0 [OPTIONS]

Restore an ERPNext site from a bench backup.

Options:
  -b, --backup-dir DIR      Path to the unpacked backup directory (containing .sql.gz and .tar files)
                            OR path to the consolidated .tar.gz archive
  -s, --site SITE           Site name (default: \$SITE_NAME)
  -f, --force               Skip confirmation prompts (use with caution in automation)
  -h, --help                Show this help

Examples:
  # From unpacked backup dir:
  $0 --backup-dir /opt/erpnext-backups/20240915_030000

  # From consolidated archive:
  $0 --backup-dir /opt/erpnext-backups/erpnext_backup_20240915_030000.tar.gz

  # Override site:
  $0 --backup-dir /opt/erpnext-backups/20240915_030000 --site staging.example.com

Environment variables (can also be set in .env):
  COMPOSE_FILE, BACKEND_SERVICE, DB_SERVICE, SITE_NAME,
  MYSQL_ROOT_USER, MYSQL_ROOT_PASSWORD, BACKUP_BASE_DIR
EOF
	exit 0
}

# ---------------------------------------------------------------------------
# ARGUMENT PARSING
# ---------------------------------------------------------------------------
BACKUP_INPUT=""
FORCE=false

while [[ $# -gt 0 ]]; do
	case "$1" in
	-b | --backup-dir)
		BACKUP_INPUT="$2"
		shift 2
		;;
	-s | --site)
		SITE_NAME="$2"
		shift 2
		;;
	-f | --force)
		FORCE=true
		shift
		;;
	-h | --help) usage ;;
	*) die "Unknown option: $1. Use --help." ;;
	esac
done

[[ -z "$BACKUP_INPUT" ]] && die "You must specify --backup-dir. Use --help for usage."
[[ -z "$MYSQL_ROOT_PASSWORD" ]] && die "MYSQL_ROOT_PASSWORD is not set. Export it before running this script."

mkdir -p "${BACKUP_BASE_DIR}/logs"

require_cmd docker
require_cmd docker-compose

# ---------------------------------------------------------------------------
# STEP 1: Resolve backup directory — unpack archive if needed
# ---------------------------------------------------------------------------
log "========================================================"
log "ERPNext Restore — site: ${SITE_NAME}"
log "========================================================"

if [[ -f "$BACKUP_INPUT" && "$BACKUP_INPUT" == *.tar.gz ]]; then
	log "Input is a .tar.gz archive — extracting ..."
	EXTRACT_DIR="${BACKUP_BASE_DIR}/_restore_tmp_$(date +%s)"
	mkdir -p "$EXTRACT_DIR"
	tar -xzf "$BACKUP_INPUT" -C "$EXTRACT_DIR" ||
		die "Failed to extract archive: ${BACKUP_INPUT}"
	# The archive contains a single timestamped directory
	BACKUP_DIR=$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
	[[ -z "$BACKUP_DIR" ]] && die "No directory found inside archive."
	log "Extracted to: ${BACKUP_DIR}"
else
	BACKUP_DIR="$BACKUP_INPUT"
fi

[[ -d "$BACKUP_DIR" ]] || die "Backup directory not found: ${BACKUP_DIR}"

# ---------------------------------------------------------------------------
# STEP 2: Identify backup files
# ---------------------------------------------------------------------------
SQL_FILE=$(find "$BACKUP_DIR" -maxdepth 1 -name "*.sql.gz" | sort | tail -1)
PUB_FILE=$(find "$BACKUP_DIR" -maxdepth 1 -name "*-files.tar" | grep -v private | sort | tail -1)
PRIV_FILE=$(find "$BACKUP_DIR" -maxdepth 1 -name "*-private-files.tar" | sort | tail -1)

[[ -z "$SQL_FILE" ]] && die "No .sql.gz database file found in ${BACKUP_DIR}"

log "Database backup  : ${SQL_FILE}"
log "Public files     : ${PUB_FILE:-<not found — will skip>}"
log "Private files    : ${PRIV_FILE:-<not found — will skip>}"

# ---------------------------------------------------------------------------
# STEP 3: Verify checksums if manifest exists
# ---------------------------------------------------------------------------
MANIFEST="${BACKUP_DIR}/MANIFEST.txt"
if [[ -f "$MANIFEST" ]]; then
	log "Manifest found — verifying checksums ..."
	# Extract checksum block and verify (best-effort)
	awk '/^Checksums/,0' "$MANIFEST" | grep -v "^Checksums" | grep -v "^$" >/tmp/restore_checksums.txt 2>/dev/null || true
	if [[ -s /tmp/restore_checksums.txt ]]; then
		cd "$BACKUP_DIR"
		sha256sum --check /tmp/restore_checksums.txt 2>&1 | tee -a "$LOG_FILE" ||
			warn "Checksum verification had warnings — review log before proceeding"
		cd - >/dev/null
	fi
	log "Manifest info:"
	grep -E "^(Timestamp|Site|Host|Frappe Image)" "$MANIFEST" | tee -a "$LOG_FILE"
fi

# ---------------------------------------------------------------------------
# STEP 4: Confirmation gate
# ---------------------------------------------------------------------------
if [[ "$FORCE" == false ]]; then
	echo ""
	echo "  ⚠️  WARNING: This will OVERWRITE the existing site data for:"
	echo "      Site     : ${SITE_NAME}"
	echo "      Compose  : ${COMPOSE_FILE}"
	echo "      DB backup: $(basename "$SQL_FILE")"
	echo ""
	confirm "Are you absolutely sure you want to proceed? Type 'yes' to continue"
fi

# ---------------------------------------------------------------------------
# STEP 5: Copy backup files INTO the container
# bench restore requires files to be accessible inside the container
# ---------------------------------------------------------------------------
CONTAINER_ID=$(docker-compose -f "$COMPOSE_FILE" ps -q "$BACKEND_SERVICE")
[[ -z "$CONTAINER_ID" ]] && die "Backend container is not running. Start the stack first."

log "Copying backup files into container at ${BENCH_BACKUP_PATH} ..."
docker exec "$CONTAINER_ID" mkdir -p "$BENCH_BACKUP_PATH"

docker cp "$SQL_FILE" "${CONTAINER_ID}:${BENCH_BACKUP_PATH}/" || die "Failed to copy SQL file"

if [[ -n "$PUB_FILE" ]]; then docker cp "$PUB_FILE" "${CONTAINER_ID}:${BENCH_BACKUP_PATH}/" || warn "Could not copy public files tar"; fi
if [[ -n "$PRIV_FILE" ]]; then docker cp "$PRIV_FILE" "${CONTAINER_ID}:${BENCH_BACKUP_PATH}/" || warn "Could not copy private files tar"; fi

SQL_BASENAME=$(basename "$SQL_FILE")
PUB_BASENAME=$(basename "$PUB_FILE" 2>/dev/null || echo "")
PRIV_BASENAME=$(basename "$PRIV_FILE" 2>/dev/null || echo "")

# ---------------------------------------------------------------------------
# STEP 6: Disable the site scheduler before restore
# ---------------------------------------------------------------------------
log "Disabling scheduler on site before restore ..."
docker-compose -f "$COMPOSE_FILE" exec -T "$BACKEND_SERVICE" \
	bench --site "$SITE_NAME" scheduler disable 2>/dev/null || warn "Could not disable scheduler (may already be off)"

# ---------------------------------------------------------------------------
# STEP 7: Run bench restore
# ---------------------------------------------------------------------------
log "Running bench restore ..."

RESTORE_CMD="bench --site ${SITE_NAME} restore ${BENCH_BACKUP_PATH}/${SQL_BASENAME}"

if [[ -n "$PUB_BASENAME" ]]; then RESTORE_CMD="${RESTORE_CMD} --with-public-files  ${BENCH_BACKUP_PATH}/${PUB_BASENAME}"; fi
if [[ -n "$PRIV_BASENAME" ]]; then RESTORE_CMD="${RESTORE_CMD} --with-private-files ${BENCH_BACKUP_PATH}/${PRIV_BASENAME}"; fi

log "Restore command: ${RESTORE_CMD}"

docker-compose -f "$COMPOSE_FILE" exec -T "$BACKEND_SERVICE" \
	bash -c "$RESTORE_CMD" ||
	die "bench restore failed — check logs above"

log "bench restore completed."

# ---------------------------------------------------------------------------
# STEP 8: FIX DATABASE PERMISSIONS  ← The critical "access denied" fix
#
# After bench restore, the restored DB's user grants may be wiped.
# We re-grant all privileges to the site's DB user from MariaDB directly.
# ---------------------------------------------------------------------------
log "Applying database permission fix ..."

# Extract DB name and DB user from the site's site_config.json
DB_NAME=$(docker-compose -f "$COMPOSE_FILE" exec -T "$BACKEND_SERVICE" \
	bash -c "python3 -c \"import json; c=json.load(open('/home/frappe/frappe-bench/sites/${SITE_NAME}/site_config.json')); print(c['db_name'])\"" \
	2>/dev/null | tr -d '\r')

DB_USER=$(docker-compose -f "$COMPOSE_FILE" exec -T "$BACKEND_SERVICE" \
	bash -c "python3 -c \"import json; c=json.load(open('/home/frappe/frappe-bench/sites/${SITE_NAME}/site_config.json')); print(c.get('db_name', c.get('db_user', '')))\"" \
	2>/dev/null | tr -d '\r')

# In Frappe, db_user defaults to db_name if not separately specified
[[ -z "$DB_USER" ]] && DB_USER="$DB_NAME"

if [[ -z "$DB_NAME" ]]; then
	warn "Could not read db_name from site_config.json — skipping permission fix. You may need to run it manually."
else
	log "DB name: ${DB_NAME} | DB user: ${DB_USER}"

	# Get DB password from site_config too (needed for the grant)
	DB_PASS=$(docker-compose -f "$COMPOSE_FILE" exec -T "$BACKEND_SERVICE" \
		bash -c "python3 -c \"import json; c=json.load(open('/home/frappe/frappe-bench/sites/${SITE_NAME}/site_config.json')); print(c['db_password'])\"" \
		2>/dev/null | tr -d '\r')

	# Apply grants via MariaDB container
	log "Granting privileges on ${DB_NAME} to '${DB_USER}'@'%' ..."
	docker-compose -f "$COMPOSE_FILE" exec -T "$DB_SERVICE" \
		mysql -u"$MYSQL_ROOT_USER" -p"$MYSQL_ROOT_PASSWORD" \
		-e "
      -- Create user if not exists (safe for both new and existing users)
      CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
      -- Update password in case it changed
      ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
      -- Grant full access to the site database
      GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
      FLUSH PRIVILEGES;
    " 2>&1 | tee -a "$LOG_FILE" ||
		die "Failed to apply DB grants — run the GRANT statements manually"

	log "Database permissions fixed successfully."
fi

# ---------------------------------------------------------------------------
# STEP 9: Post-restore steps
# ---------------------------------------------------------------------------
log "Running post-restore steps ..."

# Re-run migrations in case schema versions differ between backup and current image
log "  → bench migrate ..."
docker-compose -f "$COMPOSE_FILE" exec -T "$BACKEND_SERVICE" \
	bench --site "$SITE_NAME" migrate ||
	warn "bench migrate had errors — check output above"

# Clear all caches
log "  → bench clear-cache ..."
docker-compose -f "$COMPOSE_FILE" exec -T "$BACKEND_SERVICE" \
	bench --site "$SITE_NAME" clear-cache ||
	warn "clear-cache failed (non-fatal)"

# Re-enable the scheduler
log "  → Re-enabling scheduler ..."
docker-compose -f "$COMPOSE_FILE" exec -T "$BACKEND_SERVICE" \
	bench --site "$SITE_NAME" scheduler enable ||
	warn "Could not re-enable scheduler"

# Rebuild search index (optional but recommended after restore)
log "  → Rebuilding global search index (background) ..."
docker-compose -f "$COMPOSE_FILE" exec -T "$BACKEND_SERVICE" \
	bench --site "$SITE_NAME" rebuild-global-search 2>/dev/null &

# ---------------------------------------------------------------------------
# DONE
# ---------------------------------------------------------------------------
log "========================================================"
log "Restore COMPLETE for site: ${SITE_NAME}"
log "========================================================"
echo ""
echo "  Restore finished. Next steps:"
echo "    1. Verify the site is accessible in your browser"
echo "    2. Check Scheduler status: bench --site ${SITE_NAME} scheduler status"
echo "    3. Review error logs: bench --site ${SITE_NAME} console"
echo ""

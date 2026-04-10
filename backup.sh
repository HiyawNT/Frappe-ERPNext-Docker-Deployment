#!/bin/bash
# =============================================================================
# ERPNext Production Backup Script
# Uses native bench backup --with-files for full fidelity backups
# Includes: DB dump, private files, public files
# =============================================================================

set -euo pipefail

set -a
source .env
set +a

# ---------------------------------------------------------------------------
# CONFIG — edit these or override via environment variables
# ---------------------------------------------------------------------------
COMPOSE_FILE="${COMPOSE_FILE}"
BACKEND_SERVICE="${BACKEND_SERVICE:-backend}" # your backend container name
SITE_NAME="${SITE_NAME}"                      # bench site name
BACKUP_BASE_DIR="${BACKUP_BASE_DIR}"
RETENTION_DAYS="${RETENTION_DAYS:-30}" # local retention
S3_BUCKET="${S3_BUCKET:-}"             # optional: s3://my-bucket/erpnext
NOTIFY_WEBHOOK="${NOTIFY_WEBHOOK:-}"   # optional: Slack/Teams webhook URL
LOG_FILE="${BACKUP_BASE_DIR}/logs/backup.log"

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
die() {
	log "ERROR: $*"
	notify "❌ ERPNext backup FAILED on $(hostname): $*"
	exit 1
}

notify() {
	[[ -z "$NOTIFY_WEBHOOK" ]] && return 0
	local msg="$1"
	curl -s -X POST "$NOTIFY_WEBHOOK" \
		-H 'Content-Type: application/json' \
		-d "{\"text\": \"${msg}\"}" >/dev/null || true
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

# ---------------------------------------------------------------------------
# PRE-FLIGHT
# ---------------------------------------------------------------------------
require_cmd docker
require_cmd docker-compose

mkdir -p "${BACKUP_BASE_DIR}/logs"

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_DIR="${BACKUP_BASE_DIR}/${TIMESTAMP}"
mkdir -p "$BACKUP_DIR"

log "========================================================"
log "Starting ERPNext backup — site: ${SITE_NAME}"
log "Timestamp: ${TIMESTAMP}"
log "Backup dir: ${BACKUP_DIR}"
log "========================================================"

# ---------------------------------------------------------------------------
# STEP 1: Run bench backup --with-files inside the backend container
# This produces:
#   <timestamp>-<site>-database.sql.gz
#   <timestamp>-<site>-files.tar          (public files)
#   <timestamp>-<site>-private-files.tar  (private files / attachments)
# ---------------------------------------------------------------------------
log "Running bench backup --with-files ..."

docker-compose -f "$COMPOSE_FILE" exec -T "$BACKEND_SERVICE" \
	bench --site "$SITE_NAME" backup --with-files ||
	die "bench backup command failed"

log "bench backup completed."

# ---------------------------------------------------------------------------
# STEP 2: Copy the freshly created backup files out of the container
# bench stores backups at: /home/frappe/frappe-bench/sites/<site>/private/backups/
# ---------------------------------------------------------------------------
BENCH_BACKUP_PATH="/home/frappe/frappe-bench/sites/${SITE_NAME}/private/backups"

log "Fetching backup file list from container ..."

# Get the three most recent backup files (db, files, private-files) by timestamp
CONTAINER_ID=$(docker-compose -f "$COMPOSE_FILE" ps -q "$BACKEND_SERVICE")
[[ -z "$CONTAINER_ID" ]] && die "Could not find running container for service: $BACKEND_SERVICE"

# List and grab the files created in the last 5 minutes
BACKUP_FILES=$(docker exec "$CONTAINER_ID" \
	find "$BENCH_BACKUP_PATH" -maxdepth 1 -type f -newer /tmp \
	\( -name "*.sql.gz" -o -name "*.tar" -o -name "*.tar.gz" \) \
	-printf '%T@ %f\n' 2>/dev/null | sort -n | tail -6 | awk '{print $2}')

if [[ -z "$BACKUP_FILES" ]]; then
	# Fallback: grab files modified in last 10 minutes
	BACKUP_FILES=$(docker exec "$CONTAINER_ID" \
		find "$BENCH_BACKUP_PATH" -maxdepth 1 -type f -mmin -10 \
		\( -name "*.sql.gz" -o -name "*.tar" -o -name "*.tar.gz" \) \
		-printf '%f\n' 2>/dev/null)
fi

[[ -z "$BACKUP_FILES" ]] && die "No backup files found in container at ${BENCH_BACKUP_PATH}"

FILE_COUNT=0
for fname in $BACKUP_FILES; do
	log "Copying: ${fname}"
	docker cp "${CONTAINER_ID}:${BENCH_BACKUP_PATH}/${fname}" "${BACKUP_DIR}/" ||
		die "Failed to copy ${fname} from container"
	FILE_COUNT=$((FILE_COUNT + 1))
done

log "Copied ${FILE_COUNT} file(s) to ${BACKUP_DIR}"

# Sanity check — we expect at least a .sql.gz
SQL_FILE=$(find "$BACKUP_DIR" -name "*.sql.gz" | head -1)
[[ -z "$SQL_FILE" ]] && die "No .sql.gz found in backup dir — backup may be incomplete"

# ---------------------------------------------------------------------------
# STEP 3: Create a manifest for easy identification during restore
# ---------------------------------------------------------------------------
MANIFEST="${BACKUP_DIR}/MANIFEST.txt"
{
	echo "ERPNext Backup Manifest"
	echo "======================="
	echo "Timestamp   : ${TIMESTAMP}"
	echo "Site        : ${SITE_NAME}"
	echo "Host        : $(hostname)"
	echo "Frappe Image: $(docker inspect "$CONTAINER_ID" --format '{{.Config.Image}}' 2>/dev/null || echo 'unknown')"
	echo ""
	echo "Files:"
	ls -lh "$BACKUP_DIR"/*.sql.gz "$BACKUP_DIR"/*.tar "$BACKUP_DIR"/*.tar.gz 2>/dev/null || ls -lh "$BACKUP_DIR"
	echo ""
	echo "Checksums (SHA256):"
	sha256sum "$BACKUP_DIR"/* 2>/dev/null || true
} >"$MANIFEST"

log "Manifest written: ${MANIFEST}"

# ---------------------------------------------------------------------------
# STEP 4: Compress everything into a single archive for offsite storage
# ---------------------------------------------------------------------------
ARCHIVE="${BACKUP_BASE_DIR}/erpnext_backup_${TIMESTAMP}.tar.gz"
log "Creating consolidated archive: ${ARCHIVE}"
tar -czf "$ARCHIVE" -C "$BACKUP_BASE_DIR" "$TIMESTAMP" ||
	die "Failed to create consolidated archive"

ARCHIVE_SIZE=$(du -sh "$ARCHIVE" | cut -f1)
log "Archive created: ${ARCHIVE} (${ARCHIVE_SIZE})"

# ---------------------------------------------------------------------------
# STEP 5: Upload to S3 (if configured)
# ---------------------------------------------------------------------------
if [[ -n "$S3_BUCKET" ]]; then
	require_cmd aws
	log "Uploading to S3: ${S3_BUCKET} ..."
	aws s3 cp "$ARCHIVE" "${S3_BUCKET}/$(basename "$ARCHIVE")" \
		--storage-class STANDARD_IA ||
		die "S3 upload failed"
	log "S3 upload complete."

	# Also upload the unpacked dir so individual files are accessible in S3
	aws s3 sync "$BACKUP_DIR" "${S3_BUCKET}/${TIMESTAMP}/" \
		--storage-class STANDARD_IA ||
		log "WARN: S3 sync of individual files failed (archive upload succeeded)"
fi

# ---------------------------------------------------------------------------
# STEP 6: Prune old local backups
# ---------------------------------------------------------------------------
log "Pruning local backups older than ${RETENTION_DAYS} days ..."
find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" -exec rm -rf {} + 2>/dev/null || true
find "$BACKUP_BASE_DIR" -maxdepth 1 -name "erpnext_backup_*.tar.gz" -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true
log "Pruning done."

# ---------------------------------------------------------------------------
# STEP 7: Cleanup bench's own backup dir inside the container
# (bench accumulates backups inside the site; keep only last 5)
# ---------------------------------------------------------------------------
log "Pruning old backups inside container (keeping last 5 sets) ..."
docker exec "$CONTAINER_ID" bash -c "
  cd '${BENCH_BACKUP_PATH}' 2>/dev/null || exit 0
  # Delete .sql.gz files older than the 5 newest
  ls -t *.sql.gz 2>/dev/null | tail -n +6 | xargs -r rm --
  ls -t *-files.tar 2>/dev/null | tail -n +6 | xargs -r rm --
  ls -t *-private-files.tar 2>/dev/null | tail -n +6 | xargs -r rm --
  echo 'Container backup dir pruned.'
" || log "WARN: Could not prune container backup dir (non-fatal)"

# ---------------------------------------------------------------------------
# DONE
# ---------------------------------------------------------------------------
log "========================================================"
log "Backup SUCCESSFUL"
log "  Archive : ${ARCHIVE} (${ARCHIVE_SIZE})"
log "  Files   : ${FILE_COUNT}"
log "========================================================"

notify "✅ ERPNext backup succeeded on $(hostname) | Site: ${SITE_NAME} | Size: ${ARCHIVE_SIZE} | $(date '+%Y-%m-%d %H:%M')"

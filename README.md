# ERPNext Docker Compose Stack

Production-ready Docker Compose configuration for Frappe/ERPNext v16 with automated backup and restore capabilities.

## Overview

This stack includes:
- ERPNext v16 with custom apps
- MariaDB 10.6
- Redis (cache and queue)
- Nginx frontend
- Background workers and scheduler
- Automated backup/restore scripts

## Prerequisites

- Docker Engine 20.10+
- Docker Compose 2.0+
- AWS CLI (optional, for S3 backups)

## Quick Start

1. **Clone and configure**
   ```bash
   cp .env.example .env
   # Edit .env with your credentials
   ```

2. **Build the image**
   ```bash
   docker-compose -f docker-compose-prod.yml build
   ```

3. **Start the stack**
   ```bash
   docker-compose -f docker-compose-prod.yml up -d
   ```

4. **Access ERPNext**
   - URL: http://localhost:8080
   - Username: Administrator
   - Password: (value of `ADMIN_PASSWORD` from .env)

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `DB_HOST` | MariaDB host | `db` |
| `DB_PORT` | MariaDB port | `3306` |
| `MYSQL_ROOT_PASSWORD` | MariaDB root password | Required |
| `ADMIN_PASSWORD` | ERPNext admin password | Required |
| `REDIS_CACHE` | Redis cache endpoint | `redis-cache:6379` |
| `REDIS_QUEUE` | Redis queue endpoint | `redis-queue:6379` |
| `SOCKETIO_PORT` | WebSocket port | `9000` |
| `SITE_NAME` | Frappe site name | `dev.localhost` |
| `BACKUP_BASE_DIR` | Backup storage directory | Required for backups |
| `RETENTION_DAYS` | Local backup retention | `30` |
| `S3_BUCKET` | S3 bucket for offsite backups | Optional |
| `NOTIFY_WEBHOOK` | Slack/Teams webhook URL | Optional |

## Custom Apps

Add custom apps in `builder/Dockerfile`:

```dockerfile
FROM frappe/erpnext:version-16
USER frappe
RUN bench get-app --branch version-16 payments
```

**Important:** Always specify app versions. Never use `develop` branch in production.

## Backup

Run manual backup:
```bash
./backup.sh
```

Schedule automated backups (cron example):
```cron
0 3 * * * /path/to/backup.sh >> /var/log/erpnext-backup.log 2>&1
```

Backups include:
- Database dump (`.sql.gz`)
- Public files (`.tar`)
- Private files/attachments (`.tar`)
- Manifest with checksums

Output:
- Unpacked files: `${BACKUP_BASE_DIR}/${TIMESTAMP}/`
- Consolidated archive: `${BACKUP_BASE_DIR}/erpnext_backup_${TIMESTAMP}.tar.gz`
- S3 upload (if configured)

## Restore

```bash
# From unpacked directory
./restore.sh --backup-dir /path/to/backup/20240915_030000

# From consolidated archive
./restore.sh --backup-dir /path/to/erpnext_backup_20240915_030000.tar.gz

# Skip confirmation prompt
./restore.sh --backup-dir /path/to/backup --force
```

The restore script:
1. Verifies backup integrity (checksums)
2. Copies files into container
3. Runs `bench restore` with database and files
4. Fixes database permissions (resolves MariaDB access denied errors)
5. Runs migrations and clears cache
6. Re-enables scheduler

## File Structure

```
.
├── builder/
│   └── Dockerfile              # Custom ERPNext image
├── docker-compose-dev.yml      # Development configuration
├── docker-compose-prod.yml     # Production configuration
├── .env                        # Environment variables
├── backup.sh                   # Backup script
└── restore.sh                  # Restore script
```

## Services

| Service | Description | Ports |
|---------|-------------|-------|
| `frontend` | Nginx reverse proxy | 8080 |
| `backend` | Gunicorn application server | Internal |
| `websocket` | Socket.IO server | Internal |
| `queue-short` | Background worker (short tasks) | N/A |
| `queue-long` | Background worker (long tasks) | N/A |
| `scheduler` | Cron job scheduler | N/A |
| `db` | MariaDB 10.6 | Internal |
| `redis-cache` | Redis cache | Internal |
| `redis-queue` | Redis queue | Internal |

## Development vs Production

**Production** (`docker-compose-prod.yml`):
- No site creation automation
- Services start independently
- Manual bench commands required

**Development** (`docker-compose-dev.yml`):
- Automated site creation via `create-site` service
- Installs ERPNext and Payments apps
- Proper dependency ordering

## Troubleshooting

**Site creation fails:**
```bash
docker-compose -f docker-compose-prod.yml logs create-site
```

**Database connection errors after restore:**
Database permissions are automatically fixed by the restore script. If issues persist:
```bash
docker-compose exec db mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e \
  "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%'; FLUSH PRIVILEGES;"
```

**Check service health:**
```bash
docker-compose -f docker-compose-prod.yml ps
```

**View logs:**
```bash
docker-compose -f docker-compose-prod.yml logs -f backend
```

## Security Notes

- Never commit `.env` to version control
- Change default passwords before deployment
- Use strong passwords for `MYSQL_ROOT_PASSWORD` and `ADMIN_PASSWORD`
- Restrict port 8080 access via firewall in production
- Configure SSL/TLS termination (use reverse proxy like Traefik or Nginx)

## License

Inherits license from [Frappe/ERPNext](https://github.com/frappe/erpnext).

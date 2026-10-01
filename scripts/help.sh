#!/usr/bin/env bash

PROJECT_NAME_LABEL=""
if [ -n "${PROJECT_NAME}" ]; then
  PROJECT_NAME_LABEL=" (${PROJECT_NAME})"
fi

cat << 'EOF'
════════════════════════════════════════
  PostgreSQL Backup Tool
════════════════════════════════════════

Commands:
  backup                  Run a backup immediately
  restore [file] [db]     Restore from a backup (interactive if no file given)
  list [db]               List all backups, optionally filter by database
  list --cleanup-preview  Preview what retention policy would delete
  restore --from-s3 <db|key> [db]  Restore the newest off-site dump of <db>, or one key
  list --s3 [db]          List the off-site dumps (S3), optionally for one database
  status                  Show system status, config, and last backup result
  help                    Show this help message

Examples:
  backup                                    # trigger manual backup
  list                                      # show all backups
  list mydb                                 # show backups for 'mydb'
  list --cleanup-preview                    # preview retention cleanup
  list --s3                                 # what the bucket holds
  restore --from-s3 mydb                    # newest off-site dump of 'mydb'
  restore                                   # interactive restore picker
  restore /backups/last/mydb-latest.sql.gz  # restore specific file
  restore /backups/daily/mydb-20260416.sql.gz mydb_staging  # restore to different db
  status                                    # check system health

Environment Variables:
  Database:     POSTGRES_HOST, POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD
  Schedule:     SCHEDULE (@daily, cron expression)
  Retention:    BACKUP_KEEP_DAYS, BACKUP_KEEP_WEEKS, BACKUP_KEEP_MONTHS
  Telegram:     TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, TELEGRAM_NOTIFY_ON
  Encryption:   BACKUP_ENCRYPTION_KEY
  Off-site:     S3_BUCKET, S3_ENDPOINT, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, S3_PREFIX
  Project:      PROJECT_NAME
  Exclude:      POSTGRES_EXCLUDE_TABLES

For full documentation: https://github.com/ganiyevuz/backupgram
════════════════════════════════════════
EOF

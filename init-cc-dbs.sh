#!/bin/bash

DB_RESTORE_COUNT=12

echo "get sql passwords..."

# get the sql password from the .netrc file
SA_PASSWORD=$(awk '/sa/{getline; print $2}' /root/.netrc)
VOICE4NET_ADMIN_PASSWORD=$(awk '/Voice4netAdmin/{getline; print $2}' /root/.netrc)

echo "SA Password: ${SA_PASSWORD}, Voice4netAdmin Password: ${VOICE4NET_ADMIN_PASSWORD}"

voice4net_admin_login_exists=$(/opt/mssql-tools/bin/sqlcmd -S 127.0.0.1 -U sa -P "${SA_PASSWORD}" -d master -h -1 -Q "set nocount on;select case when exists (select top 1 1 from sys.syslogins where loginname='Voice4netAdmin') then 'true' else 'false' end" | xargs)

echo "Voice4netAdmin Login Exists: ${voice4net_admin_login_exists}"

if [ "${voice4net_admin_login_exists}" != "true" ]; then
	echo "create Voice4netAdmin login..."

	# create Voice4netAdmin login
	/opt/mssql-tools/bin/sqlcmd -S 127.0.0.1 -U sa -P "${SA_PASSWORD}" -d master -Q "CREATE LOGIN [Voice4netAdmin] WITH PASSWORD=N'""${VOICE4NET_ADMIN_PASSWORD}""', DEFAULT_DATABASE=[master], DEFAULT_LANGUAGE=[us_english], CHECK_EXPIRATION=OFF, CHECK_POLICY=OFF"

	# Voice4netAdmin user to sysadmin role
	/opt/mssql-tools/bin/sqlcmd -S 127.0.0.1 -U sa -P "${SA_PASSWORD}" -d master -Q "ALTER SERVER ROLE [sysadmin] ADD MEMBER [Voice4netAdmin]"
fi

echo "enable clr..."

# enable clr
/opt/mssql-tools/bin/sqlcmd -S 127.0.0.1 -U sa -P "${SA_PASSWORD}" -d master -Q "sp_configure 'show advanced options', 1;"
/opt/mssql-tools/bin/sqlcmd -S 127.0.0.1 -U sa -P "${SA_PASSWORD}" -d master -Q "RECONFIGURE"
/opt/mssql-tools/bin/sqlcmd -S 127.0.0.1 -U sa -P "${SA_PASSWORD}" -d master -Q "sp_configure 'clr enabled', 1;"
/opt/mssql-tools/bin/sqlcmd -S 127.0.0.1 -U sa -P "${SA_PASSWORD}" -d master -Q "RECONFIGURE"

# create directory for hallengren sql scripts
if [ ! -d /usr/src/sql_scripts ]; then
	mkdir /usr/src/sql_scripts
fi

echo "download hallengren scripts..."

# download the hallengren scripts
curl -o /usr/src/sql_scripts/001-CommandExecute.sql https://ola.hallengren.com/scripts/CommandExecute.sql
curl -o /usr/src/sql_scripts/002-DatabaseIntegrityCheck.sql https://ola.hallengren.com/scripts/DatabaseIntegrityCheck.sql
curl -o /usr/src/sql_scripts/003-DatabaseBackup.sql https://ola.hallengren.com/scripts/DatabaseBackup.sql
curl -o /usr/src/sql_scripts/004-IndexOptimize.sql https://ola.hallengren.com/scripts/IndexOptimize.sql
curl -o /usr/src/sql_scripts/005-CommandLog.sql https://ola.hallengren.com/scripts/CommandLog.sql

echo "execute hallengren scripts..."
for filename in /usr/src/sql_scripts/*.sql; do
	echo "FileName: $filename"
	/opt/mssql-tools/bin/sqlcmd -S 127.0.0.1 -U sa -P "${SA_PASSWORD}" -d msdb -i "$filename"
done

# set up nightly backups
cp /usr/src/sql-shell-scripts/upload-sql-backups.sh /usr/local/bin/
chmod +x /usr/local/bin/upload-sql-backups.sh

if [ ! -d /var/opt/mssql/backup ]; then
	echo "create backup directory..."
	mkdir /var/opt/mssql/backup
fi

if [ ! -d /var/opt/mssql/backup/ZIPS ]; then
	echo "create ZIPS directory..."
	mkdir /var/opt/mssql/backup/ZIPS
fi

chown mssql:mssql "/var/opt/mssql/backup"
chown mssql:mssql "/var/opt/mssql/backup/ZIPS"

echo "check for sql backup cron job..."
if ! crontab -l | grep -q 'upload-sql-backups'; then
	echo "add sql backup cron job..."
	crontab -l | { cat; echo "05 05 * * * /usr/local/bin/upload-sql-backups.sh > /dev/null 2>&1"; } | crontab -
fi

download_latest_backup()
{
	echo "download latest backup..."
	curl --ssl --insecure --list-only --netrc --netrc-file /root/.netrc 'ftp://phl-prod-dbback-01.epbx.com/PHL-TEST/' 2>/dev/null | \
		grep '.zip' | \
		tail -n 1 | \
		curl -v --ssl --insecure --netrc --netrc-file /root/.netrc 'ftp://phl-prod-dbback-01.epbx.com/PHL-TEST/'"$(xargs)" -o /tmp/DB_BACKUP.zip && \
		unzip /tmp/DB_BACKUP.zip -d /tmp/DB_BACKUP && \
		mv /tmp/DB_BACKUP/V4_SPPS_V6/FULL/*.bak /var/opt/mssql/backup/V4_SPPS_V6.bak && \
		rm -rf /tmp/DB_BACKUP && \
		rm /tmp/DB_BACKUP.zip
}

restore_db()
{
	DB_NAME=$1
	echo "restore V4_SPPS_V6 database to $DB_NAME..."
	/opt/mssql-tools/bin/sqlcmd -S 127.0.0.1 -U sa -P "${SA_PASSWORD}" -d master -Q "RESTORE DATABASE $DB_NAME FROM DISK = '/var/opt/mssql/backup/V4_SPPS_V6.bak' WITH MOVE 'V4_SPPS_V6' TO '/var/opt/mssql/data/${DB_NAME}.mdf', MOVE 'V4_SPPS_V6_log' TO '/var/opt/mssql/data/${DB_NAME}_log.ldf', STATS = 5"
}

delete_backup()
{
	if [ -f /var/opt/mssql/backup/V4_SPPS_V6.bak ]; then
		rm /var/opt/mssql/backup/V4_SPPS_V6.bak
	fi
}

verify_online()
{
	all_online=$(/opt/mssql-tools/bin/sqlcmd -S 127.0.0.1 -U sa -P "${SA_PASSWORD}" -d master -h -1 -Q "set nocount on;select case when exists (select top 1 1 from sys.databases where [name] like 'V4_SPPS_INVENTORY_%' and state_desc!='ONLINE') then 'false' else 'true' end" | xargs)
	echo "${all_online}"
}

if ! ls /var/opt/mssql/data/V4_SPPS_*.mdf 1> /dev/null 2>&1; then
	download_latest_backup
	for (( i=1; i<=DB_RESTORE_COUNT; i++ ))
	do
		restore_db "V4_SPPS_INVENTORY_$i"
	done
	delete_backup
	for (( i=1; i<=10; i++ ))
	do
		online=$(verify_online)
        echo "ONLINE=${online}"
        if [ "$(online)" = "true" ]; then
            break
        fi
        sleep 30
	done
fi
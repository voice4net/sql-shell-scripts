#!/bin/bash

# check if the ZIPS directory does not exist
if [ ! -d "/var/opt/mssql/backup/ZIPS" ]; then
	# create ZIPS directory
	mkdir "/var/opt/mssql/backup/ZIPS"
fi

# change ownership of ZIPS directory to mssql user
chown mssql:mssql "/var/opt/mssql/backup/ZIPS"

# get the sql password from the .netrc file
SQL_PASSWORD=$(awk '/Voice4netAdmin/{getline; print $2}' /root/.netrc)

# loop through all the customer DBs named like V4_SPPS_%
for db_name in $(/opt/mssql-tools/bin/sqlcmd -S 127.0.0.1 -U Voice4netAdmin -P "${SQL_PASSWORD}" -d master -h -1 -Q "set nocount on;select [name] from sys.databases where [name] like 'V4_SPPS%' and  [name] not like 'V4_SPPS_INVENTORY%'")
do

	# print the db name
	echo "Database Name: ${db_name}"

	# look up the customer name
	customer_name=$(/opt/mssql-tools/bin/sqlcmd -S 127.0.0.1 -U Voice4netAdmin -P "${SQL_PASSWORD}" -d "${db_name}" -h -1 -Q "set nocount on;select top 1 UPPER(SettingValue) from dbo.SPPS_ConfigurationSettings where Active=1 and SettingName='CustomerName'" | xargs)

	# format the customer name
	customer_name=$(echo "${customer_name}" | sed -e 's/[^_0-9A-Za-z-]//g')

	# print the formatted customer name
	echo "Customer Name: ${customer_name}"

	# create the backup directory name
	backup_dir="/var/opt/mssql/backup/""${customer_name}"

	# print the backup directory name
	echo "Backup Directory: ${backup_dir}"

	# check if the backup directory does not exist
	if [ ! -d "${backup_dir}" ]; then
		# create backup directory
		mkdir "${backup_dir}"
	fi

	# change ownership of backup directory to mssql user
	chown mssql:mssql "${backup_dir}"

	# create the V4_CUSTOM database name from the V4_SPPS database name
	v4_custom_db_name=$(echo "${db_name}" | sed -e 's/V4_SPPS_\(.*\)/V4_CUSTOM_\1/')

	# print the V4_CUSTOM database name
	echo "V4_CUSTOM Database Name: ${v4_custom_db_name}"

	# run a query to find out if the V4_CUSTOM database exists
	v4_custom_exists=$(/opt/mssql-tools/bin/sqlcmd -S 127.0.0.1 -U Voice4netAdmin -P "${SQL_PASSWORD}" -d master -h -1 -Q "set nocount on;select case when exists (select top 1 1 from sys.databases where [name]='""${v4_custom_db_name}""') then 'true' else 'false' end" | xargs)

	# print whether or not the V4_CUSTOM database exists
	echo "V4_CUSTOM Database Exists: ${v4_custom_exists}"

	# create a variable with the db names to be backed up
	db_names="${db_name}"

	if [ "${v4_custom_exists}" = "true" ]; then
		# if the V4_CUSTOM database does exist set the db names to both
		db_names="${db_name},${v4_custom_db_name}"
	fi

	# backup the database(s)
	/opt/mssql-tools/bin/sqlcmd -S 127.0.0.1 -U Voice4netAdmin -P "${SQL_PASSWORD}" -d master -h -1 -Q "exec [msdb].[dbo].[DatabaseBackup] @Databases='""${db_names}""',@Directory='""${backup_dir}""',@BackupType='FULL',@Verify='Y',@CheckSum='Y',@LogToTable='Y'"

	# find the backup file
	backup_filename=$(find "${backup_dir}" -name "*$(date +%Y%m%d)*.bak" -print | head -n 1)

	# print the backup filename
	echo "Backup Filename: ${backup_filename}"

	# derive the directory to zip from the backup file path
	dir_to_zip=$(echo "${backup_filename}" | awk -F/ '{ printf "/var/opt/mssql/backup/%s/%s/", $6, $7 }')

	# print the directory to zip
	echo "Directory to Zip: ${dir_to_zip}"

	# create the zip filename
	zip_filename="/var/opt/mssql/backup/ZIPS/${customer_name}_$(date +%Y%m%d).zip"

	# print the zip filename
	echo "Zip Filename: ${zip_filename}"

	# zip the backup directory
	/usr/bin/zip -r "${zip_filename}" "${dir_to_zip}"

	# create the customer directory on the PHL ftp site
	/usr/bin/curl --verbose --ssl --insecure --netrc --netrc-file /root/.netrc --ftp-create-dirs ftp://phl-prod-dbback-01.epbx.com/"${customer_name}"/

	# upload the zip to the PHL ftp site
	/usr/bin/curl --verbose --ssl --insecure --netrc --netrc-file /root/.netrc --upload-file "${zip_filename}" ftp://phl-prod-dbback-01.epbx.com/"${customer_name}"/

	# create the customer directory on the PHX ftp site
	/usr/bin/curl --verbose --ssl --insecure --netrc --netrc-file /root/.netrc --ftp-create-dirs ftp://10.1.15.134/"${customer_name}"/

	# upload the zip to the PHX ftp site
	/usr/bin/curl --verbose --ssl --insecure --netrc --netrc-file /root/.netrc --upload-file "${zip_filename}" ftp://10.1.15.134/"${customer_name}"/

	# delete the zip
	rm --verbose "${zip_filename}"

	# delete the backup directory
	rm -rf --verbose "${backup_dir}"

done
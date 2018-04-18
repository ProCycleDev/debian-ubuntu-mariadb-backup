#!/bin/bash

export LC_ALL=C

database_name="$1"
s3_space_name="$2"
backup_owner="$3"
parent_dir="/backups/mariadb"
defaults_file="/etc/mysql/${database_name}-backup.cnf"
todays_dir="$(date +%F)"
log_file="${parent_dir}/${todays_dir}/backup-progress.log"
now="$(date +%m-%d-%Y_%H-%M-%S)"
processors="$(nproc --all)"

# Use this to echo to standard error
error () {
    printf "%s: %s\n" "$(basename "${BASH_SOURCE}")" "${1}" >&2
    exit 1
}

trap 'error "An unexpected error occurred."' ERR

sanity_check () {
    # Check user running the script
    if [ "$USER" != "$backup_owner" ]; then
        error "Script can only be run as the \"$backup_owner\" user"
    fi
}

set_options () {
    # List the innobackupex arguments
    innobackupex_args=(
        "--defaults-file=${defaults_file}"
        "--extra-lsndir=${parent_dir}/${todays_dir}"
        "--backup"
        "--compress"
        "--stream=xbstream"
        "--parallel=${processors}"
        "--compress-threads=${processors}"
    )

    backup_type="full"

    # Add option to read LSN (log sequence number) if a full backup has been
    # taken today.
    if grep -q -s "to_lsn" "${parent_dir}/${todays_dir}/xtrabackup_checkpoints"; then
        backup_type="incremental"
        lsn=$(awk '/to_lsn/ {print $3;}' "${parent_dir}/${todays_dir}/xtrabackup_checkpoints")
        innobackupex_args+=( "--incremental-lsn=${lsn}" )
    fi
}

take_backup () {
    # Make sure today's backup directory is available and take the actual backup
    mkdir -p "${parent_dir}/${todays_dir}"
    find "${parent_dir}/${todays_dir}" -type f -name "*.incomplete" -delete
    mariabackup "${innobackupex_args[@]}" "--target-dir=${parent_dir}/${todays_dir}" > "${parent_dir}/${todays_dir}/${backup_type}-${now}.xbstream.incomplete" 2> "${log_file}"
    
    mv "${parent_dir}/${todays_dir}/${backup_type}-${now}.xbstream.incomplete" "${parent_dir}/${todays_dir}/${backup_type}-${now}.xbstream"
}

upload_backup () {
    # Upload the backup file to an S3 compatible provider using s3cmd
	if [ -e "${parent_dir}/${todays_dir}/${backup_type}-${now}.xbstream" ]
	then
		if [ -s "${parent_dir}/${todays_dir}/${backup_type}-${now}.xbstream" ]
		then
			if [ -r "${parent_dir}/${todays_dir}/${backup_type}-${now}.xbstream" ]
			then
				s3cmd -c "/etc/mysql/${s3_space_name}.s3cfg" -e put "${parent_dir}/${todays_dir}/${backup_type}-${now}.xbstream" "s3://${s3_space_name}/$HOSTNAME/${database_name}/${todays_dir}/"
			else
				echo "${parent_dir}/${todays_dir}/${backup_type}-${now}.xbstream is not readable"
			fi
		else
			echo "${parent_dir}/${todays_dir}/${backup_type}-${now}.xbstream is zero in size"
		fi
	else
		echo "${parent_dir}/${todays_dir}/${backup_type}-${now}.xbstream does not exist"
	fi
}

sanity_check && set_options && take_backup && upload_backup

# Check success and print message
if tail -1 "${log_file}" | grep -q "completed OK"; then
    printf "Backup successful!\n"
    printf "Backup created at %s/%s-%s.xbstream\n" "${parent_dir}/${todays_dir}" "${backup_type}" "${now}"
else
    error "Backup failure! Check ${log_file} for more information"
fi

#!/usr/bin/bash

# TODO: noter fra 2026-09-25
# future run on RUNDECK?
# needs better logging function (see Graham github logging module) 
# - set logging levels (info, debug, warning, errors)
# - set conditions for types of log messages (currently only info logs

set -eu
umask 077

# ------------------------------------------------------------------- default variables

PROG=$(basename "$0")
DRY_RUN=""
CURRENT_DATETIME=$(date +"%Y-%m-%d-h%Hm%M")
BACKUP_FOLDER=""
TALOS_CONFIG=""
CLUSTER_NAME=""
LOGFILE=""

# ---------------------------------------------------------------- diagnostics

info() { printf '%s\n' "$*" >&2; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
die()  { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $PROG [options]


Backs up etcd store from a defined cluster and its controlplane nodes using talosctl.
Logs actions and results using stdout.

Dependencies: 
  * talosctl binary
  * etdcutl binary
  * valid talos config located in .talos/
  * valid backup folder

Options:
  -c, --cluster string      cluster name used to identify context 
  -t, --talosconfig string  talosconfig to use
  -b, --backup-folder       FOLDER path to backup folder (do not end with "/")
  -l, --log-file            path to log file (default stdout)
  --dry-run                 show what would happen, change nothing

EOF
}


# ------------------------------------------------------------------- arguments and options

check_args() {
  # check number of args
  if [ $# -lt 2 ]; then 
    usage
    die "Not enough arguments, see --help"
    exit 1
  fi
  # then go through arguments
  while [ $# -gt 0 ]; do
    case $1 in
      -c|--cluster)         [ $# -ge 2 ] || die "$1 needs a value"; CLUSTER_NAME=$2; shift 2 ;;
      -t|--talosconfig)      [ $# -ge 2 ] || die "$1 needs a value"; TALOS_CONFIG=$2; shift 2 ;;
      -b|--backup-folder)   [ $# -ge 2 ] || die "$1 needs a value"; BACKUP_FOLDER=$2; shift 2 ;;
      -l|--log-file)        [ $# -ge 2 ] || die "$1 needs a value"; LOGFILE=$2; shift 2 ;;
      --dry-run)            DRY_RUN=yes; shift ;;
      -h|--help)            usage; exit 0 ;;
      --)                   shift; break ;;
      -*)                   die "unknown option: $1 (try --help)" ;;
      *)                    die "unexpected argument: $1 (try --help)" ;;
    esac
  done
}

check_dry_run() {
  if [ "$DRY_RUN" = "yes" ]; then
    echo ""$PROG" is dry running with the following settings:
    DATE:                  "$CURRENT_DATETIME"
    TALOS CONFIG LOCATION: "$TALOS_CONFIG"
    BACKUP FOLDER LOCATION:"$BACKUP_FOLDER"
    LOG FILE LOCATION:     "$LOGFILE"
    CLUSTER IP ENDPOINT:   "$CLUSTER_IP"
    CLUSTER NAME:          "$CLUSTER_NAME""
    exit 1
  fi
}

# ---------------------------------------------------------------- set needed cluster variables

set_cluster_variables() {
  # switch to correct talos context first
  talosctl config context $CLUSTER_NAME --talosconfig $TALOS_CONFIG
  # get cluster endpoint from context
  CLUSTER_IP=$(cat $TALOS_CONFIG | grep -A2 ""$CLUSTER_NAME":" | tail -n 1 | awk '{ print $2 }') 
}

# ---------------------------------------------------------------- remove old backups

remove_old_backups() {
  find $BACKUP_FOLDER -type f -mtime +180 -exec echo "found old snapshot(s) for removal:" {} \;
  if [ ! "$DRY_RUN" = "yes" ]; then
    find $BACKUP_FOLDER -type f -mtime +180 -delete -print
    log "INFO" "Succesfully deleted old snapshot(s)"
  fi
}

# ---------------------------------------------------------------- backup etcd snapshot

backup_etcd() { 
  local log_string
  # remove older backups first
  remove_old_backups
  SNAPSHOT="$BACKUP_FOLDER"/"$CURRENT_DATETIME"_"$CLUSTER_NAME".db
  talos_out=$(talosctl etcd snapshot "$SNAPSHOT" --nodes "$CLUSTER_IP")
  log "INFO" "$talos_out"
  snapshot_status=$(etcdutl snapshot status "$SNAPSHOT")
  log_string=$(gzip -v "$SNAPSHOT" 2>&1)
  log "INFO" "compressing snapshot: $log_string"
}

log() {
    local log_level=$1  # A string representing the log level provided by the user when calling the function
    local message=$2  # A string representing the message provided by the user when calling the function
    local script_name=$(basename $0)  # The name of the script that is running
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")  # The current date and time at the time the function is called
    echo "$timestamp [$log_level] [$script_name] $message" | tee -a $LOGFILE
}  

# ---------------------------------------------------------------- program functions executed in order

check_args "$@" 
# set_cluster_variables to run first to initialize and test dry run
set_cluster_variables 
check_dry_run
backup_etcd
echo "$LOGFILE"

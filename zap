#!/bin/sh

# zap - Maintain ZFS snapshots with cron [1]
#
# Run zap without arguments or visit the GitHub page for an overview.
#
# https://github.com/Jehops/zap
#
# Key features:
#
#  - uses neither configuration files nor custom ZFS properties - all
#    information is supplied when zap is invoked and stored in snapshot names
#  - uses /namespaces/ to avoid collisions with other snapshots
#  - creates and destroys snapshots only when it makes sense to [1,2]
#  - written in POSIX sh
#
# [1] zap was influenced by zfSnap, which is under a BEER-WARE license.  We owe
# the authors a beer.
#
# [2] New snapshots are only created when a filesystem has changed since the
# last snapshot.  If the filesystem hasn't changed, then the timestamp of the
# newest snapshot is updated.
#
# [3] If the pool is in a DEGRADED state, zap will not destroy snapshots.
#
# ===============================================================================
# This script was written by Joseph Mingrone <jrm@ftfl.ca>.  Do whatever you
# like with it, but please retain this notice.
# ===============================================================================

fatal () {
    echo "FATAL: $*" > /dev/stderr
    exit 1
}

help () {
    readonly version=0.1.3

    cat <<EOF
NAME
   ${0##*/} - manage ZFS snapshots

SYNOPSIS
   ${0##*/} TTL pool[/filesystem] ...
   ${0##*/} -d

DESCRIPTION
   Create ZFS snapshots with the specified time to live (TTL).  TTL is of the
   form [0-9]{1,4}[dwmy].

   -d   Destroy expired snapshots.

EXAMPLES
   Create snapshots that will last for 1 day, 3 weeks, 6 months, and 1 year:
      $ ${0##*/} 1d zroot/ROOT/default
      $ ${0##*/} 3w tank zroot/usr/home/nox
      $ ${0##*/} 6m zroot/usr/home/jrm zroot/usr/home/mem
      $ ${0##*/} 1y tank/backup
   Destroy snapshots past expiration:
      $ ${0##*/} -d

AUTHORS
Joseph Mingrone <jrm@ftfl.ca>
Tobias Kortkamp <t@tobik.me>

VERSION
   ${0##*/} version ${version}

EOF
    exit 0
}

is_pint () {
    case $1 in
        ''|*[!0-9]*|0*)
            return 1;;
    esac

    return 0
}

ss_ts () {
    case $os in
        'Darwin'|'FreeBSD')
            date -j -f'%Y-%m-%dT%H:%M:%S%z' "$1" +%s
            ;;
        'Linux')
            gdate=$(echo "$1" | sed 's/T/ /')
            date -d"$gdate" +%s
            ;;
    esac
}

ttl2s () {
    echo "$1" | sed 's/d/*86400/;s/w/*604800/;s/m/*2592000/;s/y/*31536000/' | bc
}

warn () {
    echo "WARN: $*" > /dev/stderr
}

# ===============================================================================

create () {
    ttl="$1"
    shift
    date=$(date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/+/p/')
    for i in "$@"; do
        if zpool status "$(echo "$i" | cut -f1 -d'/')" | \
                grep -q "FAULTED\|OFFLINE\|REMOVED\|UNAVAIL"; then
            warn "zap skipped creating a snapshot for $i because of pool state!"
        else
            r=$(zfs list -rHo name -t snap -S name "$i" | grep "${i}${zptn}" | \
                    grep -e "--${ttl}[[:space:]]" -m1)
            if [ ! -z "$r" ]; then
                s=$(zfs get -H -o value written "$r")
                if [ "${s}" != "0" ]; then
	            zfs snapshot "${i}@ZAP_${date}--${ttl}"
                else
                    zfs rename "${r}" "${i}@ZAP_${date}--${ttl}"
                fi
            else
                zfs snapshot "${i}@ZAP_${date}--${ttl}"
            fi
        fi
    done
}

destroy () {
    now_ts=$(date '+%s')
    zfs list -H -t snap -o name | while read -r i; do
        if zpool status "$(echo "$i" | sed 's/[/@].*//')" | \
                grep -q "DEGRADED\|FAULTED\|OFFLINE\|REMOVED\|UNAVAIL"; then
            warn "zap skipped destroying $i because of pool state!"
        else
            if echo "$i" | grep -q -e "$zptn"; then
	        create_time=$(echo "$i" | sed 's/^..*@ZAP_//;
s/--[0-9]\{1,4\}[dwmy]$//;s/p/+/')
                create_ts=$(ss_ts "$create_time")
	        ttls=$(ttl2s "$(echo "$i" | grep -o '[0-9]\{1,4\}[dwmy]$')")
                if ! is_pint "$create_ts" || ! is_pint "$ttls"; then
                    warn "Skipping $i. Could not determine its expiration time."
                else
	            expire_ts=$((create_ts + ttls))
	            [ "$now_ts" -gt "$expire_ts" ] && zfs destroy "$i"
                fi
	    fi
        fi
    done
}

# ===============================================================================

zptn='@ZAP_..*--[0-9]\{1,4\}[dwmy]'

os=$(uname)
case $os in
    'Darwin'|'FreeBSD'|'Linux')
    ;;
    *)
        fatal "${0##*/} has not be tested on $os.
       Feedback and patches are welcome."
        ;;
esac

if echo "$1" | grep -q -e "^[0-9]\{1,4\}[dwmy]$" && [ $# -gt 1 ]; then
    create "$@"
elif [ "$1" = '-d' ]; then
    destroy
else
    help
fi

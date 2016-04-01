#!/bin/sh

# zap - Maintain ZFS snapshots with cron [1]
#
# Run zap without arguments or visit the GitHub page for an overview.
#
# https://github.com/Jehops/zap
#
# Key features:
#
#  - uses neither configuration files nor custom ZFS properites - all
#    information is supplied when zap is invoked and stored in snapshot names
#  - uses /namespaces/ to avoid collisions with other snapshots
#  - creates and deletes snapshots only when it makes sense to [fn:so1][fn:so2]
#  - written in POSIX sh
#
# [1] zap was influenced by zfSnap, which is under a BEER-WARE license.  We owe
# the authors a beer.
#
# [2] New snapshots are only created when a file system has changed since the
# last snapshot.  If the filesystem hasn't changed, then the timestamp of the
# newest snapshot is updated.
#
# [3] If the pool is being scrubbed or reslivered, or the pool is in a degraded
# state, zap will not create or delete snapshots.
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
    readonly version=0.1

    cat <<EOF
NAME
   ${0##*/} - manage ZFS snapshots

SYNOPSIS
   ${0##*/} TTL pool[/files system] ...
   ${0##*/} -d

DESCRIPTION
   Create ZFS snapshots with the specified time to live (TTL).  TTL is of the
   form [0-9]{1,4}[dwmy].

   -d   Delete expired snapshots.

EXAMPLES
   Create snapshots that will last for 1 day, 3 weeks, 6 months, and 1 year:
      $ ${0##*/} 1d zroot/ROOT/default
      $ ${0##*/} 3w tank zroot/usr/home/nox
      $ ${0##*/} 6m zroot/usr/home/jrm zroot/usr/home/mem
      $ ${0##*/} 1y tank/backup
   Delete snapshots past expiration:
      $ ${0##*/} -d

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

safe () {
    echo "$1" | cut -f1 -d'/' | \
        grep -qv "scan: resilver in progress\|scan: scrub in progress\|state: DEGRADED"
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
    p=$*
    date=$(date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/+/p/')
    for i in $p; do
        if ! safe $i; then continue; fi
        r=$(zfs list -rHo name,written -t snap -S name $i | \
                grep "${i}${zptn}" | grep -e "--${ttl}[[:space:]]" -m1)
        set -- $r
        if [ "$2" != "0" ]; then
	    zfs snapshot "${i}@ZAP_${date}--${ttl}"
        else
            zfs rename "$1" "${i}@ZAP_${date}--${ttl}"
        fi
    done
}

delete () {
    now_ts=$(date '+%s')
    for i in `zfs list -H -t snap -o name`; do
        if ! safe $i; then continue; fi
        if $(echo "$i" | grep -q -e $zptn); then
	    create_time=$(echo "$i" | \
                              sed 's/^..*@ZAP_//;s/--[0-9]\{1,4\}[dwmy]$//;s/p/+/')
            create_ts=$(ss_ts ${create_time})
	    ttls=$(ttl2s $(echo "$i" | grep -o '[0-9]\{1,4\}[dwmy]$'))
            if ! is_pint $create_ts || ! is_pint $ttls; then
                warn "Skipping $i. Could not determine its expiration time."
            else
	        expire_ts=$(($create_ts + $ttls))
	        [ ${now_ts} -gt ${expire_ts} ] && zfs destroy $i
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
    create $*
elif [ "$1" = '-d' ]; then
    delete
else
    help
fi

#!/bin/sh

# ===============================================================================
# Copyright (c) 2016, Joseph Mingrone.  All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this
# list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# ===============================================================================

# zap - Maintain ZFS snapshots with cron [1]
#
# Run zap without arguments or visit the GitHub page for an overview.
#
# https://github.com/Jehops/zap
#
# Key features:
#
#  - no configuration files
#  - uses "namespaces" to avoid collisions with other snapshots
#  - creates and destroys snapshots only when it makes sense [1,2]
#  - written in POSIX sh
#
# [1] zap was influenced by zfSnap, which is under a BEER-WARE license.  We owe
# the authors a beer.
#
# [2] New snapshots are only created when a filesystem has changed since the
# last snapshot.  If the filesystem has not changed, then the timestamp of the
# newest snapshot is updated.
#
# [3] If the pool is in a DEGRADED state, zap will not destroy snapshots.
#

fatal () {
    echo "FATAL: $*" > /dev/stderr
    exit 1
}

help () {
    readonly version=0.3.0

    cat <<EOF
NAME
   ${0##*/} -- maintain ZFS snapshots

SYNOPSIS
   ${0##*/} TTL [pool[/filesystem] ...]
   ${0##*/} -d

DESCRIPTION
   ${0##*/} TTL [pool[/filesystem] ...]

   Create ZFS snapshots that will expire after TTL (time to live) time has
   elapsed.  TTL takes the form [0-9]{1,4}[dwmy], i.e., one to four digits
   followed by a character to represent the time unit (day, week, month, or
   year).  If [pool[/filesystem] ...] is not supplied, snapshots will be created
   for filesystems with the property zap:snap set to "on".

   ${0##*/} -d

   Destroy expired snapshots.

   Run ${0##*/} with no arguments, -h, or --help to show this documentation.

EXAMPLES
   Create snapshots that will last for 1 day, 3 weeks, 6 months, and 1 year:
      $ ${0##*/} 1d zroot/ROOT/default
      $ ${0##*/} 3w tank zroot/usr/home/nox
      $ ${0##*/} 6m zroot/usr/home/jrm zroot/usr/home/mem
      $ ${0##*/} 1y tank/backup

   Create the same snapshots for filesystems with the zap:snap property set to
   "on"
      $ ${0##*/} 1y
      $ ${0##*/} 3w
      $ ${0##*/} 6m
      $ ${0##*/} 1y

   Destroy expired snapshots:
      $ ${0##*/} -d

AUTHORS AND CONTRIBUTORS
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
        'Linux'|'SunOS')
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
                    grep -e "--${ttl}" -m1)
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

prop () {
    zfs list -Ho name -t volume,filesystem | while read -r f; do
        if [ "$(zfs get -H -o value zap:snap "$f")" = 'on' ]; then
            create "$1" "$f"
        fi
    done
}

# ===============================================================================

zptn='@ZAP_..*--[0-9]\{1,4\}[dwmy]'

os=$(uname)
case $os in
    'Darwin'|'FreeBSD'|'Linux'|'SunOS')
    ;;
    *)
        fatal "${0##*/} has not be tested on $os.
       Feedback and patches are welcome."
        ;;
esac

if echo "$1" | grep -q -e "^[0-9]\{1,4\}[dwmy]$" && [ $# -gt 1 ]; then
    create "$@"
elif echo "$1" | grep -q -e "^[0-9]\{1,4\}[dwmy]$" && [ $# -eq 1 ]; then
    prop "$1"
elif [ "$1" = '-d' ]; then
    destroy
else
    help
fi

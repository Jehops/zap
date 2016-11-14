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
#  - written in POSIX sh
#
# [1] zap was influenced by zfSnap, which is under a BEER-WARE license.  We owe
# the authors a beer.
#

fatal () {
    echo "FATAL: $*" > /dev/stderr
    exit 1
}

help () {
    readonly version=0.5.0

    cat <<EOF
NAME
   ${0##*/} -- maintain ZFS snapshots

SYNOPSIS
   ${0##*/} [-v] TTL [[-r] pool[/filesystem] ...]
   ${0##*/} -d [-v]

DESCRIPTION
   ${0##*/} [-v] TTL [[-r] pool[/filesystem] ...]

   Create ZFS snapshots that will expire after TTL (time to live) time has
   elapsed.  TTL takes the form [0-9]{1,4}[dwmy], i.e., one to four digits
   followed by a character to represent the time unit (day, week, month, or
   year).  If [pool[/filesystem] ...] is not supplied, snapshots will be created
   for filesystems with the property zap:snap set to "on".

   -v  Be verbose.
   -r  Snapshots will be created for all dependent datasets.

   ${0##*/} -d [-v]

   Destroy expired snapshots.

   -v  Be verbose.

EXAMPLES
   Create snapshots that will last for 1 day, 3 weeks, 6 months, and 1 year.
      $ ${0##*/} 1d zroot/ROOT/default
      $ ${0##*/} 3w tank zroot/usr/home/nox zroot/var
      $ ${0##*/} 6m zroot/usr/home/jrm zroot/usr/home/mem
      $ ${0##*/} 1y tank/backup

   Create snapshots (recursively for zroot/var).  Be verbose.
      $ ${0##*/} -v 3w tank zroot/usr/home/nox -r zroot/var

   Create the same snapshots for filesystems with the zap:snap property set to
   "on".
      $ ${0##*/} 1y
      $ ${0##*/} 3w
      $ ${0##*/} 6m
      $ ${0##*/} 1y

   Destroy expired snapshots.
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
    case $OS in
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
create_parse () {
    ttl="$1"
    shift

    [ -n "$v_OPT" ] && printf "%s\nCreating snapshots...\n" "$(date)"

    while getopts ":r:" opt; do
        case $opt in
            r)  create "$ttl" -r "$OPTARG"
                ;;
            \?) echo "Invalid create_parse() option: -$OPTARG" >&2;
                exit 1
                ;;
        esac
    done
    shift $(( OPTIND - 1 ))

    for i in "$@"; do
        create "$ttl" "$i"
    done
}

create () {
    ttl="$1"
    shift

    r_opt=''
    while getopts ":r" opt; do
        case $opt in
            r)  r_opt=1
                ;;
            \?) echo "Invalid create() option: -$OPTARG" >&2
                exit 1
                ;;
        esac
    done
    shift $(( OPTIND - 1 ))

    if ! pool_ok "${1%%/*}"; then
        warn "zap DID NOT snapshot $i because of the pool state!"
    else
        if [ -n "$v_OPT" ]; then
            printf "zfs snap "
            [ -n "$r_opt" ] && printf "\-r "
            echo "${1}@ZAP_${DATE}--${ttl}"
        fi
        if [ -n "$r_opt" ]; then
            zfs snap -r "$1@ZAP_${DATE}--${ttl}"
        else
            zfs snap "$1@ZAP_${DATE}--${ttl}"
        fi
    fi
}

destroy () {
    now_ts=$(date '+%s')

    [ -n "$v_OPT" ] && printf "%s\nDestroying snapshots...\n" "$(date)"
    zfs list -H -t snap -o name | while read -r i; do
        if echo "$i" | grep -q -e "$ZPTN"; then
            pool="${i%%/*}"
            if ! pool_ok "$pool"; then
                warn "zap DID NOT destroy $i because of the state of $pool!"
            elif pool_scrub "$pool"; then
                warn "zap DID NOT destroy $i because $pool is being scrubbed!"
            else
                create_time=$(echo "$i" | sed 's/^..*@ZAP_//;
s/--[0-9]\{1,4\}[dwmy]$//;s/p/+/')
                create_ts=$(ss_ts "$create_time")
                ttls=$(ttl2s "$(echo "$i"|grep -o '[0-9]\{1,4\}[dwmy]$')")
                if ! is_pint "$create_ts" || ! is_pint "$ttls"; then
                    warn "SNAPSHOT $i WAS NOT DESTROYED because its expiration \
time could not be determined."
                else
                    expire_ts=$((create_ts + ttls))
                    if [ "$now_ts" -gt "$expire_ts" ]; then
                        [ -n "$v_OPT" ] && echo "zfs destroy $i"
                        zfs destroy "$i"
                    fi
                fi
            fi
        fi
    done
}

pool_ok () {
    skip="FAULTED\|OFFLINE\|REMOVED\|UNAVAIL"
    if zpool status "$1" | grep -q "$skip"; then
        return 1
    fi

    return 0
}

pool_scrub () {
    if zpool status "$1" | grep -q "scrub in progress"; then
        return 0
    fi

    return 1
}

prop () {
    [ -n "$v_OPT" ] && printf "%s\nCreating snapshots...\n" "$(date)"
    zfs list -Ho name -t volume,filesystem | while read -r f; do
        if [ "$(zfs get -H -o value zap:snap "$f")" = 'on' ]; then
            create "$1" "$f"
        fi
    done
}

# ===============================================================================

OS=$(uname)
case $OS in
    'Darwin'|'FreeBSD'|'Linux'|'SunOS')
    ;;
    *)
        fatal "${0##*/} has not be tested on $OS.
       Feedback and patches are welcome."
        ;;
esac

while getopts ":dhv" OPT; do
    case $OPT in
        d)  d_OPT=true   ;;
        h)  help         ;;
        v)  v_OPT=true   ;;
        \?) printf "Invalid option: -%s\n\n" "$OPTARG" >&2;
            help         ;;
    esac
done
shift $(( OPTIND - 1 ))
if [ -n "$d_OPT" ] && [ $# -gt 0 ]; then
    help
fi

DATE=$(date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/+/p/')
TTLPTN='^[0-9]\{1,4\}[dwmy]$'
ZPTN='@ZAP_..*--[0-9]\{1,4\}[dwmy]'

if [ -n "$d_OPT" ]; then
    destroy
elif echo "$1" | grep -q -e "$TTLPTN" && [ $# -gt 1 ]; then
    create_parse "$@"
elif echo "$1" | grep -q -e "$TTLPTN" && [ $# -eq 1 ]; then
    prop "$1"
else
    help
fi

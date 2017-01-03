#!/bin/sh

# ==============================================================================
# Copyright (c) 2017, Joseph Mingrone.  All rights reserved.
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
# ==============================================================================

# zap - Maintain and replicate rolling ZFS snapshots [1].
#
# Run zap without arguments or visit github.com/Jehops/zap for an overview.
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
    readonly version=0.6.0

    cat <<EOF
NAME
   ${0##*/} -- maintain and replicate ZFS snapshots

SYNOPSIS
   ${0##*/} snap|snapshot [-v] TTL [-r dataset]... [dataset]...
   ${0##*/} rep|replicate [-v] [local_dataset remote_destination]...
   ${0##*/} destroy [-v] [host[,host]...]

DESCRIPTION
   ${0##*/} snap|snapshot [-v] TTL [-r dataset]... [dataset]...

   Create ZFS snapshots that will expire after TTL (time to live) time has
   elapsed.  Expired means they will be destroyed by ${0##*/} destroy.  TTL
   takes the form [0-9]{1,4}[dwmy], i.e., one to four digits followed by a
   character to represent the time unit (day, week, month, or year).  If neither
   [-r dataset]... nor [dataset]... is supplied, snapshots will be created for
   datasets with the property zap:snap set to 'on'.

   -v  Be verbose
   -r  Recursively create snapshots of all descendents

   ${0##*/} rep|replicate [-v] [local_dataset remote_destination]...

   Remotly replicate datasets via ssh.  Remote destinations are specified in
   zap:rep user properties or as arguments.  Remote destinations are specificed
   using the format [user@]hostname:dataset.

   TODO: Describe setting up permissions and possible changes on the remote
   side.
   TODO: More details described at
   http://ftfl.ca/blog/beta/2016-12-27-zfs-replication.html

   -v  Be verbose.

   ${0##*/} destroy [-v] [host[,host2]...]

   Destroy expired snapshots.  If a comma separated list of hosts are specified,
   then only delete snapshots originating from those hosts.  Hosts are specified
   without any domain information, i.e., as returned by hostname -s.

   -v  Be verbose.

EXAMPLES
   Create snapshots that will last for 1 day, 3 weeks, 6 months, and 1 year.
      $ ${0##*/} snap 1d zroot/ROOT/default
      $ ${0##*/} snap 3w tank zroot/usr/home/nox zroot/var
      $ ${0##*/} snap 6m zroot/usr/home/jrm zroot/usr/home/mem
      $ ${0##*/} snap 1y tank/backup

   Create snapshots (recursively for tank and zroot/var) that will expire after
   3 weeks.  Be verbose.
      $ ${0##*/} snap 3w -v -r tank -r zroot/var zroot/usr/home/nox

   Create snapshots for datasets with the zap:snap property set to 'on'.
      $ ${0##*/} snap 1d
      $ ${0##*/} snap 3w
      $ ${0##*/} snap 6m
      $ ${0##*/} snap 1y

   Replicate datasets with the zap:rep user property set to a remote
   destination.  Be verbose.
      $ ${0##*/} rep -v

   Replicate datasets from host phe to host bravo.
      $ ${0##*/} rep zroot/ROOT/defalut jrm@bravo:rback/phe \
                     zroot/usr/home/jrm jrm@bravo:rback/phe

   Destroy expired snapshots.
      $ ${0##*/} destroy

   Destroy expired snapshots that originated from either the host awarnach or
   the host gly.  Be verbose.
      $ ${0##*/} destroy -v awarnach,gly

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
            return 1 ;;
    esac

    return 0
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

ss_st () {
    echo "$1" | sed "s/^.*@ZAP_${hn}_//;s/--[0-9]\{1,4\}[dwmy]$//;s/p/+/"
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

val_rdest () {
    un=$(echo "$1" | cut -d'@' -f1) # extract username
    rest=$(echo "$1" | cut -d'@' -f2) # everything but username
    host=$(echo "$rest" | cut -d":" -f1) # host or ip
    ds=$(echo "$rest" | cut -d":" -f2) # dataset

    ([ -z "$un" ] || echo "$un" | grep -q "$unptn") && \
        echo "$host" | grep -q "$hostptn\|$ipptn" && \
        echo "$ds" | grep -q '[^\0]\+'
}

warn () {
    echo "WARN: $*" > /dev/stderr
}

# ==============================================================================
destroy () {
    while getopts ":v" opt; do
        case $opt in
            v)  v_opt=1 ;;
            \?) fatal "Invalid option: -$OPTARG" ;;
        esac
    done
    shift $(( OPTIND - 1 ))

    if [ -n "$*" ]; then
        # hostname was specified; only delete snapshots for that host
        hl=$(echo "$*" | sed 's/[[:space:]]//g;s/,/\\|/g')
        zptn="@ZAP_\(${hl}\)_..*--[0-9]\{1,4\}[dwmy]"
    fi

    now_ts=$(date '+%s')

    [ -n "$v_opt" ] && printf "%s\nDestroying snapshots...\n" "$(date)"
    for i in $(zfs list -H -t snap -o name); do
        if echo "$i" | grep -q "$zptn"; then
            pool="${i%%/*}"
            if ! pool_ok "$pool"; then
                warn "DID NOT destroy $i because of the state of $pool!"
            elif pool_scrub "$pool"; then
                warn "DID NOT destroy $i because $pool is being scrubbed!"
            else
                snap_ts=$(ss_ts "$(ss_st "$i")")
                ttls=$(ttl2s "$(echo "$i"|grep -o '[0-9]\{1,4\}[dwmy]$')")
                if ! is_pint "$snap_ts" || ! is_pint "$ttls"; then
                    warn "SNAPSHOT $i WAS NOT DESTROYED because its expiration \
time could not be determined."
                else
                    expire_ts=$((snap_ts + ttls))
                    if [ "$now_ts" -gt "$expire_ts" ]; then
                        [ -n "$v_opt" ] && echo "zfs destroy $i"
                        zfs destroy "$i"
                    fi
                fi
            fi
        fi
    done
}

rep_parse () {
    while getopts ":v" opt; do
        case $opt in
            v)  v_opt=1 ;;
            \?) fatal "Invalid option: -$OPTARG" ;;
        esac
    done
    shift $(( OPTIND - 1 ))

    [ -n "$v_opt" ] && printf "%s\nSending snapshots...\n" "$(date)"
    if [ -z "$*" ]; then # use zap:rep property to send
        for f in $(zfs list -H -o name -t volume,filesystem); do
            rdest=$(zfs get -H -o value zap:rep "$f")
            if val_rdest "$rdest"; then
                if [ -n "$v_opt" ]; then
                    rep -v "$f" "$rdest"
                else
                    rep "$f" "$rdest"
                fi
            elif [ "$rdest" != '-' ]; then
                warn "Invalid value in zap:rep user property: $rdest."
                warn "Failed to replicate $f."
            fi
        done
    else
        until [ -z "$1" ] && [ -z "$2" ]; do
            if ! zfs list -H -o name -t volume,filesystem "$1" \
                 > /dev/null 2>&1; then
                warn "Dataset $1 does not exist."
                warn "Failed to replicate $1."
            elif ! val_rdest "$2"; then
                warn "Invalid remote replication location: $2."
                warn "Failed to replicate $1."
            else
                if [ -n "$v_opt" ]; then
                    rep -v "$1" "$2"
                else
                    rep "$1" "$2"
                fi
            fi
            shift 2
        done
    fi
}

rep () {
    while getopts ":v" opt; do
        case $opt in
            v)  v_opt2=1 ;;
            \?) fatal "Invalid option: -$OPTARG" ;;
        esac
    done
    shift $(( OPTIND - 1 ))

    sshto=$(echo "$2" | cut -d':' -f1)
    rloc=$(echo "$2" | cut -d':' -f2)
    lsnap=$(zfs list -rd1 -tsnap -o name -s creation "$1" \
                | grep "@ZAP_${hn}_" | tail -1 | cut -w -f1)
    l_ts=$(ss_ts "$(ss_st "$lsnap")")
    fs=${1#*/}
    # get the youngest remote snapshot for this dataset
    rsnap=$(ssh "$sshto" "zfs list -rd1 -tsnap -o name -s creation $rloc/$fs |\
grep @ZAP_${hn}_ | tail -1 | cut -w -f1 | sed 's/^.*@/@/'")
    if [ -z "$rsnap" ]; then
        [ -n "$v_opt2" ] && \
            echo "No remote snapshots found. Sending full stream."
        if zfs send "$lsnap" | \
                ssh "$sshto" "zfs recv -dFv $rloc"; then
            zfs bookmark "$lsnap" \
                "$(echo "$lsnap" | sed 's/@/#/')"
        else
            warn "Failed to replicate $lsnap to $sshto:$rloc"
        fi
    else # send incremental stream
        r_ts=$(ss_ts "$(ss_st "$rsnap")")
        [ -n "$v_opt2" ] && echo "$lsnap > $sshto:$rloc$rsnap"
        if [ "$l_ts" -gt "$r_ts" ]; then
            ## ensure there is a bookmark for the remote snapshot
            if bm=$(zfs list -rd1 -t bookmark -H -o name "$1" | \
                        grep "${rsnap#@}"); then
                if zfs send -i "$bm" "$lsnap" | \
                        ssh "$sshto" "zfs recv -dv $rloc"; then
                    if zfs bookmark "$lsnap" \
                           "$(echo "$lsnap" | sed 's/@/#/')"; then
                        [ -n "$v_opt2" ] && \
                            echo "Created bookmark for $rsnap"
                    else
                        warn "Failed to create bookmark for $lsnap"
                    fi
                else
                    warn "Failed to replicate $lsnap > $sshto:$rloc"
                fi
            else
                warn "Failed to find bookmark for remote snapshot, $rsnap."
            fi
        fi
    fi
}

snap_parse () {
    while getopts ":v" opt; do
        case $opt in
            v)  v_opt=1 ;;
            \?) fatal "Invalid option: -$OPTARG" ;;
        esac
    done
    shift $(( OPTIND - 1 ))

    ttl="$1"
    shift
    if ! echo "$ttl" | grep -q "$ttlptn"; then
        fatal "Unrecognized TTL $ttl."
    fi

    if [ -z "$*" ]; then # use zap:snap property to create snapshots
        [ -n "$v_opt" ] && printf "%s\nCreating snapshots...\n" "$(date)"
        for f in $(zfs list -Ho name -t volume,filesystem); do
            if [ "$(zfs get -H -o value zap:snap "$f")" = 'on' ]; then
                if [ -n "$v_opt" ]; then
                    snap -v "$ttl" "$f"
                else
                    snap "$ttl" "$f"
                fi
            fi
        done
    else # use arguments to create snapshots
        while getopts ":r:" opt; do
            case $opt in
                r)
                    if [ -n "$v_opt" ]; then
                        snap "$ttl" -v -r "$OPTARG"
                    else
                        snap "$ttl" -r "$OPTARG"
                    fi
                    ;;
                \?) fatal "Invalid snap_parse() option: -$OPTARG" ;;
            esac
        done
        shift $(( OPTIND - 1 ))

        for f in "$@"; do
            if [ -n "$v_opt" ]; then
                snap "$ttl" -v "$f"
            else
                snap "$ttl" "$f"
            fi
        done
    fi
}

snap () {
    while getopts ":rv" opt; do
        case $opt in
            r)  r_opt=1  ;;
            v)  v_opt2=1 ;;
            \?) fatal "Invalid create() option: -$OPTARG" ;;
        esac
    done
    shift $(( OPTIND - 1 ))

    if ! pool_ok "${2%%/*}"; then
        warn "DID NOT snapshot $2 because of pool state!"
    else
        if [ -n "$v_opt2" ]; then
            printf "zfs snap "
            [ -n "$r_opt" ] && printf "\-r "
            echo "${2}@ZAP_${hn}_${date}--${ttl}"
        fi
        if [ -n "$r_opt" ]; then
            zfs snap -r "$2@ZAP_${hn}_${date}--${ttl}"
        else
            zfs snap "$2@ZAP_${hn}_${date}--${ttl}"
        fi
    fi
}
# ==============================================================================

os=$(uname)
case $os in
    'Darwin'|'FreeBSD'|'Linux'|'SunOS') ;;
    *)
        fatal "${0##*/} has not be tested on $os.
       Feedback and patches are welcome." ;;
esac

date=$(date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/+/p/')
hn=$(hostname -s)
hostptn="^\(\([:alnum:]]\|[[:alnum:]][[:alnum:]\-]*[[:alnum:]]\)\.\)*\([[:alnum:]]\|[[:alnum:]][[:alnum:]\-]*[[:alnum:]]\)$"
ipptn="^\(\([0-9]\|[1-9][0-9]\|1[0-9]\{2\}\|2[0-4][0-9]\|25[0-5]\)\.\)\{3\}\([0-9]\|[1-9][0-9]\|1[0-9]\{2\}\|2[0-4][0-9]\|25[0-5]\)$"
ttlptn='^[0-9]\{1,4\}[dwmy]$'
unptn="^[[:alpha:]_][[:alnum:]_-]\{0,31\}$"
zptn="@ZAP_${hn}_..*--[0-9]\{1,4\}[dwmy]"

case $1 in
    snap|snapshot) shift; snap_parse "$@" ;;
    rep|replicate) shift; rep_parse  "$@" ;;
    destroy)       shift; destroy    "$@" ;;
    *)             help                   ;;
esac

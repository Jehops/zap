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
   ${0##*/} snap|snapshot [-dLSv] TTL [-r dataset]... [dataset]...
   ${0##*/} rep|replicate [-dLSv] [[-r dataset]... [dataset]... remote_dest]
   ${0##*/} destroy [-dlsv] [host[,host]...]

DESCRIPTION
   ${0##*/} snap|snapshot [-dLSv] TTL [-r dataset]... [dataset]...

   Create ZFS snapshots that will expire after TTL (time to live) time has
   elapsed.  Expired means they will be destroyed by ${0##*/} destroy.  TTL
   takes the form [0-9]{1,4}[dwmy], i.e., one to four digits followed by a
   character to represent the time unit (day, week, month, or year).  If neither
   [-r dataset]... nor [dataset]... is supplied, snapshots will be created for
   datasets with the property zap:snap set to 'on'.  By default, if the pool is
   in any one of the states DEGRADED, FAULTED, OFFLINE, REMOVED, or UNAVAIL,
   then no snapshots will be created.  Snapshots are still created, by default,
   when the pool has a resilver in progress or is being scrubbed.

   -d  Create snapshots when the pool is in a DEGRADED state.
   -L  Do not create the snapshots if the pool has a resilver in progress.
   -S  Do not create the snapshots if the pool is being scrubbed.
   -v  Be verbose.
   -r  Recursively create snapshots of all descendents.

   ${0##*/} rep|replicate [-dLSv] [local_dataset remote_destination]...

   Remotely replicate datasets via ssh.  Remote destinations are specified in
   zap:rep user properties or as arguments using the format
   [user@]hostname:dataset.  By default, if the pool is in any one of the states
   DEGRADED, FAULTED, OFFLINE, REMOVED, or UNAVAIL, then replication will be
   skipped.  Replication still occurs, by default, when the pool has a resilver
   in progress or is being scrubbed.

   -d  Replicate when the pool is in a DEGRADED state.
   -L  Do not replicate if the pool has a resilver in progress.
   -S  Do not replicate if the pool is being scrubbed.
   -v  Be verbose.

   ${0##*/} destroy [-dsv] [host[,host2]...]

   Destroy expired snapshots.  If a comma separated list of hosts are specified,
   then only delete snapshots originating from those hosts.  Hosts are specified
   without any domain information, i.e., as returned by hostname -s.  By
   default, if the pool is in any one of the states DEGRADED, FAULTED, OFFLINE,
   REMOVED, or UNAVAIL, has a resilver in progress or is being scrubbed, then
   the destroy will be skipped.

   -d  Destroy when the pool is in a DEGRADED state.
   -l  Destroy if the pool has a resilver in progress.
   -s  Destroy if the pool is being scrubbed.
   -v  Be verbose.

EXAMPLES
   Create snapshots that will last for 1 day, 3 weeks, 6 months, and 1 year.
      $ ${0##*/} snap 1d zroot/ROOT/default
      $ ${0##*/} snap 3w tank zroot/usr/home/nox zroot/var
      $ ${0##*/} snap 6m zroot/usr/home/jrm zroot/usr/home/mem
      $ ${0##*/} snap 1y tank/backup

   Create snapshots (recursively for tank and zroot/var) that will expire after
   3 weeks even if if the pool is DEGRADED.  Be verbose.
      $ ${0##*/} snap -dv 3w -r tank -r zroot/var zroot/usr/home/nox

   Create snapshots for datasets with the zap:snap property set to 'on'.
      $ ${0##*/} snap 1d
      $ ${0##*/} snap 3w
      $ ${0##*/} snap 6m
      $ ${0##*/} snap 1y

   Replicate datasets with the zap:rep user property set to a remote
   destination.  Be verbose.
      $ ${0##*/} rep -v

   Replicate datasets from host phe to host bravo.
      $ ${0##*/} rep zroot/ROOT/defalut zroot/usr/home/jrm jrm@bravo:rback/phe

   Destroy expired snapshots.
      $ ${0##*/} destroy

   Destroy expired snapshots that originated from either the host awarnach or
   the host gly.  Be verbose.
      $ ${0##*/} destroy -v awarnach,gly

AUTHORS AND CONTRIBUTORS
   Joseph Mingrone <jrm@ftfl.ca>
   Tobias Kortkamp <t@tobik.me>

BUGS
   https://github.com/Jehops/zap/issues

SEE ALSO
   Refer to http://ftfl.ca/blog/2016-12-27-zfs-replication.html for a
   description of a replication strategy.

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

# pool_ok [-d] pool
# If the -d option is supplied, consider the DEGRADED state ok.
pool_ok () {
    skip="DEGRADED\|FAULTED\|OFFLINE\|REMOVED\|UNAVAIL"
    OPTIND=1
    while getopts ":d" opt; do
        case $opt in
            d)  skip=$(echo "$skip" | sed "s/DEGRADED\\\|//") ;;
            \?) fatal "Invalid pool_ok() option -$OPTARG" ;;
        esac
    done
    shift $(( OPTIND - 1 ))

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

pool_resilver () {
    if zpool status "$1" | grep -q "scan: resilver in progress"; then
        return 0
    fi

    return 1
}

ss_st () {
    # Using an extended regexp here, because $hn may contains a list of
    # alternatives like awarnach|bravo|phe.
    echo "$1" | sed -r "s/^.*@ZAP_(${hn})_//;s/--[0-9]{1,4}[dwmy]$//;s/p/+/"
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
    un=$(echo "$1"      | cut -s -d'@' -f1) # extract username
    rest=$(echo "$1"    | cut    -d'@' -f2) # everything but username
    host=$(echo "$rest" | cut -s -d':' -f1) # host or ip
    ds=$(echo "$rest"   | cut -s -d":" -f2) # dataset

    ([ -z "$un" ] || echo "$un" | grep -q "$unptn") && \
        echo "$host" | grep -q "$hostptn\|$ipptn" && \
        echo "$ds" | grep -q '[^\0]\+'
}

warn () {
    echo "WARN: $*" > /dev/stderr
}

# ==============================================================================
destroy () {
    while getopts ":dlsv" opt; do
        case $opt in
            d)  d_opt='-d' ;;
            l)  l_opt=1    ;;
            s)  s_opt=1    ;;
            v)  v_opt=1    ;;
            \?) fatal "Invalid destroy() option -$OPTARG" ;;
        esac
    done
    shift $(( OPTIND - 1 ))

    if [ -n "$*" ]; then
        # One or more hostnames were specified, so delete snapshots for those
        # hosts.  Using an extended regexp here, because sed in ss_st() requires
        # it for (host1|host2...).
        hn=$(echo "$*" | sed 's/[[:space:]]//g;s/,/|/g')
        zptn="@ZAP_(${hn})_..*--[0-9]{1,4}[dwmy]"
    fi

    now_ts=$(date '+%s')

    [ -n "$v_opt" ] && printf "%s\nDestroying snapshots...\n" "$(date)"
    for i in $(zfs list -H -t snap -o name); do
        if echo "$i" | grep -E -q "$zptn"; then
            pool="${i%%/*}"
            # Do not quote $d_opt, but ensure it does not contain spaces.
            if ! pool_ok $d_opt "$pool"; then
                warn "Did not destroy $i because of pool state."
            elif [ -z "$s_opt" ] && pool_scrub "$pool"; then
                warn "Did not destroy $i because $pool is being scrubbed."
            elif [ -z "$l_opt" ] && pool_resilver "$pool"; then
                warn "Did not destroy $i because $pool has a resilver in \
progress."
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

# rep_parse [-dSv] [[-r dataset]... [dataset]... remote_dest]
rep_parse () {
    while getopts ":dLrSv" opt; do
        case $opt in
            d)  d_opt='-d'        ;;
            S)  L_opt=1           ;;
            r)  r_opt=1           ;;
            S)  S_opt=1           ;;
            v)  v_opt='-v'        ;;
            \?) fatal "Invalid rep_parse() option -$OPTARG." ;;
        esac
    done
    if [ -n "$r_opt" ]; then
        shift $(( OPTIND - 2 ))
    else
        shift $(( OPTIND - 1 ))
    fi

    [ -n "$v_opt" ] && printf "%s\nReplicating...\n" "$(date)"
    if [ -z "$*" ]; then # use zap:rep property to replicate
        for f in $(zfs list -H -o name -t volume,filesystem); do
            rdest=$(zfs get -H -o value zap:rep "$f")
            rep "$f" "$rdest"
        done
    else # use arguments to replicate
        for rdest; do :; done # put the last argument in rdest
        OPTIND=1
        while getopts ":r:" opt; do
            case $opt in
                r)  rep -r "$OPTARG" "$rdest" ;;
                \?) fatal "Invalid rep_parse() option -$OPTARG" ;;
                :)  fatal "rep_parse() option -$OPTARG requires an argument." ;;
            esac
        done
        shift $(( OPTIND - 1 ))

        for f; do # equivalent to: for f in "$@"; do ...; done
            [ "$#" -gt 1 ] && rep "$f" "$rdest"
            shift
        done
    fi
}

# rep [-r] data_set remote_dest
rep () {
    OPTIND=1
    while getopts ":r" opt; do
        case $opt in
            r)  r_opt='-R' ;;
            \?) fatal "Invalid rep() option -$OPTARG" ;;
        esac
    done
    shift $(( OPTIND - 1 ))

    # Do not quote $d_opt, but ensure it does not contain spaces.
    if ! pool_ok $d_opt "${1%%/*}"; then
        warn "DID NOT replicate $1 because of pool state!"
    elif [ -n "$S_opt" ] && pool_scrub "${1%%/*}"; then
        warn "DID NOT replicate $1 because '-S' was supplied and the pool is \
being scrubbed!"
    elif [ -n "$L_opt" ] && pool_scrub "${1%%/*}"; then
        warn "DID NOT replicate $1 because '-L' was supplied and the pool has \
a resilver in progress!"
    elif ! zfs list -H -o name -t volume,filesystem "$1" \
           > /dev/null 2>&1; then
        warn "Dataset $1 does not exist."
        warn "Failed to replicate $1."
    elif ! val_rdest "$2"; then
        trdest=$(echo "$2" | tr '[:upper:]' '[:lower:]')
        if [ "$trdest" != '-' ] && [ "$trdest" != 'off' ]; then
            warn "Invalid remote replication location, $trdest."
            warn "Failed to replicate $1."
        fi
    else
        sshto=$(echo "$2" | cut -d':' -f1)
        rloc=$(echo "$2" | cut -d':' -f2)
        # TODO: validate lsnap
        lsnap=$(zfs list -rd1 -tsnap -o name -s creation "$1" \
                    | grep "@ZAP_${hn}_" | tail -1 | cut -w -f1)
        l_ts=$(ss_ts "$(ss_st "$lsnap")")
        fs="${1#*/}"
        # get the youngest remote snapshot for this dataset
        rsnap=$(ssh "$sshto" "zfs list -rd1 -tsnap -o name -s creation \
$rloc/$fs 2>/dev/null | grep @ZAP_${hn}_ | tail -1 | sed 's/^.*@/@/'")
        if [ -z "$rsnap" ]; then
            [ -n "$v_opt" ] && \
                echo "No remote snapshots found. Sending full stream."
            # $r_opt may by empty, so do not quote it, but ensure it never
            # contains whitespace.
            if zfs send -p $r_opt "$lsnap" | \
                    ssh "$sshto" "zfs recv -dFu $v_opt $rloc"; then
                zfs bookmark "$lsnap" \
                    "$(echo "$lsnap" | sed 's/@/#/')"
            else
                warn "Failed to replicate $lsnap to $sshto:$rloc"
            fi
        else # send incremental stream
            r_ts=$(ss_ts "$(ss_st "$rsnap")")
            if [ -n "$v_opt" ]; then
                printf "Newest snapshots:\nlocal: %s\nremote: %s\n" \
                       "$lsnap" "$sshto:$rloc/$fs$rsnap"
            fi
            if [ "$l_ts" -gt "$r_ts" ]; then
                ## ensure there is a bookmark for the remote snapshot
                if bm=$(zfs list -rd1 -t bookmark -H -o name "$1" | \
                            grep "${rsnap#@}"); then
                    if zfs send -i "$bm" "$lsnap" | \
                            ssh "$sshto" "zfs recv -du $v_opt $rloc" ; then
                        if zfs bookmark "$lsnap" \
                               "$(echo "$lsnap" | sed 's/@/#/')"; then
                            [ -n "$v_opt" ] && \
                                echo "Created bookmark for $lsnap"
                        else
                            warn "Failed to create bookmark for $lsnap"
                        fi
                    else
                        warn "Failed to replicate $lsnap > $sshto:$rloc"
                    fi
                else
                    warn "Failed to find bookmark for remote snapshot, $rsnap."
                fi
            else
                [ -n "$v_opt" ] && echo "Nothing new to replicate."
            fi
        fi
    fi
}

# snap_parse [-dSv] TTL [-r dataset]... [dataset]...
snap_parse () {
    while getopts ":dLSv" opt; do
        case $opt in
            d)  d_opt='-d'        ;;
            L)  L_opt=1           ;;
            S)  S_opt=1           ;;
            v)  v_opt=1           ;;
            \?) fatal "Invalid snap_parse() option -$OPTARG." ;;
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
                snap "$f"
            fi
        done
    else # use arguments to create snapshots
        OPTIND=1
        while getopts ":r:" opt; do
            case $opt in
                r)  snap -r "$OPTARG" ;;
                \?) fatal "Invalid snap_parse() option -$OPTARG" ;;
                :)  fatal "snap_parse: Option -$OPTARG requires an argument." ;;
            esac
        done
        shift $(( OPTIND - 1 ))

        for f; do # equivalent to: for f in "$@"; do ...; done
            snap "$f"
        done
    fi
}

# snap [-r] dataset
snap () {
    OPTIND=1
    unset r_opt
    while getopts ":r" opt; do
        case $opt in
            r)  r_opt='-r' ;;
            \?) fatal "Invalid snap() option -$OPTARG" ;;
        esac
    done
    shift $(( OPTIND - 1 ))

    # Do not quote $d_opt, but ensure it does not contain spaces.
    if ! pool_ok $d_opt "${1%%/*}"; then
        warn "DID NOT snapshot $1 because of pool state!"
    elif [ -n "$S_opt" ] && pool_scrub "${1%%/*}"; then
        warn "DID NOT snapshot $1 because '-S' was supplied and the pool is \
being scrubbed!"
    elif [ -n "$L_opt" ] && pool_resilver "${1%%/*}"; then
        warn "DID NOT snapshot $1 because '-L' was supplied and the pool has \
a resilver in progress!"
    else
        if [ -n "$v_opt" ]; then
            printf "zfs snap "
            [ -n "$r_opt" ] && printf "\-r "
            echo "$1@ZAP_${hn}_${date}--${ttl}"
        fi
        # Do not quote $d_opt, but ensure it does not contain spaces.
        zfs snap $r_opt "$1@ZAP_${hn}_${date}--${ttl}"
    fi
}
# ==============================================================================

os=$(uname)
case $os in
    # Needs testing on Linux
    #'Darwin'|'FreeBSD'|'Linux'|'SunOS') ;;
    'FreeBSD') ;;
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

#!/bin/sh

# ==============================================================================
# Copyright (c) 2021, Joseph Mingrone.  All rights reserved.
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

# if [ "$(zpool get -H -o value feature@encryption zroot)" = 'enabled' ]; then echo yes; else echo no; fi

fatal () {
  echo "FATAL: $*" 1>&2
  exit 1
}

is_pint () {
  case $1 in
    ''|*[!0-9]*|0*)
      return 1 ;;
  esac
  return 0
}

# pool_ok [-D] <pool>
# If the -D option is supplied, do not consider the DEGRADED state ok.
pool_ok () {
  skip='state: (FAULTED|OFFLINE|REMOVED|UNAVAIL)'
  OPTIND=1
  while getopts ":D" opt; do
    case $opt in
      D)  skip='state: (DEGRADED|FAULTED|OFFLINE|REMOVED|UNAVAIL)' ;;
      \?) fatal "Invalid pool_ok() option: -$OPTARG" ;;
    esac
  done
  shift $(( OPTIND - 1 ))

  if zpool status "$1" | grep -Eq "$skip"; then
    return 1
  fi
  return 0
}

# pool_scrub <pool>
pool_scrub () {
  if zpool status "$1" | grep -q "scrub in progress"; then
    return 0
  fi
  return 1
}

# pool_resilver <pool>
pool_resilver () {
  if zpool status "$1" | grep -q "scan: resilver in progress"; then
    return 0
  fi
  return 1
}

# pool encs <pool>
pool_encs () {
  if [ "$(zpool get -H -o value feature@encryption "$1")" = 'active' ]; then
    return 0;
  fi
  return 1;
}

# ss_st <snapshot>
# Extract zap snapshot time.
ss_st () {
  # Using an extended regexp here, because $hn may contain a list of
  # alternatives like awarnach|bravo|phe.
  echo "$1" | sed -r "s/^.*@ZAP_(${hn})_//;s/--[0-9]{1,4}[dwmy]$//;s/p/+/"
}

# ss_ts <YYYY-MM-DDTHH:MM:SS±hhmm>
# Return a zap snapshot timestamp (seconds since epoch) given snapshot time in
# the format YYYY-MM-DDTHH:MM:SS±hhmm.
ss_ts () {
  case $os in
    'Darwin'|'FreeBSD')
      date -j -f'%Y-%m-%dT%H:%M:%S%z' "$1" +%s
      ;;
    'SunOS')
      date -d"$(echo "$1" | sed 's/T/ /')" +%s
      ;;
    'Linux')
      if [ $is_busybox_date -eq 0 ]; then
        # busybox does not support timezones by default
        if [ $is_glibc -eq 0 ]; then
          # busybox date can use [e]glibc strptime %z extension
          date -D'%Y-%m-%dT%H:%M:%S%z' -d"$1" +%s
        else
          # need to calculate tz offset manually
          # NOTE: no support for 'Z' offset, should never happen with %z fmt;
          #       however, older versions of coreutils may use [+-]hh:mm
          offset=$(echo "$1" | grep -Eo '[+-]\d\d:?\d\d$')
          if [ $? -ne 0 ]; then
            echo "bad snapshot timestamp: $1" >&2
            exit 1
          fi
          sign=${offset:0:1}
          h=${offset:1:2}
          if [ "${offset:3:1}" = ':' ]; then
            m=${offset:4:2}
          else
            m=${offset:3:2}
          fi
          if [ $m -gt 59 ]; then
            echo "bad snapshot timezone offset: $offset" >&2
            exit 1
          fi
          sec=$(date -ud"$(echo "${1%$offset}" | sed 's/T/ /')" +%s)
          [ $? -ne 0 ] && exit 1
          echo "$sec $sign (($h * 60 + $m) * -60)" | bc
        fi
      else
        # assuming non-busybox date is coreutils which supports timezone offset
        date -d"$(echo "$1" | sed 's/T/ /')" +%s
      fi
      ;;
    'NetBSD')
      ndate=$(echo "$1" | sed 's/\+.*//;s/[T-]//g;s/://;s/:/./')
      date -j "$ndate" +%s
      ;;
  esac
}

# ttl2s <time-to-live>
# Return a zap snapshot time-to-live argument to seconds.
ttl2s () {
  echo "$1" | sed 's/d/*86400/;s/w/*604800/;s/m/*2592000/;s/y/*31536000/' | bc
}

usage () {
  echo "$*" 1>&2
  cat <<EOF 1>&2
usage:
   ${0##*/} snap|snapshot [-DLSv] TTL [[-r] dataset]...
   ${0##*/} rep|replicate [-DFLSv] [[user@]host:parent_dataset
                               [-r] dataset [[-r] dataset]...]
   ${0##*/} destroy [-Dlsv] [host[,host]...]
   ${0##*/} -v|-version|--version

EOF
}

# val_dest <destination>
val_dest () {
  case $1 in
    *:*)
      case $1 in
        *@*)
          un=${1%%@*}
          rest=${1#*@}
          ;;
        *)
          rest="$1"
          ;;
      esac
      host=${rest%%:*} # host or ip
      ds=${rest##*:} # dataset

      # TODO: there other ways to express ::1, but ignore them for now
      if [ "$host" = "localhost" ] || echo "$host" | grep -Eq "$iplbptn"; then
        host=""
      fi

      # TODO: The test for the host or IP is not that helpful, because many
      # invalid IPs will match a valid hostname.
      { [ -z "$un" ] || echo "$un" | grep -Eq "$unptn"; } && \
        { [ -z "$host" ] || echo "$host" | \
              grep -Eq "$hostptn|$ipv4ptn|$ipv6ptn"; } && \
        echo "$ds" | grep -Eq "$dsptn"
      ;;
    *)
      ds="$1"
      echo "$ds" | grep -Eq "$dsptn"
      ;;
  esac
}

warn () {
  echo "WARN: $*" >&2
}

# ==============================================================================
destroy () {
  while getopts ":Dlsv" opt; do
    case $opt in
      D)  D_opt='-D' ;;
      l)  l_opt=1    ;;
      s)  s_opt=1    ;;
      v)  v_opt=1    ;;
      \?) fatal "Invalid destroy() option: -$OPTARG" ;;
    esac
  done
  shift $(( OPTIND - 1 ))

  if [ -n "$*" ]; then
    # One or more hostnames were specified, so delete snapshots for those
    # hosts.
    hn=$(echo "$*" | sed 's/[[:space:]]//g;s/,/|/g')
    zptn="@ZAP_(${hn})_..*--[0-9]{1,4}[dwmy]"
  fi

  now_ts=$(date '+%s')

  [ -n "$v_opt" ] && printf '%s\nDestroying snapshots...\n' "$(date)"
  for i in $(zfs list -H -t snap -o name); do
    if echo "$i" | grep -Eq "$zptn"; then
      pool="${i%%[/@]*}"
      # Do not quote $D_opt, but ensure it does not contain spaces.
      if ! pool_ok $D_opt "$pool"; then
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

# rep_parse [-CDFLSv] [-h host] [destination [-r] dataset [[-r] dataset]...]
rep_parse () {
  while getopts ":CDFLSvh:" opt; do
    case $opt in
      C)  C_opt=1           ;;
      D)  D_opt='-D'        ;;
      L)  L_opt=1           ;;
      S)  S_opt=1           ;;
      v)  v_opt='-v'        ;;
      F)  F_opt='-F'        ;;
      h)
          hn="$OPTARG"
          (echo "$hn" | grep -Eq "$hostalone") || fatal "Invalid hostname $hn."
          ;;
      \?) fatal "Invalid rep_parse() option: -$OPTARG." ;;
    esac
  done
  shift $(( OPTIND - 1 ))

  if [ -n "$C_opt" ]; then # user has request no compression
    C_opt=
  else # use compression by default
    C_opt='-c'
  fi
  [ -n "$v_opt" ] && printf '%s\nReplicating %s...\n' "$(date)" "$hn"
  if [ -z "$*" ]; then # use zap:rep property to replicate
    for f in $(zfs list -H -o name -t volume,filesystem); do
      dest=$(zfs get -H -o value zap:rep "$f")
      sshto=${dest%:*}
      rloc=${dest##*:} # replication location
      if ! val_dest "$dest"; then
        [ "$dest" = '-' ] || \
          warn "Failed to replicate to $2.  Invalid destination."
      else
        tdest=$(echo "$dest" | tr '[:upper:]' '[:lower:]')
        if [ "$tdest" != 'off' ]; then
          if [ -z "$host" ]; then
            rzsv=$(zfs get -H -o value -t filesystem zap:snap "$rloc")
          else
            rzsv=$(ssh "$sshto" "sh -c 'zfs get -H -o value -t filesystem \
zap:snap $rloc'")
          fi
          rzsv=$(echo "$rzsv" | tr '[:upper:]' '[:lower:]')
          if [ "$rzsv" = 'on' ]; then
            warn "zap:snap is on for the target dataset, $dest."
            warn "Refusing to replicate to $dest."
          else
            rep "$f" "$dest"
          fi
        fi
      fi
    done
  else # use arguments to replicate
    dest="$1"; shift
    sshto=${dest%:*}
    rloc=${dest##*:} # replication location
    if ! val_dest "$dest"; then
      warn "Failed to replicate to $2.  Invalid destination."
    else
      if [ -z "$host" ]; then
        rzsv=$(zfs get -H -o value -t filesystem zap:snap "$rloc")
      else
        rzsv=$(ssh "$sshto" "sh -c 'zfs get -H -o value -t filesystem \
zap:snap $rloc'")
      fi
      rzsv=$(echo "$rzsv" | tr '[:upper:]' '[:lower:]')
      if [ "$rzsv" = 'on' ]; then
        warn "zap:snap is on for the target dataset, $dest."
        warn "Refusing to replicate to $dest."
      else
        while [ "$#" -gt 0 ]; do
          OPTIND=1
          while getopts ":r:" opt; do
            case $opt in
              r)
                for f in $(zfs list -H -o name -t filesystem,volume -r \
                               "$OPTARG"); do
                  rep "$f" "$dest"
                done
                ;;
              \?) fatal "Invalid rep_parse() option: -$OPTARG" ;;
              :)  fatal "rep_parse() option -$OPTARG requires an argument." ;;
            esac
          done
          shift $(( OPTIND - 1 ))
          if [ "$#" -gt 0 ]; then
            rep "$1" "$dest"
            shift
          fi
        done
      fi
    fi
  fi
}

# replicate full stream
# rep_full <dataset>
rep_full() {
  # variable            | set in..
  # --------------------|------------
  # v_opt,rloc,sshto    | rep_parse()
  # host                | val_dest()
  # fs,lsnap            | rep()

  if pool_encs "${lsnap%%[/@]*}"; then
    rep_args='-wp'
  else
    rep_args='-Lep'
  fi

  if [ -z "$host" ]; then # replicating locally
    [ -n "$v_opt" ] && \
      echo "zfs send $rep_args $C_opt $lsnap | zfs recv -Fu $v_opt -d $rloc"
    if zfs send $rep_args $C_opt "$lsnap" | zfs recv -Fu $v_opt -d "$rloc"; then
      [ -n "$v_opt" ] && \
        echo "zfs bookmark $lsnap $(echo "$lsnap" | sed 's/@/#/')"
      zfs bookmark "$lsnap" "$(echo "$lsnap" | sed 's/@/#/')"
      if [ "$(zfs get -H -o value canmount "$1")" = 'on' ]; then
        if zfs set canmount=noauto "${rloc}${fs}"; then
          echo "Set canmount=noauto for ${rloc}${fs}";
        else warn "Failed to set canmount=noauto for ${rloc}${fs}"
        fi
      fi
      if zfs set zap:snap=off "${rloc}${fs}"; then
        [ -n "$v_opt" ] && echo "Set zap:snap=off for ${rloc}${fs}";
      else warn "Failed to set zap:snap=offfor ${rloc}${fs}"
      fi
      if zfs set zap:rep=off "${rloc}${fs}"; then
        [ -n "$v_opt" ] && echo "Set zap:rep=off for ${rloc}${fs}";
      else warn "Failed to set zap:rep=off for ${rloc}${fs}"
      fi
    else warn "Failed to replicate $lsnap to $sshto:$rloc"
    fi
  else # replicating remotely
    if rsend "$rep_args $C_opt $lsnap" "zfs recv -Fu $v_opt -d $rloc"; then
      [ -n "$v_opt" ] && \
        echo "zfs bookmark $lsnap $(echo "$lsnap" | sed 's/@/#/')"
      zfs bookmark "$lsnap" "$(echo "$lsnap" | sed 's/@/#/')"
      if ssh "$sshto" "sh -c 'zfs set zap:snap=off ${rloc}${fs}'"; then
        [ -n "$v_opt" ] && echo "zfs set zap:snap=off for $sshto:${rloc}${fs}"
      else warn "Failed to set zap:snap=off for for $sshto:${rloc}${fs}"
      fi
      if ssh "$sshto" "sh -c 'zfs set zap:rep=off ${rloc}${fs}'"; then
        [ -n "$v_opt" ] && echo "zfs set zap:rep=off for $sshto:${rloc}${fs}"
      else warn "Failed to set zap:rep=off for for $sshto:${rloc}${fs}"
      fi
      if [ "$(zfs get -H -o value canmount "$1")" = 'on' ]; then
        if ssh "$sshto" "sh -c 'zfs set canmount=noauto ${rloc}${fs}'"; then
          [ -n "$v_opt" ] && echo "Set canmount=noauto for $sshto:${rloc}${fs}"
        else warn "Failed to set canmount=noauto for $sshto:${rloc}${fs}"
        fi
      fi
    else warn "Failed to replicate $lsnap to $sshto:$rloc"
    fi
  fi
}

# replicate incremental stream
# rep_incr <dataset>
rep_incr() {
  # variable                       | set in..
  # -------------------------------|------------
  # F_opt,v_opt,rloc,sshto         | rep_parse()
  # host                           | val_dest()
  # lsnap,l_ts,rsnap,fs            | rep()

  if pool_encs "${lsnap%%[/@]*}"; then
    rep_args='-w'
  else
    rep_args='-Le'
  fi

  r_ts=$(ss_ts "$(ss_st "$rsnap")")
  if [ "$l_ts" -gt "$r_ts" ]; then
    ## check if there is a local snapshot for the remote snapshot
    if ! sp=$(zfs list -rd1 -t snap -H -o name "$1" | grep "$rsnap"); then
      warn "Failed to find local snapshot for remote snapshot\
${rloc}${fs}${rsnap}."
      warn "Will attempt to fall back to a bookmark, but all\
intermediary snapshots will not be sent."
    fi
    ## check if there is a bookmark for the remote snapshot
    if [ -z "$sp" ] && ! sp=$(zfs list -rd1 -t bookmark -H -o name \
                                  "$1" | grep "${rsnap#@}"); then
      warn "Failed to find bookmark for remote snapshot ${rloc}${fs}${rsnap}."
      warn "Failed to replicate $lsnap to $sshto:$rloc."
    else
      if echo "$sp" | grep -q '@'; then i='-I'; else i='-i'; fi
      if [ -z "$host" ]; then # replicate locally
        [ -n "$v_opt" ] && \
          echo "zfs send $rep_args $C_opt $i $sp $lsnap | zfs recv -du $F_opt \
$v_opt $rloc"
        if zfs send $rep_args $C_opt $i "$sp" "$lsnap" | \
            zfs recv -du $F_opt $v_opt "$rloc"; then
          [ -n "$v_opt" ] && \
            echo "zfs bookmark $lsnap $(echo "$lsnap" | sed 's/@/#/')"
          if zfs bookmark "$lsnap" "$(echo "$lsnap" | sed 's/@/#/')"; then
            [ -n "$v_opt" ] && echo "Created bookmark for $lsnap."
          else warn "Failed to create bookmark for $lsnap."
          fi
        else warn "Failed to replicate $lsnap to $sshto:$rloc."
        fi
      else # replicate remotely
        if rsend "$rep_args $C_opt $i $sp $lsnap" \
                 "zfs recv -du $F_opt $v_opt $rloc"; then
          [ -n "$v_opt" ] && \
            echo "zfs bookmark $lsnap $(echo "$lsnap" | sed 's/@/#/')"
          if zfs bookmark "$lsnap" "$(echo "$lsnap" | sed 's/@/#/')"; then
            [ -n "$v_opt" ] && echo "Created bookmark for $lsnap."
          else warn "Failed to create bookmark for $lsnap."
          fi
        else warn "Failed to replicate $lsnap to $sshto:$rloc."
        fi
      fi
    fi
  else
    [ -n "$v_opt" ] && echo "$1: Nothing new to replicate."
  fi
}

# destination contains no single quotes
# rep <dataset> <destination>
rep () {
  # Do not quote $D_opt, but ensure it does not contain spaces.
  if ! pool_ok $D_opt "${1%%/*}"; then
    warn "DID NOT replicate $1 because of pool state."
  elif [ -n "$S_opt" ] && pool_scrub "${1%%/*}"; then
    warn "DID NOT replicate $1 because '-S' was supplied and the pool is \
being scrubbed."
  elif [ -n "$L_opt" ] && pool_scrub "${1%%/*}"; then
    warn "DID NOT replicate $1 because '-L' was supplied and the pool has \
a resilver in progress."
  elif ! zfs list -H -o name -t volume,filesystem "$1" \
         > /dev/null 2>&1; then
    warn "Dataset $1 does not exist."
    warn "Failed to replicate $1."
  elif ! lsnap=$(zfs list -rd1 -H -tsnap -o name -S creation "$1" \
                   | grep -m1 "@ZAP_${hn}_") || [ -z "$lsnap" ]; then
    warn "Failed to find the newest local snapshot of $hn for $1."
  else
    l_ts=$(ss_ts "$(ss_st "$lsnap")")
    [ "${1#*/}" = "${1}" ] || fs="/${1#*/}"
    # get the youngest replicated snapshot for this dataset
    # $host extracted in val_dest(). If it is empty, we are replicating locally.
    if [ -z "$host" ]; then
      rsnap=$(zfs list -rd1 -H -tsnap -o name -S creation "${rloc}${fs}" \
                  2>/dev/null | head -n1 | sed 's/^.*@/@/')
    else
      rsnap=$(ssh "$sshto" "sh -c 'zfs list -rd1 -H -tsnap -o name -S \
creation ${rloc}${fs} 2>/dev/null | head -n1'" | sed 's/^.*@/@/')
    fi
    if [ -z "$rsnap" ]; then # replicate full stream
      [ -n "$v_opt" ] && \
        echo "No remote snapshots found. Sending full stream."
      # $host extracted in val_dest()
      rep_full "$1"
    elif [ "${rsnap#*@ZAP_${hn}_}" = "${rsnap}" ]; then
      echo "Failed to replicate $1, because the youngest snapshot for \
$sshto:$rloc/$fs was not created by zap."
    else # send incremental stream
      rep_incr "$1"
    fi
  fi
}

rsend() {
  if [ -n "$ZAP_FILTER" ] || [ -n "$ZAP_FILTER_REMOTE" ]; then
    if [ -n "$ZAP_FILTER" ]; then
      if [ -z "$ZAP_FILTER_REMOTE" ]; then # Only ZAP_FILTER is set
        ZAP_FILTER_REMOTE="$ZAP_FILTER"
      fi
      if [ -n "$v_opt" ]; then
        printf "zfs send %s | %s | ssh %s sh -c '%s | %s'\\n" \
               "$1" "$ZAP_FILTER" "$sshto" "$ZAP_FILTER_REMOTE" "$2"
      fi
      zfs send $1 | $ZAP_FILTER | ssh "$sshto" "sh -c '$ZAP_FILTER_REMOTE | $2'"
    else # Only ZAP_FILTER_REMOTE is set
      if [ -n "$v_opt" ]; then
        printf "zfs send %s | ssh %s sh -c '%s | %s'\\n" "$1" "$sshto" \
               "$ZAP_FILTER_REMOTE" "$2"
      fi
      zfs send $1 | ssh "$sshto" "sh -c '$ZAP_FILTER_REMOTE | $2'"
    fi
  else
    if [ -n "$v_opt" ]; then
      printf "zfs send %s | ssh %s sh -c '%s'\\n" "$1" "$sshto" "$2"
    fi
    zfs send $1 | ssh "$sshto" "sh -c '$2'"
  fi
}

# snap_parse [-DLSv] TTL [[-r] dataset [[-r] dataset]...]
snap_parse () {
  while getopts ":DLSv" opt; do
    case $opt in
      D)  D_opt='-D'        ;;
      L)  L_opt=1           ;;
      S)  S_opt=1           ;;
      v)  v_opt=1           ;;
      \?) fatal "Invalid snap_parse() option: -$OPTARG." ;;
    esac
  done
  shift $(( OPTIND - 1 ))

  ttl="$1"
  shift
  if ! echo "$ttl" | grep -Eq "$ttlptn"; then
    fatal "Unrecognized TTL $ttl."
  fi

  if [ -z "$*" ]; then # use zap:snap property to create snapshots
    [ -n "$v_opt" ] && printf '%s\nCreating snapshots...\n' "$(date)"
    for f in $(zfs list -Ho name -t volume,filesystem); do
      if [ "$(zfs get -H -o value zap:snap "$f")" = 'on' ]; then
        snap "$f"
      fi
    done
  else # use arguments to create snapshots
    while [ "$#" -gt 0 ]; do
      OPTIND=1
      while getopts ":r:" opt; do
        case $opt in
          r)  snap -r "$OPTARG" ;;
          \?) fatal "Invalid snap_parse() option: -$OPTARG" ;;
          :)  fatal "snap_parse: Option -$OPTARG requires an \
argument." ;;
        esac
      done
      shift $(( OPTIND - 1 ))

      if [ "$#" -gt 0 ]; then
        snap "$1"
        shift
      fi
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
      \?) fatal "Invalid snap() option: -$OPTARG" ;;
    esac
  done
  shift $(( OPTIND - 1 ))

  # Do not quote $D_opt, but ensure it does not contain spaces.
  if ! pool_ok $D_opt "${1%%/*}"; then
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
      [ -n "$r_opt" ] && printf '%s ' '-r'
      echo "$1@ZAP_${hn}_${date}--${ttl}"
    fi
    # Do not quote $r_opt, but ensure it does not contain spaces.
    zfs snap $r_opt "$1@ZAP_${hn}_${date}--${ttl}"
  fi
}
# ==============================================================================

os=$(uname)
case $os in
  # Needs testing
  # 'Darwin'|'Linux'|'SunOS') ;;
  'FreeBSD') ;;
  *)
    warn "${0##*/} has not be sufficiently tested on $os.
      Feedback and patches are welcome.
" ;;
esac

if [ "$os" = Linux ]; then
  # cache some checks
  ldd --version 2>&1 | head -1 | grep -Eqiw 'e?glibc'
  is_glibc=$?
  [ "busybox" = "$(basename "$(readlink -f "$(command -v date)")")" ]
  is_busybox_date=$?
fi

date=$(date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/+/p/')
hn=$(hostname -s)
if [ -z "$hn" ]; then
  fatal "Failed to find hostname."
fi

# extended REs for egrep
# portability of {} in egrep is uncertain
dsptn='^\w[[:alnum:]_.:-]*(/[[:alnum:]_\.:-]+)*$'
hostptn='^((\w|\w[[:alnum:]-]*\w)\.)*(\w|\w[[:alnum:]-]*\w)$'
hostalone='^(\w|\w[[:alnum:]-]*\w)$'
# goo.gl/t3meuX (Stackoverflow answer about IP regexp)
ipv4ptn="^((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|\
1{0,1}[0-9]){0,1}[0-9])$"
ipv6ptn="^([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|\
([0-9a-fA-F]{1,4}:){1,7}:|\
([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|\
([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|\
([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|\
([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|\
([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|\
[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|\
:((:[0-9a-fA-F]{1,4}){1,7}|:)|\
[fF][eE]80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|\
::([fF]{4}(:0{1,4}){0,1}:){0,1}\
((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}\
(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|\
([0-9a-fA-F]{1,4}:){1,4}:\
((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}\
(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])$"
iplbptn="^(127\.((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){2,2}\
(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))$|^::1$"
ttlptn='^[0-9]{1,4}[dwmy]$'
unptn='^[[:alnum:]_][[:alnum:]_-]{0,31}$'
zptn="@ZAP_(${hn})_..*--[0-9]{1,4}[dwmy]"

readonly version=0.8.2

case $1 in
  snap|snapshot) shift; snap_parse "$@" ;;
  rep|replicate) shift; rep_parse  "$@" ;;
  destroy)       shift; destroy    "$@" ;;
  -v|-version|--version) echo "$version" >&2 ;;
  *)             usage "${0##*/}: missing or unknown subcommand -- $1"; exit 1 ;;
esac

#!/bin/sh

# ==============================================================================
# Copyright (c) 2018, Joseph Mingrone.  All rights reserved.
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

# pool_ok [-D] pool
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

## Snapshot snap time
ss_st () {
  # Using an extended regexp here, because $hn may contain a list of
  # alternatives like awarnach|bravo|phe.
  echo "$1" | sed -r "s/^.*@ZAP_(${hn})_//;s/--[0-9]{1,4}[dwmy]$//;s/p/+/"
}

## Snapshot time in seconds since epoch
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
      if [ "$host" = "localhost" ] || \
           [ "$host" = "::1" ] || \
           echo "$host" | grep -Eq "$ipv4llptn"; then
        host=""
      fi

      # TODO: The test for the host or IP is not that helpful, because many
      # invalid IPs will match a valid hostname.
      ([ -z "$un" ] || echo "$un" | grep -Eq "$unptn") && \
        ([ -z "$host" ] || echo "$host" | \
             grep -Eq "$hostptn|$ipv4ptn|$ipv6ptn") && \
        echo "$ds" | grep -Eq "$dsptn"
      ;;
    *)
      ds="$1"
      echo "$ds" | grep -Eq "$dsptn"
      ;;
  esac
}

warn () {
  echo "WARN: $*" > /dev/stderr
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
    # hosts.  Using an extended regexp here, because sed in ss_st() requires
    # it for (host1|host2...).
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

# rep_parse [-DLSv] [destination [-r] dataset [[-r] dataset]...]
rep_parse () {
  while getopts ":DFLSv" opt; do
    case $opt in
      D)  D_opt='-D'        ;;
      L)  L_opt=1           ;;
      S)  S_opt=1           ;;
      v)  v_opt='-v'        ;;
      F)  F_opt='-F'        ;;
      \?) fatal "Invalid rep_parse() option: -$OPTARG." ;;
    esac
  done
  shift $(( OPTIND - 1 ))

  [ -n "$v_opt" ] && printf '%s\nReplicating...\n' "$(date)"
  if [ -z "$*" ]; then # use zap:rep property to replicate
    for f in $(zfs list -H -o name -t volume,filesystem); do
      dest=$(zfs get -H -o value zap:rep "$f")
      rep "$f" "$dest"
    done
  else # use arguments to replicate
    dest="$1"; shift
    while [ "$#" -gt 0 ]; do
      OPTIND=1
      while getopts ":r:" opt; do
        case $opt in
          r)
            for f in $(zfs list -H -o name -t filesystem,volume -r "$OPTARG"); do
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
}

# replicate full stream
# rep_full dataset
rep_full() {
  # variable            | set in..
  # --------------------|------------
  # host                | val_dest()
  # v_opt               | rep_parse()
  # fs,lsnap,rloc,sshto | rep()

  if [ -z "$host" ]; then # replicating locally
    [ -n "$v_opt" ] && echo "zfs send -p $lsnap | zfs recv -Fu $v_opt -d $rloc"
    if zfs send -p "$lsnap" | zfs recv -Fu $v_opt -d "$rloc"; then
      [ -n "$v_opt" ] && \
        echo "zfs bookmark $lsnap $(echo "$lsnap" | sed 's/@/#/')"
      zfs bookmark "$lsnap" "$(echo "$lsnap" | sed 's/@/#/')"
      if [ "$(zfs get -H -o value canmount "$1")" = 'on' ]; then
        if zfs set canmount=noauto "${rloc}${fs}"; then
          echo "Set canmount=noauto for ${rloc}${fs}";
        else warn "Failed to set canmount=noauto for ${rloc}${fs}"
        fi
      fi
    else warn "Failed to replicate $lsnap to $sshto:$rloc"
    fi
  else # replicating remotely
    [ -n "$v_opt" ] && \
      echo "zfs send -p $lsnap | ssh $sshto \"sh -c 'zfs recv -Fu $v_opt \
-d $rloc'\""
    # interpret remote command with sh to avoid surprises with remote shell
    if zfs send -p "$lsnap" | \
        ssh "$sshto" "sh -c 'zfs recv -Fu $v_opt -d $rloc'"; then
      [ -n "$v_opt" ] && \
        echo "zfs bookmark $lsnap $(echo "$lsnap" | sed 's/@/#/')"
      zfs bookmark "$lsnap" "$(echo "$lsnap" | sed 's/@/#/')"
      if [ "$(zfs get -H -o value canmount "$1")" = 'on' ]; then
        # interpret remote command with sh to avoid surprises with remote shell
        if ssh "$sshto" "sh -c 'zfs set canmount=noauto ${rloc}${fs}'"
        then
          [ -n "$v_opt" ] && echo "Set canmount=noauto for $sshto:${rloc}${fs}"
        else warn "Failed to set canmount=noauto for $sshto:${rloc}${fs}"
        fi
      fi
    else warn "Failed to replicate $lsnap to $sshto:$rloc"
    fi
  fi
}

# replicate incremental stream
# rep_incr dataset
rep_incr() {
  # variable                       | set in..
  # -------------------------------|------------
  # host                           | val_dest()
  # F_opt,v_opt                    | rep_parse()
  # lsnap,l_ts,rloc,rsnap,fs,sshto | rep()
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
          echo "zfs send $i $sp $lsnap | zfs recv -du $F_opt $v_opt $rloc"
        if zfs send $i "$sp" "$lsnap" | zfs recv -du $F_opt $v_opt "$rloc"; then
          [ -n "$v_opt" ] && \
            echo "zfs bookmark $lsnap $(echo "$lsnap" | sed 's/@/#/')"
          if zfs bookmark "$lsnap" "$(echo "$lsnap" | sed 's/@/#/')"; then
            [ -n "$v_opt" ] && echo "Created bookmark for $lsnap."
          else warn "Failed to create bookmark for $lsnap."
          fi
        else warn "Failed to replicate $lsnap to $sshto:$rloc."
        fi
      else # replicate remotely
        [ -n "$v_opt" ] && \
          echo "zfs send $i $sp $lsnap | ssh $sshto \"sh -c 'zfs recv -du \
$F_opt $v_opt $rloc'\""
        # interpret remote command with sh to avoid surprises with remote shell
        if zfs send $i "$sp" "$lsnap" | \
            ssh "$sshto" "sh -c 'zfs recv -du $F_opt $v_opt $rloc'"; then
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

# rep dataset destination
# destination contains no single quotes
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
  elif ! val_dest "$2"; then
    tdest=$(echo "$2" | tr '[:upper:]' '[:lower:]')
    if [ "$tdest" != '-' ] && [ "$tdest" != 'off' ]; then
      warn "Invalid remote replication location: $tdest."
      warn "Failed to replicate $1."
    fi
  elif ! lsnap=$(zfs list -rd1 -H -tsnap -o name -S creation "$1" \
                   | grep -m1 "@ZAP_${hn}_") || [ -z "$lsnap" ]; then
    warn "Failed to find the newest local snapshot for $1."
  else
    sshto=${2%:*}
    rloc=${2##*:} # replication location
    l_ts=$(ss_ts "$(ss_st "$lsnap")")
    [ "${1#*/}" = "${1}" ] || fs="/${1#*/}"
    # get the youngest replicated snapshot for this dataset
    # $host extracted in val_dest(). If it is empty, we are replicating locally.
    if [ -z "$host" ]; then
      rsnap=$(zfs list -rd1 -H -tsnap -o name -S creation "${rloc}${fs}" \
                  2>/dev/null | head -n1 | sed 's/^.*@/@/')
    else
      # interpret remote command with sh to avoid surprises with remote shell
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

date=$(date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/+/p/')
hn=$(hostname -s)

# extended REs for egrep
# portability of {} in egrep is uncertain
dsptn='^\w[[:alnum:]_.:-]*(/[[:alnum:]_\.:-]+)*$'
hostptn='^((\w|\w[[:alnum:]-]*\w)\.)*(\w|\w[[:alnum:]-]*\w)$'
# https://stackoverflow.com/questions/53497/regular-expression-that-matches-valid-ipv6-addresses
ipv4ptn='^((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])$'
ipv6ptn='^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))$'
ipv4llptn='^127\.((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){2,2}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])$'
ttlptn='^[0-9]{1,4}[dwmy]$'
unptn='^[[:alnum:]_][[:alnum:]_-]{0,31}$'
zptn="@ZAP_(${hn})_..*--[0-9]{1,4}[dwmy]"

readonly version=0.7.5b1

case $1 in
  snap|snapshot) shift; snap_parse "$@" ;;
  rep|replicate) shift; rep_parse  "$@" ;;
  destroy)       shift; destroy    "$@" ;;
  -v|-version|--version) echo "$version" > /dev/stderr ;;
  *)             usage "${0##*/}: missing or unknown subcommand -- $1"; exit 1 ;;
esac

#!/bin/bash
# Navi remote runner — runs a command on the Mac mini (over Tailscale, via `molty`)
# and prints its output. Used by the Cmd+Shift+M "Ask the mini…" box.
#
#   mini_run.sh "ps aux | grep node"   -> runs that command on the mini
#   mini_run.sh "__status__"           -> prints a friendly one-line terminal summary
#   mini_run.sh ""                     -> same as __status__
#
# Output is trimmed to keep Navi's speech bubble readable.

HOST="${NAVI_MINI_HOST:-molty}"
CMD="$1"

# Reuses the persistent master connection opened by mini_probe.sh (same ControlPath).
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=6 -o ServerAliveInterval=4 -o ServerAliveCountMax=2
          -o ControlMaster=auto -o ControlPath="$HOME/.ssh/navi-cm-%r@%h:%p" -o ControlPersist=30s)

if [ -z "$CMD" ] || [ "$CMD" = "__status__" ]; then
  read -r -d '' REMOTE <<'REMOTE'
probe=$(ps -axo tty=,pid=,stat=,comm= | awk '
  $1 ~ /^ttys[0-9]+$/ {
    tty=$1; pid=$2+0; stat=$3; comm=$4;
    for (i=5;i<=NF;i++) comm=comm" "$i;
    n=split(comm,a,"/"); base=a[n];
    isshell = (base ~ /^-?(zsh|bash|sh|fish)$/ || base=="login");
    shells[tty]=1;
    if (index(stat,"+")>0 && !isshell) { if (pid>bp[tty]){bp[tty]=pid; bc[tty]=base} }
  }
  END {
    ns=0; nb=0; names="";
    for (t in shells){ ns++; if(bc[t]!=""){nb++; names=names (names==""?"":", ") bc[t]} }
    if (names=="") names="(all idle)";
    printf("%d terminal%s, %d busy: %s", ns, (ns==1?"":"s"), nb, names);
  }')
load=$(uptime | sed -E 's/.*load averages?: //' | awk '{print $1}')
up=$(uptime | sed -E 's/^.*up +//; s/, *[0-9]+ user.*$//; s/,$//')
printf "%s  ·  load %s  ·  up %s\n" "$probe" "$load" "$up"
REMOTE
else
  REMOTE="$CMD"
fi

# Run once, capturing the real exit code (ssh returns 255 on connection failure).
out=$(ssh "${SSH_OPTS[@]}" "$HOST" "$REMOTE" 2>&1)
rc=$?
if [ $rc -eq 255 ]; then
  echo "__NAVI_OFFLINE__"
else
  printf '%s' "$out" | head -c 700
fi

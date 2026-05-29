#!/bin/bash
# Navi remote probe — asks the Mac mini (over Tailscale, via the `molty` ssh host)
# what terminal sessions are alive and which are busy, then prints ONE parseable line:
#   NAVI shells=<n> busy=<m> names=<comma-list-or-->
# Prints nothing if the mini is unreachable (Navi treats that as "offline").
#
# A "terminal" = an interactive shell attached to a pty (ttysNNN).
# "busy"       = that pty has a foreground (+) non-shell process; the representative
#                command is the deepest (highest-pid) such foreground process.

HOST="${NAVI_MINI_HOST:-molty}"

read -r -d '' PROBE <<'REMOTE'
ps -axo tty=,pid=,stat=,comm= | awk '
  $1 ~ /^ttys[0-9]+$/ {
    tty=$1; pid=$2+0; stat=$3; comm=$4;
    for (i=5;i<=NF;i++) comm=comm" "$i;
    n=split(comm,a,"/"); base=a[n];
    isshell = (base ~ /^-?(zsh|bash|sh|fish)$/ || base=="login");
    shells[tty]=1;
    if (index(stat,"+")>0 && !isshell) {
      if (pid > bestpid[tty]) { bestpid[tty]=pid; bestcmd[tty]=base; }
    }
  }
  END {
    # Per-terminal: "NAVI ttys000=codex ttys001=-"  (- == idle at the shell prompt).
    # Lets Navi diff poll-to-poll and detect a single command finishing even while
    # other terminals (codex/claude) stay busy.
    out="NAVI";
    for (t in shells) {
      c = bestcmd[t]; if (c=="") c="-";
      gsub(/ /,"_",c);
      out = out " " t "=" c;
    }
    print out;
  }'
REMOTE

# ControlMaster keeps one persistent connection warm so a 4s poll loop isn't
# doing a fresh TCP+crypto handshake every tick (shared with mini_run.sh).
ssh -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o ServerAliveInterval=3 \
    -o ServerAliveCountMax=1 \
    -o ControlMaster=auto \
    -o ControlPath="$HOME/.ssh/navi-cm-%r@%h:%p" \
    -o ControlPersist=30s \
    "$HOST" "$PROBE" 2>/dev/null

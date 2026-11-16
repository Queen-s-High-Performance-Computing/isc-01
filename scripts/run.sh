#!/usr/bin/env bash
# TEAM-OWNED: how your team launches Doom. Change it however you like.
#
# scripts/score.sh starts this, waits for the time limit, then kills every
# process it started. Demos still running at that moment don't count.
#
# score.sh provides: DOOM_BIN DOOM_IWAD DOOM_DEMO DG_REFERENCE RESULTS_DIR
#
# Must-follow rules (see RULES.md):
#   - run everything on this node: no srun, sbatch or ssh
#   - keep every process in this process group: no setsid, nohup or disown
#   - send each copy's output to a *.log file in $RESULTS_DIR
#
# Strategy: one copy per CPU, each restarting Doom for every demo, and each
# copy pinned to its own CPU with taskset so it stays on one core and keeps
# its caches warm instead of being moved around by the scheduler.
#
# Knobs for experiments (set them in front of score.sh):
#   COPIES=8 scripts/score.sh demo1 30 1   # run fewer copies than CPUs
#   PIN=0    scripts/score.sh demo1 30 1   # turn pinning off, to compare

PIN=${PIN:-1}

# CPUs this job is allowed to use, one per line. Inside a Slurm job these are
# not simply 0..N-1, so read the real list, e.g. "0-7,64-71".
allowed_cpus() {
    local list range
    list=$(awk '/^Cpus_allowed_list/ { print $2 }' /proc/self/status 2>/dev/null)
    for range in ${list//,/ }; do
        seq "${range%-*}" "${range#*-}"
    done
}

# Allowed CPUs in the order copies should get them: first one hardware thread
# on every physical core, alternating between the two sockets, and only then
# the second hyperthread of each core. With fewer copies than CPUs, each copy
# then gets a physical core to itself and both sockets' caches and memory
# are used evenly.
ordered_cpus() {
    if ! command -v lscpu >/dev/null 2>&1; then
        allowed_cpus
        return
    fi
    awk -F, '
        NR == FNR { ok[$1] = 1; next }              # first input: allowed CPUs
        /^#/ || !($1 in ok) { next }                # lscpu lines: CPU,CORE,SOCKET
        {
            core = $3 "," $2
            if (!(core in rank)) { rank[core] = 0; slot[core] = nslot[$3]++ }
            else                 { rank[core]++ }
            # sort keys: hyperthread rank, core slot within socket, socket
            print rank[core], slot[core], $3, $1
        }' <(allowed_cpus) <(lscpu -p=CPU,CORE,SOCKET) |
        sort -n -k1,1 -k2,2 -k3,3 | awk '{ print $4 }'
}

CPUS=()
if [ "$PIN" = 1 ] && command -v taskset >/dev/null 2>&1; then
    CPUS=($(ordered_cpus))
fi

COPIES=${COPIES:-16}

for i in $(seq 0 $((COPIES - 1))); do
    workdir="$RESULTS_DIR/w$i"   # each copy needs its own folder for its config file
    mkdir -p "$workdir"

    pin=()
    if [ ${#CPUS[@]} -gt 0 ]; then
        pin=(taskset -c "${CPUS[i % ${#CPUS[@]}]}")
    fi

    (
        cd "$workdir"
        while true; do
            "${pin[@]}" "$DOOM_BIN" -iwad "$DOOM_IWAD" -timedemo "$DOOM_DEMO" || true
        done
    ) > "$RESULTS_DIR/w$i.log" 2>&1 &
done
wait

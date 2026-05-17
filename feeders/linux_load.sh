#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Esseforma LLC
#
# linux_load.sh — sample the Linux load-average input at 100 ms cadence
# and either print the stream to stdout or pipe it into rtchart
# (https://rtchart.cloud.esseforma.com — a streaming OHLC chart
# renderer that consumes one numeric value per line on stdin).
#
# Three streams are produced per sample:
#   R     = sum over online CPUs of rq->nr_running
#   D     = sum over online CPUs of rq->nr_uninterruptible
#   load1 = kernel's `avenrun[0]`, the 1-minute load-average EWMA,
#           read as a FIXED_1 (1<<11) fixed-point value and expanded
#           to decimal here. The kernel updates avenrun every
#           LOAD_FREQ ≈ 5 s, so this stream looks like a step
#           function relative to the 100 ms R/D streams.
#
# R and D are the same per-CPU `struct rq` quantities the kernel folds
# into `calc_load_tasks` in kernel/sched/loadavg.c (the EWMA inputs);
# load1 is the kernel's own EWMA output. Per-CPU `nr_uninterruptible`
# is intentionally non-meaningful in isolation — increment on the
# sleeping CPU, decrement on the waking CPU — but the sum across CPUs
# is the global uninterruptible-task count regardless of NO_HZ state
# (kernel/sched/loadavg.c documents this).
set -euo pipefail

print_help() {
    cat <<'HELP'
Usage: linux_load.sh [<room-id> ...] [options]

Sample the Linux load-average input every 100 ms and either print
the stream to stdout or drive up to three rtchart instances (R, D,
load1) with the data. rtchart is a streaming OHLC chart renderer
that consumes one numeric value per line on stdin; see
https://rtchart.cloud.esseforma.com.

Streams:
  R      = sum of rq->nr_running across online CPUs (runnable tasks),
  D      = sum of rq->nr_uninterruptible across online CPUs,
  load1  = kernel `avenrun[0]`, the 1-minute load-average EWMA the
           kernel itself maintains (updated every LOAD_FREQ ≈ 5 s).

Modes (positional args = room IDs):
  linux_load.sh
      Print samples to stdout, one per line:
          ms_since_start R D load1 sample
      where sample = R + D (the instantaneous quantity the kernel
      folds into load1 every 5 s).

  linux_load.sh <room>
      Three rtchart peers in the same room (R, D, load1 overlaid in
      one browser tab).

  linux_load.sh <r-room> <d+load1-room>
      R in <r-room>; D and load1 share <d+load1-room>.

  linux_load.sh <r-room> <d-room> <load1-room>
      Three independent rtcharts, each in its own room.

  In general the i-th stream takes positional arg i (R=0, D=1,
  load1=2); streams without their own arg fall back to the last
  arg given.

Sampling needs sudo so bpftrace can resolve kernel symbols. Requires
bpftrace >= 0.13 (for while-loop support) and a kernel built with
CONFIG_DEBUG_INFO_BTF=y so `struct rq` is BTF-resolvable.

The rtchart-driving modes additionally require:
  - the rtchart binary. linux_load.sh searches $PATH for
    `rtchart-linux-amd64` and `rtchart-linux-arm64`. If neither is
    found, --rtchart=PATH or RTCHART=PATH is required.
  - setpriv from util-linux (used for PR_SET_PDEATHSIG so rtchart
    auto-exits if this script is SIGKILL'd and bypasses the EXIT
    trap).

Options:
  -h, --help          show this help and exit.
  --rtchart=PATH      path to the rtchart binary. Equivalent to the
                      RTCHART environment variable. Mandatory if
                      neither `rtchart-linux-amd64` nor
                      `rtchart-linux-arm64` is on $PATH.
  --debug             leave rtchart stdout/stderr attached to this
                      terminal. Without it each rtchart's output is
                      sent to /dev/null so it doesn't interleave with
                      the sampler.
  --sample-ms=N       sampler interval in milliseconds (default 100).

  The following pass straight through to every rtchart instance
  (R, D, and load1). Defaults are tuned for a 100 ms-cadence load
  trace; override individually as needed.

  --x-range=N         rtchart --x-range, scroll-window length in
                      seconds (default 30).
  --ohlc-span=N       rtchart --ohlc-span, seconds per OHLC bar
                      (default 1 — 10 samples/bar at 100 ms cadence).
  --no-auto           omit rtchart's --auto value-axis flag (auto is
                      on by default; the streams are unbounded so
                      autoscale is usually what you want).
  --weight-low=N      rtchart --weight-low (default 0). Pin tight
                      since stdin carries no weight column (rtchart
                      defaults weight to 1.0).
  --weight-high=N     rtchart --weight-high (default 11).
  --nice=N            renice this script and all its children to N at
                      startup (default -10). Negative values keep the
                      sampler + awk demuxer + rtchart subprocesses
                      responsive during the load events the chart is
                      meant to observe. Requires sudo to lower
                      niceness; if sudo creds aren't cached the renice
                      silently no-ops and the script continues at
                      default priority. Set to 0 (or use --no-renice)
                      to skip the renice attempt entirely.
  --no-renice         shorthand for --nice=0.

Any other --flag (or --flag=value) that this script doesn't recognise
is forwarded verbatim to every rtchart instance. Use --flag=value
form so the value can't be mistaken for a room ID. Forwarded flags
appear after the default flags on the rtchart command line, so they
override the defaults (rtchart takes the last occurrence).
HELP
}

# --- argument parsing ---
# Known flags below are consumed by this script. Unknown `-...` flags
# are collected into EXTRA and forwarded to both rtchart instances
# verbatim (positionally after the defaults, so `--flag=val` overrides
# of a default work even though the default is still on the command
# line — rtchart's argparser takes the last occurrence). Non-flag
# positional args are room IDs.
ROOMS=()
EXTRA=()
DEBUG=
SAMPLE_MS=100
X_RANGE=30
OHLC_SPAN=1
AUTO=1
WEIGHT_LOW=0
WEIGHT_HIGH=11
NICE=-10
for arg in "$@"; do
    case "$arg" in
        -h|--help|-\?)        print_help; exit 0 ;;
        --rtchart=*)          RTCHART=${arg#*=} ;;
        --debug)              DEBUG=1 ;;
        --sample-ms=*)        SAMPLE_MS=${arg#*=} ;;
        --x-range=*)          X_RANGE=${arg#*=} ;;
        --ohlc-span=*)        OHLC_SPAN=${arg#*=} ;;
        --auto)               AUTO=1 ;;
        --no-auto)            AUTO=0 ;;
        --weight-low=*)       WEIGHT_LOW=${arg#*=} ;;
        --weight-high=*)      WEIGHT_HIGH=${arg#*=} ;;
        --nice=*)             NICE=${arg#*=} ;;
        --no-renice)          NICE=0 ;;
        -*)                   EXTRA+=("$arg") ;;
        *)                    ROOMS+=("$arg") ;;
    esac
done

# Renice ourselves (and, by inheritance, all descendants — bpftrace
# under sudo, awk, the rtchart subprocesses) so the user-space
# pipeline stays scheduled during heavy load. Data quality is
# unaffected either way (bpftrace's `interval:ms:$SAMPLE_MS` timing
# is in-kernel); this only smooths chart responsiveness when the
# system is busy. `sudo -n` is non-interactive — if creds aren't
# cached we silently skip the renice and continue at default priority.
if [ "$NICE" != "0" ]; then
    sudo -n renice -n "$NICE" -p $$ >/dev/null 2>&1 \
        || echo "warning: could not renice to $NICE (continuing at default priority)" >&2
fi

if [ ${#ROOMS[@]} -gt 3 ]; then
    echo "ERROR: too many room IDs (got ${#ROOMS[@]}, expected 0, 1, 2, or 3)" >&2
    print_help >&2
    exit 1
fi

# Loop bound = highest possible CPU ID + 1 from
# /sys/devices/system/cpu/possible. Sysfs format is a list of ranges
# like "0-63" or "0-7,9-15"; last token after `,` or `-` is the max
# ID. The in-loop offset check skips never-allocated CPU slots so
# sparse / hot-removed CPUs don't read garbage.
NCPUS=$(awk -F'[,-]' '{print $NF + 1}' /sys/devices/system/cpu/possible)

# Run bpftrace with the per-CPU runqueue sampler. Wraps the heredoc
# so the same body works in both stdout-mode (called directly) and
# rtchart-mode (called as the left side of a pipeline).
run_bpftrace() {
    sudo bpftrace -q - <<BT
BEGIN { printf("ms_since_start R D load1 sample\n"); }

interval:ms:$SAMPLE_MS
{
    \$r = (int64)0;
    \$d = (int64)0;
    \$c = (uint64)0;
    while (\$c < (uint64)$NCPUS) {
        \$off = *(uint64 *)(kaddr("__per_cpu_offset") + \$c * 8);
        if (\$off != 0) {
            \$rq = (struct rq *)(kaddr("runqueues") + \$off);
            \$r += (int64)\$rq->nr_running;
            \$d += (int64)\$rq->nr_uninterruptible;
        }
        \$c += 1;
    }
    /*
     * avenrun[0] = kernel's 1-min load EWMA in FIXED_1 (1<<11)
     * fixed-point. Integer part = \$av >> 11; fractional part
     * (3-decimal-place) = ((\$av & 0x7FF) * 1000) >> 11, which
     * fits comfortably in 32-bit math (max 2047*1000 = 2,047,000).
     * Kernel only updates this every LOAD_FREQ (~5 s), so the
     * stream looks step-shaped relative to R/D.
     */
    \$av = *(uint64 *)kaddr("avenrun");
    \$li = \$av >> 11;
    \$lf = ((\$av & 0x7FF) * 1000) >> 11;
    printf("%lld %lld %lld %lld.%03lld %lld\n",
           elapsed / 1000000, \$r, \$d, \$li, \$lf, \$r + \$d);
}
BT
}

# --- Mode A: no rooms → just print samples to stdout. ---
if [ ${#ROOMS[@]} -eq 0 ]; then
    run_bpftrace
    exit 0
fi

# --- Mode B: rooms given → drive rtchart(s). ---
# The i-th stream (R=0, D=1, load1=2) takes positional arg i; if
# there are fewer rooms than streams the trailing streams reuse the
# last room. So:
#   1 room  → all three peers overlay in that one room.
#   2 rooms → R alone in room 0; D and load1 share room 1.
#   3 rooms → R, D, load1 each in their own room.
N=${#ROOMS[@]}
R_ROOM=${ROOMS[0]}
if [ $N -ge 2 ]; then D_ROOM=${ROOMS[1]}; else D_ROOM=$R_ROOM; fi
if [ $N -ge 3 ]; then L_ROOM=${ROOMS[2]}; else L_ROOM=$D_ROOM; fi

# Locate rtchart. Explicit override (--rtchart=PATH or RTCHART env)
# wins. Otherwise look for the host-arch arch-named binary on $PATH;
# fall back to the other arch's name (the user may have only one
# installed regardless of host).
if [ -z "${RTCHART:-}" ]; then
    case "$(uname -m)" in
        x86_64)         CANDS=(rtchart-linux-amd64 rtchart-linux-arm64) ;;
        aarch64|arm64)  CANDS=(rtchart-linux-arm64 rtchart-linux-amd64) ;;
        *)              CANDS=(rtchart-linux-amd64 rtchart-linux-arm64) ;;
    esac
    for cand in "${CANDS[@]}"; do
        if path=$(command -v "$cand" 2>/dev/null); then
            RTCHART="$path"
            break
        fi
    done
fi
if [ -z "${RTCHART:-}" ] || [ ! -x "$RTCHART" ]; then
    echo "ERROR: rtchart binary not found." >&2
    echo "Neither rtchart-linux-amd64 nor rtchart-linux-arm64 is on \$PATH." >&2
    echo "Specify --rtchart=/path/to/rtchart or set RTCHART=/path/to/rtchart." >&2
    exit 1
fi

# Open fd 3 → R rtchart, fd 4 → D rtchart, fd 5 → load1 rtchart via
# process substitution. Two layers of `exec` collapse the tree
# (script → bash subshell → setpriv → rtchart) down to a direct
# parent (script → rtchart):
#   - `>(exec setpriv ...)` makes the process-substitution subshell
#     replace itself with setpriv rather than fork+exec'ing it.
#   - setpriv calls prctl(PR_SET_PDEATHSIG, SIGTERM) and then execs
#     rtchart. PR_SET_PDEATHSIG is preserved across execve(2) for
#     non-setuid binaries (prctl(2) docs).
#
# Shutdown paths converge on rtchart exiting:
#   - Normal exit: bash closes fd 3/4/5 → rtchart sees stdin EOF →
#     exits. pdeathsig also fires once bash is reaped, but rtchart
#     is already on its way out by then.
#   - SIGKILL of bash (no traps): kernel still closes fd 3/4/5
#     (same EOF path) and delivers SIGTERM via pdeathsig. Belt and
#     suspenders.
# Either path leaves no orphan rtchart, so no explicit EXIT trap is
# needed.
#
# rtchart flag rationale (see --help for override flags):
#   --x-range           scroll-window length, default 30 s.
#   --ohlc-span         OHLC bar width, default 1 s (10 samples/bar at
#                       100 ms cadence) so each bar carries an actual
#                       open/high/low/close rather than a single tick.
#   --auto              value-axis auto-ranges. R is bounded by NCPUS;
#                       D is usually 0 with sporadic spikes. Auto lets
#                       each chart pick a sensible scale for its own
#                       stream.
#   --weight-low/-high  stdin carries no weight column — rtchart
#                       defaults weight to 1.0. Pin the weight axis
#                       tight so the constant-1 weight stream doesn't
#                       get its own random auto-range.
#   --name="..."        labels the legend chip in the browser.
#
# `${DEBUG:+:}` expands to `:` when DEBUG is set (turning the
# `exec >/dev/null 2>&1` into a no-op `:` invocation with discarded
# redirections) and to empty when DEBUG is unset (so the redirection
# permanently silences the subshell, which setpriv then inherits via
# execve). This way the launch lines aren't duplicated between debug
# and non-debug paths.
RTCHART_FLAGS=(
    --x-range="$X_RANGE"
    --ohlc-span="$OHLC_SPAN"
    --weight-low="$WEIGHT_LOW"
    --weight-high="$WEIGHT_HIGH"
)
[ "$AUTO" = "1" ] && RTCHART_FLAGS+=(--auto)

# When an rtchart subprocess exits (bad room ID, signaling server
# unreachable, arch mismatch on the binary, etc.) the kernel closes
# its end of fd 3/4/5. awk's next fflush fails with "Broken pipe"
# and the script exits with awk's fatal-error code. Without this
# trap the user sees only the awk message, which buries the real
# cause. Suggest --debug for actual diagnosis (rtchart's stderr is
# /dev/null'd otherwise).
trap '
    rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$DEBUG" ]; then
        echo "" >&2
        echo "ERROR: pipeline exited unexpectedly (rc=$rc). The most" >&2
        echo "  common cause is an rtchart subprocess dying — invalid" >&2
        echo "  room ID, signaling server unreachable, or arch mismatch" >&2
        echo "  on the rtchart binary. Rerun with --debug to see" >&2
        echo "  rtchart stderr and the real cause." >&2
    fi
' EXIT

exec 3> >(${DEBUG:+:} exec >/dev/null 2>&1; \
          exec setpriv --pdeathsig TERM "$RTCHART" \
            "${RTCHART_FLAGS[@]}" "${EXTRA[@]}" \
            --name="R (runnable)" \
            "$R_ROOM") \
     4> >(${DEBUG:+:} exec >/dev/null 2>&1; \
          exec setpriv --pdeathsig TERM "$RTCHART" \
            "${RTCHART_FLAGS[@]}" "${EXTRA[@]}" \
            --name="D (uninterruptible)" \
            "$D_ROOM") \
     5> >(${DEBUG:+:} exec >/dev/null 2>&1; \
          exec setpriv --pdeathsig TERM "$RTCHART" \
            "${RTCHART_FLAGS[@]}" "${EXTRA[@]}" \
            --name="load1 (1-min avg)" \
            "$L_ROOM")

# Demux R/D/load1 columns to fd 3/4/5. `fflush` per line keeps the
# rtchart streams live at the same cadence the sampler produces;
# without it awk's block buffering would coalesce samples into
# 4 KB chunks.
#
# The `2> >(grep -v ...)` suppresses gawk's fatal-error message when
# a downstream rtchart dies — that message is purely consequential
# (broken pipe on fflush) and obscures the real cause; the EXIT trap
# above prints a useful diagnostic in its place. Any OTHER awk
# stderr (real bugs in the script) passes through unchanged.
run_bpftrace | awk '
    NR == 1 { next }                                    # skip header
    {
        print $2 > "/dev/fd/3"; fflush("/dev/fd/3")     # R
        print $3 > "/dev/fd/4"; fflush("/dev/fd/4")     # D
        print $4 > "/dev/fd/5"; fflush("/dev/fd/5")     # load1
    }
' 2> >(grep -v 'fflush: cannot flush file' >&2)

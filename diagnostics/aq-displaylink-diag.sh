#!/usr/bin/env bash
# Reversible DisplayLink diagnostics for the running Omarchy session.
# This script does not change monitor mode, scale, evdi loglevel, or Hyprland config.
# Default (no --go) only prints what it would do.
#
# Run from foot on the built-in panel, not from a Quickshell terminal.
# Do not move the pointer during an idle trace. Leave it on the built-in panel.
#
#   ./aq-displaylink-diag.sh pause-test --check
#   I_UNDERSTAND=1 ./aq-displaylink-diag.sh pause-test --go
#   sudo -E ./aq-displaylink-diag.sh trace-test --check
#   I_UNDERSTAND=1 sudo -E ./aq-displaylink-diag.sh trace-test --go
#
# pause-test answers only: does idle DisplayLink CPU require Quickshell to be runnable?
# It does not show whether a damage rectangle is really full-screen.
# trace-test is a separate 25s capture. Its CPU is instrumentation overhead, not the
# performance measurement. Neither result by itself confirms a root cause.

set -euo pipefail
umask 077

PAUSE_SEC=25
BASE_SEC=5
POST_SEC=5
TRACE_SEC=25
COUNTDOWN=5

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,20p' "$0" >&2
    exit 2
}

need_understand() {
    [[ "${I_UNDERSTAND:-}" == 1 ]] || die "refusing: set I_UNDERSTAND=1 after reading the check output"
}

outdir() {
    local stamp dir
    stamp=$(date +%Y%m%d-%H%M%S)
    dir="${HOME}/aqdiag-displaylink/${stamp}-${1}"
    mkdir -p "$dir"
    chmod 700 "${HOME}/aqdiag-displaylink" "$dir"
    printf '%s\n' "$dir"
}

proc_cmdline() {
    tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null || true
}

ancestor_is() {
    local target=$1 cur=$$
    while [[ "$cur" -gt 1 ]]; do
        [[ "$cur" -eq "$target" ]] && return 0
        cur=$(awk '/^PPid:/ {print $2}' "/proc/${cur}/status")
    done
    return 1
}

find_one_quickshell() {
    local p cmd matches=()
    while read -r p; do
        [[ -n "$p" ]] || continue
        cmd=$(proc_cmdline "$p")
        if [[ "$cmd" == *quickshell* && "$cmd" == */usr/share/omarchy/shell* ]]; then
            matches+=("$p")
        fi
    done < <(pgrep -x quickshell || true)
    [[ ${#matches[@]} -eq 1 ]] || die "expected exactly one quickshell using /usr/share/omarchy/shell, found ${#matches[@]} (${matches[*]:-none})"
    printf '%s\n' "${matches[0]}"
}

descendants_of() {
    local p=$1 c
    printf '%s\n' "$p"
    while read -r c; do
        [[ -n "$c" ]] || continue
        descendants_of "$c"
    done < <(pgrep -P "$p" || true)
}

watchdog_us() {
    local pid=$1 cg unit val
    cg=$(tr '\0' '\n' <"/proc/${pid}/cgroup" 2>/dev/null || true)
    unit=$(printf '%s\n' "$cg" | sed -n 's/.*\///; s/\.service$//p' | tail -1)
    if [[ -z "$unit" ]] || ! command -v systemctl >/dev/null; then
        printf 'none\n'
        return
    fi
    if ! systemctl --user show "${unit}.service" -p Id --value >/dev/null 2>&1; then
        printf 'none\n'
        return
    fi
    val=$(systemctl --user show "${unit}.service" -p WatchdogUSec --value 2>/dev/null || true)
    printf '%s %s\n' "${unit}.service" "${val:-0}"
}

task_ticks() {
    local pid=$1 f rest ticks=0 u s
    for f in /proc/"$pid"/task/*/stat; do
        [[ -r "$f" ]] || continue
        rest=$(sed -n 's/.*) //p' "$f") || continue
        # after comm: state ppid pgrp sid tty tpgid flags minflt cminflt majflt cmajflt utime stime
        read -r _ _ _ _ _ _ _ _ _ _ _ u s _ <<<"$rest"
        ticks=$((ticks + u + s))
    done
    printf '%s\n' "$ticks"
}

find_by_comm() {
    local name=$1 p ids=()
    while read -r p; do
        [[ -n "$p" ]] || continue
        ids+=("$p")
    done < <(pgrep -x "$name" || true)
    printf '%s\n' "${ids[@]}"
}

sum_comm_ticks() {
    local name=$1 p total=0
    while read -r p; do
        [[ -n "$p" && -d /proc/$p ]] || continue
        total=$((total + $(task_ticks "$p")))
    done < <(find_by_comm "$name")
    printf '%s\n' "$total"
}

sample_cpu_line() {
    local label=$1 now qs hl dlm
    now=$(date +%s)
    qs=$(sum_comm_ticks quickshell)
    hl=$(sum_comm_ticks Hyprland)
    dlm=$(sum_comm_ticks DisplayLinkManager)
    printf '%s %s %s %s %s\n' "$label" "$now" "$qs" "$hl" "$dlm"
}

percent_between() {
    local a=$1 b=$2 seconds=$3
    local clk delta
    clk=$(getconf CLK_TCK)
    delta=$((b - a))
    if [[ $delta -lt 0 ]]; then delta=0; fi
    awk -v d="$delta" -v s="$seconds" -v c="$clk" 'BEGIN { if (s<=0 || c<=0) print "0"; else printf "%.1f", (d / c) / s * 100 }'
}

pause_check() {
    local pid wd unit val
    pid=$(find_one_quickshell)
    ancestor_is "$pid" && die "this shell is inside Quickshell. Run it from foot on the built-in panel."
    wd=$(watchdog_us "$pid")
    unit=${wd%% *}
    val=${wd#* }
    printf 'quickshell pid %s\n' "$pid"
    printf 'cmdline: %s\n' "$(proc_cmdline "$pid")"
    printf 'descendants:\n'
    descendants_of "$pid" | sed 's/^/  /'
    printf 'user-service watchdog: unit=%s WatchdogUSec=%s\n' "$unit" "$val"
    if [[ "$val" != none && "$val" != 0 && "$val" != infinity ]]; then
        die "systemd watchdog is ${val}. SIGSTOP could make the service restart. Not pausing."
    fi
    printf 'evdi loglevel (not modified): %s\n' "$(cat /sys/devices/evdi/loglevel 2>/dev/null || echo unreadable)"
    printf 'pause would be %ss, with %ss CPU baseline before it and %ss after CONT.\n' "$PAUSE_SEC" "$BASE_SEC" "$POST_SEC"
    printf '4K modes are not touched. Quickshell stays in memory; its threads stop scheduling.\n'
    printf 'Recovery if this shell dies after STOP: kill -CONT <each pid printed above>\n'
    printf 'A setsid watchdog also sends CONT about 30s after STOP.\n'
    printf 'Check only. Re-run with I_UNDERSTAND=1 and --go to pause.\n'
}

cont_pids() {
    local p
    for p in "$@"; do
        kill -CONT "$p" 2>/dev/null || true
    done
}

pause_go() {
    need_understand
    local pid dir wd unit val mapfile_pids=() p ticks_clk
    pid=$(find_one_quickshell)
    ancestor_is "$pid" && die "this shell is inside Quickshell. Run it from foot on the built-in panel."
    wd=$(watchdog_us "$pid")
    unit=${wd%% *}
    val=${wd#* }
    if [[ "$val" != none && "$val" != 0 && "$val" != infinity ]]; then
        die "systemd watchdog is ${val}. Not pausing."
    fi
    mapfile -t mapfile_pids < <(descendants_of "$pid")
    for p in "${mapfile_pids[@]}"; do
        [[ "$p" -eq $$ ]] && die "refusing to stop this script"
    done
    dir=$(outdir pause)
    {
        printf 'quickshell %s\n' "$pid"
        printf 'unit %s watchdog %s\n' "$unit" "$val"
        printf 'pids %s\n' "${mapfile_pids[*]}"
        printf 'evdi_loglevel_before %s\n' "$(cat /sys/devices/evdi/loglevel 2>/dev/null || echo unreadable)"
    } >"$dir/meta.txt"
    printf 'RECOVERY: kill -CONT %s\n' "${mapfile_pids[*]}" | tee "$dir/recovery.txt"
    local i
    for ((i = BASE_SEC; i > 0; i--)); do
        sample_cpu_line base >>"$dir/samples.txt"
        sleep 1
    done
    local watchdog=$dir/watchdog.sh
    cat >"$watchdog" <<EOF
#!/bin/bash
sleep 30
$(printf 'kill -CONT %q 2>/dev/null || true\n' "${mapfile_pids[@]}")
echo watchdog-cont >>$(printf '%q' "$dir/watchdog.log")
EOF
    chmod 700 "$watchdog"
    setsid "$watchdog" >/dev/null 2>&1 &
    local wpid=$!
    echo "$wpid" >"$dir/watchdog.pid"
    cleanup() {
        cont_pids "${mapfile_pids[@]}"
        kill "$wpid" 2>/dev/null || true
    }
    trap cleanup EXIT
    printf 'STOP quickshell for %ss. Built-in foot should keep working. Pointer and 4K mode are unchanged.\n' "$PAUSE_SEC"
    kill -STOP "${mapfile_pids[@]}"
    for ((i = PAUSE_SEC; i > 0; i--)); do
        sample_cpu_line paused >>"$dir/samples.txt"
        sleep 1
    done
    cont_pids "${mapfile_pids[@]}"
    kill "$wpid" 2>/dev/null || true
    trap - EXIT
    for ((i = POST_SEC; i > 0; i--)); do
        sample_cpu_line post >>"$dir/samples.txt"
        sleep 1
    done
    printf 'evdi_loglevel_after %s\n' "$(cat /sys/devices/evdi/loglevel 2>/dev/null || echo unreadable)" >>"$dir/meta.txt"
    python3 - "$dir/samples.txt" "$dir/summary.txt" <<'PY'
import sys
rows=[]
for line in open(sys.argv[1]):
    lab, ts, qs, hl, dlm = line.split()
    rows.append((lab, int(ts), int(qs), int(hl), int(dlm)))
def avg(name, idx):
    pts=[r for r in rows if r[0]==name]
    if len(pts)<2:
        return "n/a"
    dt=pts[-1][1]-pts[0][1]
    if dt<=0:
        return "n/a"
    d=pts[-1][idx]-pts[0][idx]
    import os
    clk=os.sysconf("SC_CLK_TCK")
    return f"{(d/clk)/dt*100:.1f}"
text=[]
text.append("CPU percent of a second, summed across threads. Not a frame rate.")
for name in ("base","paused","post"):
    text.append(f"{name}: quickshell {avg(name,2)}  Hyprland {avg(name,3)}  DisplayLinkManager {avg(name,4)}")
text.append("If paused DisplayLinkManager stays near base, Quickshell being scheduled is not required for that CPU.")
text.append("If it falls and post returns, Quickshell is necessary for the idle load.")
text.append("That still does not prove the damage rectangle is the whole 4K framebuffer.")
text.append("This is not a confirmed root cause.")
open(sys.argv[2],"w").write("\n".join(text)+"\n")
print("\n".join(text))
PY
    printf 'wrote %s\n' "$dir"
}

kallsym_ok() {
    grep -qw "$1" /proc/kallsyms
}

trace_check() {
    [[ "$(id -u)" -eq 0 ]] || die "trace check needs root: sudo -E $0 trace-test --check"
    [[ "$(uname -m)" == aarch64 ]] || die "this probe syntax is for aarch64 registers"
    local tracing=/sys/kernel/tracing
    [[ -d "$tracing" ]] || die "tracefs missing"
    [[ -w "$tracing/tracing_on" ]] || die "tracefs not writable"
    local tracer on
    tracer=$(cat "$tracing/current_tracer")
    on=$(cat "$tracing/tracing_on")
    printf 'current_tracer=%s tracing_on=%s\n' "$tracer" "$on"
    [[ "$tracer" == nop && "$on" == 0 ]] || die "ftrace is already in use. Not touching it."
    [[ -e "$tracing/kprobe_events" ]] || die "kprobe_events missing (CONFIG_KPROBE_EVENTS). No kernel rect/pacing probe."
    [[ -e "$tracing/uprobe_events" ]] || die "uprobe_events missing (CONFIG_UPROBE_EVENTS). Userspace damage rects need the 0.15.1 review patch; do not install it from this check."
    [[ -z "$(cat "$tracing/kprobe_events")" && -z "$(cat "$tracing/uprobe_events")" ]] || die "probe lists are not empty. Not adding probes beside an existing session."
    local hp maps aq drm
    hp=$(pgrep -x Hyprland | head -n1)
    [[ -n "$hp" ]] || die "Hyprland is not running"
    maps=/proc/$hp/maps
    aq=$(awk '/libaquamarine\.so/{print $6; exit}' "$maps")
    drm=$(awk '/libdrm\.so/{print $6; exit}' "$maps")
    [[ -n "$aq" && -n "$drm" ]] || die "could not find mapped libaquamarine or libdrm"
    printf 'Hyprland pid %s\n' "$hp"
    printf 'aquamarine %s\n' "$aq"
    printf 'libdrm %s\n' "$drm"
    local sym
    for sym in evdi_painter_mark_dirty evdi_painter_set_scanout_buffer evdi_painter_grabpix_ioctl evdi_painter_set_vblank drm_crtc_send_vblank_event; do
        if kallsym_ok "$sym"; then printf 'kallsyms %s yes\n' "$sym"; else printf 'kallsyms %s NO\n' "$sym"; fi
    done
    python3 - "$aq" "$drm" <<'PY'
import subprocess, sys
libs={"aq":sys.argv[1], "drm":sys.argv[2]}
def nm(path):
    for cmd in (["eu-nm","-D","--demangle",path], ["nm","-D","--demangle",path], ["eu-nm","-D",path], ["nm","-D",path]):
        try:
            out=subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
            return out
        except Exception:
            continue
    sys.exit("nm failed for "+path)
want={
 "drm":["drmModeCreatePropertyBlob"],
 "aq":["CDRMAtomicImpl::commit(","CDRMAtomicImpl::moveCursor(","COutputState::addDamage("],
}
for key,path in libs.items():
    text=nm(path)
    for needle in want[key]:
        hits=[ln for ln in text.splitlines() if needle in ln and " T " in f" {ln} "]
        # eu-nm demangled lines contain the needle and a type letter
        hits=[ln for ln in text.splitlines() if needle in ln]
        print(f"{key} {needle} matches {len(hits)}")
        for ln in hits[:6]:
            print(" ", ln)
PY
    printf 'evdi loglevel (not modified): %s\n' "$(cat /sys/devices/evdi/loglevel 2>/dev/null || echo unreadable)"
    printf 'Check only. Idle trace is %ss and requires I_UNDERSTAND=1 --go.\n' "$TRACE_SEC"
    printf 'Do not raise evdi loglevel for this measurement. Verbose printk is a different, heavier capture.\n'
}

elf_offset() {
    python3 - "$1" "$2" <<'PY'
import struct, sys
data=open(sys.argv[1],"rb").read()
addr=int(sys.argv[2],16)
assert data[:4]==b"\x7fELF" and data[4]==2 and data[5]==1
phoff,=struct.unpack_from("<Q", data, 32)
phentsize,phnum=struct.unpack_from("<HH", data, 54)
for i in range(phnum):
    off=phoff+i*phentsize
    p_type,p_flags,p_offset,p_vaddr,p_paddr,p_filesz,p_memsz,p_align=struct.unpack_from("<IIQQQQQQ", data, off)
    if p_type==1 and p_vaddr<=addr<p_vaddr+max(p_memsz,p_filesz):
        print(f"{addr - p_vaddr + p_offset:x}")
        break
else:
    sys.exit(1)
PY
}

resolve_user_sym() {
    local lib=$1 needle=$2 line addr
    line=$(python3 - "$lib" "$needle" <<'PY'
import subprocess, sys
path, needle=sys.argv[1], sys.argv[2]
text=""
for cmd in (["eu-nm","-D","--demangle",path], ["nm","-D","--demangle",path]):
    try:
        text=subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
        break
    except Exception:
        text=""
if not text:
    sys.exit("no nm")
hits=[]
for ln in text.splitlines():
    parts=ln.split(None,2)
    if len(parts)<3 or needle not in parts[2]:
        continue
    if parts[1] not in ("T","W","t"):
        continue
    hits.append(parts)
if len(hits)!=1:
    for h in hits:
        print("AMBIGUOUS", h[0], h[2], file=sys.stderr)
    sys.exit(f"{needle} matches {len(hits)}")
print(hits[0][0])
print(hits[0][2])
PY
)
    addr=$(printf '%s\n' "$line" | head -n1)
    elf_offset "$lib" "$addr"
}

trace_go() {
    need_understand
    [[ "$(id -u)" -eq 0 ]] || die "trace-test --go needs root"
    local tracing=/sys/kernel/tracing
    [[ "$(cat "$tracing/current_tracer")" == nop && "$(cat "$tracing/tracing_on")" == 0 ]] || die "ftrace is already in use"
    [[ -z "$(cat "$tracing/kprobe_events")" && -z "$(cat "$tracing/uprobe_events")" ]] || die "probe lists are not empty"
    local hp aq drm dir
    hp=$(pgrep -x Hyprland | head -n1)
    [[ -n "$hp" ]] || die "Hyprland is not running"
    aq=$(awk '/libaquamarine\.so/{print $6; exit}' /proc/$hp/maps)
    drm=$(awk '/libdrm\.so/{print $6; exit}' /proc/$hp/maps)
    [[ -n "$aq" && -n "$drm" ]] || die "mapped libraries not found"
    for s in evdi_painter_mark_dirty evdi_painter_set_scanout_buffer evdi_painter_grabpix_ioctl; do
        kallsym_ok "$s" || die "kallsyms missing $s"
    done
    local off_blob off_commit off_cursor off_add
    off_blob=$(resolve_user_sym "$drm" "drmModeCreatePropertyBlob") || die "drmModeCreatePropertyBlob not a unique dynamic symbol"
    off_commit=$(resolve_user_sym "$aq" "CDRMAtomicImpl::commit(") || die "CDRMAtomicImpl::commit not a unique dynamic symbol"
    off_cursor=$(resolve_user_sym "$aq" "CDRMAtomicImpl::moveCursor(") || true
    off_add=$(resolve_user_sym "$aq" "COutputState::addDamage(") || true
    dir=$(outdir trace)
    local old_clock old_buf old_tgid
    old_clock=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$tracing/trace_clock" | head -n1)
    old_buf=$(cat "$tracing/buffer_size_kb")
    old_tgid=0
    if [[ -f "$tracing/options/record-tgid" ]]; then old_tgid=$(cat "$tracing/options/record-tgid"); fi
    local probes_k=() probes_u=()
    cleanup() {
        echo 0 >"$tracing/tracing_on" || true
        local ev
        if ((${#probes_k[@]})); then
            for ev in "${probes_k[@]}"; do echo "-:${ev}" >>"$tracing/kprobe_events" 2>/dev/null || true; done
        fi
        if ((${#probes_u[@]})); then
            for ev in "${probes_u[@]}"; do echo "-:${ev}" >>"$tracing/uprobe_events" 2>/dev/null || true; done
        fi
        if [[ -n "${old_clock:-}" ]]; then echo "$old_clock" >"$tracing/trace_clock" || true; fi
        if [[ -n "${old_buf:-}" ]]; then echo "$old_buf" >"$tracing/buffer_size_kb" || true; fi
        if [[ -f "$tracing/options/record-tgid" ]]; then echo "$old_tgid" >"$tracing/options/record-tgid" || true; fi
        echo nop >"$tracing/current_tracer" || true
    }
    trap cleanup EXIT
    echo mono >"$tracing/trace_clock"
    echo 1024 >"$tracing/buffer_size_kb"
    if [[ -f "$tracing/options/record-tgid" ]]; then echo 1 >"$tracing/options/record-tgid"; fi
    add_k() {
        local name=$1 spec=$2
        echo "p:aqdiag_${name} ${spec}" >>"$tracing/kprobe_events"
        probes_k+=("aqdiag_${name}")
        echo 1 >"$tracing/events/kprobes/aqdiag_${name}/enable"
    }
    add_k dirty "evdi_painter_mark_dirty x1=+0(%x1):u16 y1=+2(%x1):u16 x2=+4(%x1):u16 y2=+6(%x1):u16"
    add_k scanout "evdi_painter_set_scanout_buffer"
    add_k grab "evdi_painter_grabpix_ioctl"
    if kallsym_ok evdi_painter_set_vblank; then add_k vblank "evdi_painter_set_vblank"; fi
    if kallsym_ok drm_crtc_send_vblank_event; then add_k flip "drm_crtc_send_vblank_event"; fi
    add_u() {
        local name=$1 lib=$2 off=$3 spec=$4
        [[ -n "$off" ]] || return 0
        echo "p:aqdiag_${name} ${lib}:0x${off} ${spec}" >>"$tracing/uprobe_events"
        probes_u+=("aqdiag_${name}")
        echo 1 >"$tracing/events/uprobes/aqdiag_${name}/enable"
    }
    add_u blob "$drm" "$off_blob" "sz=%x2:u64 x1=+0(%x1):s32 y1=+4(%x1):s32 x2=+8(%x1):s32 y2=+12(%x1):s32"
    add_u commit "$aq" "$off_commit" ""
    add_u cursor "$aq" "$off_cursor" ""
    add_u add "$aq" "$off_add" ""
    printf 'probes_k %s\nprobes_u %s\nloglevel %s\n' "${probes_k[*]}" "${probes_u[*]}" "$(cat /sys/devices/evdi/loglevel 2>/dev/null || echo unreadable)" >"$dir/meta.txt"
    printf 'Leave the pointer on the built-in panel and do not move it. Trace starts in %ss and lasts %ss.\n' "$COUNTDOWN" "$TRACE_SEC"
    sleep "$COUNTDOWN"
    sample_cpu_line trace_start >"$dir/cpu.txt" || true
    echo >"$tracing/trace"
    echo 1 >"$tracing/tracing_on"
    sleep "$TRACE_SEC"
    echo 0 >"$tracing/tracing_on"
    sample_cpu_line trace_end >>"$dir/cpu.txt" || true
    cp "$tracing/trace" "$dir/trace.txt"
    printf 'evdi_loglevel_after %s\n' "$(cat /sys/devices/evdi/loglevel 2>/dev/null || echo unreadable)" >>"$dir/meta.txt"
    python3 - "$dir" <<'PY'
import os, re, statistics, sys
d=sys.argv[1]
text=open(os.path.join(d,"trace.txt"), errors="replace").read().splitlines()
ts_re=re.compile(r"\b(\d+\.\d+)\b")
def ts(line):
    m=ts_re.search(line)
    return float(m.group(1)) if m else None
ev={"dirty":[],"scanout":[],"grab":[],"vblank":[],"flip":[],"blob":[],"commit":[],"cursor":[],"add":[]}
for line in text:
    for name in ev:
        if f"aqdiag_{name}:" in line:
            t=ts(line)
            ev[name].append((t,line))
            break
def field(line, key):
    m=re.search(rf"\b{key}=(-?\d+)", line)
    return int(m.group(1)) if m else None
dirty={}
for t,line in ev["dirty"]:
    rect=(field(line,"x1"), field(line,"y1"), field(line,"x2"), field(line,"y2"))
    dirty[rect]=dirty.get(rect,0)+1
blobs=[]
for t,line in ev["blob"]:
    sz=field(line,"sz")
    rect=(field(line,"x1"), field(line,"y1"), field(line,"x2"), field(line,"y2"))
    blobs.append((t,sz,rect))
commits=[t for t,_ in ev["commit"] if t is not None]
commits.sort()
paired=naked=0
paired_rects={}
bi=0
blobs_sorted=sorted(blobs, key=lambda x: x[0] if x[0] is not None else 0)
for i,t in enumerate(commits):
    nxt=commits[i+1] if i+1<len(commits) else t+0.05
    found=None
    while bi < len(blobs_sorted) and blobs_sorted[bi][0] is not None and blobs_sorted[bi][0] < t:
        bi+=1
    j=bi
    while j < len(blobs_sorted) and blobs_sorted[j][0] is not None and blobs_sorted[j][0] < nxt:
        sz, rect=blobs_sorted[j][1], blobs_sorted[j][2]
        if sz and sz%16==0 and 16<=sz<=256:
            found=(sz,rect)
            break
        j+=1
    if found:
        paired+=1
        paired_rects[found[1]]=paired_rects.get(found[1],0)+1
    else:
        naked+=1
def rate(n):
    return f"{n/25:.2f}/s" if n else "0"
def gaps(items):
    ts=[t for t,_ in items if t is not None]
    ts.sort()
    g=[b-a for a,b in zip(ts, ts[1:]) if b>=a]
    if not g:
        return "n/a"
    return f"median {statistics.median(g)*1000:.1f} ms  min {min(g)*1000:.1f}  max {max(g)*1000:.1f}  n={len(g)}"
lines=[]
lines.append("25s idle trace. Pointer was supposed to stay on the built-in panel. Not a performance measurement.")
lines.append(f"commits {len(commits)} ({rate(len(commits))})  with a 16..256-byte 16-multiple blob before the next commit: {paired}  without: {naked}")
lines.append(f"moveCursor entries {len(ev['cursor'])}  addDamage entries {len(ev['add'])}")
lines.append(f"set_scanout {len(ev['scanout'])} ({rate(len(ev['scanout']))})  mark_dirty {len(ev['dirty'])} ({rate(len(ev['dirty']))})")
lines.append(f"grabpix {len(ev['grab'])} ({rate(len(ev['grab']))}) inter-arrival {gaps(ev['grab'])}")
lines.append(f"set_vblank {len(ev['vblank'])} inter-arrival {gaps(ev['vblank'])}")
lines.append(f"drm_crtc_send_vblank_event {len(ev['flip'])} inter-arrival {gaps(ev['flip'])}")
lines.append("commit-associated blob rectangles (x1,y1,x2,y2): count")
for rect, n in sorted(paired_rects.items(), key=lambda kv: -kv[1])[:40]:
    lines.append(f"  blob {rect} {n}")
lines.append("evdi mark_dirty rectangles after its own policy (u16 x1,y1,x2,y2): count")
for rect, n in sorted(dirty.items(), key=lambda kv: -kv[1])[:40]:
    lines.append(f"  dirty {rect} {n}")
lines.append("Reading: a blob of 0,0,3840,2160 was submitted by aquamarine. A commit with no such blob has empty or unrecorded damage, which this library sends as FB_DAMAGE_CLIPS absent.")
lines.append("If the blob is smaller than the dirty rectangle, the enlargement happened after userspace.")
lines.append("moveCursor near zero means this window was not cursor motion. set_scanout near the commit count means a new scanout buffer was installed.")
lines.append("grabpix/vblank spacing is a pacing observation only. Compare DisplayLink CPU in cpu.txt with the pause-test baseline before calling the trace itself slow or fast.")
lines.append("Not a confirmed root cause. Both cards are counted together; a rectangle is not attributed to card0 versus card2.")
open(os.path.join(d,"summary.txt"),"w").write("\n".join(lines)+"\n")
print("\n".join(lines))
PY
    printf 'wrote %s\n' "$dir"
    cleanup
    trap - EXIT
}

cmd=${1:-}
flag=${2:-}
case "$cmd" in
    pause-test)
        if [[ "$flag" == --go ]]; then pause_go; else pause_check; fi
        ;;
    trace-test)
        if [[ "$flag" == --go ]]; then trace_go; else trace_check; fi
        ;;
    *)
        usage
        ;;
esac

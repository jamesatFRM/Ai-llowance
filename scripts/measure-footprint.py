#!/usr/bin/env python3
"""Read-only macOS process-tree benchmark; no provider traffic or process arguments.

Counters use proc_pid_rusage v2 from the installed macOS SDK. CPU counters are
Mach absolute-time units, converted with mach_timebase_info. Completed child CPU
is included so short CLI reads between samples do not disappear from the total.
References:
https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/resource.h
https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c
https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c
"""
import argparse
import ctypes
import json
import statistics
import sys
import time


class RUsageV2(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_ubyte * 16)] + [(name, ctypes.c_uint64) for name in (
        'user_time', 'system_time', 'pkg_idle_wkups', 'interrupt_wkups', 'pageins',
        'wired_size', 'resident_size', 'phys_footprint', 'proc_start_abstime',
        'proc_exit_abstime', 'child_user_time', 'child_system_time',
        'child_pkg_idle_wkups', 'child_interrupt_wkups', 'child_pageins',
        'child_elapsed_abstime', 'diskio_bytesread', 'diskio_byteswritten')]


class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]


class Reader:
    def __init__(self):
        self.proc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        self.system = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        self.proc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.proc.proc_pid_rusage.restype = ctypes.c_int
        self.proc.proc_listchildpids.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        self.proc.proc_listchildpids.restype = ctypes.c_int
        self.system.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
        self.system.mach_timebase_info.restype = ctypes.c_int
        self.timebase = Timebase()
        if self.system.mach_timebase_info(ctypes.byref(self.timebase)) != 0 or not self.timebase.denom:
            raise RuntimeError('Unable to read the Mach timebase.')
        self.seconds_per_tick = self.timebase.numer / self.timebase.denom / 1_000_000_000

    def usage(self, pid):
        result = RUsageV2()
        if self.proc.proc_pid_rusage(pid, 2, ctypes.byref(result)) != 0:
            return None
        return result

    def children(self, pid):
        # proc_listchildpids returns a PID count, unlike proc_listpids (bytes).
        buffer = (ctypes.c_int * 4096)()
        count = self.proc.proc_listchildpids(pid, buffer, ctypes.sizeof(buffer))
        if count < 0 or count >= len(buffer):
            raise RuntimeError('Unable to enumerate the complete process subtree.')
        return {int(value) for value in buffer[:count] if value > 0}

    def descendants(self, root):
        found = set()
        pending = [root]
        while pending:
            for child in self.children(pending.pop()):
                if child != root and child not in found:
                    found.add(child)
                    pending.append(child)
            if len(found) >= 4096:
                raise RuntimeError('Process subtree exceeds the measurement limit.')
        return found

    def snapshot(self, pid):
        # Retry changing boundaries to reduce overlap between live child counters
        # and the same child's CPU rolling into the parent's terminated counters.
        for _ in range(3):
            before = self.descendants(pid)
            children = {child: self.usage(child) for child in before}
            parent = self.usage(pid)
            if parent is None:
                raise RuntimeError('Target PID is no longer readable; measurement stopped.')
            after = self.descendants(pid)
            stable = before == after
            if stable:
                break
        missing = sum(value is None for value in children.values())
        live = [value for value in children.values() if value is not None]
        own = parent.user_time + parent.system_time
        completed = parent.child_user_time + parent.child_system_time
        subtree_cpu = own + completed + sum(value.user_time + value.system_time +
            value.child_user_time + value.child_system_time for value in live)
        return dict(parent=parent, children=len(live), inaccessible=missing, stable=stable,
                    own_ticks=own, completed_ticks=completed, subtree_ticks=subtree_cpu,
                    combined_footprint=parent.phys_footprint + sum(value.phys_footprint for value in live),
                    combined_rss=parent.resident_size + sum(value.resident_size for value in live))


def measure(pid, seconds, interval):
    reader = Reader()
    first = reader.snapshot(pid)
    start = time.monotonic()
    samples = [first]
    deadline = start + seconds
    while time.monotonic() < deadline:
        time.sleep(min(interval, max(0, deadline - time.monotonic())))
        sample = reader.snapshot(pid)
        if sample['parent'].proc_start_abstime != first['parent'].proc_start_abstime:
            raise RuntimeError('Target PID was reused; measurement stopped.')
        samples.append(sample)
    elapsed = time.monotonic() - start
    last = samples[-1]
    def cpu(field):
        return max(0, last[field] - first[field]) * reader.seconds_per_tick
    app_cpu = cpu('own_ticks')
    completed_cpu = cpu('completed_ticks')
    combined_cpu = cpu('subtree_ticks')
    mib = 1024 * 1024
    return dict(
        pid=pid, elapsed_seconds=round(elapsed, 3), sample_interval_seconds=interval,
        sample_count=len(samples), mach_timebase_numer=reader.timebase.numer,
        mach_timebase_denom=reader.timebase.denom,
        app_cpu_seconds=round(app_cpu, 6), completed_child_cpu_seconds=round(completed_cpu, 6),
        combined_cpu_seconds=round(combined_cpu, 6),
        app_percent_of_one_core=round(app_cpu / elapsed * 100, 4),
        combined_percent_of_one_core=round(combined_cpu / elapsed * 100, 4),
        app_footprint_median_mib=round(statistics.median(s['parent'].phys_footprint for s in samples) / mib, 3),
        app_footprint_peak_mib=round(max(s['parent'].phys_footprint for s in samples) / mib, 3),
        combined_footprint_sampled_peak_mib=round(max(s['combined_footprint'] for s in samples) / mib, 3),
        app_rss_median_mib=round(statistics.median(s['parent'].resident_size for s in samples) / mib, 3),
        combined_rss_sampled_peak_mib=round(max(s['combined_rss'] for s in samples) / mib, 3),
        app_interrupt_wakeups=max(0, last['parent'].interrupt_wkups - first['parent'].interrupt_wkups),
        app_disk_read_bytes=max(0, last['parent'].diskio_bytesread - first['parent'].diskio_bytesread),
        app_disk_written_bytes=max(0, last['parent'].diskio_byteswritten - first['parent'].diskio_byteswritten),
        peak_live_children=max(s['children'] for s in samples),
        initial_live_children=first['children'], final_live_children=last['children'],
        unstable_samples=sum(not s['stable'] for s in samples),
        inaccessible_child_samples=sum(s['inaccessible'] for s in samples),
        excludes_reparented_and_os_services=True, memory_peaks_are_sampled=True,
        combined_memory_is_sum_of_per_process_charges=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', required=True, type=int)
    parser.add_argument('--seconds', type=float, default=300)
    parser.add_argument('--interval', type=float, default=2)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('This script requires macOS.')
    if args.pid < 1 or not 0 < args.seconds <= 86400 or not 0.1 <= args.interval <= 60:
        parser.error('Use a positive PID, 0–86400 seconds, and a 0.1–60 second sampling interval.')
    try:
        print(json.dumps(measure(args.pid, args.seconds, args.interval), indent=2, sort_keys=True))
    except (RuntimeError, OSError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()

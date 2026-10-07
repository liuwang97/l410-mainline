#!/usr/bin/python3
"""sysprof.py T0 T1 < perf script -F comm,pid,tid,time,ip,sym,dso (with -g):
CPU time between T0 and T1 (perf clock, s) per process, its user DSOs, and its kernel time by entry path."""
import sys, re, collections
t0, t1 = float(sys.argv[1]), float(sys.argv[2])
HZ = float(sys.argv[3]) if len(sys.argv) > 3 else 2000
hdr = re.compile(r"^\s*(.+?)\s+(\d+)/(\d+)\s+([\d.]+):")
fr_re = re.compile(r"^\s*[0-9a-f]+\s+(.*?)\s+\((.*)\)\s*$")
proc = collections.Counter(); udso = collections.defaultdict(collections.Counter)
kpath = collections.defaultdict(collections.Counter); kern = collections.Counter(); comm_of = {}
def classify(k):
    s = set(k)
    if any(x in s for x in ("do_page_fault", "do_translation_fault", "do_mem_abort", "el0_da", "el0_ia")):
        if "filemap_map_pages" in s or "filemap_fault" in s or "do_read_fault" in s: return "fault:file-read"
        if "do_cow_fault" in s: return "fault:file-cow"
        if "do_wp_page" in s or "wp_page_copy" in s: return "fault:cow/wp"
        if "do_anonymous_page" in s: return "fault:anon"
        if "drm_gem_shmem_fault" in s: return "fault:gpu-bo"
        return "fault:other"
    for x in ("panfrost_ioctl_create_bo", "panfrost_ioctl_submit", "drm_gem_close_ioctl", "panfrost_ioctl_wait_bo",
              "panfrost_ioctl_mmap_bo", "drm_ioctl"):
        if x in s: return "ioctl:" + x.replace("panfrost_ioctl_", "pf_")
    for x in ("__arm64_sys_execve", "__arm64_sys_clone", "__arm64_sys_clone3", "__arm64_sys_exit_group", "__arm64_sys_mmap",
              "__arm64_sys_munmap", "__arm64_sys_mprotect", "__arm64_sys_openat", "__arm64_sys_read", "__arm64_sys_pread64",
              "__arm64_sys_futex", "__arm64_sys_newfstatat", "__arm64_sys_statx", "__arm64_sys_getdents64",
              "__arm64_sys_sendmsg", "__arm64_sys_recvmsg", "__arm64_sys_ppoll", "__arm64_sys_epoll_pwait",
              "__arm64_sys_write", "__arm64_sys_madvise", "__arm64_sys_memfd_create", "__arm64_sys_ftruncate",
              "__arm64_sys_close", "__arm64_sys_inotify_add_watch", "__arm64_sys_readlinkat", "__arm64_sys_faccessat"):
        if x in s: return "sys:" + x[len("__arm64_sys_"):]
    if any(x.startswith("__arm64_sys_") for x in s): return "sys:" + next(x for x in k if x.startswith("__arm64_sys_"))[12:]
    if "schedule" in s or "__schedule" in s: return "sched"
    if any("irq" in x for x in s): return "irq"
    return "other:" + (k[-1] if k else "?")
for blk in sys.stdin.read().split("\n\n"):
    lines = blk.strip().split("\n")
    if not lines or not lines[0]: continue
    m = hdr.match(lines[0])
    if not m: continue
    comm, pid, tid, t = m.group(1), int(m.group(2)), int(m.group(3)), float(m.group(4))
    if t < t0 or t > t1 or pid == 0: continue
    comm_of.setdefault(pid, comm) if pid == tid else comm_of.setdefault(pid, comm)
    if pid == tid: comm_of[pid] = comm
    fr = [fm.groups() for l in lines[1:] for fm in [fr_re.match(l)] if fm]
    if not fr: continue
    proc[pid] += 1
    if "kernel" in fr[0][1]:
        kern[pid] += 1
        k = [s for s, d in fr if "kernel" in d]
        kpath[pid][classify(k)] += 1
    else:
        udso[pid][fr[0][1].split("/")[-1]] += 1
ms = lambda n: n * 1000.0 / HZ
tot = sum(proc.values())
print(f"window {1000*(t1-t0):.0f} ms, all CPU {ms(tot):.0f} ms (kernel {ms(sum(kern.values())):.0f})")
for pid, n in proc.most_common(12):
    if ms(n) < 15: break
    print(f"  {comm_of.get(pid,'?')[:16]:16s} {pid:7d} {ms(n):6.0f} ms  kernel {ms(kern[pid]):5.0f}  | " +
          ", ".join(f"{d[:22]} {ms(c):.0f}" for d, c in udso[pid].most_common(6)))
    print("      kernel: " + ", ".join(f"{p} {ms(c):.0f}" for p, c in kpath[pid].most_common(9)))

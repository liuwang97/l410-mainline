#!/usr/bin/python3
"""fold.py COMM < perf script -F comm,tid,ip,sym,dso output (with -g): for samples of thread COMM,
count kernel time by entry path (syscall/fault handler and the 2 frames under it), and user time by DSO."""
import sys, collections, re
want = sys.argv[1]
kern, user = collections.Counter(), collections.Counter()
n = 0
for blk in sys.stdin.read().split("\n\n"):
    lines = [l for l in blk.strip().split("\n") if l.strip()]
    if not lines or want not in lines[0]:
        continue
    n += 1
    fr = []
    for l in lines[1:]:
        m = re.match(r"\s*[0-9a-f]+\s+(.*?)\s+\((.*)\)\s*$", l)
        if m: fr.append((m.group(1), m.group(2)))
    if not fr:
        continue
    if "kernel" not in fr[0][1]:
        user[fr[0][1].split("/")[-1]] += 1
        continue
    k = [s for s, d in fr if "kernel" in d]
    # walk from the outermost kernel frame inward, skip the entry glue
    k.reverse()
    skip = re.compile(r"^(el0|el1|__arm64_sys_ioctl$|invoke_syscall|do_el0|el0t|__do_sys|__se_sys|ret_from|do_mem_abort|el0_da|el0_ia|do_translation_fault|do_page_fault|handle_mm_fault)")
    head = k[0]
    rest = [s for s in k[1:] if not skip.match(s)]
    key = head + " > " + " > ".join(rest[:3])
    kern[key] += 1
print(f"{want}: {n} samples ({n/4:.0f} ms at 4 kHz); kernel {sum(kern.values())/4:.0f} ms, user {sum(user.values())/4:.0f} ms")
print("user DSOs: " + ", ".join(f"{d} {c/4:.0f}" for d, c in user.most_common(8)))
print("kernel paths (ms):")
for k, c in kern.most_common(25):
    print(f"  {c/4:6.1f}  {k}")

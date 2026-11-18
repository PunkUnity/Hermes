#!/usr/bin/env python3
"""Summarize one Hermes stream from verbose logs (journalctl -o cat) and an optional
per-second NIC byte counter file ("<unix_time> <tx_bytes>" per line).

Usage: journalctl --user -u hermes --since ... -o cat | python3 -I stream-report.py [net.txt]
"""
import re
import statistics
import sys

PACKET_BYTES = 1040  # Hestia's packet size plus the RTP header, as logged on this host

sent = re.compile(r"Sent Frame seq \[(\d+)\] pts \[[^\]]*\] shards \[(\d+)/(\d+)%\]( Dupe)?( Key)?( RFI)?")
lost = re.compile(r"Client lost (\d+) packets of frame (\d+)(?P<drop> and dropped it)?")
large = re.compile(r"Abnormally large encoded (key frame|frame) \((\d+) KiB in (\d+) packets\).*with (\d+)% FEC")

frames = {}  # seq -> dict(shards, data, key, rfi, dupe, min_pct)
losses = []
larges = []
other = {"summary": [], "silent": [], "filler": 0, "cbr": 0}

for line in sys.stdin:
    if m := sent.search(line):
        seq, shards, pct = int(m[1]), int(m[2]), int(m[3])
        f = frames.setdefault(seq, {"shards": 0, "data": 0, "key": False, "rfi": False, "dupe": False, "pct": pct, "blocks": 0})
        f["shards"] += shards
        f["data"] += round(shards * 100 / (100 + pct))
        f["blocks"] += 1
        f["pct"] = min(f["pct"], pct)
        f["key"] |= bool(m[5])
        f["rfi"] |= bool(m[6])
        f["dupe"] |= bool(m[4])
    elif m := lost.search(line):
        losses.append((int(m[2]), int(m[1]), bool(m["drop"])))
    elif m := large.search(line):
        larges.append((m[1], int(m[2]), int(m[3]), int(m[4])))
    elif "video packets (" in line:
        other["summary"].append(line.split("]: ", 1)[-1].strip())
    elif "went silent" in line:
        other["silent"].append(line.split("]: ", 1)[-1].strip())
    elif "Removing the filler" in line:
        other["filler"] += 1
    elif "Using CBR with single frame VBV" in line:
        other["cbr"] += 1

def pct(values, p):
    if not values:
        return 0
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * p / 100))]

print("== Frames")
if not frames:
    print("no 'Sent Frame' lines: was min_log_level = verbose during the stream?")
else:
    data = [f["data"] for f in frames.values()]
    keys = [f for f in frames.values() if f["key"]]
    print(f"frames sent: {len(frames)}  key frames: {len(keys)}  after ref-frame invalidation: {sum(f['rfi'] for f in frames.values())}  duplicates: {sum(f['dupe'] for f in frames.values())}")
    print(f"data packets per frame: median {statistics.median(data):.0f}  p95 {pct(data, 95)}  p99 {pct(data, 99)}  max {max(data)}  (x{PACKET_BYTES} B)")
    big = [f for f in frames.values() if f["data"] > 800]
    print(f"frames over 800 data packets (beyond 4 FEC blocks at 20%): {len(big)}  of them key frames: {sum(f['key'] for f in big)}")
    if keys:
        ks = [f["data"] for f in keys]
        print(f"key frame sizes (data packets): {sorted(ks)[:10]}{' ...' if len(ks) > 10 else ''}")
    reduced = [f for f in frames.values() if f["pct"] < 20]
    print(f"frames sent with less than 20% FEC: {len(reduced)}")

print("\n== Oversized frames logged")
for kind, kib, packets, fec in larges:
    print(f"{kind}: {kib} KiB, {packets} packets, sent with {fec}% FEC")
if not larges:
    print("none")

print("\n== Loss reports from the client")
if not losses:
    print("none")
else:
    dropped = [l for l in losses if l[2]]
    repaired = [l for l in losses if not l[2]]
    print(f"blocks repaired by FEC: {len(repaired)}  blocks lost (frame dropped): {len(dropped)}  distinct dropped frames: {len({l[0] for l in dropped})}")
    if frames:
        median = statistics.median([f["data"] for f in frames.values()])
        hit = [frames[l[0]] for l in losses if l[0] in frames]
        if hit:
            print(f"frames with loss: median {statistics.median([f['data'] for f in hit]):.0f} data packets (all frames: {median:.0f}); key frames among them: {sum(f['key'] for f in hit)}")
        for seq, missing, was_dropped in losses[:15]:
            f = frames.get(seq)
            size = f"{f['data']} packets{' KEY' if f['key'] else ''}" if f else "size unknown"
            print(f"  frame {seq}: {missing} packets missing, {'DROPPED' if was_dropped else 'repaired'} ({size})")
        if len(losses) > 15:
            print(f"  ... {len(losses) - 15} more")

if len(sys.argv) > 1:
    print("\n== Host network traffic (per second)")
    rows = [tuple(map(int, l.split())) for l in open(sys.argv[1]) if len(l.split()) == 2]
    rates = [(b2 - b1) * 8 / (t2 - t1) / 1e6 for (t1, b1), (t2, b2) in zip(rows, rows[1:]) if t2 > t1]
    if rates:
        print(f"seconds: {len(rates)}  Mbps min {min(rates):.1f}  median {statistics.median(rates):.1f}  p95 {pct(rates, 95):.1f}  max {max(rates):.1f}")
        print("per 10 s: " + " ".join(f"{statistics.mean(rates[i:i + 10]):.0f}" for i in range(0, len(rates), 10)))

print("\n== Session")
print(f"CBR chosen: {other['cbr']} times  filler removal logged: {other['filler']} times")
for line in other["silent"] + other["summary"]:
    print(line)

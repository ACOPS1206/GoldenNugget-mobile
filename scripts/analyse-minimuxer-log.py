#!/usr/bin/env python3
"""Tabulate jktcp's delivery clock from a minimuxer.log.

The question the goldennugget.log could not answer: is `expected` (the next byte jktcp can
hand upstream) standing still, advancing steadily, or advancing in steps?  That
separates "the tunnel is dead" from "the tunnel is delivering in chunks".
"""
import re
import sys
from datetime import datetime

PATH = sys.argv[1] if len(sys.argv) > 1 else None
if not PATH:
    raise SystemExit("usage: analyse-minimuxer-log.py <minimuxer.log>")

line_re = re.compile(
    r"^(?P<ts>\S+Z) DEBUG out-of-order seq=(?P<seq>\d+) expected=(?P<exp>\d+) hp=(?P<hp>\d+)"
    r"(?: held=(?P<held>\w+) buffered=(?P<buf>\d+))?$")
dup_re = re.compile(r"^(?P<ts>\S+Z) DEBUG duplicate data seq=(?P<seq>\d+) expected=(?P<exp>\d+) hp=(?P<hp>\d+)$")
dup_ack_re = re.compile(
    r"^(?P<ts>\S+Z) DEBUG duplicate ACK for hp=(?P<hp>\d+): ack=(?P<ack>\d+) "
    r"window=(?P<win>\d+) \(hole (?P<hole>\d+) bytes wide\)$")
rst_re = re.compile(r"^(?P<ts>\S+Z)\s+WARN RST on hp=(?P<hp>\d+)$")
dl_re = re.compile(r"^(?P<ts>\S+Z) DEBUG (?:Received DL message|Sending device link message): (?P<tag>\S+)")
dx_re = re.compile(r"^(?P<ts>\S+Z) DEBUG (?:Starting|Received DL message: DLMessageVersionExchange)")

rows = []
dups, rsts, versions = [], [], []
dup_acks, held_dropped = [], 0
dl_by_second = {}

with open(PATH) as fh:
    for line in fh:
        line = line.rstrip("\n")
        m = line_re.match(line)
        if m:
            rows.append((m["ts"], int(m["seq"]), int(m["exp"]), m["hp"]))
            if m["held"] == "false":
                held_dropped += 1
            continue
        m = dup_re.match(line)
        if m:
            dups.append((m["ts"], int(m["seq"]), int(m["exp"]), m["hp"]))
            continue
        m = dup_ack_re.match(line)
        if m:
            dup_acks.append((m["ts"], m["hp"], int(m["ack"]), int(m["win"]), int(m["hole"])))
            continue
        m = rst_re.match(line)
        if m:
            rsts.append((m["ts"], m["hp"]))
            continue
        if "Starting DeviceLink version exchange" in line:
            versions.append(line.split()[0])
        m = dl_re.match(line)
        if m:
            sec = m["ts"][:19]
            dl_by_second[sec] = dl_by_second.get(sec, 0) + 1


def parse(ts):
    return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S.%fZ")


if not rows:
    raise SystemExit("no out-of-order lines")

print(f"out-of-order lines : {len(rows)}   hp values: {sorted({r[3] for r in rows})}")
print(f"duplicate data     : {len(dups)}   hp values: {sorted({d[3] for d in dups})}")
print(f"duplicate ACKs     : {len(dup_acks)}   hp values: {sorted({d[1] for d in dup_acks})}   "
      f"held=false: {held_dropped}")
print(f"RST                : {len(rsts)}   hp values: {sorted({r[1] for r in rsts})}")
print(f"version exchanges  : {len(versions)}")
print()

print("— expected: every distinct value, with how long it held and how much seq ran ahead")
prev_exp, seg_start, seg_first_ts, held = None, 0, None, 0
for i, (ts, seq, exp, hp) in enumerate(rows):
    if exp != prev_exp:
        if prev_exp is not None:
            dt = (parse(ts) - parse(seg_first_ts)).total_seconds()
            print(f"  expected={prev_exp:>12d} held {dt:7.3f}s over {held:5d} lines "
                  f"(seq ran to {last_seq:>12d}, gap {last_seq - prev_exp:>9d} B)")
        prev_exp, seg_start, seg_first_ts, held = exp, i, ts, 0
    last_seq = seq
    held += 1
dt = (parse(rows[-1][0]) - parse(seg_first_ts)).total_seconds()
print(f"  expected={prev_exp:>12d} held {dt:7.3f}s over {held:5d} lines "
      f"(seq ran to {last_seq:>12d}, gap {last_seq - prev_exp:>9d} B)")

# Where dd the seq bursts sit in time?
print()
print("— seq advances seen within the same microsecond (a burst arriving at once)")
bursts = {}
for ts, seq, exp, hp in rows:
    bursts.setdefault(ts, []).append(seq)
big = sorted(((len(v), k, max(v) - min(v)) for k, v in bursts.items() if len(v) >= 50), reverse=True)
print(f"  {len(big)} such instants, top 5: lines / timestamp / seq span")
for n, ts, span in big[:5]:
    print(f"    {n:5d} lines at {ts}  seq span {span} B")

print()
print("— RST and duplicate events (chronological)")
for ts, seq, exp, hp in dups:
    print(f"  {ts}  duplicate data seq={seq} expected={exp} hp={hp}  (expected is {exp - seq:+d} vs seq)")
for ts, hp in rsts:
    print(f"  {ts}  RST hp={hp}")

print()
print("— duplicate ACKs sent by jktcp, per connection (whether the peer was asked to retransmit)")
by_hp = {}
for ts, hp, ack, win, hole in dup_acks:
    by_hp.setdefault(hp, []).append((ts, ack, win, hole))
for hp in sorted(by_hp, key=lambda k: -len(by_hp[k])):
    evs = by_hp[hp]
    distinct_ack = sorted({a for _, a, _, _ in evs})
    widest = max(h for _, _, _, h in evs)
    print(f"  hp={hp}: {len(evs)} dup ACK(s), ack value(s) {distinct_ack[:4]}"
          f"{'…' if len(distinct_ack) > 4 else ''}, widest hole {widest} B")
    for ts, ack, win, hole in evs[:3]:
        print(f"      {ts}  ack={ack} window={win} hole={hole} B")
    if len(evs) > 3:
        print(f"      … {len(evs) - 3} more")

print()
print("— DL messages per second (only seconds that had any)")
for sec in sorted(dl_by_second):
    n = dl_by_second[sec]
    bar = "#" * min(n // 2, 60)
    print(f"  {sec}  {n:4d} {bar}")

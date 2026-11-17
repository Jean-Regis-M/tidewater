#!/usr/bin/env python3
"""On-chain latency from block timestamps.

For each loop in a JSONL file (as written by scripts/live_loop.sh) this reads the Base Sepolia block of the
origin transaction (repay) and of the settle transaction, using the millisecond `timestampMs` field, and reports
the gap. No client-side polling is involved, so the result does not depend on the measuring machine's latency.

Usage:
  python scripts/measure_onchain.py deployments/measurements.jsonl [out.json]

Needs Foundry's `cast` on PATH (or set CAST). Read-only.
"""
import json
import os
import statistics
import subprocess
import sys

CAST = os.environ.get("CAST", "cast")
RPC = os.environ.get("BASE_RPC", "https://base-sepolia-rpc.publicnode.com")


def cast_json(*args):
    out = subprocess.run([CAST, *args, "--json", "--rpc-url", RPC], capture_output=True, text=True).stdout
    j = json.loads(out)
    return j.get("data", j) if isinstance(j, dict) else j


def hx(v):
    return int(v, 16) if isinstance(v, str) and v.startswith("0x") else int(v)


def block_ms(tx):
    receipt = cast_json("receipt", tx)
    number = hx(receipt["blockNumber"])
    block = cast_json("block", str(number))
    ms = block.get("timestampMs")
    return number, (hx(ms) if ms else hx(block["timestamp"]) * 1000)


def pct(sorted_vals, p):
    return sorted_vals[min(len(sorted_vals) - 1, int(round(p * (len(sorted_vals) - 1))))]


def main():
    src = sys.argv[1]
    rows = [json.loads(line) for line in open(src) if line.strip()]
    out = []
    for r in rows:
        if r.get("settled") != 1 or not r.get("settleTx"):
            continue
        ob, ot = block_ms(r["originTx"])
        sb, st = block_ms(r["settleTx"])
        out.append(
            {
                "loop": r["loop"],
                "origin": r["originTx"],
                "settle": r["settleTx"],
                "originBlock": ob,
                "settleBlock": sb,
                "blocks": sb - ob,
                "originToSettleMs": st - ot,
            }
        )
    vals = sorted(x["originToSettleMs"] / 1000 for x in out)
    summary = {
        "n": len(vals),
        "min_s": vals[0],
        "p50_s": statistics.median(vals),
        "p95_s": pct(vals, 0.95),
        "max_s": vals[-1],
        "mean_s": round(statistics.mean(vals), 3),
    }
    print(json.dumps(summary))
    if len(sys.argv) > 2:
        json.dump({"summary": summary, "loops": out}, open(sys.argv[2], "w"), indent=1)


if __name__ == "__main__":
    main()

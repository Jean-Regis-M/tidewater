#!/usr/bin/env python3
"""Prints the Reactive vs keeper latency comparison as a Markdown table, from recorded on-chain results.

Inputs (all produced by scripts/measure_onchain.py or the Reactive loop evidence):
  deployments/lasna-links.json                  Reactive path, 20 loops
  deployments/baseline-poll1000-onchain.json    keeper polling every 1000 ms
  deployments/baseline-poll250-onchain.json     keeper polling every 250 ms
"""
import json
import statistics

ROOT = "deployments"


def load_reactive():
    rows = json.load(open(f"{ROOT}/lasna-links.json"))
    return sorted(r["originToSettleMs"] / 1000 for r in rows)


def load_keeper(name):
    d = json.load(open(f"{ROOT}/{name}"))
    return sorted(r["originToSettleMs"] / 1000 for r in d["loops"])


def pct(v, p):
    return v[min(len(v) - 1, int(round(p * (len(v) - 1))))]


def row(label, v):
    return (
        f"| {label} | {len(v)} | {v[0]:.1f} s | {statistics.median(v):.1f} s | "
        f"{pct(v, 0.95):.1f} s | {v[-1]:.1f} s |"
    )


print("| Settler | Loops | Min | Median | p95 | Max |")
print("|---|---|---|---|---|---|")
print(row("Reactive (callback via proxy)", load_reactive()))
print(row("Keeper, polling every 1000 ms", load_keeper("baseline-poll1000-onchain.json")))
print(row("Keeper, polling every 250 ms", load_keeper("baseline-poll250-onchain.json")))

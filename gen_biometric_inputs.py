#!/usr/bin/env python3
"""
Generate inputs for the biometric squared-distance matching workload
(Programs/Source/biometric_test.mpc).

Workload is square: N templates of dimension D, with N == D == --n.

- Party 0 file: Player-Data/Input-P0-0
      probe vector C of length D (= n) values
- Party 1 file: Player-Data/Input-P1-0
      database S as n rows of n ints (row-major), totalling N*D values

Defaults:
- n = 2048
- values are positive 32-bit unsigned integers (matches the uint32_t source
  in the user's C frontend), drawn in [0, 2^bits - 1]

Note on bitwidth: the values themselves are kept narrow (default 32-bit)
so the squared sums fit comfortably inside MP-SPDZ's compile-time bit
length budget; the field that backs the secret-shared arithmetic is
configured separately via PRIME / INT_BITS in the test script.
"""

import argparse
import os
import random
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=2048,
                    help="dimension n; sets BOTH templates count N and "
                         "per-template dim D (workload is square N==D)")
    ap.add_argument("--seed", type=int, default=42,
                    help="PRNG seed for reproducibility")
    ap.add_argument("--bits", type=int, default=32,
                    help="bit width for input values (1..31 for safe "
                         "decimal I/O; default 32 matches the uint32_t "
                         "C frontend but is clamped to 31 for safety)")
    ap.add_argument("--signed", action="store_true",
                    help="use signed range [-2^(bits-1), 2^(bits-1)-1]; "
                         "default is unsigned [0, 2^bits - 1]")
    ap.add_argument("--ones", action="store_true",
                    help="ignore RNG and emit all 1s (useful for sanity / "
                         "matches the --ones option in the parallel "
                         "biometric_new.sh pipeline)")
    ap.add_argument("--dir", default="Player-Data",
                    help="output directory")
    ap.add_argument("--p0-file", default="Input-P0-0",
                    help="filename for party 0 input (within --dir)")
    ap.add_argument("--p1-file", default="Input-P1-0",
                    help="filename for party 1 input (within --dir)")
    args = ap.parse_args()

    n = args.n
    if n <= 0:
        raise SystemExit("--n must be positive")

    random.seed(args.seed)

    # Clamp bits to the 31 we can safely emit as decimal text without
    # tripping into 32-bit-signed parsers downstream.
    bits = min(max(args.bits, 1), 31)
    if args.signed:
        lo = -(1 << (bits - 1))
        hi = (1 << (bits - 1)) - 1
    else:
        lo = 0
        hi = (1 << bits) - 1

    if args.ones:
        def r():
            return 1
    else:
        def r():
            return random.randint(lo, hi)

    os.makedirs(args.dir, exist_ok=True)
    p0_path = os.path.join(args.dir, args.p0_file)
    p1_path = os.path.join(args.dir, args.p1_file)

    # Party 0: probe vector C of length D (= n)
    with open(p0_path, "w") as f0:
        f0.write(" ".join(str(r()) for _ in range(n)))
        f0.write("\n")

    # Party 1: database S of N rows × D cols (= n × n), row-major
    with open(p1_path, "w") as f1:
        for _ in range(n):
            f1.write(" ".join(str(r()) for _ in range(n)))
            f1.write("\n")

    # Summary
    try:
        from pathlib import Path
        s0 = Path(p0_path).stat().st_size
        s1 = Path(p1_path).stat().st_size
        rng = "all-ones" if args.ones else f"[{lo}, {hi}]"
        print(f"✔ Wrote Party0: {p0_path}  ({s0:,} bytes)")
        print(f"✔ Wrote Party1: {p1_path}  ({s1:,} bytes)")
        print(f"   Shapes: C={n} (D), S={n}x{n} (N x D); values: {rng}")
    except Exception:
        pass


if __name__ == "__main__":
    sys.exit(main())

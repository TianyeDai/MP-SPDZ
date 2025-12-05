#!/usr/bin/env python3
"""
Generate inputs for a linear layer y = W x + b.

- Party 0 file: Player-Data/Input-P0-0  (x of length n)
- Party 1 file: Player-Data/Input-P1-0  (W as n rows of n ints, then b of length n)

Defaults:
- n = 4096
- values are POSITIVE 16-bit unsigned integers in [0, 65535]
"""

import argparse, os, random, sys

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=2048, help="dimension n (x: n, W: n×n, b: n)")
    ap.add_argument("--seed", type=int, default=42, help="PRNG seed for reproducibility")
    ap.add_argument("--bits", type=int, default=16, help="bit width for values (max 31 recommended for decimal I/O)")
    ap.add_argument("--signed", action="store_true", help="use signed range [-2^(bits-1), 2^(bits-1)-1]; default is unsigned [0, 2^bits-1]")
    ap.add_argument("--dir", default="Player-Data", help="output directory")
    ap.add_argument("--p0-file", default="Input-P0-0", help="filename for party 0 input (within --dir)")
    ap.add_argument("--p1-file", default="Input-P1-0", help="filename for party 1 input (within --dir)")
    args = ap.parse_args()

    n = args.n
    random.seed(args.seed)

    # Compute range based on bits/signedness
    if args.bits <= 0 or args.bits > 31:
        raise SystemExit("bits must be between 1 and 31 for practical decimal I/O sizes.")
    if args.signed:
        lo = -(1 << (args.bits - 1))
        hi =  (1 << (args.bits - 1)) - 1
    else:
        lo = 0
        hi = (1 << args.bits) - 1

    def r():  # draw one value
        return random.randint(lo, hi)

    os.makedirs(args.dir, exist_ok=True)
    p0_path = os.path.join(args.dir, args.p0_file)
    p1_path = os.path.join(args.dir, args.p1_file)

    # Party 0: x (length n)
    with open(p0_path, "w") as f0:
        f0.write(" ".join(str(r()) for _ in range(n)))
        f0.write("\n")

    # Party 1: W (n rows × n cols) then b (length n)
    with open(p1_path, "w") as f1:
        for _ in range(n):
            f1.write(" ".join(str(r()) for _ in range(n)))
            f1.write("\n")
        f1.write(" ".join(str(r()) for _ in range(n)))
        f1.write("\n")

    # Summary
    try:
        from pathlib import Path
        s0 = Path(p0_path).stat().st_size
        s1 = Path(p1_path).stat().st_size
        rng_desc = f"[{lo}, {hi}]"
        print(f"✔ Wrote Party0: {p0_path}  ({s0:,} bytes)")
        print(f"✔ Wrote Party1: {p1_path}  ({s1:,} bytes)")
        print(f"   Shapes: x={n}, W={n}x{n}, b={n}; value range: {rng_desc}")
    except Exception:
        pass

if __name__ == "__main__":
    sys.exit(main())

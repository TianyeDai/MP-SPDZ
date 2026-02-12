#!/usr/bin/env python3
"""
Generate inputs for vectorized LTZ test:

- Party 0 file: Player-Data/Input-P0-0  (LEN ints)
- No other party inputs needed (program reads only input_from(0))

Defaults:
- LEN=1024
- signed values in [-2^(bits-1), 2^(bits-1)-1] so LTZ is meaningful
"""

import argparse, os, random, sys

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--len", type=int, default=1024, help="LEN (vector length)")
    ap.add_argument("--seed", type=int, default=42, help="PRNG seed for reproducibility")
    ap.add_argument("--bits", type=int, default=16, help="bit width (<=31 recommended for decimal I/O)")
    ap.add_argument("--signed", action="store_true", default=True,
                    help="use signed range [-2^(bits-1), 2^(bits-1)-1] (default: true)")
    ap.add_argument("--unsigned", action="store_true",
                    help="override to use unsigned [0, 2^bits-1] (not recommended for LTZ)")
    ap.add_argument("--dir", default="Player-Data", help="output directory")
    ap.add_argument("--p0-file", default="Input-P0-0", help="filename for party 0 input (within --dir)")
    args = ap.parse_args()

    LEN = args.len
    if LEN <= 0:
        raise SystemExit("LEN must be positive.")

    random.seed(args.seed)

    if args.bits <= 0 or args.bits > 31:
        raise SystemExit("bits must be between 1 and 31 for practical decimal I/O sizes.")

    use_signed = args.signed and not args.unsigned
    if use_signed:
        lo = -(1 << (args.bits - 1))
        hi =  (1 << (args.bits - 1)) - 1
    else:
        lo = 0
        hi = (1 << args.bits) - 1

    def r():
        return random.randint(lo, hi)

    os.makedirs(args.dir, exist_ok=True)
    p0_path = os.path.join(args.dir, args.p0_file)

    # Party 0: LEN integers, one per line (MP-SPDZ decimal input is fine with whitespace)
    with open(p0_path, "w", encoding="utf-8") as f0:
        for _ in range(LEN):
            f0.write(f"{r()}\n")

    try:
        from pathlib import Path
        s0 = Path(p0_path).stat().st_size
        rng_desc = f"[{lo}, {hi}]"
        print(f"✔ Wrote Party0: {p0_path}  ({s0:,} bytes)")
        print(f"   LEN={LEN}; value range: {rng_desc}")
    except Exception:
        pass

if __name__ == "__main__":
    sys.exit(main())

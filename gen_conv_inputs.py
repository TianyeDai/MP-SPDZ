#!/usr/bin/env python3
"""
Generate inputs for a single valid 2D convolution:
  y[r,c] = sum_{i,j} A[r+i, c+j] * W[i,j]

- Party 0 file: Player-Data/Input-P0-0  (A as A_ROWS rows of A_COLS ints)
- Party 1 file: Player-Data/Input-P1-0  (W as W_DIM rows of W_DIM ints)

Defaults:
- A_ROWS=A_COLS=8, W_DIM=2
- values are POSITIVE 16-bit unsigned integers in [0, 65535]
"""

import argparse, os, random, sys

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a-rows", type=int, default=8, help="A_ROWS (height of input matrix A)")
    ap.add_argument("--a-cols", type=int, default=8, help="A_COLS (width of input matrix A)")
    ap.add_argument("--w-dim",  type=int, default=2, help="W_DIM (kernel is w_dim x w_dim)")
    ap.add_argument("--seed", type=int, default=42, help="PRNG seed for reproducibility")
    ap.add_argument("--bits", type=int, default=16, help="bit width for values (max 31 recommended for decimal I/O)")
    ap.add_argument("--signed", action="store_true",
                    help="use signed range [-2^(bits-1), 2^(bits-1)-1]; default is unsigned [0, 2^bits-1]")
    ap.add_argument("--dir", default="Player-Data", help="output directory")
    ap.add_argument("--p0-file", default="Input-P0-0", help="filename for party 0 input (within --dir)")
    ap.add_argument("--p1-file", default="Input-P1-0", help="filename for party 1 input (within --dir)")
    args = ap.parse_args()

    A_ROWS = args.a_rows
    A_COLS = args.a_cols
    W_DIM  = args.w_dim

    if A_ROWS <= 0 or A_COLS <= 0 or W_DIM <= 0:
        raise SystemExit("A_ROWS, A_COLS, and W_DIM must be positive.")
    if W_DIM > A_ROWS or W_DIM > A_COLS:
        raise SystemExit(f"W_DIM={W_DIM} must be <= A_ROWS={A_ROWS} and <= A_COLS={A_COLS} (valid conv).")

    random.seed(args.seed)

    # Range based on bits/signedness
    if args.bits <= 0 or args.bits > 31:
        raise SystemExit("bits must be between 1 and 31 for practical decimal I/O sizes.")
    if args.signed:
        lo = -(1 << (args.bits - 1))
        hi =  (1 << (args.bits - 1)) - 1
    else:
        lo = 0
        hi = (1 << args.bits) - 1

    def r():
        return random.randint(lo, hi)

    os.makedirs(args.dir, exist_ok=True)
    p0_path = os.path.join(args.dir, args.p0_file)
    p1_path = os.path.join(args.dir, args.p1_file)

    # Party 0: A matrix (A_ROWS x A_COLS), one row per line
    with open(p0_path, "w", encoding="utf-8") as f0:
        for _ in range(A_ROWS):
            f0.write(" ".join(str(r()) for _ in range(A_COLS)))
            f0.write("\n")

    # Party 1: W kernel (W_DIM x W_DIM), one row per line
    with open(p1_path, "w", encoding="utf-8") as f1:
        for _ in range(W_DIM):
            f1.write(" ".join(str(r()) for _ in range(W_DIM)))
            f1.write("\n")

    # Summary
    try:
        from pathlib import Path
        s0 = Path(p0_path).stat().st_size
        s1 = Path(p1_path).stat().st_size
        out_r = A_ROWS - W_DIM + 1
        out_c = A_COLS - W_DIM + 1
        rng_desc = f"[{lo}, {hi}]"
        print(f"✔ Wrote Party0: {p0_path}  ({s0:,} bytes)")
        print(f"✔ Wrote Party1: {p1_path}  ({s1:,} bytes)")
        print(f"   Shapes: A={A_ROWS}x{A_COLS}, W={W_DIM}x{W_DIM}, out={out_r}x{out_c}; value range: {rng_desc}")
    except Exception:
        pass

if __name__ == "__main__":
    sys.exit(main())

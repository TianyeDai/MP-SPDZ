#!/usr/bin/env bash
# activation_ltz_test.sh
# Build VM once, then for each LEN in LENS, THREAD in THREAD_SET, and PARTY in PARTIES:
#   generate inputs (once per LEN)
#   preprocess (Fake-Offline) per PARTY
#   compile (per THREAD)
#   run REPEAT times with PARTY parties.

set -euo pipefail

########################################
# Build runtime first
########################################
# Auto-detect core count; override with JOBS=<n>
JOBS="${JOBS:-$({
  command -v getconf >/dev/null 2>&1 && getconf _NPROCESSORS_ONLN 2>/dev/null || \
  sysctl -n hw.ncpu 2>/dev/null || echo 4;
})}"
echo "[0/5] Build runtime (mascot-party.x) with ${JOBS} jobs"
make -j "${JOBS}" mascot-party.x

########################################
# Config (override with env vars)
########################################
PROGRAM="${PROGRAM:-activation_ltz_vec}"       # Programs/Source/activation_ltz_vec.mpc
LENS_STR="${LENS:-262140}"                      # comma-separated list of LEN(s)
REPEAT="${REPEAT:-1}"                         # repetitions per (LEN,THREAD)
THREAD_SET_STR="${THREAD_SET:-32}"            # thread counts to test
PARTIES_STR="${PARTIES:-2}"                   # comma-separated list, e.g. "2,3,4"

# Exact prime p = 4_294_967_291
PRIME="${PRIME:-4294967291}"
INT_BITS="${INT_BITS:-30}"     # for ./compile.py -F (bitlen(p) >= INT_BITS + 2)

# MP-SPDZ runtime flags (party count is added later with -N)
HOST="${HOST:-127.0.0.1}"
PORT_BASE="${PORT_BASE:-14000}"
SECURITY="${SECURITY:-16}"                     # -S security parameter
BASE_FLAGS="-v -F -S ${SECURITY} -h ${HOST}"   # -F = use file-based preprocessing

########################################
# Helpers
########################################
IFS=',' read -r -a LENS <<< "${LENS_STR}"
IFS=',' read -r -a THREAD_SET <<< "${THREAD_SET_STR}"
IFS=',' read -r -a PARTIES <<< "${PARTIES_STR}"

ensure_dirs() {
  mkdir -p "logs"
  for n in "${LENS[@]}"; do
    mkdir -p "logs/L${n}"
    for t in "${THREAD_SET[@]}"; do
      mkdir -p "logs/L${n}/T${t}"
      for p in "${PARTIES[@]}"; do
        mkdir -p "logs/L${n}/P${p}/T${t}"
      done
    done
  done
}

# Kill any children on exit/Ctrl-C
pids=()
cleanup() {
  if [[ ${#pids[@]} -gt 0 ]]; then
    for pid in "${pids[@]}"; do
      kill "$pid" 2>/dev/null || true
    done
  fi
}
trap cleanup EXIT INT TERM

# --- helper: compile + measure wall time in seconds; capture outputs to log ---
compile_and_time() {
  local len="$1" threads="$2" bits="$3" prog="$4"
  local outdir="logs/L${len}/T${threads}"
  python3 - "$len" "$threads" "$bits" "$prog" "$outdir" <<'PY'
import os, sys, subprocess, time, pathlib

length, threads, bits, prog, outdir = sys.argv[1:6]
out = pathlib.Path(outdir); out.mkdir(parents=True, exist_ok=True)
log_path = out / "compile.log"

env = os.environ.copy()
env['LEN'] = length
env['THREADS'] = threads
prime = env.get('PRIME')

cmd = ["./compile.py"]
if prime:
    cmd += ["-P", prime]
if bits:
    cmd += ["-F", bits]
cmd.append(prog)

t0 = time.perf_counter()
res = subprocess.run(cmd, env=env, capture_output=True, text=True)
dt = time.perf_counter() - t0

with open(log_path, "w", encoding="utf-8") as f:
    if res.stdout:
        f.write(res.stdout)
    if res.stderr:
        f.write(res.stderr)

print(f"{dt:.6f}")

if res.returncode != 0:
    print(res.stdout, end="")
    print(res.stderr, end="", file=sys.stderr)

sys.exit(res.returncode)
PY
}

run_once_parties() {
  local port="$1"
  local len="$2"
  local run_idx="$3"
  local fe="$4"
  local threads="$5"
  local parties="$6"

  local log_dir="logs/L${len}/P${parties}/T${threads}"

  echo "    [run ${run_idx}] starting ${parties} parties on port ${port}"
  echo "    LEN=${len}  BENCH_FE_SEC=${fe}  BENCH_THREADS=${threads}  PARTIES=${parties}"

  local pids_local=()
  local party_ids=()

  for ((pid_id = 0; pid_id < parties; ++pid_id)); do
    local party_id="${pid_id}"
    local log_path="${log_dir}/run${run_idx}_p${party_id}.log"

    LEN="${len}" THREADS="${threads}" \
    BENCH_INPUT_LEN="${len}" BENCH_FE_SEC="${fe}" BENCH_THREADS="${threads}" \
    /usr/bin/time -v ./mascot-party.x ${BASE_FLAGS} -N "${parties}" -pn "${port}" "${party_id}" "${PROGRAM}" \
      &> "${log_path}" &

    pids_local+=("$!")
    party_ids+=("${party_id}")
  done

  pids=("${pids_local[@]}")

  local num="${#pids_local[@]}"
  for ((i = 0; i < num; ++i)); do
    local pid="${pids_local[$i]}"
    local party_id="${party_ids[$i]}"
    if ! wait "${pid}"; then
      echo "    [run ${run_idx}] Party ${party_id} failed (LEN=${len}, P=${parties}, T=${threads})"
      for ((j = 0; j < num; ++j)); do
        [[ $j == $i ]] && continue
        kill "${pids_local[$j]}" 2>/dev/null || true
      done
      exit 1
    fi
  done

  pids=()
  echo "    [run ${run_idx}] complete for P=${parties}"
}

########################################
# Main
########################################
ensure_dirs
export PRIME INT_BITS

for len in "${LENS[@]}"; do
  echo "=== LEN = ${len} =============================================================="

  echo "[1/5] Generate inputs for LEN=${len}"
  python3 gen_activation_inputs.py --len "${len}" --seed 42 --bits 16

  echo "[2/5] Preprocess (Fake-Offline) for prime=${PRIME}, S=${SECURITY}"
  for p in "${PARTIES[@]}"; do
    echo "    -> parties=${p}"
    ./Fake-Offline.x "${p}" -P "${PRIME}" -S "${SECURITY}"
  done

  echo "[3/5] Per-thread compile + runs"
  for t in "${THREAD_SET[@]}"; do
    echo "  -> THREADS=${t}"
    fe_sec="$(compile_and_time "${len}" "${t}" "${INT_BITS}" "${PROGRAM}")"
    fe_sec="${fe_sec//$'\r'/}"
    fe_sec="${fe_sec//$'\n'/}"
    echo "     front-end (compile) time: ${fe_sec}s"
    echo "${fe_sec}" > "logs/L${len}/T${t}/compile_seconds.txt"

    for p in "${PARTIES[@]}"; do
      echo "  [4/5] Online runs (REPEAT=${REPEAT}) for LEN=${len}, P=${p}, THREADS=${t}"
      for run_idx in $(seq 1 "${REPEAT}"); do
        port=$((PORT_BASE + run_idx - 1))
        run_once_parties "${port}" "${len}" "${run_idx}" "${fe_sec}" "${t}" "${p}"
        sleep 1
      done
    done
  done

  echo "=== Finished LEN=${len} ======================================================="
  echo
done

echo "All LENS done. Logs in ./logs/L<LEN>/P<parties>/T<threads>/."

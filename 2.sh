#!/usr/bin/env bash
# bench_all.sh
# Build VM once, then for each N, THREAD in {1,2,4,8,16,32,64,128}, and PARTY in {2,3,4}:
#   generate inputs (once per N)
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
make -j -DINSECURE Fake-Offline.x
########################################
# Config (override with env vars)
########################################
PROGRAM="${PROGRAM:-linear_test}"              # name passed to compile.py and runtime
SIZES_STR="${SIZES:-2048,4096,8192}"                     # comma-separated list of input sizes
REPEAT="${REPEAT:-1}"                          # repetitions per (N,THREAD)
THREAD_SET_STR="${THREAD_SET:-1,2,4,8,16,32,64}"  # set of thread counts to test
PARTIES_STR="${PARTIES:-2,3,4,5,6}"                    # comma-separated list, e.g. "2,3,4"

# Exact prime p = 4_294_967_291
PRIME="${PRIME:-4294967291}"   # 4_294_967_291
INT_BITS="${INT_BITS:-30}"     # for ./compile.py -F, must satisfy bitlen(p) >= INT_BITS + 2

# MP-SPDZ runtime flags (party count is added later with -N)
HOST="${HOST:-127.0.0.1}"
PORT_BASE="${PORT_BASE:-14000}"                # base TCP port for runs
SECURITY="${SECURITY:-16}"                     # -S security parameter
BASE_FLAGS="-v -F -S ${SECURITY} -h ${HOST}"   # -F = use file-based preprocessing

########################################
# Helpers
########################################
IFS=',' read -r -a SIZES <<< "${SIZES_STR}"
IFS=',' read -r -a THREAD_SET <<< "${THREAD_SET_STR}"
IFS=',' read -r -a PARTIES <<< "${PARTIES_STR}"

ensure_dirs() {
  mkdir -p "logs"
  for n in "${SIZES[@]}"; do
    mkdir -p "logs/${n}"
    for t in "${THREAD_SET[@]}"; do
      # compile logs (independent of party count)
      mkdir -p "logs/${n}/T${t}"
      # runtime logs per party count
      for p in "${PARTIES[@]}"; do
        mkdir -p "logs/${n}/P${p}/T${t}"
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
  local n="$1" threads="$2" bits="$3" prog="$4"
  local outdir="logs/${n}/T${threads}"
  python3 - "$n" "$threads" "$bits" "$prog" "$outdir" <<'PY'
import os, sys, subprocess, time, pathlib

n, threads, bits, prog, outdir = sys.argv[1:6]
out = pathlib.Path(outdir); out.mkdir(parents=True, exist_ok=True)
log_path = out / "compile.log"

env = os.environ.copy()
env['N'] = n
env['THREADS'] = threads
prime = env.get('PRIME')

# Build compile.py command: ./compile.py -DINSECURE -P <prime> -F <bits> <prog>
cmd = ["./compile.py"]
if prime:
    cmd += ["-P", prime]
if bits:
    cmd += ["-F", bits]
cmd.append(prog)

t0 = time.perf_counter()
res = subprocess.run(
    cmd,
    env=env,
    capture_output=True,
    text=True,
)
dt = time.perf_counter() - t0

with open(log_path, "w", encoding="utf-8") as f:
    if res.stdout:
        f.write(res.stdout)
    if res.stderr:
        f.write(res.stderr)

print(f"{dt:.6f}")
sys.exit(res.returncode)
PY
}

run_once_parties() {
  local port="$1"
  local n="$2"
  local run_idx="$3"
  local fe="$4"       # compile(frontend) seconds
  local threads="$5"  # thread count for this run
  local parties="$6"  # number of parties in this run

  local log_dir="logs/${n}/P${parties}/T${threads}"

  echo "    [run ${run_idx}] starting ${parties} parties on port ${port}"
  echo "    BENCH_INPUT_N=${n}  BENCH_FE_SEC=${fe}  BENCH_THREADS=${threads}  PARTIES=${parties}"

  local pids_local=()
  local party_ids=()

  # Launch all parties
  for ((pid_id = 0; pid_id < parties; ++pid_id)); do
    local party_id="${pid_id}"
    local log_path="${log_dir}/run${run_idx}_p${party_id}.log"

    BENCH_INPUT_N="${n}" BENCH_FE_SEC="${fe}" BENCH_THREADS="${threads}" \
    /usr/bin/time -l ./mascot-party.x ${BASE_FLAGS} -N "${parties}" -pn "${port}" "${party_id}" "${PROGRAM}" \
      &> "${log_path}" &

    pids_local+=("$!")
    party_ids+=("${party_id}")
  done

  # For cleanup trap
  pids=("${pids_local[@]}")

  # Wait for all, fail if any one fails
  local num="${#pids_local[@]}"
  for ((i = 0; i < num; ++i)); do
    local pid="${pids_local[$i]}"
    local party_id="${party_ids[$i]}"
    if ! wait "${pid}"; then
      echo "    [run ${run_idx}] Party ${party_id} failed (N=${n}, P=${parties}, T=${threads})"
      # kill all others
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

# Export PRIME and INT_BITS so the Python helper sees them
export PRIME INT_BITS

for n in "${SIZES[@]}"; do
  echo "=== N = ${n} ====================================================="

  echo "[1/5] Generate inputs for N=${n}"
  python3 gen_linear_inputs.py --n "${n}"

  echo "[2/5] Preprocess (Fake-Offline) for prime=${PRIME}, S=${SECURITY}"
  for p in "${PARTIES[@]}"; do
    echo "    -> parties=${p}"
    ./Fake-Offline.x "${p}" -P "${PRIME}" -S "${SECURITY}"
  done

  echo "[3/5] Per-thread compile + runs"
  for t in "${THREAD_SET[@]}"; do
    echo "  -> THREADS=${t}"
    fe_sec="$(compile_and_time "${n}" "${t}" "${INT_BITS}" "${PROGRAM}")"
    fe_sec="${fe_sec//$'\r'/}"
    fe_sec="${fe_sec//$'\n'/}"
    echo "     front-end (compile) time: ${fe_sec}s"
    echo "${fe_sec}" > "logs/${n}/T${t}/compile_seconds.txt"

    for p in "${PARTIES[@]}"; do
      echo "  [4/5] Online runs (REPEAT=${REPEAT}) for N=${n}, P=${p}, THREADS=${t}"
      for run_idx in $(seq 1 "${REPEAT}"); do
        # ports can be reused across (t, p) since runs are sequential
        port=$((PORT_BASE + run_idx - 1))
        run_once_parties "${port}" "${n}" "${run_idx}" "${fe_sec}" "${t}" "${p}"
        sleep 1
      done
    done
  done

  echo "=== Finished N = ${n} ============================================="
  echo
done

echo "All sizes done. Logs in ./logs/<N>/P<parties>/T<threads>/. CSV is written by your Machine.cpp."

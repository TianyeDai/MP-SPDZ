#!/usr/bin/env bash
# run_biometric.sh
# Build VM once, then for each SIZE (=N=D), THREAD in THREAD_SET, and PARTY in
# PARTIES:
#   generate inputs (once per SIZE)
#   preprocess (Fake-Offline) per PARTY
#   compile (per THREAD, per SIZE)
#   run REPEAT times with PARTY parties.
#
# This is the MP-SPDZ counterpart of the user's tests/biometric/shell_scripts/
# biometric_new.sh -- same sweep dimensions (PARTIES, THREADS, SIZES, REPEAT),
# same square-workload assumption (N templates of dimension D, with N == D),
# and the same ``BENCH_INPUT_N=$SIZE`` hookup so the result CSV's input_size
# column reflects N (= D).

set -euo pipefail

########################################
# Build runtime first
########################################
JOBS="${JOBS:-$({
  command -v getconf >/dev/null 2>&1 && getconf _NPROCESSORS_ONLN 2>/dev/null || \
  sysctl -n hw.ncpu 2>/dev/null || echo 4;
})}"
echo "[0/5] Build runtime (mascot-party.x) with ${JOBS} jobs"
make -j "${JOBS}" mascot-party.x

########################################
# Config (override with env vars)
########################################
PROGRAM="${PROGRAM:-biometric_test}"           # Programs/Source/biometric_test.mpc
SIZES_STR="${SIZES:-256}"        # comma-separated list of N=D sizes
REPEAT="${REPEAT:-1}"                          # repetitions per (N,THREAD,PARTY)
THREAD_SET_STR="${THREAD_SET:-1,2}"            # compute-thread counts to test
PARTIES_STR="${PARTIES:-2}"                    # comma-separated, e.g. "2,3,4"

# 128-bit prime
PRIME="${PRIME:-340282366920938463463374607431768211297}"
INT_BITS="${INT_BITS:-126}"

# Input generation knobs (passed to gen_biometric_inputs.py).
INPUT_BITS="${INPUT_BITS:-32}"                 # bit width of the (unsigned) inputs
INPUT_SEED="${INPUT_SEED:-42}"
INPUT_ONES="${INPUT_ONES:-0}"                  # set to 1 to use all-ones inputs

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
    mkdir -p "logs/biometric/N${n}"
    for t in "${THREAD_SET[@]}"; do
      mkdir -p "logs/biometric/N${n}/T${t}"
      for p in "${PARTIES[@]}"; do
        mkdir -p "logs/biometric/N${n}/P${p}/T${t}"
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
  local outdir="logs/biometric/N${n}/T${threads}"
  python3 - "$n" "$threads" "$bits" "$prog" "$outdir" <<'PY'
import os, sys, subprocess, time, pathlib

n, threads, bits, prog, outdir = sys.argv[1:6]
out = pathlib.Path(outdir); out.mkdir(parents=True, exist_ok=True)
log_path = out / "compile.log"

env = os.environ.copy()
env['N'] = n
env['THREADS'] = threads
prime = env.get('PRIME')

# Build compile.py command: ./compile.py -P <prime> -F <bits> <prog>
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

if res.returncode != 0:
    print(res.stdout, end="")
    print(res.stderr, end="", file=sys.stderr)

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

  local log_dir="logs/biometric/N${n}/P${parties}/T${threads}"

  echo "    [run ${run_idx}] starting ${parties} parties on port ${port}"
  echo "    BENCH_INPUT_N=${n}  BENCH_FE_SEC=${fe}  BENCH_THREADS=${threads}  PARTIES=${parties}"

  local pids_local=()
  local party_ids=()

  # Launch all parties
  for ((pid_id = 0; pid_id < parties; ++pid_id)); do
    local party_id="${pid_id}"
    local log_path="${log_dir}/run${run_idx}_p${party_id}.log"

    BENCH_INPUT_N="${n}" BENCH_FE_SEC="${fe}" BENCH_THREADS="${threads}" \
    /usr/bin/time -v ./mascot-party.x ${BASE_FLAGS} -N "${parties}" -pn "${port}" "${party_id}" "${PROGRAM}" \
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

# Export PRIME and INT_BITS so the Python compile-helper sees them
export PRIME INT_BITS

# Build the (re-usable) gen-inputs flag list once
GEN_INPUT_FLAGS=(--seed "${INPUT_SEED}" --bits "${INPUT_BITS}")
if [[ "${INPUT_ONES}" == "1" ]]; then
  GEN_INPUT_FLAGS+=(--ones)
fi

for n in "${SIZES[@]}"; do
  echo "=== N = D = ${n} =================================================="

  echo "[1/5] Generate inputs for N=D=${n}"
  python3 gen_biometric_inputs.py --n "${n}" "${GEN_INPUT_FLAGS[@]}"

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
    echo "${fe_sec}" > "logs/biometric/N${n}/T${t}/compile_seconds.txt"

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

  echo "=== Finished N = D = ${n} ========================================="
  echo
done

echo "All sizes done."
echo "Logs in ./logs/biometric/N<size>/P<parties>/T<threads>/."
echo "CSV rows are appended by Machine.cpp to activation_result.csv with"
echo "  progname=${PROGRAM}, input_size=N (= D)."

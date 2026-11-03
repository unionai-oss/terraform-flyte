#!/usr/bin/env bash
# Static checks for every cloud folder in this repository and its two roots, infra/ and helm/ (CONVENTIONS.md
# section 8). Byte-identical in terraform-flyte and terraform-union-dataplane. Never applies anything and needs no
# cloud credentials; it does download providers, modules and TFLint plugins.
#
# Env: CLOUDS="aws azure" limits the cloud folders checked (default: every top-level folder but examples/).
#      TOOLS_DIR is where pinned Terraform/TFLint are cached (default ~/.cache/terraform-checks).
#      CHECKS_JOBS is how many Terraform/TFLint processes run at once (default: the CPUs this process may use).
#      CHECKS_SLOTS is a slot pool shared with other checks.sh runs (default: a new one of its own).
#      GOGC is passed to Terraform (default 400; see below).
set -euo pipefail

TF_VERSION=1.16.6
TFLINT_VERSION=0.65.0
# The one required_version every root declares (CONVENTIONS.md section 8).
TF_REQUIRED_VERSION='>= 1.11.0, < 2.0.0'
# sha256 of the release zips, from the vendors' published checksum files.
declare -A TF_SHA256=(
  [linux_amd64]=38034b38d03096399a7a1264a14561a8029b2b496fd1f169452656e53968f1b7
  [linux_arm64]=a750b5a11038f165846b2658c40c88cd7070aa67a61bab431a14ba27928ea9ea
  [darwin_amd64]=794a36c3f7ebf6c58f2089c226068a539d1705ba358a5679b51671c8dc7ebc7b
  [darwin_arm64]=85e1bc78ab45bdc5f82a7bac3929e37d072834a584d22583a2498dc67bb624cd
)
declare -A TFLINT_SHA256=(
  [linux_amd64]=d4c545ed2e29d6338604b586f34f544f380f70f243aa72f7b484713835eaec61
  [linux_arm64]=843017c47a98be1de4d88fa038daa293770fe25cd01656c4f08b2e30d1d3b3a0
  [darwin_amd64]=27696ea23ed77c1918945147ebfe6485a74f58560b9557ccecc77379205702c5
  [darwin_arm64]=5a71c63481ba56760864298011fdb7317a9ae80a0bbaeceefa35883c7f62ac71
)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
export TF_IN_AUTOMATION=1 TF_INPUT=0 CHECKPOINT_DISABLE=1
# terraform test is bound by CPU, and much of that is Go garbage collection: collecting at 5x the live heap rather
# than 2x cuts its CPU time by about a quarter, for roughly twice the memory (about 0.7 GB for the largest test
# file). It changes nothing about the results.
export GOGC="${GOGC:-400}"
TOOLS_DIR="${TOOLS_DIR:-$HOME/.cache/terraform-checks}"

# Until the roots start (their own handlers replace these), a TERM, INT or HUP ends a download in progress and removes
# its temporary directory and the install lock this run holds, so an interrupted first run leaves nothing behind.
fetch_pid='' fetch_tmp='' held_lock=''
end_fetch() {
  [[ -z "$fetch_pid" ]] || kill -TERM "$fetch_pid" 2>/dev/null || true
  [[ -z "$fetch_tmp" ]] || rm -rf "$fetch_tmp"
  [[ -z "$held_lock" ]] || rm -rf "$held_lock"
}
trap end_fetch EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

failures=()
fail() {
  echo "FAIL: $*" >&2
  failures+=("$*")
}

# The tools this script uses besides Terraform and TFLint (which it fetches): checked before any work starts.
for tool in awk curl find grep mktemp pgrep sed sort unzip; do
  command -v "$tool" >/dev/null || { echo "checks.sh needs $tool on PATH" >&2; exit 1; }
done

detect_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) echo "unsupported machine $(uname -m)" >&2; return 1 ;;
  esac
  echo "${os}_${arch}"
}

hash_file() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Runs "$@" holding a lock shared by every checks.sh on this machine (both repositories' checks run at once from
# terraform-split/checks.sh). tflint --init writes to the shared ~/.tflint.d, and terraform init writes to
# TF_PLUGIN_CACHE_DIR when that is set; neither is safe to run concurrently. The lock is a directory because mkdir is
# atomic and flock(1) is not on macOS; a lock left behind by a killed run is taken over once its pid is gone.
with_install_lock() {
  local lock="$TOOLS_DIR/install.lock" holder rc
  mkdir -p "$(dirname "$lock")"
  until mkdir "$lock" 2>/dev/null; do
    holder="$(cat "$lock/pid" 2>/dev/null || true)"
    # Read again after the check, as in with_slot: the lock may have changed hands in between.
    if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null &&
      [[ "$(cat "$lock/pid" 2>/dev/null || true)" == "$holder" ]]; then
      rm -rf "$lock"
    else
      sleep 1
    fi
  done
  echo "$BASHPID" >"$lock/pid"
  # Only the main shell's own lock is its to remove on a signal; a subshell's is released by the line below.
  [[ "$BASHPID" != "$$" ]] || held_lock="$lock"
  "$@" && rc=0 || rc=$?
  rm -rf "$lock"
  [[ "$BASHPID" != "$$" ]] || held_lock=''
  return "$rc"
}

# Puts the pinned version of a tool first on PATH, downloading it when PATH has a different one. The download runs
# under the install lock and lands in a temporary directory that is moved into place, so a concurrent checks.sh never
# sees, or executes, a half-written binary.
use_tool() {
  local tool="$1" version="$2" url="$3" want="$4" dir
  if command -v "$tool" >/dev/null && "$tool" --version 2>/dev/null | sed -n 1p | grep -F "v${version}" >/dev/null; then
    return 0
  fi
  dir="$TOOLS_DIR/${tool}-${version}"
  [[ -x "$dir/$tool" ]] || with_install_lock fetch_tool "$tool" "$version" "$url" "$want" "$dir"
  export PATH="$dir:$PATH"
}

# Downloads tool $1 version $2 from $3, checks its sha256 against $4 and installs it as $5/$1. Call under the lock.
fetch_tool() {
  local tool="$1" version="$2" url="$3" want="$4" dir="$5" rc=0
  [[ -x "$dir/$tool" ]] && return 0 # another run installed it while this one waited for the lock
  fetch_tmp="$(mktemp -d "$(dirname "$dir")/.fetch.XXXXXX")"
  echo "== fetching $tool $version"
  # In the background and waited for: a trapped signal interrupts wait at once, but not a foreground curl.
  curl -sSfL --connect-timeout 20 --max-time 600 --retry 3 -o "$fetch_tmp/$tool.zip" "$url" &
  fetch_pid=$!
  wait "$fetch_pid" || rc=$?
  fetch_pid=''
  if ((rc == 0)) &&
    { [[ "$(hash_file "$fetch_tmp/$tool.zip")" == "$want" ]] || { echo "checksum mismatch for $url" >&2; false; }; } &&
    unzip -q "$fetch_tmp/$tool.zip" "$tool" -d "$fetch_tmp/out" && chmod +x "$fetch_tmp/out/$tool"; then
    rm -rf "$dir" && mv "$fetch_tmp/out" "$dir" || rc=$?
  else
    rc=1
  fi
  rm -rf "$fetch_tmp"
  fetch_tmp=''
  return "$rc"
}

# The number of Terraform/TFLint processes that may run at once: CHECKS_JOBS, else the CPUs this process may use
# (a cgroup CPU quota when there is one, which nproc does not report). More than that and provider plugins, which
# must start within Terraform's one-minute plugin timeout, can miss it on a loaded machine.
count_cpus() {
  local quota period n
  if [[ -r /sys/fs/cgroup/cpu.max ]] && read -r quota period </sys/fs/cgroup/cpu.max && [[ "$quota" != max ]]; then
    n=$(((quota + period - 1) / period))
  else
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
  fi
  ((n >= 1)) || n=1
  echo "$n"
}
export CHECKS_JOBS="${CHECKS_JOBS:-$(count_cpus)}"
# Slots are files under CHECKS_SLOTS: terraform-split/checks.sh sets one for every checks.sh it starts, so they
# share the limit; a checks.sh run on its own makes its own, removed on exit (the trap is extended below).
if [[ -z "${CHECKS_SLOTS:-}" ]]; then
  CHECKS_SLOTS="$(mktemp -d)"
  export CHECKS_SLOTS
  own_slots=1
  trap 'end_fetch; rm -rf "$CHECKS_SLOTS"' EXIT
fi

# Runs "$@" in one of the CHECKS_JOBS slots, waiting for a free one. A slot is a file holding its holder's pid, made
# with noclobber, so taking one is a single exclusive create; the wait uses only shell builtins and sleep, because
# dozens of roots and test cases wait at once and a fork per slot per pass cost a third of these checks' CPU. A slot
# left by a killed process is reclaimed once its pid is gone, checked every 20 passes (about 10 s).
# Call it only in a subshell of its own, ( ... ) or $( ... ): it sets that subshell's EXIT trap to release the slot,
# so a holder killed mid-command still frees it. It gives up when the pool is gone, which means the run that owned
# it has ended.
with_slot() {
  local i slot holder again rc pass=0
  while :; do
    if [[ ! -d "$CHECKS_SLOTS" ]]; then
      echo "slot pool $CHECKS_SLOTS is gone: the run that owned it has ended" >&2
      return 1
    fi
    for ((i = 0; i < CHECKS_JOBS; i++)); do
      slot="$CHECKS_SLOTS/slot.$i"
      set -C
      if { echo "$BASHPID" >"$slot"; } 2>/dev/null; then
        set +C
        # Expanded now. The explicit rm below still releases it on the normal path: one subshell may take a second
        # slot after the first, and must not hold the first while it waits.
        # shellcheck disable=SC2064
        trap "rm -f '$slot'" EXIT
        "$@" && rc=0 || rc=$?
        rm -f "$slot"
        return "$rc"
      fi
      set +C
    done
    if ((++pass % 20 == 0)); then
      for ((i = 0; i < CHECKS_JOBS; i++)); do
        slot="$CHECKS_SLOTS/slot.$i"
        holder=
        again=
        read -r holder 2>/dev/null <"$slot" || true
        # The pid is read again after the check: a holder that released the slot and exited between the two reads
        # has made way for a new one, whose slot stays. An empty read is a slot being taken.
        if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
          read -r again 2>/dev/null <"$slot" || true
          [[ "$again" != "$holder" ]] || rm -f "$slot"
        fi
      done
    fi
    sleep 0.5
  done
}

# Terraform gives a provider plugin 60 s to start; on a loaded host that can be missed once. These two run a command
# once more when its output says that, and still fail the second time. Not for init, tflint or the slot pool: only
# validate and test have been seen missing it. They run inside the caller's slot, so the retry starts no process the
# tree listing (kill_tree) misses.
plugin_timeout='timeout while waiting for plugin to start'
retry_on_plugin_timeout() {
  local out
  out="$("$@" 2>&1)" && { [[ -z "$out" ]] || echo "$out"; return 0; }
  if grep -qF "$plugin_timeout" <<<"$out"; then
    echo "retrying once: a provider plugin missed its start timeout" >&2
    "$@"
  else
    echo "$out" >&2
    return 1
  fi
}
# terraform test with its output in log $2, which holds the second run's output when there was one.
terraform_test_retrying() {
  terraform test -no-color -test-directory="$1" >"$2" 2>&1 && return 0
  grep -qF "$plugin_timeout" "$2" || return 1
  echo "retrying once: a provider plugin missed its start timeout" >&2
  terraform test -no-color -test-directory="$1" >"$2" 2>&1
}

plat="$(detect_platform)"
use_tool terraform "$TF_VERSION" \
  "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_${plat}.zip" "${TF_SHA256[$plat]}"
use_tool tflint "$TFLINT_VERSION" \
  "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_${plat}.zip" "${TFLINT_SHA256[$plat]}"
terraform version | sed -n 1p
tflint --version | sed -n 1p

if [[ -n "${CLOUDS:-}" ]]; then
  read -r -a clouds <<<"$CLOUDS"
else
  clouds=()
  for d in */; do
    d="${d%/}"
    [[ "$d" == examples ]] && continue
    clouds+=("$d")
  done
fi

echo "== terraform fmt"
terraform fmt -check -recursive . || fail "terraform fmt: run 'terraform fmt -recursive'"

# Prints the names of the top-level blocks of one kind in a file, in file order.
list_block_names() {
  sed -n -E "s/^$1 \"([^\"]+)\".*/\\1/p" "$2"
}

# Succeeds when variable $1 in file $2 has a top-level default. terraform fmt puts block attributes at two spaces,
# so this does not see the defaults of optional() object attributes, which are deeper.
has_default() {
  awk -v name="$1" '$0 ~ "^variable \"" name "\"" {p = 1; next}
    p && /^}/ {p = 0}
    p && /^  default[[:space:]]*=/ {found = 1}
    END {exit !found}' "$2"
}

# Prints "file: module <name> version <v>" for every registry module whose version is not exact (X.Y.Z).
# Local paths (./, ../) and VCS/URL sources have no version argument; everything else is a registry source.
find_inexact_modules() {
  awk '/^module "/ {name = $2; gsub(/"/, "", name); src = ""; ver = "(none)"; p = 1; next}
    p && /^  source[[:space:]]*=/ {src = $0; sub(/^[^"]*"/, "", src); sub(/".*/, "", src)}
    p && /^  version[[:space:]]*=/ {ver = $0; sub(/^[^"]*"/, "", ver); sub(/".*/, "", ver)}
    p && /^}/ {
      p = 0
      if (src ~ /^\.\.?\// || src ~ /::/ || src ~ /:\/\//) next
      if (ver !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) print FILENAME ": module " name " version " ver
    }' "$@"
}

# Writes test directory $2, inside root $1, for the root's one terraform test: a copy of every tests/*.tftest.hcl but
# examples.tftest.hcl, then examples.tftest.hcl with its run blocks once per example $3..., the i-th example's copies
# renamed ex<i>__<name> and given the example's values as their variables. The blocks outside run blocks (mock
# providers, overrides) are written once. One process plans the unit tests and every example because each terraform
# test process loads the configuration and starts every provider again, which one process per example spent a
# third of these checks' CPU on.
write_test_dir() {
  local dir="$1" tdir="$2" t i=0 example
  shift 2
  for t in "$dir"/tests/*.tftest.hcl; do
    [[ -f "$t" && "$(basename "$t")" != examples.tftest.hcl ]] && cp "$t" "$tdir/"
  done
  (($# > 0)) || return 0
  awk '/^run "/ {skip = 1} !skip {print} skip && /^}/ {skip = 0}' "$dir/tests/examples.tftest.hcl" >"$tdir/examples.tftest.hcl"
  for example in "$@"; do
    i=$((i + 1))
    awk -v i="$i" -v vars="$ROOT/$example" '
      /^run "/ {
        name = $2
        gsub(/"/, "", name)
        print ""
        print "run \"ex" i "__" name "\" {"
        print "  variables {"
        while ((getline line < vars) > 0) print "    " line
        close(vars)
        print "  }"
        inrun = 1
        next
      }
      inrun {print}
      inrun && /^}/ {inrun = 0}' "$dir/tests/examples.tftest.hcl" >>"$tdir/examples.tftest.hcl"
  done
}

# Succeeds when the terraform test log $1 reports test file $2 (as the test directory names it) passed.
has_file_passed() {
  grep -qxF "$2... pass" "$1"
}

# Succeeds when the terraform test log $1 reports $3 runs named ex$2__*, all passed; $3 must be at least one.
has_example_passed() {
  (($3 > 0)) && [[ "$(grep -cE "^  run \"ex$2__[^\"]+\"\\.\\.\\. pass\$" "$1")" == "$3" ]]
}

# Prints the names of the outputs in file $1 that are marked sensitive = true.
list_sensitive_outputs() {
  awk '/^output "/ {name = $2; gsub(/"/, "", name); next}
    name != "" && /^  sensitive[[:space:]]*=[[:space:]]*true/ {print name}
    /^}/ {name = ""}' "$1"
}

# Prints file:line: local.infra.<name> for every use of a name in $1 (space-separated) in files $2... that is neither
# sensitive(local.infra.<name>) nor the value of a set_sensitive entry. A set_sensitive entry is recognised by bracket
# depth, counted outside strings and comments.
find_bare_sensitive_uses() {
  local names="$1"
  shift
  awk -v names="$names" '
    FNR == 1 {depth = 0; in_set = 0}
    {
      code = $0
      gsub(/"([^"\\]|\\.)*"/, "\"\"", code)
      sub(/(#|\/\/).*/, "", code)
      if (code ~ /(^|[^A-Za-z0-9_])set_sensitive[[:space:]]*=/) {in_set = 1; set_depth = depth}
      opened = code; closed = code
      depth += gsub(/[[{(]/, "", opened) - gsub(/[]})]/, "", closed)
      if ($0 !~ /^[[:space:]]*(#|\/\/)/) {
        n = split(names, list, " ")
        for (i = 1; i <= n; i++) {
          line = $0
          gsub("(^|[^A-Za-z0-9_])sensitive\\(local\\.infra\\." list[i] "\\)", "", line)
          if (in_set) gsub("value[[:space:]]*=[[:space:]]*local\\.infra\\." list[i] "([^A-Za-z0-9_]|$)", "", line)
          if (line ~ "local\\.infra\\." list[i] "([^A-Za-z0-9_]|$)") print FILENAME ":" FNR ": local.infra." list[i]
        }
      }
      if (in_set && depth <= set_depth) in_set = 0
    }' "$@"
}

# The helm root's contract with the infra root (CONVENTIONS.md section 8). The helm root reads infra's state in one
# place, reads only outputs infra has, and marks infra's sensitive outputs sensitive again, because remote state
# drops the mark. Its test fixtures have exactly infra's output names, so the helm tests plan against the outputs
# infra really has. $2 is a folder with no configuration in it, where terraform console reads the fixtures.
check_contract() {
  local cloud="$1" work="$2" helm="$1/helm" outputs="$1/infra/outputs.tf" infra_outputs=() fixtures=() name hits
  local fixture keys missing extra sensitive t
  [[ -f "$outputs" ]] || return 0 # reported for the infra root
  mapfile -t infra_outputs < <(list_block_names output "$outputs" | LC_ALL=C sort)

  if [[ "$(grep -hE '^data "terraform_remote_state"' "$helm"/*.tf)" != 'data "terraform_remote_state" "infra" {' ]] ||
    ! grep -q '^data "terraform_remote_state" "infra"' "$helm/main.tf" 2>/dev/null ||
    [[ "$(grep -lE '^[^#]*data\.terraform_remote_state\.' "$helm"/*.tf)" != "$helm/main.tf" ]] ||
    [[ "$(grep -cE '^[^#]*data\.terraform_remote_state\.' "$helm/main.tf")" != 1 ]]; then
    fail "$helm: data.terraform_remote_state.infra must be declared and read exactly once, in main.tf (everything else reads local.infra)"
  fi

  while IFS= read -r name; do
    [[ -n "$name" ]] && fail "$helm: reads local.infra.$name, but $outputs has no output \"$name\""
  done < <({ grep -ohE 'local\.infra\.[a-z0-9_]+' "$helm"/*.tf || true; } | sed 's/^local\.infra\.//' | LC_ALL=C sort -u |
    LC_ALL=C comm -23 - <(printf '%s\n' ${infra_outputs[@]+"${infra_outputs[@]}"}))

  # A helm variable named like an infra output is a value entered by hand that the state already has.
  while IFS= read -r name; do
    [[ -n "$name" ]] && fail "$helm: variable \"$name\" duplicates an infra output; read local.infra.$name instead"
  done < <(list_block_names variable "$helm/variables.tf" 2>/dev/null | LC_ALL=C sort -u |
    LC_ALL=C comm -12 - <(printf '%s\n' ${infra_outputs[@]+"${infra_outputs[@]}"}))

  sensitive="$(list_sensitive_outputs "$outputs" | tr '\n' ' ')"
  if [[ -n "$sensitive" ]] && hits="$(find_bare_sensitive_uses "$sensitive" "$helm"/*.tf)" && [[ -n "$hits" ]]; then
    echo "$hits" >&2
    fail "$helm: a sensitive infra output is used without sensitive() or set_sensitive (remote state drops the mark)"
  fi

  # Terraform stores no null root output, so a mock of infra's state that keeps the fixture's nulls plans a helm
  # root against outputs the real state never has (CONVENTIONS.md section 10).
  for t in "$helm"/tests/*.tftest.hcl; do
    [[ -f "$t" ]] || continue
    hits="$(awk -v f="$t" '
      !p && /^[[:space:]]*override_data[[:space:]]*\{/ {p = 1; depth = 0; infra = 0; drops = 0; start = FNR}
      p {
        if ($0 ~ /target[[:space:]]*=[[:space:]]*data\.terraform_remote_state\.infra/) infra = 1
        if ($0 ~ /if[[:space:]]+v[[:space:]]*!=[[:space:]]*null/) drops = 1
        line = $0; depth += gsub(/\{/, "", line); depth -= gsub(/\}/, "", line)
        if (depth <= 0) { if (infra && !drops) print f ":" start; p = 0 }
      }' "$t")"
    [[ -z "$hits" ]] || fail "$hits: override_data on data.terraform_remote_state.infra keeps null outputs (drop them: if v != null)"
  done
  for fixture in "$helm"/tests/fixtures/*.json; do
    [[ -f "$fixture" ]] && fixtures+=("$fixture")
  done
  if ((${#fixtures[@]} == 0)); then
    fail "$helm: no tests/fixtures/*.json (the infra outputs the helm tests plan against)"
    return 0
  fi
  for fixture in "${fixtures[@]}"; do
    # terraform console in a folder with no configuration, so the helm root's required variables need no values.
    if ! keys="$(with_slot terraform -chdir="$work" console <<<"jsonencode(sort(keys(jsondecode(file(\"$ROOT/$fixture\")))))" 2>&1)"; then
      echo "$keys" >&2
      fail "$fixture: not a JSON object"
      continue
    fi
    # The console prints the JSON list as a quoted string, ["a","b"] as "[\"a\",\"b\"]"; output names need no escaping.
    keys="${keys//[\[\]\"\\]/}"
    keys="$(tr , '\n' <<<"$keys" | sed '/^$/d')"
    missing="$(LC_ALL=C comm -23 <(printf '%s\n' ${infra_outputs[@]+"${infra_outputs[@]}"}) <(echo "$keys") | sed '/^$/d' | tr '\n' ' ')"
    extra="$(LC_ALL=C comm -13 <(printf '%s\n' ${infra_outputs[@]+"${infra_outputs[@]}"}) <(echo "$keys") | sed '/^$/d' | tr '\n' ' ')"
    [[ -z "$missing" ]] || fail "$fixture: missing infra outputs: ${missing% }"
    [[ -z "$extra" ]] || fail "$fixture: keys that are not infra outputs: ${extra% }"
  done
}

# The cloud-level checks of folder $1: its roots and its README (CONVENTIONS.md sections 1 and 9). Runs in this
# shell, so its failures go straight into the failures array, and sets cloud_roots to the root folders to check.
check_cloud() {
  local cloud="$1" d
  cloud_roots=()
  echo "== $cloud"
  if [[ -f "$cloud/terraform.tf" ]]; then
    fail "$cloud: Terraform at the cloud level; roots go in $cloud/infra and $cloud/helm"
    return 0
  fi
  if ! compgen -G "$cloud/*/terraform.tf" >/dev/null; then
    if [[ -f "$cloud/README.md" ]] && grep -qi 'pending' "$cloud/README.md"; then
      echo "PENDING: $cloud has no Terraform yet (see $cloud/README.md); nothing to check"
      return 0
    fi
    fail "$cloud: no terraform.tf in $cloud/infra or $cloud/helm"
    return 0
  fi
  for d in "$cloud"/*/; do
    d="$(basename "$d")"
    [[ "$d" == infra || "$d" == helm ]] || fail "$cloud: unexpected folder $cloud/$d/; a cloud folder holds only infra/ and helm/"
  done
  # helm is optional here; lockstep.py decides whether a cloud must have one.
  [[ -f "$cloud/infra/terraform.tf" ]] || fail "$cloud: no infra root ($cloud/infra/terraform.tf)"
  if [[ ! -f "$cloud/README.md" ]]; then
    fail "$cloud: README.md missing"
  else
    grep -qi 'not yet applied live\|applied live on' "$cloud/README.md" ||
      fail "$cloud: README.md does not say whether it has been applied live"
    grep -q '^## Differences from the sibling repo' "$cloud/README.md" ||
      fail "$cloud: README.md has no 'Differences from the sibling repo' section"
  fi
  # An example left at the old place would silently go unplanned.
  if compgen -G "examples/$cloud/*.tfvars" >/dev/null; then
    fail "$cloud: examples/$cloud/*.tfvars is not planned; examples go in examples/$cloud/infra/ and examples/$cloud/helm/"
  fi
  for d in infra helm; do
    [[ -d "$cloud/$d" ]] && cloud_roots+=("$d")
  done
  return 0
}

# Every check of one root, $1/$2. Runs in its own subshell, concurrently with the other roots, so its failures are
# only in that subshell's failures array; run_root hands them back to the parent.
check_root() {
  local cloud="$1" root="$2" work="$3" dir="$1/$2" f kind file other required var inexact t i name example tdir rel runs ok shown \
    tests=() examples=()
  echo "== $dir"
  if [[ ! -f "$dir/terraform.tf" ]]; then
    fail "$dir: no terraform.tf"
    return 0
  fi
  for f in main.tf variables.tf outputs.tf .tflint.hcl .terraform.lock.hcl; do
    [[ -f "$dir/$f" ]] || fail "$dir: $f missing"
  done
  for kind in variable output; do
    file="$dir/${kind}s.tf"
    [[ -f "$file" ]] || continue
    if ! diff <(list_block_names "$kind" "$file") <(list_block_names "$kind" "$file" | LC_ALL=C sort) >/dev/null; then
      fail "$dir: ${kind}s.tf is not in alphabetical order"
    fi
    for other in "$dir"/*.tf; do
      [[ "$other" == "$file" ]] && continue
      if grep -qE "^$kind \"" "$other"; then fail "$dir: $kind block outside ${kind}s.tf in $other"; fi
    done
  done
  required="$(sed -n -E 's/^[[:space:]]*required_version[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$dir/terraform.tf")"
  [[ "$required" == "$TF_REQUIRED_VERSION" ]] ||
    fail "$dir: required_version is '$required', not '$TF_REQUIRED_VERSION'"
  # These repositories hard-code no region or project (AGENTS.md); a default would be one.
  for var in region project_id; do
    if [[ -f "$dir/variables.tf" ]] && has_default "$var" "$dir/variables.tf"; then fail "$dir: variable $var has a default"; fi
  done
  if inexact="$(find_inexact_modules "$dir"/*.tf)" && [[ -n "$inexact" ]]; then
    echo "$inexact" >&2
    fail "$dir: module version is not an exact X.Y.Z"
  fi
  # The boundary between the roots (CONVENTIONS.md section 10): infra creates nothing through the Kubernetes API and
  # configures no Kubernetes or Helm provider (a module may still require one to be declared); helm uses no cloud
  # provider, only the Kubernetes and Helm providers and the utility ones.
  if [[ "$root" == infra ]]; then
    if hits="$(grep -nHE '^(resource|data) "(helm|kubernetes|kubectl)_|^provider "(helm|kubernetes|kubectl)"' "$dir"/*.tf)"; then
      echo "$hits" >&2
      fail "$dir: Kubernetes or Helm resources or provider configuration belong in the helm root"
    fi
  else
    while IFS= read -r name; do
      [[ -n "$name" ]] && fail "$dir: provider $name in the helm root (it may use only hashicorp/helm, hashicorp/kubernetes, hashicorp/random and hashicorp/time)"
    done < <(sed -n -E 's/^[[:space:]]*source[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$dir/terraform.tf" | tr '[:upper:]' '[:lower:]' |
      grep -vxE 'hashicorp/(helm|kubernetes|random|time)' || true)
  fi

  # init and tflint print nothing when they pass, so each step is named here.
  echo "$dir: terraform init -backend=false"
  if [[ -n "${TF_PLUGIN_CACHE_DIR:-}" ]]; then
    (cd "$dir" && with_slot with_install_lock terraform init -backend=false -lockfile=readonly -no-color >/dev/null)
  else
    (cd "$dir" && with_slot terraform init -backend=false -lockfile=readonly -no-color >/dev/null)
  fi || { fail "$dir: terraform init"; return 0; }
  # The unit tests and every example in one terraform test (write_test_dir), in the background while validate and
  # tflint run: it only reads the initialised folder. test { parallel = true } in the files does not help: every run
  # block plans the root module, so they share one state and run in turn. The test directory has to be inside the
  # root (terraform test refuses any other), so it is a hidden one that .gitignore and lockstep.py leave out, removed
  # once the test is done.
  for t in "$dir"/tests/*.tftest.hcl; do
    [[ -f "$t" && "$(basename "$t")" != examples.tftest.hcl ]] && tests+=("$(basename "$t")")
  done
  for example in examples/"$cloud"/"$root"/*.tfvars; do
    [[ -f "$example" ]] || continue
    if [[ ! -f "$dir/tests/examples.tftest.hcl" ]]; then
      fail "$dir: examples exist but tests/examples.tftest.hcl does not"
      break
    fi
    examples+=("$example")
  done
  tdir="$(mktemp -d "$dir/.checks-tests.XXXXXX")"
  # Removed however this root's subshell (run_root) ends, also when a failed command stops it early. The path is
  # expanded now: the local is gone by the time the trap runs.
  # shellcheck disable=SC2064
  trap "rm -rf '$tdir'" EXIT
  write_test_dir "$dir" "$tdir" ${examples[@]+"${examples[@]}"}
  rel="$(basename "$tdir")"
  if ((${#tests[@]} + ${#examples[@]} > 0)); then
    (cd "$dir" && with_slot terraform_test_retrying "$rel" "$work/tests.log" &&
      echo 0 >"$work/tests.rc" || echo $? >"$work/tests.rc") &
  fi
  [[ "$root" != helm ]] || check_contract "$cloud" "$work"
  (cd "$dir" && with_slot retry_on_plugin_timeout terraform validate -no-color) || fail "$dir: terraform validate"
  echo "$dir: tflint"
  (cd "$dir" && with_slot with_install_lock tflint --init >/dev/null && with_slot tflint --format compact) || fail "$dir: tflint"
  wait

  if ((${#tests[@]} + ${#examples[@]} > 0)); then
    # Printed with the test directory named as the files' home, tests/.
    sed -n -E "s#^$rel/#tests/#; /^(Success|Failure)!|\\.\\.\\. (fail|pass)\$/p" "$work/tests.log"
    shown=
    # Prints the whole log once, for the first failure; shown also records that a test failure was reported.
    show_log() { [[ -n "$shown" ]] || sed "s#$rel/#tests/#g" "$work/tests.log" >&2; shown=1; }
    if ((${#tests[@]} == 0)); then
      show_log
      fail "$dir: no tests/*.tftest.hcl"
    else
      ok=1
      for t in "${tests[@]}"; do has_file_passed "$work/tests.log" "$rel/$t" || ok=
      done
      [[ -n "$ok" ]] || { show_log; fail "$dir: terraform test"; }
    fi
    runs="$(grep -c '^run "' "$dir/tests/examples.tftest.hcl" 2>/dev/null || true)"
    for i in "${!examples[@]}"; do
      if has_example_passed "$work/tests.log" "$((i + 1))" "${runs:-0}"; then
        echo "example ${examples[$i]}: plans"
      else
        show_log
        fail "$dir: example ${examples[$i]} does not plan"
      fi
    done
    # Every file and example passed, yet terraform test failed: say so rather than pass on it.
    if [[ "$(cat "$work/tests.rc")" != 0 && -z "$shown" ]]; then
      show_log
      fail "$dir: terraform test"
    fi
  else
    fail "$dir: no tests/*.tftest.hcl"
  fi
}

# Runs check_root for root $1/$2 with everything it prints in $3/$1-$2.log and its failures, one per line, in
# $3/$1-$2.failures. That file is written only when check_root returns, so a missing one means it stopped early.
run_root() {
  local work="$3/$1-$2"
  mkdir -p "$work"
  failures=()
  check_root "$1" "$2" "$work" >"$3/$1-$2.log" 2>&1
  printf '%s\n' ${failures[@]+"${failures[@]}"} >"$3/$1-$2.failures"
}

logs="$(mktemp -d)"
trap 'rm -rf "$logs"; [[ -z "${own_slots:-}" ]] || rm -rf "$CHECKS_SLOTS"' EXIT
# Every root of every cloud is its own background job, so the roots of all clouds share the CHECKS_JOBS slots.
roots=()
pids=()

# Ends process $1 and everything under it (the subshell per root, the subshells per step, Terraform, TFLint and the
# provider plugins) and returns when none is left. Terraform ends gracefully over several seconds after TERM, while
# the subshells above it die at once and are not waited for by anyone (the orphans belong to PID 1), so without the
# poll this script would exit, and remove the slot pool and logs, with Terraform still running. The tree is listed
# before any signal, so nothing in it can fork a process the list misses; whatever outlives 20 s gets KILL.
list_tree() {
  local child
  echo "$1"
  for child in $(pgrep -P "$1" || true); do list_tree "$child"; done
}
kill_tree() {
  local tree pid alive
  mapfile -t tree < <(list_tree "$1")
  for pid in "${tree[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
  for _ in {1..100}; do
    alive=0
    # Not $1 itself: it is this shell's child, a zombie until the caller's wait, and kill -0 answers for a zombie.
    for pid in "${tree[@]:1}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
    ((alive)) || return 0
    sleep 0.2
  done
  for pid in "${tree[@]}"; do kill -KILL "$pid" 2>/dev/null || true; done
  sleep 1
}
# On TERM, INT or HUP the roots are ended with TERM whatever arrived (background jobs of a non-interactive shell ignore
# INT), and waited for: each root's EXIT trap removes its test directory and each step's frees its slot. Only then does
# this shell exit, and its EXIT trap remove the logs and its own slot pool.
on_signal() {
  local pid
  trap '' TERM INT HUP
  for pid in ${pids[@]+"${pids[@]}"}; do kill_tree "$pid"; done
  wait
  # A root's EXIT trap can fire before Terraform has stopped writing, so remove the test directories here too.
  find . -name '.checks-tests.*' -prune -exec rm -rf {} +
  exit "$1"
}
trap 'on_signal 143' TERM
trap 'on_signal 130' INT
trap 'on_signal 129' HUP
for cloud in "${clouds[@]}"; do
  check_cloud "$cloud" >"$logs/$cloud.log" 2>&1
  for root in ${cloud_roots[@]+"${cloud_roots[@]}"}; do
    run_root "$cloud" "$root" "$logs" &
    roots+=("$cloud/$root")
    pids+=("$!")
  done
done
# Printed in cloud and apply order, each as soon as it and the roots before it are done.
for cloud in "${clouds[@]}"; do
  cat "$logs/$cloud.log"
  for ((i = 0; i < ${#roots[@]}; i++)); do
    [[ "${roots[$i]%/*}" == "$cloud" ]] || continue
    name="${roots[$i]/\//-}"
    wait "${pids[$i]}" && rc=0 || rc=$?
    cat "$logs/$name.log"
    if [[ ! -f "$logs/$name.failures" ]]; then
      fail "${roots[$i]}: checks stopped early (exit $rc); see the output above"
      continue
    fi
    while IFS= read -r line; do
      [[ -n "$line" ]] && failures+=("$line")
    done <"$logs/$name.failures"
  done
done


echo "== hygiene"
# The files git tracks or would add (untracked and not ignored), but not this script, which spells out the patterns,
# nor the provider and module caches and test directories in use. That is Terraform, templates, files/, READMEs,
# AGENTS.md, CONVENTIONS.md and workflows, and never .git/ (hook samples, COMMIT_EDITMSG) or what .gitignore hides
# (state files, plans, tfvars), so a checkout and a clean copy of it give the same result. Lock files are scanned:
# they are generated, but a hand edit there is a place to hide a value.
# Without a usable git work tree (an export, a tarball, git refusing a directory owned by someone else) it is every
# file but .git/ and the names this folder's .gitignore lists for state, plans and credentials.
list_sources() {
  local f
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # -z because git quotes unusual names otherwise; the [[ -f ]] test below drops a tracked file that has been
    # deleted. The current directory may be a subfolder of a larger repository (the monorepo these folders are
    # developed in), so the paths are relative to it, as find prints them.
    git ls-files -z -co --exclude-standard -- . | while IFS= read -r -d '' f; do
      f="./$f"
      if [[ -f "$f" && "$f" != ./checks.sh && "$f" != */.terraform/* && "$f" != */.checks-tests.*/* ]]; then
        printf '%s\0' "$f"
      fi
    done
  else
    find . -name .git -prune -o -name .terraform -prune -o -name '.checks-tests.*' -prune -o \
      -type f ! -path ./checks.sh ! -name '*.tfstate' ! -name '*.tfstate.*' ! -name '*.tfplan' ! -name crash.log \
      ! -name terraform.tfvars ! -name '*.auto.tfvars' ! -name .terraform.tfstate.lock.info -print0
  fi
}
# Through a file, not a process substitution, so git's exit status is checked.
if ! list_sources | LC_ALL=C sort -z >"$logs/sources"; then
  fail "hygiene: could not list the files to scan"
fi
mapfile -d '' -t sources <"$logs/sources"
mapfile -t tf_sources < <(printf '%s\n' "${sources[@]}" | grep -E '\.(tf|tfvars|tftest\.hcl)$' || true)

# Placeholders the repositories use on purpose, so examples and tests read like real input: anything containing
# "example" (example-project, ocid1.tenancy.oc1..example, project-e00example, flyte.example.com), the tailnet
# tail1234 on its own (a *.ts.net host is never a placeholder: tailnets are given without .ts.net), and the test
# fixtures' test-project, project-e00test and tenant-e00test. A hit containing one of these is not reported; a new placeholder
# should contain "example" rather than be added here.
export HYGIENE_PLACEHOLDER='example|(^|[^a-z0-9.-])tail1234([^a-z0-9.-]|$)|(^|[^a-z0-9-])(test-project|project-e00test|tenant-e00test)([^a-z0-9-]|$)'

# Prints the file:line of each file:line:match on stdin: what matched is never printed (it may be a secret).
strip_matches() { sed -E 's/^([^:]+:[0-9]+):.*/\1/'; }

# Prints file:line:match for each match of $1 (grep -E; $2 is an optional extra grep flag) that is not a placeholder.
find_unplaceholdered_matches() {
  { grep -nHoE ${2:+"$2"} -- "$1" "${sources[@]}" || true; } |
    awk '{m = $0; sub(/^[^:]*:[0-9]+:/, "", m); if (m !~ ENVIRON["HYGIENE_PLACEHOLDER"]) print}'
}

if ((${#sources[@]} == 0)); then
  fail "hygiene: no files to scan"
else
  scan() {
    local what="$1" pattern="$2" flags="${3:-}" hits
    hits="$(find_unplaceholdered_matches "$pattern" "$flags" | strip_matches)"
    if [[ -n "$hits" ]]; then
      echo "$hits" >&2
      fail "$what"
    fi
  }
  scan "hard-coded 12-digit account or project number" '(^|[^0-9A-Za-z_.])[0-9]{12}([^0-9A-Za-z_]|$)'
  scan "hard-coded GUID (subscription, tenant or client ID)" '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
  # A *.ts.net host, a tailnet assigned to anything called tailnet, or a bare tail<hex> MagicDNS name.
  scan "hard-coded tailnet name" '[A-Za-z0-9-]+\.ts\.net|tailnet"?[[:space:]]*[:=][[:space:]]*"[^"$]+"|(^|[^A-Za-z0-9_-])tail[0-9a-f]{4,}([^A-Za-z0-9_-]|$)' -i
  scan "hard-coded GCP project ID" '(^|[^A-Za-z0-9_])project([_-]?id)?"?[[:space:]]*[:=][[:space:]]*"[^"$]+"' -i
  scan "hard-coded OCI OCID" 'ocid1\.[a-z0-9]+\.oc[0-9]+\.[a-z0-9-]*\.[a-z0-9]+' -i
  scan "hard-coded Nebius project or tenant ID" '(^|[^A-Za-z0-9])(project|tenant)-e0[0-9a-z]+'
  scan "embedded key or secret" '(AKIA|ASIA)[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|tskey-[a-z]+-|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'
  # A string assigned to a key ending in secret, password, token, api key, access key or private key, in any case
  # (client_secret, clientSecret, aws_secret_access_key, api_key): a double- or single-quoted value after = or :
  # (HCL, YAML, JSON, shell), or a value without quotes as YAML (key: value) or shell (KEY=value, export KEY=value).
  # The unquoted forms are anchored at the start of the line (after an optional "- " or "export "), so prose such as
  # "the union-secret-auth Secret: Union-side steps" is not read as one.
  secrets='[A-Za-z0-9_-]*(secret|password|passwd|token|api_?key|access_?key|private_?key)'
  scan "embedded key or secret" "$secrets\"?[[:space:]]*[:=][[:space:]]*(\"[^\"\$]{6,}\"|'[^'\$]{6,}')" -i
  scan "embedded key or secret" "^[[:space:]]*(- )?${secrets}[[:space:]]*:[[:space:]]*[^\"'\$<{[:space:]][^[:space:]]{5,}" -i
  scan "embedded key or secret" "^[[:space:]]*(export[[:space:]]+)?${secrets}=[^\"'\$<{[:space:]][^[:space:]]{5,}" -i

  # Domains under a country-code TLD or one of the generic TLDs listed in HYGIENE_TLD below; a domain under another
  # TLD, or under .tf/.py/.sh/.md/.pb/.id, is not caught. The token is a dotted name whose last label is such a TLD.
  # Not domains: tokens with an underscore (hostnames have none; global.ORG_NAME), HCL references (var.x,
  # module.x.y, ...), and tokens ending in a file extension used here (.tf, .py, .sh, .md, .pb) or in .id (an HCL
  # attribute). There is no list of all TLDs in a portable shell, so a domain under any other one is missed.
  # Allowed are exactly the vendor hosts these folders use, never a whole vendor suffix (so
  # acme-prod.us-east-2.unionai.cloud or acme-internal.github.io is reported), the RFC 2606 example domains and
  # in-cluster Service DNS. A label that is a region (or ${var.region}, which leaves a leading - or .) is the only
  # wildcard.
  export HYGIENE_TLD='^([a-z][a-z]|com|net|org|io|ai|dev|cloud|app|info|biz|xyz|tech|site|online|internal|local|localhost|lan|corp|home|intranet|goog|edu|gov|mil|int|pro|asia|systems|services|solutions|digital|company|global|world|website|store|shop|blog|team|zone|engineering|software|tools|works|club|live|studio|agency)$'
  export HYGIENE_NOT_TLD='^(tf|py|sh|md|pb|id)$'
  export HYGIENE_HCL='^(var|local|module|data|each|count|path|self|terraform)$'
  allowed_hosts=(
    '([a-z0-9-]+\.)*example\.(com|net|org)'
    '[a-z0-9-]+\.[a-z0-9-]+\.svc\.cluster\.local'
    'amazonaws\.com' '(eks|sts)\.amazonaws\.com' '(s3|cognito-idp|oidc\.eks)\.[a-z][a-z](-gov)?-[a-z]+-[0-9]\.amazonaws\.com'
    'login\.microsoftonline\.com' '[a-z0-9-]+\.private\.postgres\.database\.azure\.com'
    '(artifactregistry|cloudresourcemanager|compute|container|iam|iamcredentials|storage)\.googleapis\.com'
    '-docker\.pkg\.dev' '(example|test)-project\.(iam\.gserviceaccount\.com|svc\.id\.goog)'
    '(region|[a-z][a-z]-[a-z]+-[0-9]+)\.ocir\.io'
    '(cr|storage)\.[a-z]+-[a-z]+[0-9]+\.nebius\.cloud'
    'cwobject\.com' '(docs|compute)\.coreweave\.com'
    '(www\.)?union\.ai' 'acme\.union\.ai' '\*\.union\.ai' '\*\.unionai\.cloud'
    'github\.com' 'ghcr\.io' '(azure|flyteorg|nvidia|oauth2-proxy|traefik|unionai)\.github\.io'
    'kubernetes\.io' '(service\.beta|traefik\.ingress)\.kubernetes\.io' 'iam\.gke\.io' 'cloud\.google\.com' 'client\.authentication\.k8s\.io'
    'cert-manager\.io' 'charts\.jetstack\.io' 'acme-v02\.api\.letsencrypt\.org' 'traefik\.io' 'nvidia\.com'
    'pkgs\.tailscale\.com' 'registry\.terraform\.io'
  )
  HYGIENE_ALLOWED="^($(
    IFS='|'
    echo "${allowed_hosts[*]}"
  ))\$"
  export HYGIENE_ALLOWED
  hits="$(find_unplaceholdered_matches '(^|[^A-Za-z0-9_.-])[A-Za-z0-9_*-]+(\.[A-Za-z0-9_*-]+)+' |
    awk '{
      match($0, /^[^:]*:[0-9]+:/); where = substr($0, 1, RLENGTH - 1); token = substr($0, RLENGTH + 1)
      sub(/^[^A-Za-z0-9_*-]/, "", token)
      host = tolower(token); n = split(host, label, ".")
      if (host ~ /_/ || label[1] ~ ENVIRON["HYGIENE_HCL"]) next
      if (label[n] ~ ENVIRON["HYGIENE_TLD"] && label[n] !~ ENVIRON["HYGIENE_NOT_TLD"] && host !~ ENVIRON["HYGIENE_ALLOWED"])
        print where
    }')"
  if [[ -n "$hits" ]]; then
    echo "$hits" >&2
    fail "domain literal that is not a vendor endpoint or example domain"
  fi

  for f in "${tf_sources[@]}"; do
    if hits="$(grep -nHE '^[[:space:]]*provisioner[[:space:]]+"|data[[:space:]]+"external"' "$f" | strip_matches)" &&
      [[ -n "$hits" ]]; then
      echo "$hits" >&2
      fail "provisioner or external data source in $f"
    fi
    # A version argument inside a provider block (pins belong in required_providers).
    if awk '/^provider "/{p=1} p&&/^[[:space:]]+version[[:space:]]*=/{bad=1} p&&/^}/{p=0} END{exit !bad}' "$f"; then
      fail "version argument inside a provider block in $f"
    fi
  done
fi

if ((${#failures[@]} > 0)); then
  echo "== ${#failures[@]} check(s) failed:" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi
echo "== all checks passed"

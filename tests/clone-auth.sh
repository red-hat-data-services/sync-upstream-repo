#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d "$repo_root/.clone-auth-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
real_git=$(command -v git)
test_token='test-placeholder-credential'

mkdir -p "$scratch/bin"
cat > "$scratch/bin/git" <<'GIT_STUB'
#!/usr/bin/env bash
set -euo pipefail

config_args=()
while [[ "${1:-}" == -c ]]; do
  config_args+=("$1" "$2")
  shift 2
done

case "$1" in
  clone)
    printf '%s\n' "$2" > "$TEST_CLONE_URL"
    if ((${#config_args[@]})); then
      printf '%s\n' "${config_args[@]}" > "$TEST_CLONE_CONFIG"
    else
      : > "$TEST_CLONE_CONFIG"
    fi
    if [[ "$TEST_AUTH_REQUIRED" == true ]]; then
      printf 'protocol=https\nhost=github.com\n\n' | \
        GIT_TERMINAL_PROMPT=0 "$REAL_GIT" "${config_args[@]}" credential fill > "$TEST_CREDENTIAL_OUTPUT"
    fi
    "$REAL_GIT" init -q work
    "$REAL_GIT" -C work remote add origin "$2"
    ;;
  remote)
    if [[ "${2:-}" == -v ]]; then
      "$REAL_GIT" remote get-url origin > "$TEST_REMOTE_URL"
      cp .git/config "$TEST_REMOTE_CONFIG"
    fi
    "$REAL_GIT" "$@"
    ;;
  push)
    printf '%s\n' "$*" >> "$TEST_PUSH_CALLS"
    "$REAL_GIT" remote get-url origin >> "$TEST_PUSH_URLS"
    cp .git/config "$TEST_PUSH_LOCAL_CONFIG"
    if ((${#config_args[@]})); then
      printf '%s\n' "${config_args[@]}" >> "$TEST_PUSH_CONFIG"
    fi
    if [[ "$TEST_GITHUB_PUSH" == true ]]; then
      printf 'protocol=https\nhost=github.com\n\n' | \
        GIT_TERMINAL_PROMPT=0 "$REAL_GIT" "${config_args[@]}" credential fill >> "$TEST_PUSH_CREDENTIALS"
    fi
    ;;
  merge)
    echo 'Merge made by the ort strategy.'
    ;;
esac
GIT_STUB
chmod +x "$scratch/bin/git"

run_case() {
  local script=$1 scenario=$2 downstream=$3 requires_auth=$4 expected_url=$5 push_tags=${6:-}
  local test_dir="$scratch/${script}-${scenario}"
  mkdir -p "$test_dir"

  (
    cd "$test_dir"
    PATH="$scratch/bin:$PATH" REAL_GIT="$real_git" \
      TEST_AUTH_REQUIRED="$requires_auth" TEST_CLONE_URL="$test_dir/clone-url" \
      TEST_CLONE_CONFIG="$test_dir/clone-config" TEST_CREDENTIAL_OUTPUT="$test_dir/credentials" \
      TEST_REMOTE_URL="$test_dir/remote-url" TEST_REMOTE_CONFIG="$test_dir/remote-config" \
      TEST_GITHUB_PUSH="$([[ "$scenario" == non-github ]] && echo false || echo true)" \
      TEST_PUSH_CALLS="$test_dir/push-calls" TEST_PUSH_CONFIG="$test_dir/push-config" \
      TEST_PUSH_URLS="$test_dir/push-urls" TEST_PUSH_LOCAL_CONFIG="$test_dir/push-local-config" \
      TEST_PUSH_CREDENTIALS="$test_dir/push-credentials" \
      GITHUB_REPOSITORY='example/current' GITHUB_ACTOR='test-user' \
      bash "$repo_root/$script" 'https://github.com/example/upstream.git' main main \
        "$test_token" '' '' '' false "$downstream" '' "$push_tags" > "$test_dir/output" 2>&1
  )

  [[ "$(cat "$test_dir/clone-url")" == "$expected_url" ]]
  [[ "$(cat "$test_dir/remote-url")" == "$expected_url" ]]
  [[ "$("$real_git" config -f "$test_dir/remote-config" --get remote.origin.url)" == "$expected_url" ]]
  if grep -Fq "$test_token" "$test_dir/remote-config"; then
    echo "Token persisted in origin configuration: $script ($scenario)" >&2
    exit 1
  fi
  if [[ "$requires_auth" == true ]]; then
    grep -Fxq 'username=x-access-token' "$test_dir/credentials"
    grep -Fxq "password=$test_token" "$test_dir/credentials"
  else
    [[ ! -e "$test_dir/credentials" ]]
  fi
  if [[ "$scenario" == non-github ]]; then
    [[ ! -s "$test_dir/clone-config" ]]
  fi
  if [[ "$script" == entrypoint.sh ]]; then
    [[ -e "$test_dir/push-calls" ]]
    [[ "$(sort -u "$test_dir/push-urls")" == "$expected_url" ]]
    [[ "$("$real_git" config -f "$test_dir/push-local-config" --get remote.origin.url)" == "$expected_url" ]]
    [[ ! "$(cat "$test_dir/push-local-config")" == *"$test_token"* ]]
    if [[ "$scenario" == non-github ]]; then
      [[ ! -e "$test_dir/push-config" ]]
      [[ ! -e "$test_dir/push-credentials" ]]
    else
      grep -Fxq 'username=x-access-token' "$test_dir/push-credentials"
      grep -Fxq "password=$test_token" "$test_dir/push-credentials"
    fi
    if [[ -n "$push_tags" ]]; then
      [[ "$(wc -l < "$test_dir/push-calls")" -eq 2 ]]
      grep -Fxq "push origin $push_tags" "$test_dir/push-calls"
      [[ "$(grep -Fc "password=$test_token" "$test_dir/push-credentials")" -eq 2 ]]
    else
      [[ "$(wc -l < "$test_dir/push-calls")" -eq 1 ]]
    fi
  else
    [[ ! -e "$test_dir/push-calls" ]]
    [[ "$("$real_git" config -f "$test_dir/work/.git/config" --get remote.origin.url)" == "$expected_url" ]]
  fi
  if grep -Fq "$test_token" "$test_dir/output"; then
    echo "Token leaked in output: $script ($scenario)" >&2
    exit 1
  fi
}

for script in entrypoint.sh entrypoint-dryrun.sh; do
  run_case "$script" private-explicit 'https://github.com/example/private.git' true \
    'https://github.com/example/private.git'
  run_case "$script" private-default 'GITHUB_REPOSITORY' true \
    'https://github.com/example/current.git'
  run_case "$script" public-explicit 'https://github.com/example/public.git' false \
    'https://github.com/example/public.git'
  run_case "$script" public-default 'GITHUB_REPOSITORY' false \
    'https://github.com/example/current.git'
  run_case "$script" non-github 'https://example.invalid/public.git' false \
    'https://example.invalid/public.git'
done
run_case entrypoint.sh private-tags 'https://github.com/example/private.git' true \
  'https://github.com/example/private.git' 'refs/tags/v1'

echo 'Clone authentication checks passed.'

#!/usr/bin/env bash
set -euo pipefail

thread_id="${1:-}"
codex_home="${CODEX_HOME:-$HOME/.codex}"

if [[ -z "$thread_id" ]]; then
  printf 'usage: %s <thread-id>\n' "$0" >&2
  exit 2
fi

root_db="$codex_home/state_5.sqlite"
root_index="$codex_home/session_index.jsonl"

if [[ ! -f "$root_db" ]]; then
  printf 'missing root state db: %s\n' "$root_db" >&2
  exit 1
fi
if [[ ! -f "$root_index" ]]; then
  printf 'missing root session index: %s\n' "$root_index" >&2
  exit 1
fi

root_count="$(sqlite3 "$root_db" "select count(*) from threads where id='$thread_id';")"
if [[ "$root_count" != "1" ]]; then
  printf 'root thread count for %s is %s, expected 1\n' "$thread_id" "$root_count" >&2
  exit 1
fi

index_line="$(rg "\"id\":\"$thread_id\"" "$root_index" || true)"
if [[ -z "$index_line" ]]; then
  printf 'root session index has no entry for %s\n' "$thread_id" >&2
  exit 1
fi

accounts_dir="$codex_home/accounts"
if [[ ! -d "$accounts_dir" ]]; then
  printf 'no account directory: %s\n' "$accounts_dir"
  exit 0
fi

ts="$(date +%Y%m%d%H%M%S)"
fixed=0

for account_dir in "$accounts_dir"/*; do
  [[ -d "$account_dir" ]] || continue
  account_db="$account_dir/state_5.sqlite"
  account_index="$account_dir/session_index.jsonl"
  [[ -f "$account_db" || -f "$account_index" ]] || continue

  if [[ -f "$account_db" ]]; then
    sqlite3 "$account_db" ".backup '$account_db.bak.$ts.repair-$thread_id'"
    sqlite3 "$account_db" <<SQL
ATTACH '$root_db' AS root;
BEGIN IMMEDIATE;
INSERT OR REPLACE INTO main.threads (
  id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
  sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
  git_sha, git_branch, git_origin_url, cli_version, first_user_message,
  agent_nickname, agent_role, memory_mode
)
SELECT
  id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
  sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
  git_sha, git_branch, git_origin_url, cli_version, first_user_message,
  agent_nickname, agent_role, memory_mode
FROM root.threads
WHERE id = '$thread_id';
COMMIT;
SQL
    fixed=$((fixed + 1))
  fi

  if [[ -f "$account_index" ]] && ! rg -q "$thread_id" "$account_index"; then
    cp -a "$account_index" "$account_index.bak.$ts.repair-$thread_id"
    printf '%s\n' "$index_line" >> "$account_index"
    fixed=$((fixed + 1))
  fi
done

printf 'repaired account session state for %s, operations=%s\n' "$thread_id" "$fixed"

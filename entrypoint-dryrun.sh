#!/usr/bin/env bash

set -x

UPSTREAM_REPO=$1
UPSTREAM_BRANCH=$2
DOWNSTREAM_BRANCH=$3
set +x
GITHUB_TOKEN=$4
set -x
FETCH_ARGS=$5
MERGE_ARGS=$6
PUSH_ARGS=$7
SPAWN_LOGS=$8
DOWNSTREAM_REPO=$9
IGNORE_FILES=${10}
PUSH_TAGS=${11}


if [[ -z "$UPSTREAM_REPO" ]]; then
  echo "Missing \$UPSTREAM_REPO"
  exit 1
fi

if [[ -z "$DOWNSTREAM_BRANCH" ]]; then
  echo "Missing \$DOWNSTREAM_BRANCH"
  echo "Default to ${UPSTREAM_BRANCH}"
  DOWNSTREAM_BRANCH=$UPSTREAM_BRANCH
fi

if [[ "$UPSTREAM_REPO" != *.git ]]; then
  UPSTREAM_REPO="https://github.com/${UPSTREAM_REPO}.git"
fi

echo "UPSTREAM_REPO=$UPSTREAM_REPO"

if [[ $DOWNSTREAM_REPO == "GITHUB_REPOSITORY" ]]
then
  git clone "https://github.com/${GITHUB_REPOSITORY}.git" --branch ${DOWNSTREAM_BRANCH} work
  cd work || { echo "Missing work dir" && exit 2 ; }
  set +x
  git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  set -x
else
  git clone "$DOWNSTREAM_REPO" --branch ${DOWNSTREAM_BRANCH} work
  cd work || { echo "Missing work dir" && exit 2 ; }
  set +x
  git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${DOWNSTREAM_REPO/https:\/\/github.com\//}"
  set -x
fi



git config user.name "${GITHUB_ACTOR}"
git config user.email "${GITHUB_ACTOR}@users.noreply.github.com"
git config --global merge.ours.driver true

git remote add upstream "$UPSTREAM_REPO"
git fetch ${FETCH_ARGS} upstream || { echo "Failed to fetch upstream" && exit 1 ; }
set +x
git remote -v 2>&1 | sed "s|${GITHUB_TOKEN}|****|g"
set -x

git checkout ${DOWNSTREAM_BRANCH}

case ${SPAWN_LOGS} in
  (true)    echo -n "sync-upstream-repo https://github.com/dabreadman/sync-upstream-repo keeping CI alive."\
            "UNIX Time: " >> sync-upstream-repo
            date +"%s" >> sync-upstream-repo
            git add sync-upstream-repo
            git commit sync-upstream-repo -m "Syncing upstream";;
  (false)   echo "Not spawning time logs"
esac


IFS=',' read -r -a raw_exclusions <<< "$IGNORE_FILES"
exclusions=()
for entry in "${raw_exclusions[@]}"; do
  trimmed="${entry#"${entry%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  [[ -z "$trimmed" ]] && continue
  exclusions+=("$trimmed")
done
for exclusion in "${exclusions[@]}"
do
  echo "$exclusion"
  if [[ "$exclusion" == */ ]]; then
    echo "${exclusion}** merge=ours" >> .git/info/attributes
  elif [[ "$exclusion" == */\*\* ]]; then
    echo "$exclusion merge=ours" >> .git/info/attributes
  elif [[ "$exclusion" == */\* ]]; then
    echo "${exclusion%\*}** merge=ours" >> .git/info/attributes
  else
    echo "$exclusion merge=ours" >> .git/info/attributes
  fi
  cat .git/info/attributes
done

MERGE_RESULT=$(git merge ${MERGE_ARGS} upstream/${UPSTREAM_BRANCH} 2>&1)
MERGE_EXIT=$?
echo "$MERGE_RESULT"

echo "checking git status"
git status

echo ""
echo "========================================="
echo "[DRY-RUN] Merge complete. Inspect the result in the 'work/' directory."
echo "[DRY-RUN] Skipped all git push commands."
echo "[DRY-RUN] Run 'rm -rf work' to clean up when done."
echo "========================================="

if [[ $MERGE_EXIT -eq 0 ]]; then
  if [[ $MERGE_RESULT != *"Already up to date."* ]]; then
    echo "[DRY-RUN] Merge succeeded with changes. Would have pushed to origin/${DOWNSTREAM_BRANCH}."
    if [[ -n ${PUSH_TAGS} ]]; then
      echo "[DRY-RUN] Would have pushed tags: ${PUSH_TAGS}"
    fi
  else
    echo "[DRY-RUN] Already up to date. Nothing to push."
  fi
else
  CONFLICTED_FILES=$(git diff --name-only --diff-filter=U)
  if [[ -z "$CONFLICTED_FILES" ]]; then
    echo "[DRY-RUN] Merge failed with no conflicted files to resolve"
    exit 1
  fi

  HAS_NON_EXCLUDED_CONFLICT=false
  while IFS= read -r conflict_file; do
    is_excluded=false
    for exclusion in "${exclusions[@]}"; do
      if [[ "$exclusion" == */ ]]; then
        if [[ "$conflict_file" == "$exclusion"* ]]; then
          is_excluded=true
          break
        fi
      elif [[ "$exclusion" == */\*\* ]]; then
        folder="${exclusion%\*\*}"
        if [[ "$conflict_file" == "$folder"* ]]; then
          is_excluded=true
          break
        fi
      elif [[ "$exclusion" == */\* ]]; then
        folder="${exclusion%\*}"
        if [[ "$conflict_file" == "$folder"* ]]; then
          is_excluded=true
          break
        fi
      elif [[ "$conflict_file" == "$exclusion" ]]; then
        is_excluded=true
        break
      fi
    done

    if [[ "$is_excluded" == true ]]; then
      echo "[DRY-RUN] Would auto-resolve excluded file conflict: $conflict_file"
    else
      echo "[DRY-RUN] Non-excluded file has conflict: $conflict_file"
      HAS_NON_EXCLUDED_CONFLICT=true
    fi
  done <<< "$CONFLICTED_FILES"

  if [[ "$HAS_NON_EXCLUDED_CONFLICT" == true ]]; then
    echo "[DRY-RUN] Merge conflicts exist in non-excluded files, would fail"
    exit 1
  fi

  echo "[DRY-RUN] All conflicts are in excluded files and would be auto-resolved"
  echo "[DRY-RUN] Would have pushed to origin/${DOWNSTREAM_BRANCH}."
  if [[ -n ${PUSH_TAGS} ]]; then
    echo "[DRY-RUN] Would have pushed tags: ${PUSH_TAGS}"
  fi
fi

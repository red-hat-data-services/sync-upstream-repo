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

if [[ $MERGE_EXIT -eq 0 ]]; then
  if [[ $MERGE_RESULT != *"Already up to date."* ]]; then
    git diff --cached --quiet 2>/dev/null || git commit -m "Merged upstream"
    git push ${PUSH_ARGS} origin ${DOWNSTREAM_BRANCH} || exit $?
    if [[ -n ${PUSH_TAGS} ]]; then
      git push origin ${PUSH_ARGS} ${PUSH_TAGS}
    fi
  fi
else
  CONFLICTED_FILES=$(git diff --name-only --diff-filter=U)
  if [[ -z "$CONFLICTED_FILES" ]]; then
    echo "Merge failed with no conflicted files to resolve"
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
      echo "Auto-resolving excluded file conflict: $conflict_file"
      if git checkout --ours -- "$conflict_file" 2>/dev/null; then
        git add "$conflict_file"
      elif git rm -f "$conflict_file" 2>/dev/null; then
        :
      else
        echo "Failed to resolve conflict for excluded file: $conflict_file"
        HAS_NON_EXCLUDED_CONFLICT=true
      fi
    else
      echo "Non-excluded file has conflict: $conflict_file"
      HAS_NON_EXCLUDED_CONFLICT=true
    fi
  done <<< "$CONFLICTED_FILES"

  if [[ "$HAS_NON_EXCLUDED_CONFLICT" == true ]]; then
    echo "Merge conflicts exist in non-excluded files, failing"
    exit 1
  fi

  echo "All conflicts were in excluded files and have been auto-resolved"
  git commit -m "Merged upstream" || { echo "Commit failed after conflict resolution" && exit 1 ; }
  git push ${PUSH_ARGS} origin ${DOWNSTREAM_BRANCH} || exit $?
  if [[ -n ${PUSH_TAGS} ]]; then
    git push origin ${PUSH_ARGS} ${PUSH_TAGS}
  fi
fi

cd ..
rm -rf work || {
  git -C work fsmonitor--daemon stop 2>/dev/null || true
  sleep 1
  rm -rf work
}

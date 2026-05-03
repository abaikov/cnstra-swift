#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/release.sh <version>

Examples:
  scripts/release.sh 1.1.0
  scripts/release.sh v1.1.0

Environment:
  RELEASE_BRANCH  Branch to release from. Default: master
  RELEASE_REMOTE  Remote to push to. Default: origin
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

VERSION="${1#v}"
TAG="v${VERSION}"
RELEASE_BRANCH="${RELEASE_BRANCH:-master}"
RELEASE_REMOTE="${RELEASE_REMOTE:-origin}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid version: $1"
  echo "Expected semver like 1.1.0 or v1.1.0."
  exit 1
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is not clean. Commit or stash changes before releasing."
  git status --short
  exit 1
fi

START_REF="$(git rev-parse --verify HEAD)"
START_BRANCH="$(git branch --show-current || true)"

echo "Preparing release ${TAG}"
echo "Start ref: ${START_REF}"
echo "Release branch: ${RELEASE_BRANCH}"
echo "Remote: ${RELEASE_REMOTE}"

git fetch "$RELEASE_REMOTE" --tags

if git rev-parse --verify --quiet "refs/tags/${TAG}" >/dev/null; then
  echo "Tag ${TAG} already exists locally."
  exit 1
fi

if git ls-remote --exit-code --tags "$RELEASE_REMOTE" "refs/tags/${TAG}" >/dev/null 2>&1; then
  echo "Tag ${TAG} already exists on ${RELEASE_REMOTE}."
  exit 1
fi

git switch "$RELEASE_BRANCH"
git merge --ff-only "${RELEASE_REMOTE}/${RELEASE_BRANCH}"
git merge --ff-only "$START_REF"

swift test

git push "$RELEASE_REMOTE" "$RELEASE_BRANCH"
git tag -a "$TAG" -m "Release ${TAG}"
git push "$RELEASE_REMOTE" "refs/tags/${TAG}"

if [[ -n "$START_BRANCH" && "$START_BRANCH" != "$RELEASE_BRANCH" ]]; then
  echo "Release complete. You are on ${RELEASE_BRANCH}; previous branch was ${START_BRANCH}."
else
  echo "Release complete."
fi

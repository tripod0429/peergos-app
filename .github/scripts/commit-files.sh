#!/bin/bash
# Commits files from the working tree to the checked-out branch through GitHub's
# GraphQL API, which signs the commit (a git push with GITHUB_TOKEN would be
# unsigned). Prints the new commit's SHA.
#
# Usage: commit-files.sh <message> <file>...
# Needs GH_TOKEN with contents: write, and GITHUB_REPOSITORY and GITHUB_REF_NAME.
set -euo pipefail

if (( $# < 2 )); then
    echo "Usage: $0 <message> <file>..." >&2
    exit 2
fi
message="$1"; shift
branch="${GITHUB_REF_NAME}"

# The commit replaces these files wholesale, so it may only go on top of a
# branch that hasn't changed them since this run checked it out.
base="$(git rev-parse HEAD)"
git fetch --quiet origin "${branch}"
tip="$(git rev-parse FETCH_HEAD)"
if [[ "${tip}" != "${base}" ]] && ! git diff --quiet "${base}" "${tip}" -- "$@"; then
    echo "::error::${branch} changed $* since this run started, so nothing was committed" >&2
    exit 1
fi

additions="$(for f in "$@"; do
    jq -n --arg path "${f}" --rawfile contents "${f}" '{path: $path, contents: ($contents | @base64)}'
done | jq -s .)"

# shellcheck disable=SC2016 # $input is a GraphQL variable
jq -n --arg repo "${GITHUB_REPOSITORY}" --arg branch "${branch}" --arg oid "${tip}" \
    --arg message "${message}" --argjson additions "${additions}" '{
    query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }",
    variables: { input: {
        branch: { repositoryNameWithOwner: $repo, branchName: $branch },
        expectedHeadOid: $oid,
        message: { headline: $message },
        fileChanges: { additions: $additions }
    } }
}' | gh api graphql --input - --jq .data.createCommitOnBranch.commit.oid

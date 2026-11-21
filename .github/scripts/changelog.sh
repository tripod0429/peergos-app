#!/bin/bash
# Prints the CHANGELOG section for package version <version>, which updates
# Peergos from <from> to <to>, with upstream's release notes copied verbatim.
#
# Usage: changelog.sh <version> <from> <to>
#
# The notes only change mechanically. Windows line endings and blank lines go
# (Cloudron's changelog parser skips blank lines anyway), and every line that
# isn't already a list item becomes one. That way no line starts with "[",
# which the parser reads as the start of the next version's section.
#
# Reads the release list from the GitHub API with `gh`, or from the file named
# by RELEASES_JSON (the API's JSON, for testing).
set -euo pipefail

if (( $# != 3 )); then
    echo "Usage: $0 <version> <from> <to>" >&2
    exit 2
fi
version="$1" from="$2" to="$3"

if [[ "${from}" == "${to}" ]]; then
    echo "Peergos is still ${to}, so there are no upstream notes to copy. Add a [${version}] section to CHANGELOG yourself." >&2
    exit 1
fi

# shellcheck disable=SC2016 # $from and friends are jq variables
filter='
def triple: split(".") | map(tonumber);
($from | triple) as $lo | ($to | triple) as $hi
| [ add[]
    | select((.draft | not) and (.prerelease | not))
    | select(.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
    | .v = (.tag_name | ltrimstr("v") | triple)
    | select(.v > $lo and .v <= $hi) ]
| sort_by(.v)
| if length == 0 or .[-1].v != $hi then error("No published Peergos release v\($to) on GitHub") else . end
| (map("[\(.tag_name | ltrimstr("v"))](\(.html_url))")) as $links
| "[\($version)]",
  "* Update Peergos to \($to) (" + (
      if ($links | length) == 1 then "[release notes](\(.[0].html_url))"
      else ($links[:-1] | join(", ")) + " and " + $links[-1] + " release notes"
      end) + ")",
  ( reverse[]
    | (.body // "") | gsub("\r"; "") | split("\n")[]
    | sub("\\s+$"; "") | select(length > 0)
    | if test("^\\s*([*+-]|[0-9]+[.)])\\s") then . else "* " + sub("^\\s+"; "") end )
'

if [[ -n "${RELEASES_JSON:-}" ]]; then
    cat "${RELEASES_JSON}"
else
    gh api --paginate 'repos/Peergos/web-ui/releases?per_page=100'
fi | jq -r -s --arg version "${version}" --arg from "${from}" --arg to "${to}" "${filter}"

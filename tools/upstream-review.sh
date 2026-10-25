#!/usr/bin/env bash
# Upstream review: what has changed in GIST (github.com/BelongaGezza/gist)
# since the commit chromeGIST was last reviewed against (UPSTREAM_BASELINE),
# and which of it can reach this app. Works from a read-only clone of GitHub
# at .upstream/gist (created and fetched on demand; override the location
# with GIST_UPSTREAM). No local GIST working copy is consulted. See docs/ARCHITECTURE.md "Upstream
# baseline" for the procedure this supports.
#
# Usage:
#   tools/upstream-review.sh              full report (for a human or Claude)
#   tools/upstream-review.sh --ref <ref>  review against <ref> instead of
#                                         origin/main (a branch, tag or sha)
#   tools/upstream-review.sh --check      one-line build warning if watched
#                                         paths changed (offline: uses the
#                                         clone as last fetched); always exits 0
#                                         (run by build-wasm.sh, i.e. on
#                                         every build and test run)
#   tools/upstream-review.sh --check --strict
#                                         same, but exits 1 if unreviewed
#                                         (for release packaging / CI)
#   tools/upstream-review.sh --record "<note>"
#                                         after reviewing: pin the workspace's
#                                         gist-* git dependencies to the
#                                         reviewed commit (Cargo.toml), run the
#                                         Rust tests, and if they pass make it
#                                         the new baseline and add a row to the
#                                         ARCHITECTURE.md table
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GIST_URL="https://github.com/BelongaGezza/gist.git"
UPSTREAM="${GIST_UPSTREAM:-$REPO_ROOT/.upstream/gist}"
BASELINE_FILE="$REPO_ROOT/UPSTREAM_BASELINE"

# What of GIST can reach chromeGIST, grouped by how it arrives.
# Shared crates: compiled into the WASM via the rev-pinned git dependency, so
# they change only when `--record` moves the pin. Everything else needs a
# deliberate port.
SHARED_CRATES="crates/gist-model crates/gist-parse-txt crates/gist-rsvp"
# GIST's Swift RSVP view. chromeGIST doesn't port pacing (it runs GIST's own
# gist-rsvp in WASM), but reader-UI and ORP-display fixes here may apply to
# the extension's reader page.
SWIFT_PORT="apps/apple/macOS/RsvpView.swift"
# Icon artwork (assets/gist-macos-app-icon.png is a copy of GIST's).
ICON_ART="assets"
# Policy/tooling chromeGIST mirrors (deny.toml, security reviews).
POLICY="deny.toml docs/security-review-v2.md docs/security-quality-review-2026-09-29.md SECURITY.md"
WATCHED="$SHARED_CRATES $SWIFT_PORT $ICON_ART"

MODE=report STRICT=0 REF="origin/main" NOTE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE=check ;;
        --strict) STRICT=1 ;;
        --ref) REF="${2:?--ref needs a branch, tag or sha}"; shift ;;
        --record) MODE=record; NOTE="${2:?--record needs a note describing the review}"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

[ -f "$BASELINE_FILE" ] || { echo "error: $BASELINE_FILE missing" >&2; exit 1; }
BASE="$(sed -n 's/^commit=//p' "$BASELINE_FILE")"
BASE_DATE="$(sed -n 's/^reviewed=//p' "$BASELINE_FILE")"

g() { git -C "$UPSTREAM" "$@"; }

# --check never touches the network (it runs on every build); the other
# modes create the clone if needed and fetch before comparing.
if [ "$MODE" = check ]; then
    if [ ! -d "$UPSTREAM/.git" ]; then
        # Not an error: nothing to compare against until the first full review.
        echo "note: upstream-review: no GIST clone at ${UPSTREAM#"$REPO_ROOT"/}; run tools/upstream-review.sh to create one."
        [ "$STRICT" = 1 ] && exit 1
        exit 0
    fi
else
    if [ ! -d "$UPSTREAM/.git" ]; then
        echo "→ Cloning $GIST_URL into ${UPSTREAM#"$REPO_ROOT"/} (read-only review copy)..."
        mkdir -p "$(dirname "$UPSTREAM")"
        git clone --quiet "$GIST_URL" "$UPSTREAM"
    else
        g fetch --quiet --tags origin || echo "(fetch failed; using the clone as last fetched)" >&2
    fi
fi

TARGET_SHA="$(g rev-parse --verify -q "$REF^{commit}")" || { echo "error: cannot resolve '$REF' in $UPSTREAM" >&2; exit 1; }
HEAD_SHA="$TARGET_SHA"
BRANCH="$REF"

# Watched-path differences between the baseline and the review target.
# shellcheck disable=SC2086
changed_paths() { g diff --name-only "$BASE" "$TARGET_SHA" -- $WATCHED 2>/dev/null; }

# ── --check: build-time nudge ───────────────────────────────────────────────
if [ "$MODE" = check ]; then
    CHANGED="$(changed_paths | wc -l | tr -d ' ')"
    if [ "$CHANGED" != 0 ]; then
        MSG="GIST ($BRANCH @ ${HEAD_SHA:0:7}, as last fetched) has $CHANGED changed file(s) in code chromeGIST uses since the last upstream review (${BASE:0:7}, $BASE_DATE). Run tools/upstream-review.sh."
        if [ "$STRICT" = 1 ]; then
            echo "error: $MSG" >&2
            exit 1
        fi
        echo "warning: $MSG"
    fi
    exit 0
fi

# ── --record: accept the current checkout as the new baseline ───────────────
if [ "$MODE" = record ]; then
    # Pin the shared crates to the reviewed commit. Cargo.toml's workspace
    # dependency `rev` is what actually decides what gets built.
    CARGO_TOML="$REPO_ROOT/Cargo.toml"
    cp "$CARGO_TOML" "$CARGO_TOML.bak"; cp "$REPO_ROOT/Cargo.lock" "$REPO_ROOT/Cargo.lock.bak"
    restore() { mv "$CARGO_TOML.bak" "$CARGO_TOML"; mv "$REPO_ROOT/Cargo.lock.bak" "$REPO_ROOT/Cargo.lock"; }
    sed -i '' -E "/^gist-(model|parse-txt|rsvp) .*BelongaGezza\/gist/ s/rev = \"[0-9a-f]+\"/rev = \"$HEAD_SHA\"/" "$CARGO_TOML"
    echo "→ Running chromeGIST's native tests against GIST ${HEAD_SHA:0:7} ($BRANCH)..."
    if ! (cd "$REPO_ROOT" && cargo test --workspace); then
        restore
        echo "error: tests failed against ${HEAD_SHA:0:7}; Cargo.toml/Cargo.lock restored, baseline unchanged." >&2
        exit 1
    fi
    rm -f "$CARGO_TOML.bak" "$REPO_ROOT/Cargo.lock.bak"
    TODAY="$(date +%Y-%m-%d)"
    cat > "$BASELINE_FILE" <<EOF
# The last GIST (github.com/BelongaGezza/gist) commit chromeGIST was reviewed and
# tested against. Written by \`tools/upstream-review.sh --record\`; don't edit
# by hand. History and notes: docs/ARCHITECTURE.md "Upstream baseline".
commit=$HEAD_SHA
branch=$BRANCH
reviewed=$TODAY
EOF
    python3 - "$REPO_ROOT/docs/ARCHITECTURE.md" "$TODAY" "${HEAD_SHA:0:7}" "$BRANCH" "$NOTE" <<'PY'
import sys
path, date, sha, branch, note = sys.argv[1:]
lines = open(path).read().split("\n")
start = next(i for i, l in enumerate(lines) if l.startswith("#") and l.lstrip("# ").startswith("Upstream baseline"))
rows = [i for i in range(start, len(lines)) if lines[i].startswith("| 20")]
if not rows:
    sys.exit("error: no baseline table rows found under the Upstream baseline heading")
lines.insert(rows[-1] + 1, f"| {date} | `{sha}` | `{branch}` | {note} |")
open(path, "w").write("\n".join(lines))
PY
    echo "✓ Baseline and Cargo.toml pin are now ${HEAD_SHA:0:7} ($BRANCH); row added to docs/ARCHITECTURE.md."
    echo "  If dependencies changed, run tools/gen-third-party.sh. Then commit UPSTREAM_BASELINE, Cargo.toml, Cargo.lock and the docs."
    exit 0
fi

# ── Report ──────────────────────────────────────────────────────────────────
echo "Upstream review: GIST ($GIST_URL)"
echo "  baseline : ${BASE:0:7} (reviewed $BASE_DATE)"
echo "  target   : ${HEAD_SHA:0:7} ($BRANCH)"
MISSING="$(g rev-list --count "$HEAD_SHA..$BASE" 2>/dev/null || echo "?")"
if [ "$MISSING" != 0 ]; then
    echo "  note: the target lacks $MISSING commit(s) of the baseline (older or different branch)."
fi
echo

SHOWN=""
section() {
    local title="$1"; shift
    local commits files
    commits="$(g log --no-merges --format='    %h %ad %s' --date=short "$BASE..$HEAD_SHA" -- "$@")"
    SHOWN="$SHOWN $(g log --no-merges --format=%h "$BASE..$HEAD_SHA" -- "$@" | tr '\n' ' ')"
    files="$(g diff --stat=100 "$BASE" "$HEAD_SHA" -- "$@" | tail -1)"
    echo "■ $title"
    if [ -z "$commits" ]; then
        echo "    no changes"
    else
        echo "$commits"
        [ -n "$files" ] && echo "    total:$files"
    fi
    echo
}
# shellcheck disable=SC2086
section "Shared crates: compiled into chromeGIST's WASM; adopting means moving the pin (--record) after checking behaviour + tests" $SHARED_CRATES
section "GIST's Swift RSVP view: reference for reader-UI/ORP-display fixes (pacing itself runs from gist-rsvp)" $SWIFT_PORT
section "Icon artwork: assets/ holds a copy; refresh it (tools/gen-icons.sh --refresh-source) and regenerate the extension icons" $ICON_ART
# shellcheck disable=SC2086
section "Security/dependency policy: mirror applicable rules in deny.toml / SECURITY_REVIEW.md" $POLICY

# Commits not already listed in a section above.
OTHER=""
for sha in $(g log --no-merges --format=%h "$BASE..$HEAD_SHA"); do
    case " $SHOWN " in *" $sha "*) ;; *) OTHER="$OTHER$(g log -1 --format='    %h %ad %s' --date=short "$sha")
" ;; esac
done
OTHER="${OTHER%
}"
echo "■ Everything else: usually GIST-only (library, storage, Windows...). Skim for fixes to shared ideas."
if [ -z "$OTHER" ]; then echo "    no changes"; else
    echo "$OTHER" | head -40
    N="$(echo "$OTHER" | wc -l | tr -d ' ')"
    [ "$N" -gt 40 ] && echo "    … and $((N - 40)) more"
fi
echo

if command -v gh >/dev/null 2>&1; then
    ISSUES="$(gh issue list --repo BelongaGezza/gist --state all --search 'chromeGIST OR contextGIST in:body' \
        --json number,state,title --jq '.[] | "    #\(.number) [\(.state)] \(.title)"' 2>/dev/null || true)"
    if [ -n "$ISSUES" ]; then
        echo "■ GIST issues that mention chromeGIST/contextGIST (a closed one may need a matching change here)"
        echo "$ISSUES"
        echo
    fi
fi

echo "Next: decide adopt / port / skip for each item. When done, run the tests"
echo "and record the review:  tools/upstream-review.sh --record \"<what you adopted/skipped>\""

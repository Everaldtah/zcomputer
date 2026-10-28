#!/bin/sh
# Publishes a downloaded "z-alpine-desktop-x86" workflow artifact (from
# .github/workflows/images.yml) as the GitHub Release `images-v1`. The app
# downloads from https://github.com/<repo>/releases/download/images-v1/<file>.
#
#   gh run download <run-id> -n z-alpine-desktop-x86 -D /tmp/zad
#   tools/images/publish.sh /tmp/zad [--repo OWNER/REPO] [--tag images-v1] [--dry-run]
#
# Creates the release when it does not exist, otherwise replaces the assets
# (gh release upload --clobber) and the release notes. Checks every file
# against manifest.json before uploading. Needs gh (logged in), sha256sum or
# shasum, and node or python3 to read the manifest.
set -eu

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

dir=""
repo=${GH_REPO:-Everaldtah/zcomputer}
tag=images-v1
dry=0
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) repo=${2:?--repo needs OWNER/REPO}; shift 2 ;;
        --tag) tag=${2:?--tag needs a name}; shift 2 ;;
        --dry-run) dry=1; shift ;;
        -h|--help) usage 0 ;;
        -*) echo "publish.sh: unknown option $1" >&2; usage 2 ;;
        *) [ -z "$dir" ] || usage 2; dir=$1; shift ;;
    esac
done
[ -n "$dir" ] || usage 2
[ -d "$dir" ] || { echo "publish.sh: $dir is not a directory" >&2; exit 1; }

id=z-alpine-desktop-x86
files="$dir/$id.img.xz $dir/$id.state.xz $dir/manifest.json $dir/README.md"
for f in $files; do
    [ -s "$f" ] || { echo "publish.sh: missing or empty: $f" >&2; exit 1; }
done

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# expected "<sha256> <size> <name>" lines from manifest.json
expected() {
    if command -v node >/dev/null 2>&1; then
        node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));for(const i of m.images)for(const f of Object.values(i.files))console.log(f.sha256,f.sizeBytes,f.name)' "$dir/manifest.json"
    else
        python3 -c 'import json,sys
m=json.load(open(sys.argv[1]))
for i in m["images"]:
    for f in i["files"].values(): print(f["sha256"], f["sizeBytes"], f["name"])' "$dir/manifest.json"
    fi
}

echo "checking $dir against manifest.json"
n=0
expected | while read -r want_sha want_size name; do
    f="$dir/$name"
    got_size=$(wc -c < "$f" | tr -d ' ')
    [ "$got_size" = "$want_size" ] || { echo "  $name: size $got_size, manifest says $want_size" >&2; exit 1; }
    got_sha=$(sha "$f")
    [ "$got_sha" = "$want_sha" ] || { echo "  $name: sha256 $got_sha, manifest says $want_sha" >&2; exit 1; }
    echo "  ok  $name  $got_size bytes  $got_sha"
done
n=$(expected | wc -l | tr -d ' ')
[ "$n" -ge 2 ] || { echo "publish.sh: manifest.json lists $n files, expected img + state" >&2; exit 1; }

version=$( (node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version)' "$dir/manifest.json" 2>/dev/null) \
    || python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$dir/manifest.json")
title="Z Computer images ($version)"

if [ "$dry" = 1 ]; then
    echo "dry run: would publish $files to $repo release $tag ($title)"
    exit 0
fi

if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    echo "updating release $tag in $repo"
    gh release upload "$tag" --repo "$repo" --clobber $files
    gh release edit "$tag" --repo "$repo" --title "$title" --notes-file "$dir/README.md"
else
    echo "creating release $tag in $repo"
    gh release create "$tag" --repo "$repo" --title "$title" --notes-file "$dir/README.md" --latest=false $files
fi

echo "done:"
for f in $files; do echo "  https://github.com/$repo/releases/download/$tag/$(basename "$f")"; done

#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat << 'EOF'
Usage:
  update_homebrew_tap_formula.sh \
    --formula /path/to/Formula/mole.rb \
    --tag V1.32.0 \
    --source-sha <sha256> \
    --arm-sha <sha256> \
    --amd-sha <sha256>
EOF
}

formula_path=""
tag=""
source_sha=""
arm_sha=""
amd_sha=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --formula)
            formula_path="${2:-}"
            shift 2
            ;;
        --tag)
            tag="${2:-}"
            shift 2
            ;;
        --source-sha)
            source_sha="${2:-}"
            shift 2
            ;;
        --arm-sha)
            arm_sha="${2:-}"
            shift 2
            ;;
        --amd-sha)
            amd_sha="${2:-}"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "$formula_path" || -z "$tag" || -z "$source_sha" || -z "$arm_sha" || -z "$amd_sha" ]]; then
    usage >&2
    exit 1
fi

if [[ ! -f "$formula_path" ]]; then
    echo "Formula not found: $formula_path" >&2
    exit 1
fi

TAG="$tag" \
    SOURCE_SHA="$source_sha" \
    ARM_SHA="$arm_sha" \
    AMD_SHA="$amd_sha" \
    perl -0pi -e '
    s{url "https://github.com/tw93/(?:Mole|mole)/archive/refs/tags/[^"]+\.tar\.gz"\n  sha256 "[^"]+"}{
      qq{url "https://github.com/tw93/Mole/archive/refs/tags/$ENV{TAG}.tar.gz"\n  sha256 "$ENV{SOURCE_SHA}"}
    }se;

    s{(on_arm do\s+url ")https://github.com/tw93/(?:Mole|mole)/releases/download/[^/]+/binaries-darwin-arm64\.tar\.gz("\s+sha256 ")[^"]+(")}{
      qq{$1https://github.com/tw93/Mole/releases/download/$ENV{TAG}/binaries-darwin-arm64.tar.gz$2$ENV{ARM_SHA}$3}
    }se;

    s{(on_intel do\s+url ")https://github.com/tw93/(?:Mole|mole)/releases/download/[^/]+/binaries-darwin-amd64\.tar\.gz("\s+sha256 ")[^"]+(")}{
      qq{$1https://github.com/tw93/Mole/releases/download/$ENV{TAG}/binaries-darwin-amd64.tar.gz$2$ENV{AMD_SHA}$3}
    }se;
' "$formula_path"

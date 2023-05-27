#!/usr/bin/env bash

set -eo pipefail

MMS_URL_PREFIX=https://dl.fbaipublicfiles.com/mms/
MAX_FAILS=3

declare _grep_util='grep' temp_dir last_dir list_file etag_file fails=0
trap teardown EXIT

teardown() {
    [ -d "$temp_dir" ] && rm -rf -- "$temp_dir"
    [ -z "$last_dir" ] || cd "$last_dir" >/dev/null
}

main() {
    [ "$(uname -s)" = Darwin ] && {
        # shellcheck disable=SC2015
        command -v ggrep &>/dev/null && _grep_util=ggrep || {
            echo 'GNU grep is required on macOS. Run "brew install grep" to install it.' >&2
            return 1
        }
    }

    local dir="$1" start_url=https://raw.githubusercontent.com/facebookresearch/fairseq/main/examples/mms/README.md

    [ -z "$dir" ] && {
        echo "Usage: $0 target_directory" >&2
        exit 1
    }
    [ -d "$dir" ] || {
        echo "Directory $dir does not exist" >&2
        exit 2
    }

    [ "$dir" = . ] || {
        last_dir=$(pwd)
        cd "$dir"
    }

    temp_dir=$(mktemp -d)
    list_file="$temp_dir/list.txt"
    etag_file="$dir/.etags"
    echo '-> Section 1/2: MMS'
    curl -fsSL "$start_url" | $_grep_util -F '[download]' | $_grep_util -Po "(?<=$MMS_URL_PREFIX"')[^\)]+' >"$list_file"
    download_list

    echo '-> Section 2/2: TTS'
    find asr -name '*_langs.html' -exec cat {} \; | $_grep_util -Po '(?<=<p> )\S+' | awk 'NR > 1 {print "tts/" $1 ".tar.gz"}' >"$list_file"
    download_list
}

download_list() {
    local i=0 count=0 part options etag
    count=$($_grep_util -c '' <"$list_file")

    while read -r part; do
        [ -n "$part" ] || continue
        i=$((i + 1))

        echo "[$i/$count] $part"
        mkdir -p "${part%/*}"

        # determine if file needs to be downloaded
        options=(--fail --location --remote-time --progress-bar --url "$MMS_URL_PREFIX$part" --output "$part")
        etag=$(get_etag "$part")
        [ -n "$etag" ] && options+=(--header "If-None-Match: \"$etag\"") || options+=(--continue-at -)

        # download file
        curl "${options[@]}" || {
            fails=$((fails + 1))
            [[ $MAX_FAILS -gt 0 && $fails -ge $MAX_FAILS ]] && {
                echo 'Too many fails occurred.' >&2
                exit 10
            }
            continue
        }

        # save etag for successfully downloaded files
        etag=$(curl -I "$MMS_URL_PREFIX$part" | $_grep_util -Pio '(?<=etag: ")[^"]+' || true)
        [ -z "$etag" ] || save_etag "$part" "$etag"
    done <"$list_file"
}

get_etag() {
    [ -f "$etag_file" ] || return 0
    $_grep_util -q "$1 " "$list_file" || return 0
    $_grep_util "$1 " "$etag_file" | cut -d' ' -f2
}

save_etag() {
    [ -f "$etag_file" ] && {
        $_grep_util -q "$1 $2" "$list_file" && return
        $_grep_util -q "$1 " "$list_file" || sed -i '\#'"$1 #d" "$etag_file"
    }
    echo "$1 $2" >>"$etag_file"
}

main "$@"

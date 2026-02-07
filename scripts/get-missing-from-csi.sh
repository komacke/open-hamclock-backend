#!/usr/bin/env bash
set -uo pipefail

# Get our directory locations in order
HERE="$(realpath -s "$(dirname "$0")")"
THIS="$(basename "$0")"

# the file with the list of paths to pull is the same as this script
SOURCE_FILE=$HERE/"${THIS%.*}".txt

# the root URL source and the root file location
REMOTE_HOST="http://clearskyinstitute.com"
OUT="/opt/hamclock-backend/htdocs"

# refresh the list of artifacts based on recent 404 errors:
grep ' 404 ' /var/log/lighttpd/access.log | \
awk -v Date="$(date -d'1 hour ago' +'%d/%b/%Y:%H:%M:%S')" '{
  if ($4" "$5 >= Date) {
    print $0
  }
}' | cut -d\"  -f2 | cut -d " " -f 2 | sort | uniq | \
while IFS= read -r url || [[ -n "$url" ]]; do
    echo $url >> $SOURCE_FILE
done
sort -uo $SOURCE_FILE $SOURCE_FILE

while IFS= read -r line || [[ -n "$line" ]]; do
    URL=${REMOTE_HOST}${line}
    OUT_FILE=${OUT}${line}
    curl -fsS --retry 3 --retry-delay 2 "$URL" -o "$OUT_FILE"
    RETVAL=$?
    if [ $RETVAL -ne 0 ]; then
        echo "Failed to download from $URL" >&2
    fi
done < $SOURCE_FILE

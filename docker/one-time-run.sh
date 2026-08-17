#!/bin/bash

# These are scripts that should only run one time when the container is created. There is a
# persistent docker volume container which might need one-time modification (clean up old
# file, for example). But we don't want this script to run every time the container restarts.
#
# RUNNING SCRIPTS
# .....
#
# CLEANING FILES
# This has built in a file cleaning function based on a file named one-time-clean.txt.
# The docker volume container persists files basically forever. We need a maintenance
# mechanism. Possible uses are:
#   - old files that are no longer used
#   - cache or data files that need to be cleared out once upon upgrade, usually for fixing a bug
#
# After the files list is run, it is cleared out so that it doesn't run again. This is especially 
# required for clearing data on upgrade. We don't want to clear the data on every restart, just
# one time.
#
# The files are relative to a root of /opt/hamclock-backend/htdocs/state/ which is the docker-mounted volume

THIS=$(basename $0)
HERE="$(cd "$(dirname "$0")" && pwd)"
RETVAL=0
DVC_MOUNT=/opt/hamclock-backend/htdocs
CLEAN_STATE_FILE=$DVC_MOUNT/state/${THIS%.*}.txt
SCRIPT_STATE_FILE=/opt/hamclock-backend/cache/${THIS%.*}.txt
GIT_VERSION_FILE=/opt/hamclock-backend/git.version
CLEAN_FILES_LIST=$HERE/one-time-clean.txt
RUN_SCRIPTS_LIST=$HERE/one-time-scripts.sh

main() {
    # Only do something if the file exists in this image
    [[ ! -r "$CLEAN_FILES_LIST" ]] && exit $RETVAL

    # see if it was run before
    if check_if_clean; then
        clean_files
        # mark as clean
        mark_clean
    fi

    if check_if_scripts_run; then
        run_scripts
        # mark as run
        mark_run
    fi

    return
}

check_if_clean() {
    # Only do something if the file wasn't already created and marked
    # by the image version
    if cmp --silent "$CLEAN_STATE_FILE" "$GIT_VERSION_FILE"; then
        echo "One-time clean was done previously."
        return 1
    else
        return 0
    fi
}

mark_clean() {
    # mark the file as from this image and having been cleaned already.
    cp "$GIT_VERSION_FILE" "$CLEAN_STATE_FILE"
}

clean_files() {
    while IFS= read -r file; do
        if [ -d "${DVC_MOUNT}${file}" ]; then
            # remove only the directory contents if it ends in slash
            if [[ "${DVC_MOUNT}${file}" == */ ]]; then
                echo "$THIS: Removing contents of directory: ${DVC_MOUNT}${file}"
                rm -Rf "${DVC_MOUNT}${file}"*
            else
                echo "$THIS: Removing directory: ${DVC_MOUNT}${file}"
                rm -Rf "${DVC_MOUNT}${file}"
            fi
        elif [ -f "${DVC_MOUNT}${file}" ]; then
            echo "$THIS: Deleting file: ${DVC_MOUNT}${file}"
            rm -f "${DVC_MOUNT}${file}"
        else
            echo "$THIS: No such file or directory: ${DVC_MOUNT}${file}"
        fi
    done < <(grep -vE '^(\s*#|\s*$)' "$CLEAN_FILES_LIST" | tr -d '\r')
}

check_if_scripts_run() {
    # Only do something if the file wasn't already created and marked
    # by the image version
    if cmp --silent "$SCRIPT_STATE_FILE" "$GIT_VERSION_FILE"; then
        echo "One-time script was done previously."
        return 1
    else
        return 0
    fi
}

run_scripts() {
    bash $RUN_SCRIPTS_LIST
}

mark_run() {
    # mark the file as run since container was created
    cp "$GIT_VERSION_FILE" "$SCRIPT_STATE_FILE"
}

main "$@"
exit $RETVAL

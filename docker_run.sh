#!/bin/bash
# Run the tartancalib image with a data folder mounted at /data and, when an
# X server is available, GUI windows (live plots, extraction view, reports)
# forwarded to the host display.
#
#   ./docker_run.sh [--data DIR] [--image NAME] [--no-display] [--dev]
#                   [--mount HOST_PATH:CONTAINER_PATH ...] [command ...]
#
# --dev mounts this checkout over the image's source, so Python edits take
# effect without rebuilding (C++ changes still need `docker build`).
# --mount adds a bind mount (repeatable), e.g. a config folder to update.
#
# Examples:
#   ./docker_run.sh --data ~/calib_data                       # interactive shell
#   ./docker_run.sh --data ~/calib_data tartan_calibrate --help
#
# macOS: needs XQuartz (brew install --cask xquartz) with "Allow connections
# from network clients" enabled (defaults write org.xquartz.X11 nolisten_tcp 0,
# then restart XQuartz). The script starts XQuartz if it is not running and
# hands the container a copy of its auth cookie, so no `xhost +` is needed.
# Linux: forwards $DISPLAY through /tmp/.X11-unix with the same cookie approach.
set -euo pipefail

IMAGE="tartancalib"
DATA_DIR="$(pwd)"
DISPLAY_ON=1
DEV=0
MOUNTS=()
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ $# -gt 0 ]; do
    case "$1" in
        --data) DATA_DIR="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        --no-display) DISPLAY_ON=0; shift ;;
        --dev) DEV=1; shift ;;
        --mount) MOUNTS+=(-v "$2"); shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done
DATA_DIR="$(cd "$DATA_DIR" && pwd)"

DOCKER_ARGS=(--rm --init -v "$DATA_DIR:/data")
if [ ${#MOUNTS[@]} -gt 0 ]; then
    DOCKER_ARGS+=("${MOUNTS[@]}")
fi
if [ "$DEV" = 1 ]; then
    DOCKER_ARGS+=(-v "$SCRIPT_DIR:/catkin_ws/src/kalibr:ro")
fi
if [ -t 0 ] && [ -t 1 ]; then
    DOCKER_ARGS+=(-it)
fi

XAUTH_FILE="${TMPDIR:-/tmp}/tartancalib.docker.xauth"

setup_display_macos() {
    local xauth=/opt/X11/bin/xauth
    if [ ! -x "$xauth" ]; then
        echo "[docker_run] XQuartz not found; running without a display." >&2
        return 1
    fi
    if [ "$(defaults read org.xquartz.X11 nolisten_tcp 2>/dev/null || echo 1)" != "0" ]; then
        echo "[docker_run] XQuartz does not accept network clients. Run:" >&2
        echo "    defaults write org.xquartz.X11 nolisten_tcp 0  # then quit and reopen XQuartz" >&2
        return 1
    fi
    if [ ! -S /tmp/.X11-unix/X0 ]; then
        echo "[docker_run] Starting XQuartz..." >&2
        open -a XQuartz
        for _ in $(seq 1 40); do
            [ -S /tmp/.X11-unix/X0 ] && break
            sleep 0.5
        done
    fi
    # Copy the :0 cookie with its host field wildcarded (family ffff), so it
    # matches however the container's connection reaches the Mac.
    rm -f "$XAUTH_FILE"; touch "$XAUTH_FILE"; chmod 600 "$XAUTH_FILE"
    "$xauth" nlist :0 | sed -e 's/^..../ffff/' | "$xauth" -f "$XAUTH_FILE" nmerge -
    DOCKER_ARGS+=(-e DISPLAY=host.docker.internal:0)
}

setup_display_linux() {
    if [ -z "${DISPLAY:-}" ]; then
        echo "[docker_run] DISPLAY is not set; running without a display." >&2
        return 1
    fi
    rm -f "$XAUTH_FILE"; touch "$XAUTH_FILE"; chmod 600 "$XAUTH_FILE"
    xauth nlist "$DISPLAY" | sed -e 's/^..../ffff/' | xauth -f "$XAUTH_FILE" nmerge -
    DOCKER_ARGS+=(-e "DISPLAY=$DISPLAY" -v /tmp/.X11-unix:/tmp/.X11-unix:rw)
}

if [ "$DISPLAY_ON" = 1 ]; then
    case "$(uname -s)" in
        Darwin) setup_display_macos || DISPLAY_ON=0 ;;
        Linux) setup_display_linux || DISPLAY_ON=0 ;;
        *) DISPLAY_ON=0 ;;
    esac
fi

if [ "$DISPLAY_ON" = 1 ]; then
    # Interactive matplotlib windows; the image defaults to off-screen Agg.
    DOCKER_ARGS+=(-e XAUTHORITY=/tmp/.docker.xauth -v "$XAUTH_FILE:/tmp/.docker.xauth:ro"
                  -e MPLBACKEND=TkAgg -e QT_X11_NO_MITSHM=1)
fi

exec docker run "${DOCKER_ARGS[@]}" "$IMAGE" "$@"

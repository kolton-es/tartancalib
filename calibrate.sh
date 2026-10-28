#!/bin/bash
# Calibrate a camera from a recorded video, end to end (everything after the
# capture), using the tartancalib Docker image.
#
#   ./calibrate.sh DATA_DIR [options] [-- extra tartan_calibrate args]
#
# DATA_DIR holds the recording(s) and the calibration target yaml. For a video
# DATA_DIR/NAME.mp4 the script writes:
#   DATA_DIR/NAME/cam0/<timestamp_ns>.png   frames (reused if already there)
#   DATA_DIR/NAME_results/                  calibration and evaluation output
#     log1-camchain.yaml                    the calibration (TartanCalib pass)
#     log1-results-cam.txt, log1-report-cam.pdf, log.pkl, debug/
#     reprojection/  pinhole/  polar_error.png  distortion.png  logs/
#
# Options:
#   --video FILE    recording to use (default: the newest video in DATA_DIR)
#   --target FILE   target yaml (default: the only *.yaml in DATA_DIR with a
#                   target_type entry)
#   --model NAME    camera model (default: ds-none)
#   --fps N         frames per second to extract (default: 4)
#   --show          show target extraction and the report while calibrating
#   --shuffle       let the calibrator shuffle frames (default: --no-shuffle,
#                   so reruns on the same frames give the same result)
#   --results DIR   results folder (default: DATA_DIR/NAME_results; must be in DATA_DIR)
#   --force         replace an existing results folder
#   --image NAME    Docker image (default: tartancalib)
#
# Updating GRA's camera intrinsics (configs/orins/camera-intrinsics/HOST.json):
#   --host HOST     vehicle, e.g. 10.3.48.228 } both turn the update on
#   --role ROLE     camera role, e.g. front_rgb }
#   --gra-repo DIR  GRA checkout (default: the first parent folder of this
#                   script with configs/orins/camera-intrinsics)
#   --gra-dry-run   show the change without writing it
#   --gra-only      skip calibration and evaluation; export the existing
#                   results folder's log1-camchain.yaml
# The calibration is converted to GRA's opencv_fisheye model in the container
# (tartan_export_gra, fit error reported) with configs/orins bind-mounted.
#
# Everything after `--` is passed to tartan_calibrate, e.g.
#   ./calibrate.sh data -- --min-views-outlier 5
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/docker_run.sh"

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die() { echo "calibrate.sh: $*" >&2; exit 1; }

DATA_DIR=""
VIDEO=""
TARGET=""
MODEL="ds-none"
FPS="4"
SHOW=0
SHUFFLE=0
FORCE=0
RESULTS=""
IMAGE="tartancalib"
EXTRA=()
GRA_HOST=""
GRA_ROLE=""
GRA_REPO=""
GRA_DRY_RUN=0
GRA_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage 0 ;;
        --video) VIDEO="$2"; shift 2 ;;
        --target) TARGET="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --fps) FPS="$2"; shift 2 ;;
        --show) SHOW=1; shift ;;
        --shuffle) SHUFFLE=1; shift ;;
        --force) FORCE=1; shift ;;
        --results) RESULTS="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        --host) GRA_HOST="$2"; shift 2 ;;
        --role) GRA_ROLE="$2"; shift 2 ;;
        --gra-repo) GRA_REPO="$2"; shift 2 ;;
        --gra-dry-run) GRA_DRY_RUN=1; shift ;;
        --gra-only) GRA_ONLY=1; shift ;;
        --) shift; EXTRA=("$@"); break ;;
        -*) die "unknown option $1 (see --help)" ;;
        *) [ -z "$DATA_DIR" ] || die "only one DATA_DIR allowed"; DATA_DIR="$1"; shift ;;
    esac
done
[ -n "$DATA_DIR" ] || usage 1
[ -d "$DATA_DIR" ] || die "no such directory: $DATA_DIR"
DATA_DIR="$(cd "$DATA_DIR" && pwd)"

UPDATE_GRA=0
if [ -n "$GRA_HOST$GRA_ROLE" ]; then
    [ -n "$GRA_HOST" ] && [ -n "$GRA_ROLE" ] || die "--host and --role go together"
    UPDATE_GRA=1
    if [ -z "$GRA_REPO" ]; then
        dir="$SCRIPT_DIR"
        while [ "$dir" != "/" ] && [ ! -d "$dir/configs/orins/camera-intrinsics" ]; do dir="$(dirname "$dir")"; done
        [ "$dir" != "/" ] || die "no GRA checkout above $SCRIPT_DIR; pass --gra-repo"
        GRA_REPO="$dir"
    fi
    [ -d "$GRA_REPO/configs/orins/camera-intrinsics" ] || die "$GRA_REPO has no configs/orins/camera-intrinsics"
    GRA_REPO="$(cd "$GRA_REPO" && pwd)"
    [ -f "$GRA_REPO/configs/orins/camera-intrinsics/$GRA_HOST.json" ] \
        || die "no camera-intrinsics for host $GRA_HOST in $GRA_REPO (known: $(ls "$GRA_REPO/configs/orins/camera-intrinsics" | sed 's/\.json$//' | tr '\n' ' '))"
elif [ "$GRA_ONLY" = 1 ] || [ "$GRA_DRY_RUN" = 1 ]; then
    die "--gra-only and --gra-dry-run need --host and --role"
fi

# Path of a file inside DATA_DIR as the container sees it (/data/...).
container_path() {
    local abs
    abs="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    case "$abs" in
        "$DATA_DIR"/*) echo "/data/${abs#"$DATA_DIR"/}" ;;
        *) die "$1 must be inside $DATA_DIR (it is mounted into the container)" ;;
    esac
}

# --- inputs ------------------------------------------------------------------
if [ -z "$VIDEO" ]; then
    VIDEO="$(ls -t "$DATA_DIR"/*.mp4 "$DATA_DIR"/*.mkv "$DATA_DIR"/*.mov 2>/dev/null | head -n 1 || true)"
    [ -n "$VIDEO" ] || die "no video (*.mp4, *.mkv, *.mov) in $DATA_DIR; pass --video"
    echo "Using the newest recording: $(basename "$VIDEO")"
fi
case "$VIDEO" in /*) ;; *) [ -f "$VIDEO" ] || VIDEO="$DATA_DIR/$VIDEO" ;; esac
[ -f "$VIDEO" ] || die "no such video: $VIDEO"

if [ -z "$TARGET" ]; then
    candidates="$(grep -l '^[[:space:]]*target_type' "$DATA_DIR"/*.yaml 2>/dev/null || true)"
    count="$(printf '%s' "$candidates" | grep -c . || true)"
    [ "$count" = 1 ] || die "found $count target yamls in $DATA_DIR; pass --target"
    TARGET="$candidates"
fi
case "$TARGET" in /*) ;; *) [ -f "$TARGET" ] || TARGET="$DATA_DIR/$TARGET" ;; esac
[ -f "$TARGET" ] || die "no such target yaml: $TARGET"

docker info >/dev/null 2>&1 || die "Docker is not responding; start Docker Desktop and retry"
docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || die "Docker image '$IMAGE' not found; build it with: docker build -t $IMAGE $SCRIPT_DIR"

NAME="$(basename "${VIDEO%.*}")"
FRAMES="$DATA_DIR/$NAME/cam0"
if [ -z "$RESULTS" ]; then
    RESULTS="$DATA_DIR/${NAME}_results"
else
    case "$RESULTS" in /*) ;; *) RESULTS="$DATA_DIR/$RESULTS" ;; esac
fi
C_VIDEO="$(container_path "$VIDEO")"
C_TARGET="$(container_path "$TARGET")"
C_DATASET="/data/$NAME"
mkdir -p "$(dirname "$RESULTS")"
C_RESULTS="$(container_path "$RESULTS")"

if [ "$GRA_ONLY" = 1 ]; then
    [ -f "$RESULTS/log1-camchain.yaml" ] || die "--gra-only: no $RESULTS/log1-camchain.yaml"
    mkdir -p "$RESULTS/logs"
else
    if [ -e "$RESULTS" ]; then
        [ "$FORCE" = 1 ] || die "$RESULTS already exists; pass --force to replace it (or --gra-only to export it)"
        rm -rf "$RESULTS"
    fi
    mkdir -p "$RESULTS/logs" "$RESULTS/debug"
fi

echo "Video:   $VIDEO"
if [ "$GRA_ONLY" != 1 ]; then
    echo "Target:  $TARGET"
    echo "Model:   $MODEL"
fi
echo "Results: $RESULTS"
[ "$UPDATE_GRA" = 1 ] && echo "GRA:     $GRA_REPO/configs/orins/camera-intrinsics/$GRA_HOST.json role $GRA_ROLE$([ "$GRA_DRY_RUN" = 1 ] && echo ' (dry run)')"

# run STEP_NAME [--display] [--mount HOST:CONTAINER] command... :
# run in the container, log to logs/STEP.log
run() {
    local step="$1"; shift
    local opts=(--data "$DATA_DIR" --image "$IMAGE")
    local display=0
    while :; do
        case "$1" in
            --display) display=1; shift ;;
            --mount) opts+=(--mount "$2"); shift 2 ;;
            *) break ;;
        esac
    done
    [ "$display" = 1 ] || opts+=(--no-display)
    local log="$RESULTS/logs/$step.log"
    local start=$SECONDS
    printf '  %-13s ' "$step"
    if "$RUNNER" "${opts[@]}" "$@" > "$log" 2>&1 < /dev/null; then
        echo "done ($((SECONDS - start)) s)"
    else
        echo "FAILED ($((SECONDS - start)) s); last lines of $log:"
        grep -vE 'libGL|Gtk-WARNING|^\s*$' "$log" | tail -n 15 | sed 's/^/      /'
        exit 1
    fi
}

echo "Steps:"
if [ "$GRA_ONLY" != 1 ]; then
# --- 1. frames ---------------------------------------------------------------
if [ -d "$FRAMES" ] && [ -n "$(ls -A "$FRAMES" 2>/dev/null)" ]; then
    echo "  frames        reusing $(ls "$FRAMES" | wc -l | tr -d ' ') existing frames in $FRAMES"
else
    run frames tartan_extract_frames --video "$C_VIDEO" --out "$C_DATASET/cam0" --fps "$FPS"
fi

# --- 2. calibration ----------------------------------------------------------
CALIB=(tartan_calibrate --dataset "$C_DATASET" --cams cam0 --target "$C_TARGET" --models "$MODEL"
       --min-init-corners-autocomplete 29 --min-tag-size-autocomplete 2 --correction-threshold 10.1
       --debug-modes originalprojection reprojectionpoints
       --save_dir "$C_RESULTS/" --debug_image_dir "$C_RESULTS/debug/")
[ "$SHUFFLE" = 1 ] || CALIB+=(--no-shuffle)
if [ "$SHOW" = 1 ]; then
    CALIB+=(--show-extraction)
    [ "$SHOW" = 1 ] && echo "  (close the report window when calibration finishes)"
    run calibrate --display "${CALIB[@]}" ${EXTRA[@]+"${EXTRA[@]}"}
else
    run calibrate "${CALIB[@]}" --dont-show-report ${EXTRA[@]+"${EXTRA[@]}"}
fi
[ -f "$RESULTS/log1-camchain.yaml" ] || die "calibration wrote no log1-camchain.yaml (see $RESULTS/logs/calibrate.log)"

# --- 3. evaluation -----------------------------------------------------------
run reprojection tartan_reprojection --obsfile "$C_RESULTS/log.pkl" --out "$C_RESULTS/reprojection"
run undistort tartan_undistort --cam "$C_RESULTS/log1-camchain.yaml" --images "$C_DATASET/cam0" \
    --out "$C_RESULTS/pinhole"
run polar-error tartan_visualize --obsfile "$C_RESULTS/log.pkl" --out "$C_RESULTS/polar_error.png" --no-show
run distortion kalibr_visualize_distortion --cam "$C_RESULTS/log1-camchain.yaml" \
    --out "$C_RESULTS/distortion.png" --no-show

# --- summary -----------------------------------------------------------------
echo
echo "Calibration ($MODEL): $RESULTS/log1-camchain.yaml"
grep -E 'intrinsics|resolution' "$RESULTS/log1-camchain.yaml" | sed 's/^ */  /'
grep -E 'Extracted corners' "$RESULTS/logs/calibrate.log" | tail -n 1 | sed 's/.*Extracted/  Extracted/'
grep -E 'Processed .* images used' "$RESULTS/logs/calibrate.log" | tail -n 1 | sed 's/^/  /'
grep -E 'reprojection error' "$RESULTS/log1-results-cam.txt" | sed 's/^[[:space:]]*/  /'
grep -E '^Per-frame mean|^Heatmap' "$RESULTS/logs/reprojection.log" | sed 's/^/  /'
grep -E '^Field of view' "$RESULTS/logs/undistort.log" | sed 's/^/  /'
echo
echo "Look at:"
echo "  $RESULTS/log1-report-cam.pdf"
echo "  $RESULTS/reprojection/reprojection_heatmap.png   (per-frame overlays alongside)"
echo "  $RESULTS/pinhole/                                (undistorted frames, pinhole_camera.yaml)"
echo "  $RESULTS/distortion.png, $RESULTS/polar_error.png"
echo "  $RESULTS/debug/                                  (detected/added corners per frame)"
fi  # GRA_ONLY

# --- 4. GRA camera intrinsics ------------------------------------------------
if [ "$UPDATE_GRA" = 1 ]; then
    [ "$GRA_ONLY" = 1 ] || echo
    GRA=(tartan_export_gra --cam "$C_RESULTS/log1-camchain.yaml" --source-file "$(basename "$VIDEO")"
         --out "$C_RESULTS/gra_intrinsics.json" --gra-dir /gra --host "$GRA_HOST" --role "$GRA_ROLE")
    [ "$GRA_DRY_RUN" = 1 ] && GRA+=(--dry-run)
    run gra-export --mount "$GRA_REPO/configs/orins:/gra" "${GRA[@]}"
    grep -vE 'libGL|Gtk-WARNING|^Wrote|^\s*$' "$RESULTS/logs/gra-export.log" | sed 's/^/  /'
    [ "$GRA_DRY_RUN" = 1 ] \
        || echo "  review: git -C $GRA_REPO diff -- configs/orins/camera-intrinsics/$GRA_HOST.json"
fi

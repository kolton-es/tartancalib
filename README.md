# TartanCalib

## Introduction
TartanCalib contributes state-of-the-art calibration for wide-angle lenses, by implementing an iterative calibration pipeline and adaptive subPixel refinement of AprilTags. The code for TartanCalib is built upon the [Kalibr](https://github.com/ethz-asl/kalibr) toolbox, is easy to use, and robust. If you are interested in helping us extend the features of TartanCalib, please reach out to Bart ([email](bduister@andrew.cmu.edu)). 

For more information, visit our project page [here](https://tartancalib.com).

## Installation
This fork has no ROS dependency. It builds on plain Ubuntu 20.04 with catkin
(from Ubuntu's own repositories) and `catkin_tools` (from pip), natively on
amd64 and arm64, including Docker on Apple Silicon Macs.

Differences from upstream TartanCalib:
- Input is a folder of images per camera instead of a rosbag:
  `tartan_calibrate` and `kalibr_calibrate_cameras` take `--dataset DIR --cams cam0 ...`
  (replacing `--bag`/`--topics`; `--bag-from-to` is now `--from-to`).
- Removed with ROS: `kalibr_bagcreater`, `kalibr_bagextractor`,
  `kalibr_camera_focus`, `kalibr_camera_validator`, IMU-camera calibration
  (`kalibr_calibrate_imu_camera`), rolling-shutter calibration
  (`kalibr_calibrate_rs_cameras`) and the VIO config exporters.
- Added: `calibrate.sh` and `docker_run.sh` (below), `tartan_extract_frames`,
  `tartan_reprojection`, `tartan_undistort`, `tartan_export_gra`; the
  visualization tools save figures and work with every camera model
  ([Visualizing results](#visualizing-results)).

### Docker (Preferred)
1. Clone and build the image

        git clone https://github.com/kolton-es/tartancalib
        cd tartancalib
        docker build -t tartancalib .

2. Run it with `docker_run.sh`, which mounts your data folder at `/data` and
   forwards GUI windows (live plots, target extraction, the report) to your
   display. The image sources the workspace for you and puts the tools on
   `PATH`.

        ./docker_run.sh --data /path/to/your/data                  # interactive shell
        ./docker_run.sh --data /path/to/your/data tartan_calibrate --help

   - **macOS:** install XQuartz (`brew install --cask xquartz`) and let it
     accept network clients once: `defaults write org.xquartz.X11 nolisten_tcp 0`,
     then quit and reopen XQuartz. The script starts XQuartz when needed and
     gives the container a copy of its auth cookie; no `xhost +` is required.
   - **Linux:** it forwards `$DISPLAY` and `/tmp/.X11-unix` with the same cookie.
   - `--no-display` runs headless (plots render off-screen with
     `MPLBACKEND=Agg`; pass `--dont-show-report` to `tartan_calibrate`).
   - `--dev` mounts this checkout over the image's source, so Python edits take
     effect without rebuilding; C++ changes still need `docker build`. Right
     after replacing a file, Docker Desktop's file sharing can briefly serve
     the old contents; rerun if a script looks truncated.
   - `--mount HOST_PATH:CONTAINER_PATH` adds a bind mount (repeatable).

   Plain `docker run --rm -v /path/to/your/data:/data tartancalib ...` also
   works for headless runs.

### Local Installation (Ubuntu 20.04)
1. Install dependencies.

        sudo apt-get update && sudo apt-get install -y \
        build-essential cmake git \
        catkin python3-catkin-pkg python3-pip python-is-python3 \
        python3-dev python3-numpy python3-scipy python3-matplotlib python3-yaml \
        python3-opencv python3-tk python3-igraph python3-wxgtk4.0 \
        libeigen3-dev libboost-all-dev libsuitesparse-dev libopencv-dev \
        libpoco-dev libtbb-dev libblas-dev liblapack-dev libv4l-dev libglew-dev
        pip3 install catkin-tools==0.9.4 dill==0.4.0

2. Clone and build the repository

        mkdir -p ~/tartan_ws/src && cd ~/tartan_ws/src
        git clone https://github.com/kolton-es/tartancalib
        cd ..
        catkin init
        catkin config --cmake-args -DCMAKE_BUILD_TYPE=Release -DCATKIN_ENABLE_TESTING=OFF
        catkin build

3. Source the workspace and put the tools on `PATH`

        source ~/tartan_ws/devel/setup.bash
        export PATH=~/tartan_ws/devel/lib/kalibr:$PATH

4. Follow the [Usage](#usage) section to get calibrating!

## Usage
### From a recording, in one command
`calibrate.sh` runs every step after the capture in the Docker image: it cuts
the video into frames, calibrates, and writes the evaluation outputs
(reprojection overlays and heatmap, undistorted pinhole frames, distortion and
polar-error plots).

        ./calibrate.sh DATA_DIR [--video FILE] [--target FILE] [--model ds-none] [--fps 4]
                       [--show] [--results DIR] [--force] [--host HOST --role ROLE]

`DATA_DIR` holds the recording (default: its newest video) and the target yaml
(default: the only yaml in it with a `target_type`). For `DATA_DIR/NAME.mp4`
the frames go to `DATA_DIR/NAME/cam0/` and everything else to
`DATA_DIR/NAME_results/` (the calibration is `log1-camchain.yaml`; step logs
are in `logs/`). `--show` displays target extraction and the report, `--force`
replaces an existing results folder, `--results` puts the output elsewhere in
`DATA_DIR`, and arguments after `--` go to `tartan_calibrate`. Frames are
processed in a fixed order (`--no-shuffle`) so reruns give the same result;
`--shuffle` restores the calibrator's random order. For very wide lenses use
`ds-none` (the default) or `eucm-none`: Kalibr's `pinhole-equi`
initialization has returned NaN on a 152 deg lens. See `./calibrate.sh --help`. The steps below are what it
does, for running them by hand.

With `--host HOST --role ROLE` it also writes the result into a GRA checkout's
`configs/orins/camera-intrinsics/HOST.json` (`gra.camera_intrinsics.v1`).
GRA takes OpenCV fisheye (Kannala-Brandt k1..k4) intrinsics, so
`tartan_export_gra` fits that model to the calibration over the whole image
and records the fit error (`fit_error_px`); it runs in the container with
`configs/orins` bind-mounted. The role's device fields are kept, other roles
are untouched, and it warns when the role's `camera-extrinsics` transforms
were solved with the previous intrinsics. `--gra-dry-run` shows the change
without writing it, `--gra-only` exports an existing results folder, and
`--gra-repo` points at the checkout (default: the first parent folder of the
script that has `configs/orins/camera-intrinsics`).

        ./calibrate.sh data --video rec.mp4 --host 10.3.48.228 --role front_rgb

### Step 1 - Create an image dataset

Put each camera's images in its own folder under one dataset folder, named by
their timestamp in integer nanoseconds (PNG, JPEG, BMP or TIFF; colour and
16-bit images are converted to 8-bit grey):

        dataset/
          cam0/1700000000000000000.png
          cam0/1700000000250000000.png
          ...
          cam1/1700000000000000000.png

For multiple cameras, images taken at the same time must carry timestamps
within `--approx-sync` seconds of each other. `tartan_extract_frames` cuts a
video into such a folder (4 frames per second by default):

        tartan_extract_frames --video video.mp4 --out dataset/cam0 --fps 4


### Step 2 - Define calibration board through YAML files

Kalibr supports three different calibration targets with different parameters associated to each target. Kalibr's [wiki](https://github.com/ethz-asl/kalibr/wiki/calibration-targets) has more information on calibration targets in YAML. An example of an aprilgrid YAML file is provided below:

        #example for aprilgrid
        target_type: 'aprilgrid' #gridtype
        tagCols: 10                 #number of apriltags
        tagRows: 7                  #number of apriltags
        tagSize: 0.025              #size of apriltag, edge to edge [m]
        tagSpacing: 0.3             #ratio of space between tags to tagSize
                                    #example: tagSize=2m, spacing=0.5m --> tagSpacing=0.25[-]

The method should also work with checkerboards but would require some adaptation. In general grids of AprilTags are most robust.

### Step 3 - Run calibration

This is sample code for running calibration with certain parameters changed. Please refer to the table below for the full range of configurable parameters.

        tartan_calibrate \
        --dataset /path/to/dataset \
        --target /path/to/target.yaml \
        --cams cam0 cam1 \
        --min-init-corners-autocomplete 29 \
        --min-tag-size-autocomplete 2 \
        --correction-threshold 10.1 \
        --models omni-radtan omni-radtan \
        --dont-show-report \
        --save_dir /path/to/output/

<br>


Below is a table of basic parameters to get TartanCalib running. You will minimally have to configure the following parameters.

| Basic Parameter                     | Description                                                                           |
| ----------------------------- | -----------                                                                           |
| dataset                       | Path to the dataset folder holding one image folder per camera (see Step 1).          |
| target                        | Path to target YAML files.                                                            |
| cams                          | List of camera folders within the dataset to calibrate, e.g. `--cams cam0 cam1 cam2`. Note that ordering here has to match ordering within --models |
| models                        | Choose the camera/distortion model pair to be fitted. The following choices are currently available: `pinhole-radtan`, `pinhole-equi`, `pinhole-fov`, `omni-none`, `omni-radtan`, `eucm-none`, `ds-none`. For more details on supported models, check out Kalibr's [documentation](https://github.com/ethz-asl/kalibr/wiki/supported-models). |  
| log_dest                      | Save filename of logs. All output filenames will begin with this parameter. (Default: log)|
| save_dir                      | Save directory of YAML files containing calibration information, and a pickle with log data. Must end with a trailing slash. (Default: /data/) |
| debug_image_dir               | Save directory of PNG files for debugging. Must be an existing folder, and debug_image_dir must end with a trailing slash if a folder is specified. Images are saved by default to your workspace folder. (Default: '') |

<br>
  
Below is a table of advanced parameters if you'd like to have greater control over TartanCalib's algorithm.

| Advanced Parameter | Description |
| ------------------ | ----------- |
| outputMatlab                  | When selected, outputs Matlab matrix for use in BabelCalib (or similar). |
| from-to                       | Only use images from this many seconds after the first image up to this many seconds (e.g. `--from-to 5 60`). |
| projections                   | Choose from four possible modes: `cornerpredictor`, `pinhole`, `homography`, and `none`. `Cornerpredictor` is the autocomplete method described within the paper, and is recommended for best results. |
| debug-modes                   | Debug images written to `debug_image_dir`: `originalprojection` (each frame with original and added corners) and `reprojectionpoints` (all corners in one image) work with every projection mode; `pinholeprojection` and `individualprojections` only produce output with `--projections pinhole`; `targetpointcloud` opens a window and needs a display. |
| fovs                          | When using pinhole projection mode, this parameter represents FOV of pinhole. This argument accepts multiple pinholes corresponding to each camera. For example, if you calibrate two cameras, `--cams cam0 cam1`, to generate three pinholes of FOVs 30, 60, 90 for `cam0` and one pinhole of fov 90 for `cam1`, use `--fovs 30 60 90 --fovs 90`. Note that the number of arguments for fovs must correspond with poses and resolutions.           |
| poses                         | When using pinhole projection mode, this parameter represents pose of pinhole. As with fovs, this argument can be configured for multiple projections.          |
| resolutions                   | When using pinhole projection mode, this parameter represents resolution of pinhole. As with fovs, this argument can be configured for multiple projections. |
| min-init-corners-autocomplete | The algorithm minimally requires this number of corners for autocomplete. With values that are too small, the pose of the board might be too uncertain for accurate results. (Default: 24)|
| min-tag-size-autocomplete     | Minimum size (px) a tag has to be before being autocompleted. This ensures small tags below a certain size are excluded instead of being detected poorly and affecting calibration. (Default: 0.0)|
| correction-threshold          | Offset (px) between reprojection and detection allowed. (Default: 10.0) |
| min-resize-window-size        | Minimum window size (px) allowed during dynamic sizing. (Default: 2) |
| max-resize-window-size        | Maximum window size (px) allowed during dynamic sizing. (Default: 8) |
| symmetry-refinement           | If included, symmetry refinement, an experimental feature, will be enabled. |
| symmetry-edge-threshold       | When symmetry refinement is active, checks if detections are too close to border of pixels. (Default: 10.0) |

### Step 4 - Output
The output YAML files will be found in the directory you've specified in `save_dir`.

TartanCalib runs in two iterations. The output file using enhancements from TartanCalib may be found in `log1-camchain.yaml`. The YAML file will contain distortion coefficients for the distortion model used, as well as intrinsics for the camera being calibrated. For multi-camera calibration, the YAML file will also include extrinsics between different cameras.

For more information on the output format, refer to Kalibr's [wiki](https://github.com/ethz-asl/kalibr/wiki/yaml-formats).

## Visualizing results
Live windows need a display (see [Docker](#docker-preferred)); every tool
below can also write its figure to a file.

| What | How | Shows |
|---|---|---|
| Calibration report | Written to `<save_dir>/<log_dest>1-report-cam.pdf`; shown on screen at the end of the run (close it to exit) unless `--dont-show-report` or `--verbose` | Reprojection error against polar and azimuthal angle, all residuals, removed outlier corners |
| Detected / added corners | `tartan_calibrate --debug-modes originalprojection --debug_image_dir DIR/` | Each frame with Kalibr's corners (red) and the corners TartanCalib added (green) |
| Coverage | `tartan_calibrate --debug-modes reprojectionpoints --debug_image_dir DIR/` | Every detected corner over all frames in one image |
| Target extraction | `tartan_calibrate --show-extraction` | Tag detection on each frame as it is processed |
| Views as they are added | `tartan_calibrate --plot` | Reprojection errors after each accepted view; close each window to continue |
| Outliers | `tartan_calibrate --plot-outliers` | Each view with corners removed as outliers; filtering only starts after `--min-views-outlier` (default 20) views are in the solution |
| Error by polar angle | `tartan_visualize --obsfile <save_dir>/log.pkl [--out FILE] [--no-show]` | Binned reprojection error against angle from the optical axis, one curve per iteration (or per `--cams` model) |
| Distortion | `kalibr_visualize_distortion --cam <camchain.yaml> [--out FILE] [--no-show]` | Rectangles in an ideal pinhole (blue) and where the same rays land in the calibrated camera (red), with rings at fixed angles from the optical axis |
| Camera rig | `kalibr_visualize_calibration --cam <camchain.yaml> [--out FILE] [--no-show]` | 3D camera frusta and frames of a camchain |
| Undistortion to pinhole | `tartan_undistort --cam <camchain.yaml> --images DIR_OR_FILES [--out DIR] [--show]` | Each image resampled into one ideal pinhole camera holding the entire field of view (up to `--max-angle`, default 85 deg); writes `<name>_pinhole.png` and the pinhole intrinsics (`pinhole_camera.yaml`). `--scale`/`--max-size` set the output focal length and size |
| Reprojection with the final model | `tartan_reprojection --obsfile <save_dir>/log.pkl [--out DIR] [--show]` | Each calibration frame with detected (green) and reprojected (red) corners and magnified error vectors; writes per-frame errors to `errors.csv`. Also writes `reprojection_heatmap.png`: the mean error per pixel over every frame it went through (unmeasured pixels interpolated; `--heatmap-bin N` averages over NxN cells), overlaid on the last frame it touched, with a colour bar marking the min and max (data in `reprojection_heatmap.npy`). The pose is fitted per frame with the final intrinsics |

## Authors
* Bardienus P. Duisterhof ([email](bduister@andrew.cmu.edu))
* Yaoyu Hu
* Si Heng Teng ([email](sihengt@andrew.cmu.edu))
* Michael Kaess
* Sebastian Scherer

## References
The calibration approaches used in TartanCalib are documented in the following paper. Please cite this paper, and the appropriate papers on [Kalibr's](https://github.com/ethz-asl/kalibr/) repository when using this toolbox or parts of it in an academic publication.

        @article{duisterhof2022tartancalib,
          title={TartanCalib: Iterative Wide-Angle Lens Calibration using Adaptive SubPixel Refinement of AprilTags},
          author={Duisterhof, Bardienus P and Hu, Yaoyu and Teng, Si Heng and Kaess, Michael and Scherer, Sebastian},
          journal={arXiv preprint arXiv:2210.02511},
          year={2022}
        }

## Acknowledgments
This work is built upon the [Kalibr](https://github.com/ethz-asl/kalibr) toolbox.

## Licenses 
### TartanCalib (The Clear BSD)
Copyright (c) 2022 AirLab
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted (subject to the limitations in the disclaimer
below) provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

NO EXPRESS OR IMPLIED LICENSES TO ANY PARTY'S PATENT RIGHTS ARE GRANTED BY
THIS LICENSE. THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

### Kalibr (BSD)
Copyright (c) 2014, Paul Furgale, Jérôme Maye and Jörn Rehder, Autonomous Systems Lab, ETH Zurich, Switzerland<br>
Copyright (c) 2014, Thomas Schneider, Skybotix AG, Switzerland<br>
All rights reserved.<br>

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

3. All advertising materials mentioning features or use of this software must display the following acknowledgement: This product includes software developed by the Autonomous Systems Lab and Skybotix AG.

4. Neither the name of the Autonomous Systems Lab and Skybotix AG nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE AUTONOMOUS SYSTEMS LAB, SKYBOTIX AG ''AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTONOMOUS SYSTEMS LAB OR SKYBOTIX AG BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

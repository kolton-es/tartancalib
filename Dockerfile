FROM ubuntu:20.04

# Plain Ubuntu 20.04, no ROS. catkin (the CMake build tool) comes from Ubuntu's
# universe repository and catkin_tools from pip; nothing is pulled from
# packages.ros.org. Builds natively on amd64 and arm64 (e.g. Apple Silicon).
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates \
        catkin python3-catkin-pkg python3-pip python-is-python3 \
        python3-dev python3-numpy python3-scipy python3-matplotlib python3-yaml \
        python3-opencv python3-tk python3-igraph python3-wxgtk4.0 \
        libeigen3-dev libboost-all-dev libsuitesparse-dev libopencv-dev \
        libpoco-dev libtbb-dev libblas-dev liblapack-dev libv4l-dev libglew-dev \
 && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir catkin-tools==0.9.4 dill==0.4.0

ENV WORKSPACE=/catkin_ws
RUN mkdir -p $WORKSPACE/src \
 && cd $WORKSPACE \
 && catkin init \
 && catkin config --cmake-args -DCMAKE_BUILD_TYPE=Release -DCATKIN_ENABLE_TESTING=OFF

COPY . $WORKSPACE/src/kalibr
RUN cd $WORKSPACE && catkin build -j$(nproc)

# Ubuntu's GTK settings name the Yaru themes, which --no-install-recommends
# leaves out; wx windows then warn about missing stock icons.
RUN sed -i -e 's/^gtk-theme-name = .*/gtk-theme-name = Adwaita/' \
           -e 's/^gtk-icon-theme-name = .*/gtk-icon-theme-name = Humanity/' \
           /etc/gtk-3.0/settings.ini

# wxPython (report and --plot windows) sets an en_US locale on start and shows
# an error dialog when it is missing. ffmpeg cuts recordings into frames
# (tartan_extract_frames).
RUN apt-get update && apt-get install -y --no-install-recommends locales ffmpeg \
 && rm -rf /var/lib/apt/lists/* \
 && locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# Use the manual focal length prompt if initialization fails
# (https://github.com/ethz-asl/kalibr/pull/346); render plots off-screen.
ENV KALIBR_MANUAL_FOCAL_LENGTH_INIT=1 \
    MPLBACKEND=Agg \
    PATH=$WORKSPACE/devel/lib/kalibr:$PATH

# catkin's setup scripts parse "$@" (e.g. --help, --extend), so source them
# with no arguments and only then run the command.
RUN printf '%s\n' '#!/bin/bash' 'args=("$@")' 'set --' \
        "source $WORKSPACE/devel/setup.bash" 'exec "${args[@]}"' > /entrypoint.sh \
 && chmod +x /entrypoint.sh
WORKDIR /data
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]

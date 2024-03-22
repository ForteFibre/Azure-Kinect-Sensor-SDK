#!/bin/bash

set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y libgl1-mesa-dev \
            libsoundio-dev \
            libjpeg-dev \
            libvulkan-dev \
            libx11-dev \
            libxcursor-dev \
            libxinerama-dev \
            libxrandr-dev \
            libusb-1.0-0-dev \
            libssl-dev \
            libudev-dev \
            libopencv-dev \
            mesa-common-dev \
            uuid-dev \
            build-essential \
            cmake \
            git \
            pkg-config \
            sudo

git config --global --add safe.directory /__w/Azure-Kinect-Sensor-SDK/Azure-Kinect-Sensor-SDK
git submodule update --init --recursive

mkdir build
cd build
cmake .. -DCUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda -DCMAKE_BUILD_TYPE=Release -DCPACK_PACKAGE_CONTACT=ForteFibre
make -j

cpack -G DEB
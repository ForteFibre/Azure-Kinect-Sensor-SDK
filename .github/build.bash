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
            libgtk-3-dev \
            libopencv-dev \
            mesa-common-dev \
            uuid-dev \
            build-essential \
            cmake \
            git \
            pkg-config \
            sudo

mkdir build
cd build
cmake .. -DCUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda \
 -DCMAKE_BUILD_TYPE=Release -DCPACK_PACKAGE_CONTACT=ForteFibre \
 -DOpenGL_GL_PREFERENCE=GLVND
make -j

cpack -G DEB
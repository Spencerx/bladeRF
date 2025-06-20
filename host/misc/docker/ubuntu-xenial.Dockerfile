# This file is part of the bladeRF project:
#   http://www.github.com/nuand/bladeRF
#
# Copyright (c) 2025 Nuand LLC.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

FROM ubuntu:xenial

LABEL maintainer="Nuand LLC <bladeRF@nuand.com>"
LABEL version="0.0.2"
LABEL description="CI build environment for the bladeRF project"
LABEL com.nuand.ci.distribution.name="Ubuntu"
LABEL com.nuand.ci.distribution.codename="xenial"
LABEL com.nuand.ci.distribution.version="16.04"

# Install things
RUN apt-get update \
 && apt-get install -y \
        build-essential \
        clang \
        cmake \
        doxygen \
        git \
        help2man \
        libcurl4-openssl-dev \
        libedit-dev \
        libncurses5-dev \
        libncurses-dev \
        libncursesw5-dev \
        libssl-dev \
        libusb-1.0-0-dev \
        pandoc \
        pkg-config \
        usbutils \
        wget \
 && apt-get clean

# Custom compile cmake because the version provided in the xenial repos is too old for our cmake scripts
RUN version=3.28 \
&& build=1 \
&& mkdir ~/temp \
&& cd ~/temp \
&& wget -nv https://cmake.org/files/v$version/cmake-$version.$build.tar.gz \
&& tar -xzf cmake-$version.$build.tar.gz \
&& cd cmake-$version.$build/ \
&& ./bootstrap --parallel=$(nproc) --no-debugger \
&& make -j$(nproc) \
&& make install

# Copy in our build context
COPY --from=nuand/bladerf-buildenv:base /root/bladeRF /root/bladeRF
COPY --from=nuand/bladerf-buildenv:base /root/.config /root/.config
WORKDIR /root/bladeRF

# Build arguments
ARG compiler=gcc
ARG buildtype=Release
ARG taggedrelease=NO
ARG parallel=1

RUN ${compiler} --version

# Do the build!
RUN cd /root/bladeRF/ \
 && mkdir -p build \
 && cd build \
 && cmake \
        -DBUILD_DOCUMENTATION=ON \
        -DCMAKE_C_COMPILER=${compiler} \
        -DCMAKE_BUILD_TYPE=${buildtype} \
        -DENABLE_FX3_BUILD=OFF \
        -DENABLE_HOST_BUILD=ON \
        -DTAGGED_RELEASE=${taggedrelease} \
        ../ \
 && make -j${parallel} \
 && make install \
 && ldconfig
    
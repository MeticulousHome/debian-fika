#!/bin/bash
set -eo pipefail

DOCKER_IMAGE=meticulous_deb_builder
NXP_DEB_DIR=./debs/nxp

if (($EUID != 0)); then
    echo "Please run as root"
    exit
fi

docker build -t ${DOCKER_IMAGE} .

# Build the imx-gpu-viv deb package
git -C ./modules/imx-gpu-viv-deb clean -xfd
docker run --platform arm64 --rm -v $NXP_DEB_DIR:/debs -v ./modules/imx-gpu-viv-deb:/debs/workspace ${DOCKER_IMAGE} /bin/bash -c "\
    cd /debs/workspace && \
    dpkg-buildpackage -b -rfakeroot -us -uc"


# # Build the libdrm-imx deb package
docker run --platform arm64 --rm -v $NXP_DEB_DIR:/debs -v ./modules/libdrm-imx-deb:/debs/workspace ${DOCKER_IMAGE} /bin/bash -c "\
    cd /debs/workspace && \
    apt install -y -o Debug::pkgProblemResolver=yes /debs/imx-gpu-viv*.deb && \
    DEBIAN_FRONTEND=noninteractive mk-build-deps -r -i debian/control -t 'apt-get -y -o Debug::pkgProblemResolver=yes --no-install-recommends' && \
    dpkg-buildpackage -b -rfakeroot -us -uc"

# Build the libg2d-viv deb package
git -C ./modules/libg2d-viv-deb clean -xfd
docker run --platform arm64 --rm -v $NXP_DEB_DIR:/debs -v ./modules/libg2d-viv-deb:/debs/workspace ${DOCKER_IMAGE} /bin/bash -c "\
    cd /debs/workspace && \
    apt install -y -o Debug::pkgProblemResolver=yes /debs/imx-gpu-viv*.deb && \
    DEBIAN_FRONTEND=noninteractive mk-build-deps -r -i debian/control -t 'apt-get -y -o Debug::pkgProblemResolver=yes --no-install-recommends' && \
    dpkg-buildpackage -b -rfakeroot -us -uc"


# Build the wayland-protocols-imx deb package
git -C ./modules/wayland-protocols-imx-deb/ clean -xdf debian || true
docker run --platform arm64 --rm -v $NXP_DEB_DIR:/debs -v ./modules/wayland-protocols-imx-deb:/debs/workspace ${DOCKER_IMAGE} /bin/bash -c "\
    cd /debs/workspace && \
    DEBIAN_FRONTEND=noninteractive mk-build-deps -r -i debian/control -t 'apt-get -y -o Debug::pkgProblemResolver=yes --no-install-recommends' && \
    dpkg-buildpackage -b -rfakeroot -us"


# Build the weston-imx deb package
git -C ./modules/weston-imx-deb clean -xdf debian
docker run --platform arm64 --rm -v $NXP_DEB_DIR:/debs -v ./modules/weston-imx-deb:/debs/workspace ${DOCKER_IMAGE} /bin/bash -c "\
    cd /debs/workspace && \
    apt-get update && \
    apt build-dep -y weston && \
    apt install -y libseat-dev && \
    apt install -y -o Debug::pkgProblemResolver=yes /debs/imx-gpu-viv*.deb && \
    apt install -y -o Debug::pkgProblemResolver=yes /debs/libg2d-viv*.deb && \
    apt install -y -o Debug::pkgProblemResolver=yes /debs/libdrm*.deb && \
    apt install -y -o Debug::pkgProblemResolver=yes /debs/wayland-protocols-imx*.deb && \
    dpkg-buildpackage -b -rfakeroot -us -uc -d"

rm -rf $NXP_DEB_DIR/workspace
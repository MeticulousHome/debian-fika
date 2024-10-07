#!/bin/bash
set -eo pipefail

if (($EUID != 0)); then
    echo "Please run as root"
    exit
fi

USERNAME=meticulous
ROOTFS_BASE=rootfs

rm -rf ${ROOTFS_BASE}
mkdir ${ROOTFS_BASE}

if [ -n "${EXTRA_PACKAGES}" ]; then
	echo "Extra packages: ${EXTRA_PACKAGES}"
	EXTRA_PACKAGES=$(echo ${EXTRA_PACKAGES} | tr ' ' ',')
fi

INCLUDE_PACKAGES="locales,openssh-server,ethtool,hostapd,ifupdown,wpasupplicant,systemd,\
base-passwd,busybox,dbus,init,login,util-linux,nano,ntp,dosfstools,\
net-tools,network-manager,alsa-utils,usbutils,gpiod,iperf3,bluetooth,bluez,\
bluez-tools,bluez-obexd,pmount,pm-utils,rng-tools-debian,dbus-user-session,libpam-systemd,\
iptables,seatd,pulseaudio,parted,avahi-daemon,zstd,nginx,ssl-cert,exfatprogs,firmware-brcm80211,\
libubootenv-tool,${EXTRA_PACKAGES}"

debootstrap --verbose  --foreign --arch arm64 --variant=minbase --merged-usr --include "${INCLUDE_PACKAGES}" bookworm ${ROOTFS_BASE}/

cp /usr/bin/qemu-aarch64-static ${ROOTFS_BASE}/bin/
systemd-nspawn -D ${ROOTFS_BASE}/ /debootstrap/debootstrap --second-stage --verbose
rm -rf ${ROOTFS_BASE}/debootstrap

cp sources.list ${ROOTFS_BASE}/etc/apt/sources.list

echo imx8mn-var-som > ${ROOTFS_BASE}/etc/hostname

systemd-nspawn -D ${ROOTFS_BASE}/ apt update
systemd-nspawn -D ${ROOTFS_BASE}/ apt dist-upgrade -y

sed -i -e 's/#PermitRootLogin.*/PermitRootLogin\tyes/g' ${ROOTFS_BASE}/etc/ssh/sshd_config

systemd-nspawn -D ${ROOTFS_BASE}/ /bin/bash -c 'echo "\
locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8 \
locales locales/default_environment_locale select en_US.UTF-8  \
openssh-server openssh-server/permit-root-login select true \
" | debconf-set-selections'

systemd-nspawn -D ${ROOTFS_BASE}/ useradd -m -G audio -s /bin/bash ${USERNAME} || true
systemd-nspawn -D ${ROOTFS_BASE}/ usermod -a -G video ${USERNAME}
systemd-nspawn -D ${ROOTFS_BASE}/ bash -c "echo \\"${USERNAME}:${USERNAME}\\" | chpasswd"
systemd-nspawn -D ${ROOTFS_BASE}/ bash -c 'echo "root:root" | chpasswd'

# add users to pulse-access group
systemd-nspawn -D ${ROOTFS_BASE}/ usermod -a -G pulse-access root
systemd-nspawn -D ${ROOTFS_BASE}/ usermod -a -G pulse-access ${USERNAME}
# update pulse home directory
systemd-nspawn -D ${ROOTFS_BASE}/ usermod -d /var/run/pulse pulse

echo "HandlePowerKey=ignore" >> ${ROOTFS_BASE}/etc/systemd/logind.conf

rm -rf ${ROOTFS_BASE}/etc/systemd/user/sockets.target.wants/pulseaudio.socket
rm -rf ${ROOTFS_BASE}/etc/systemd/user/default.target.wants/pulseaudio.service
rm -f ${ROOTFS_BASE}/etc/xdg/autostart/pulseaudio.desktop

# remove pm-utils default scripts we later install wifi / bt pm-utils script
rm -rf ${ROOTFS_BASE}/usr/lib/pm-utils/sleep.d/
rm -rf ${ROOTFS_BASE}/usr/lib/pm-utils/module.d/
rm -rf ${ROOTFS_BASE}/usr/lib/pm-utils/power.d/

systemd-nspawn -D ${ROOTFS_BASE}/ --bind debs:/opt/debs apt install -y \
	/opt/debs/variscite/imx-firmware-epdc_8.8-var02_arm64.deb \
	/opt/debs/variscite/imx-firmware-sdma_8.8-var02_arm64.deb \
	/opt/debs/variscite/imx-firmware-vpu_8.8-var02_arm64.deb

systemd-nspawn -D ${ROOTFS_BASE}/ --bind debs:/opt/debs bash -c "apt install -y \
	/opt/debs/nxp/imx-gpu-viv-wayland*.deb \
	/opt/debs/nxp/libdrm-common_*.deb \
	/opt/debs/nxp/libdrm-vivante1_*.deb \
	/opt/debs/nxp/libdrm2_*.deb \
	/opt/debs/nxp/libg2d-viv_*.deb \
	/opt/debs/nxp/libweston-12-0_*.deb \
	/opt/debs/nxp/wayland-protocols-imx_*.deb \
	/opt/debs/nxp/weston_*.deb"

systemd-nspawn -D ${ROOTFS_BASE}/ ln -sf /bin/busybox /bin/usleep

rm -f ${ROOTFS_BASE}-base.tar.gz
pushd ${ROOTFS_BASE}
tar cf ../${ROOTFS_BASE}-base.tar.gz -I pigz --exclude=sys --exclude=proc --exclude=dev *
popd
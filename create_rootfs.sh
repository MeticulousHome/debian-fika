#!/bin/bash
set -eo pipefail

print_red() {
	echo -e "\033[0;31m$1\033[0m"
}
 
if (($EUID != 0)); then
    print_red "Please run as root"
    exit
fi


USERNAME=meticulous
ROOTFS_BASE=rootfs
DISTRO=trixie


for arg in "$@"; do
	if [ "$arg" == "--inplace" ]; then
		INPLACE=1
		print_red "Using inplace rootfs: ${ROOTFS_BASE}"
		break
	fi
done

if [ -z ${INPLACE} ]; then
	print_red "Creating new rootfs: ${ROOTFS_BASE}"
	rm -rf ${ROOTFS_BASE}
	mkdir ${ROOTFS_BASE}
fi


if [ -n "${EXTRA_PACKAGES}" ]; then
	print_red "Extra packages: ${EXTRA_PACKAGES}"
	EXTRA_PACKAGES=$(echo ${EXTRA_PACKAGES} | tr ' ' ',')
fi

INCLUDE_PACKAGES="locales,openssh-server,ethtool,hostapd,ifupdown,wpasupplicant,systemd,\
base-passwd,busybox,bc,dbus,init,login,util-linux,nano,dosfstools,\
net-tools,network-manager,alsa-utils,usbutils,gpiod,bluetooth,bluez,\
bluez-tools,bluez-obexd,pmount,pm-utils,rng-tools-debian,dbus-user-session,libpam-systemd,\
iptables,seatd,pulseaudio,parted,avahi-daemon,zstd,nginx,ssl-cert,exfatprogs,\
libubootenv-tool,i2c-tools,e2fsprogs,\
libdrm2,libdrm-common,libdrm-etnaviv1,weston,wayland-protocols,xwayland,\
systemd-oomd,pv,htop,wireless-regdb,pwgen,\
${EXTRA_PACKAGES}"

INCLUDE_PACKAGES=$(echo ${INCLUDE_PACKAGES} | tr ',' ' ')

BACKPORT_PACKAGES=""

print_red "Starting rootfs creation..."
debootstrap --verbose  --foreign --arch arm64 --variant=minbase --include "console-setup,locales,util-linux" --merged-usr ${DISTRO} ${ROOTFS_BASE}/

print_red "Running second stage of debootstrap..."
cp /usr/bin/qemu-aarch64-static ${ROOTFS_BASE}/bin/
systemd-nspawn -D ${ROOTFS_BASE}/ /debootstrap/debootstrap --second-stage --verbose
rm -rf ${ROOTFS_BASE}/debootstrap

cp sources.list ${ROOTFS_BASE}/etc/apt/sources.list
sed -i "s/__DISTRO__/${DISTRO}/g" ${ROOTFS_BASE}/etc/apt/sources.list
echo imx8mn-var-som > ${ROOTFS_BASE}/etc/hostname

print_red "Updating sources..."
systemd-nspawn -D ${ROOTFS_BASE}/ apt update
systemd-nspawn -D ${ROOTFS_BASE}/ apt dist-upgrade -y
print_red "Installing packages..."
systemd-nspawn -D ${ROOTFS_BASE}/ apt install -y ${INCLUDE_PACKAGES}

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

systemd-nspawn -D ${ROOTFS_BASE}/ ln -sf /bin/busybox /bin/usleep

if [ ! -z "${BACKPORT_PACKAGES}" ]; then
	echo "deb http://deb.debian.org/debian ${DISTRO}-backports main non-free-firmware" >> ${ROOTFS_BASE}/etc/apt/sources.list
	echo "deb-src http://deb.debian.org/debian ${DISTRO}-backports main non-free-firmware" >> ${ROOTFS_BASE}/etc/apt/sources.list
	systemd-nspawn -D ${ROOTFS_BASE}/ apt update
	systemd-nspawn -D ${ROOTFS_BASE}/ apt install -y -t bookworm-backports ${BACKPORT_PACKAGES}
fi

print_red "Compressing rootfs..."

rm -f ${ROOTFS_BASE}-base.tar.gz
pushd ${ROOTFS_BASE}
tar cf ../${ROOTFS_BASE}-base.tar.gz -I pigz --exclude=sys --exclude=proc --exclude=dev *
popd

print_red "Rootfs creation completed: ${ROOTFS_BASE}-base.tar.gz"

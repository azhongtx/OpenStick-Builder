#!/bin/sh -e

export CHROOT=${CHROOT=$(pwd)/rootfs}
export HOST_NAME=${HOST_NAME=alpine}
export RELEASE=${RELEASE=v3.24}
export PMOS_RELEASE=${PMOS_RELEASE=v25.12}
export MIRROR=${MIRROR=http://dl-cdn.alpinelinux.org/alpine}
export PMOS_MIRROR=${PMOS_MIRROR=http://mirror.postmarketos.org/postmarketos}
# China mirror used for the *built device's* runtime apk (faster on the stick in CN).
# Build-time apk still uses the official MIRROR above (fast in CI).
export CHINA_MIRROR=${CHINA_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine}
export APK_STATIC_URL=https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v3.0.6/x86_64/apk.static
# Pre-extracted kernel modules + firmware + low-level firmware from the device flash package
export PREBUILT=${PREBUILT=prebuilt/ufi103s}

[ -d "${PREBUILT}/lib/modules" ] || { echo "ERROR: ${PREBUILT}/lib/modules missing; run scripts/extract_prebuilt.sh first"; exit 1; }

rm -rf ${CHROOT}

mkdir -p ${CHROOT}/etc/apk
cat << EOF >  ${CHROOT}/etc/apk/repositories
${CHINA_MIRROR}/${RELEASE}/main
${CHINA_MIRROR}/${RELEASE}/community
@pmos ${PMOS_MIRROR}/${PMOS_RELEASE}
EOF

cp /etc/resolv.conf ${CHROOT}/etc/

mkdir -p ${CHROOT}/usr/bin
cp $(which qemu-aarch64-static) ${CHROOT}/usr/bin

[ -e apk.static ] || wget ${APK_STATIC_URL}; chmod a+x apk.static

./apk.static add -p ${CHROOT} --initdb -U --arch aarch64 --allow-untrusted alpine-base

# install apps
# NOTE: we deliberately do NOT install linux-postmarketos-qcom-msm8916 here.
# The kernel comes from the device's stock boot.img (kept untouched); we only
# copy that kernel's matching /lib/modules and /lib/firmware from PREBUILT.
# ModemManager is omitted (no SIM card). dropbear is replaced by openssh-server
# so we can honor "PermitRootLogin yes" + pre-generated host keys.
chroot ${CHROOT} ash -l -c "
apk add --allow-untrusted postmarketos-keys@pmos
apk add \
    bridge-utils \
    chrony \
    dbus \
    eudev \
    gadget-tool \
    iptables \
    msm-firmware-loader@pmos \
    openrc \
    rmtfs \
    shadow \
    sudo \
    udev-init-scripts \
    udev-init-scripts-openrc \
    wireguard-tools \
    wireguard-tools-wg-quick \
    wireless-regdb \
    iw \
    wpa_supplicant \
    e2fsprogs-extra \
    openssh-server \
    iproute2 \
    dnsmasq

# clear
rm /etc/fstab
"

# copy kernel modules and firmware extracted from the device flash package.
# The module directory name under PREBUILT/lib/modules is the exact kernel
# version string and is preserved as-is (requirement #4).
mkdir -p ${CHROOT}/lib/modules ${CHROOT}/lib/firmware
cp -a ${PREBUILT}/lib/modules/. ${CHROOT}/lib/modules/
cp -a ${PREBUILT}/lib/firmware/. ${CHROOT}/lib/firmware/

# extract NetworkManager from previous alpine version (v3.20)
scripts/extract_networkmanager.sh

# setup alpine
chroot ${CHROOT} ash -l -c "
echo root:alpine | chpasswd
echo user:1::::/home/user:/bin/ash | newusers

# update users used by chrooted apps
addgroup -S dnsmasq
adduser -S -D -H -h /dev/null -s /sbin/nologin -G dnsmasq -g dnsmasq dnsmasq

# sync
ln /etc/group    /usr/local/etc
ln /etc/passwd   /usr/local/etc
ln /etc/hostname /usr/local/etc

ln -sf /usr/local/etc/resolv.conf /etc

# add symlinks
for a in nm-online nmcli nmtui nmtui-connect nmtui-edit nmtui-hostname; do
    ln -s /usr/local/bin/chroot.sh /usr/bin/\${a};
done

rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add udev sysinit
rc-update add udev-trigger sysinit
rc-update add udev-settle sysinit
rc-update add udev-postmount default
rc-update add hwclock boot
rc-update add modules boot
rc-update add sysctl boot
rc-update add hostname boot
rc-update add bootmisc boot
rc-update add mount-ro shutdown
rc-update add killprocs shutdown
rc-update add savecache shutdown
rc-update add sshd default
rc-update add rmtfs default
rc-update add networkmanager default
rc-update add networkmanager-dispatcher default
rc-update add wpa_supplicant default
rc-update add local default
"
echo 'user ALL=(ALL:ALL) NOPASSWD: ALL' > ${CHROOT}/etc/sudoers.d/user

# SSH: allow root login and pre-generate host keys at build time
if grep -q '^#\?PermitRootLogin' ${CHROOT}/etc/ssh/sshd_config; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' ${CHROOT}/etc/ssh/sshd_config
else
    echo 'PermitRootLogin yes' >> ${CHROOT}/etc/ssh/sshd_config
fi
chroot ${CHROOT} ash -l -c "ssh-keygen -A"

# WiFi firmware module autoload
echo 'qcom_wcnss_pil' > ${CHROOT}/etc/modules-load.d/wcnss.conf
echo 'qcom_wcnss_pil' >> ${CHROOT}/etc/modules

# ----------------------------------------------------------------------------
# Disable cellular modem (MSS) + GPS
# ----------------------------------------------------------------------------
# The running device tree lives inside the stock boot.img (which we never rebuild),
# and this repo ships no .dts source, so the modem/GPS dtb nodes cannot be deleted.
# Functional equivalent: blacklist the Modem SubSystem driver. GPS is hosted on the
# modem subsystem, so this also removes GPS. WiFi (qcom_wcnss_pil / wcn36xx) is
# deliberately kept for the hotspot.
echo 'blacklist qcom_q6v5_mss' > ${CHROOT}/etc/modprobe.d/blacklist-modem-gps.conf
# rmtfs only serves the modem's shared memory; drop it when there is no modem
chroot ${CHROOT} ash -l -c "rc-update del rmtfs default" 2>/dev/null || true

# ----------------------------------------------------------------------------
# CPU frequency + scheduler tuning
# ----------------------------------------------------------------------------
# Load the ondemand governor module (schedutil, if built into the kernel, needs
# no module). At runtime we prefer schedutil and fall back to ondemand.
echo 'cpufreq_ondemand' > ${CHROOT}/etc/modules-load.d/cpufreq.conf
echo 'cpufreq_ondemand' >> ${CHROOT}/etc/modules
cat << 'EOF' > ${CHROOT}/etc/local.d/cpufreq.start
#!/bin/sh
# Pick the best available CPUFreq governor: schedutil first, then ondemand.
GOV=ondemand
AVAIL=/sys/devices/system/cpu/cpufreq/policy0/scaling_available_governors
if [ -e "$AVAIL" ] && grep -qw schedutil "$AVAIL" 2>/dev/null; then
    GOV=schedutil
fi
for p in /sys/devices/system/cpu/cpufreq/policy[0-9]*; do
    echo "$GOV" > "$p/scaling_governor" 2>/dev/null
done
# ondemand tuning (silently ignored when using schedutil)
echo 60    > /sys/devices/system/cpu/cpufreq/ondemand/up_threshold         2>/dev/null
echo 20000 > /sys/devices/system/cpu/cpufreq/ondemand/sampling_rate         2>/dev/null
echo 4     > /sys/devices/system/cpu/cpufreq/ondemand/sampling_down_factor  2>/dev/null
EOF
chmod +x ${CHROOT}/etc/local.d/cpufreq.start

# ----------------------------------------------------------------------------
# I/O scheduler tuning (eMMC/SD storage on the stick)
# ----------------------------------------------------------------------------
cat << 'EOF' > ${CHROOT}/etc/local.d/iosched.start
#!/bin/sh
for d in /sys/block/mmcblk*/queue /sys/block/sd*/queue; do
    [ -d "$d" ] || continue
    # mq-deadline: low, predictable latency for mixed read/write loads
    grep -q '\[mq-deadline\]' "$d/scheduler" 2>/dev/null || \
        echo mq-deadline > "$d/scheduler" 2>/dev/null
    # larger read-ahead + queue depth for SD/eMMC throughput
    echo 2048 > "$d/read_ahead_kb" 2>/dev/null
    echo 128  > "$d/nr_requests"   2>/dev/null
done
EOF
chmod +x ${CHROOT}/etc/local.d/iosched.start

# ----------------------------------------------------------------------------
# Memory tuning: zram compressed swap (avoids OOM on low-RAM sticks)
# ----------------------------------------------------------------------------
echo 'zram' > ${CHROOT}/etc/modules-load.d/zram.conf
cat << 'EOF' > ${CHROOT}/etc/local.d/zram-swap.start
#!/bin/sh
modprobe zram 2>/dev/null || true
# built-in zram may need an explicit hot-add to get a device node
[ -b /dev/zram0 ] || echo 1 > /sys/class/zram-control/hot_add 2>/dev/null || true
ZRAM=/dev/zram0
[ -b "$ZRAM" ] || exit 0
# pick a compression algorithm the kernel actually supports
for algo in lzo-rle lzo lz4 zstd; do
    echo "$algo" > /sys/block/zram0/comp_algorithm 2>/dev/null && break
done
# ~50% of physical RAM as compressed swap (safe upper bound on small devices)
MEM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
echo $(( MEM_KB / 2 ))K > /sys/block/zram0/disksize
mkswap "$ZRAM"
swapon -p 100 "$ZRAM"
EOF
chmod +x ${CHROOT}/etc/local.d/zram-swap.start

# ----------------------------------------------------------------------------
# Network + VM sysctl tuning (router/hotspot role: USB-NCM + WiFi bridge)
# ----------------------------------------------------------------------------
# tcp_bbr + nf_conntrack are loaded at the 'modules' boot stage (before sysctl),
# so the sysctl keys below resolve cleanly.
echo 'tcp_bbr'       > ${CHROOT}/etc/modules-load.d/net-tune.conf
echo 'nf_conntrack' >> ${CHROOT}/etc/modules-load.d/net-tune.conf
echo 'fq_codel'     >> ${CHROOT}/etc/modules-load.d/net-tune.conf
mkdir -p ${CHROOT}/etc/sysctl.d
cat << 'EOF' > ${CHROOT}/etc/sysctl.d/99-tune.conf
# ---- network stack ----
net.ipv4.ip_forward = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 1024
net.core.netdev_max_backlog = 4096
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr
net.netfilter.nf_conntrack_max = 131072
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.core.default_qdisc = fq_codel
# ---- virtual memory (pairs with zram swap) ----
vm.swappiness = 80
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.min_free_kbytes = 8192
fs.file-max = 65536
# ---- task scheduler ----
kernel.sched_autogroup_enabled = 1
# ---- security ----
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF

# ----------------------------------------------------------------------------
# Boot speed + flash-wear tuning
# ----------------------------------------------------------------------------
# run independent boot services in parallel
sed -i 's/^#\?rc_parallel=.*/rc_parallel="YES"/' ${CHROOT}/etc/rc.conf
grep -q '^rc_parallel=' ${CHROOT}/etc/rc.conf || echo 'rc_parallel="YES"' >> ${CHROOT}/etc/rc.conf
# remount root with noatime + batched commit; tmpfs for /tmp and /var/log to cut SD writes
cat << EOF >> ${CHROOT}/etc/fstab
PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e / ext4 noatime,commit=60 0 0
tmpfs /tmp tmpfs nodev,nosuid,noexec,size=32M 0 0
tmpfs /var/log tmpfs nodev,nosuid,size=16M 0 0
# USB NCM gadget needs configfs mounted before the gadget script runs
configfs /sys/kernel/config configfs defaults 0 0
EOF

# First-boot rootfs resize (uses the actual root device from /proc/mounts)
cat << 'EOF' > ${CHROOT}/etc/local.d/resize-rootfs.start
#!/bin/sh
ROOT_DEV=$(awk '$2 == "/" {print $1}' /proc/mounts)
if [ -n "${ROOT_DEV}" ]; then
    resize2fs "${ROOT_DEV}"
fi
EOF
chmod +x ${CHROOT}/etc/local.d/resize-rootfs.start

# add udev rules
cat << EOF > ${CHROOT}/etc/udev/rules.d/10-udc.rules
ACTION=="add", SUBSYSTEM=="udc", RUN+="/sbin/modprobe libcomposite", RUN+="/usr/local/bin/setup_ncm_gadget.sh"
EOF

cat << EOF > ${CHROOT}/etc/udev/rules.d/99-nm-usb0.rules
SUBSYSTEM=="net", ACTION=="add|change|move", ENV{DEVTYPE}=="gadget", ENV{NM_UNMANAGED}="1"
EOF

# enable autologin on console
sed -i '/^tty/ s/^/#/' ${CHROOT}/etc/inittab
echo 'ttyMSM0::respawn:/bin/sh' >> ${CHROOT}/etc/inittab

echo ${HOST_NAME} > ${CHROOT}/etc/hostname
sed -i "/localhost/ s/$/ ${HOST_NAME}/" ${CHROOT}/etc/hosts

# timezone: Asia/Shanghai
ln -sf /usr/share/zoneinfo/Asia/Shanghai ${CHROOT}/etc/localtime
echo 'Asia/Shanghai' > ${CHROOT}/etc/TZ

# setup NetworkManager (hotspot + usb only; no modem/wwan connection)
mkdir -p ${CHROOT}/usr/local/etc/NetworkManager/system-connections
cp configs/hotspot.nmconnection ${CHROOT}/usr/local/etc/NetworkManager/system-connections
cp configs/usb.nmconnection ${CHROOT}/usr/local/etc/NetworkManager/system-connections
chmod 0600 ${CHROOT}/usr/local/etc/NetworkManager/system-connections/*
ln -s ../usr/local/etc/NetworkManager ${CHROOT}/etc/NetworkManager

# usb0 is brought up standalone by local.d/usb-gadget.start (see below); tell NM
# to leave it unmanaged so the two don't fight over the interface / DHCP server.
mkdir -p ${CHROOT}/usr/local/etc/NetworkManager/conf.d
cat << EOF > ${CHROOT}/usr/local/etc/NetworkManager/conf.d/99-unmanage-usb0.conf
[main]
unmanaged-devices=interface-name:usb0
EOF

mkdir -p ${CHROOT}/boot/extlinux
cp configs/extlinux.conf ${CHROOT}/boot/extlinux

# copy custom dtb's
mkdir -p ${CHROOT}/boot/dtbs/qcom
cp dtbs/* ${CHROOT}/boot/dtbs/qcom

# update fstab
echo "/dev/mmcblk0p14\t/boot\text2\tdefaults\t0 2" >> ${CHROOT}/etc/fstab

# copy gadget-tool templates and script
cp -a configs/templates ${CHROOT}/etc/gt
cp scripts/setup_ncm_gadget.sh ${CHROOT}/usr/local/bin

# Standalone USB NCM bring-up. This does NOT rely on NetworkManager (which runs
# chrooted and was unreliable at assigning the connected PC an IP). NM is told to
# leave usb0 unmanaged. setup_ncm_gadget.sh bails out early if the gadget already
# exists, so running it from both the udev rule and here is safe.
cat << 'EOF' > ${CHROOT}/etc/local.d/usb-gadget.start
#!/bin/sh
/usr/local/bin/setup_ncm_gadget.sh || true

IF=usb0
# wait a moment for the gadget interface to appear
for i in 1 2 3 4 5 6 7 8; do
    [ -e /sys/class/net/$IF ] && break
    sleep 1
done
[ -e /sys/class/net/$IF ] || exit 0

ip link set $IF up
ip addr add 192.168.5.1/24 dev $IF 2>/dev/null

# DHCP + DNS for the connected PC. Bound to usb0 only, so it never clashes with
# NM's hotspot dnsmasq on wlan0.
PID=/run/dnsmasq-usb0.pid
if [ ! -f "$PID" ] || ! kill -0 "$(cat "$PID" 2>/dev/null)" 2>/dev/null; then
    /usr/sbin/dnsmasq --interface=$IF --bind-interfaces \
        --pid-file=$PID \
        --dhcp-range=192.168.5.2,192.168.5.254,255.255.255.0,1h \
        --dhcp-option=option:router,192.168.5.1 \
        --dhcp-option=option:dns-server,223.5.5.5,119.119.119.119
fi
EOF
chmod +x ${CHROOT}/etc/local.d/usb-gadget.start

# backup rootfs
rm -f alpine_rootfs.tgz
tar cpzf alpine_rootfs.tgz \
    --exclude="root/*" \
    --exclude="newroot" \
    --exclude="usr/bin/qemu-aarch64-static" \
    -C rootfs .

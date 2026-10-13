#!/bin/sh

mount_proc_sys_dev() {
	# mdev
	mkdir -p /sys
	mkdir -p /proc
	mkdir -p /dev
	mkdir -p /etc

	mount -t proc -o nodev,noexec,nosuid proc /proc || echo "Couldn't mount /proc"
	mount -t sysfs -o nodev,noexec,nosuid sysfs /sys || echo "Couldn't mount /sys"

	mkdir /config
	mount -t  configfs -o nodev,noexec,nosuid configfs /config || echo "Couldn't mount /config"

	mkdir -p /dev/pts || echo "Couldn't create directory /dev/pts"
	mount -t devpts devpts /dev/pts || echo "Couldn't mount /dev/pts"

	mkdir -p /sys/kernel/debug
	mount -t debugfs -o nodev,noexec,nosuid debugfs /sys/kernel/debug || echo "Could not mount /sys/kernel/debug"

	mkdir /run
}

setup_mdev() {
	echo /sbin/mdev > /proc/sys/kernel/hotplug
	mdev -s
}

setup_usb_host_mode() {
	USB_MODE_FILE="/sys/kernel/debug/usb/a600000.usb/mode"
	if [ -f "$USB_MODE_FILE" ]; then
		echo "  Setting USB mode to host" > /dev/kmsg
		echo host > "$USB_MODE_FILE"
	else
		echo "  USB mode file $USB_MODE_FILE not found, skipping host mode setup" > /dev/kmsg
	fi
}

setup_usb_network() {
	# See: https://www.kernel.org/doc/Documentation/usb/gadget_configfs.txt
	CONFIGFS=/config/usb_gadget

	if ! [ -e "$CONFIGFS" ]; then
		echo "  /config/usb_gadget does not exist, skipping configfs usb gadget"
		return
	fi

	# Default values for USB-related deviceinfo variables
	# NetChip RNDIS default VID:PID. Do NOT use 18D1:D001 here: Google's
	# USB driver exact-matches it, so on Windows machines with that driver
	# (needed for fastboot/adb) the RNDIS function gets hijacked as
	# "Android ADB Interface" and no network adapter appears.
	usb_idVendor="${deviceinfo_usb_idVendor:-0x0525}"
	usb_idProduct="${deviceinfo_usb_idProduct:-0xA4A2}"
	usb_serialnumber="${deviceinfo_usb_serialnumber:-postmarketOS}"
	usb_rndis_function="${deviceinfo_usb_rndis_function:-rndis.usb0}"

	echo "  Setting up an USB gadget through configfs"
	# Create an usb gadet configuration
	mkdir $CONFIGFS/g1 || echo "  Couldn't create $CONFIGFS/g1"
	echo "$usb_idVendor"  > "$CONFIGFS/g1/idVendor"
	echo "$usb_idProduct" > "$CONFIGFS/g1/idProduct"

	# Windows refuses to start a class-0 composite with bare RNDIS
	# (usbccgp CM_PROB_FAILED_START). 0xEF/0x02/0x01 marks the whole
	# device as RNDIS so Windows skips usbccgp entirely.
	echo 0xEF   > "$CONFIGFS/g1/bDeviceClass"
	echo 0x02   > "$CONFIGFS/g1/bDeviceSubClass"
	echo 0x01   > "$CONFIGFS/g1/bDeviceProtocol"
	echo 0x0200 > "$CONFIGFS/g1/bcdUSB"

	# Create english (0x409) strings
	mkdir $CONFIGFS/g1/strings/0x409 || echo "  Couldn't create $CONFIGFS/g1/strings/0x409"

	# shellcheck disable=SC2154
	echo "${deviceinfo_manufacturer:-Xiaomi}" > "$CONFIGFS/g1/strings/0x409/manufacturer"
	echo "$usb_serialnumber"        > "$CONFIGFS/g1/strings/0x409/serialnumber"
	# shellcheck disable=SC2154
	echo "${deviceinfo_name:-Mi 8 SE}" > "$CONFIGFS/g1/strings/0x409/product"

	# Create rndis function. The function can be named differently in downstream kernels.
	mkdir $CONFIGFS/g1/functions/"$usb_rndis_function" \
		|| echo "  Couldn't create $CONFIGFS/g1/functions/$usb_rndis_function"

	# Create configuration instance for the gadget
	mkdir $CONFIGFS/g1/configs/c.1 \
		|| echo "  Couldn't create $CONFIGFS/g1/configs/c.1"
	mkdir $CONFIGFS/g1/configs/c.1/strings/0x409 \
		|| echo "  Couldn't create $CONFIGFS/g1/configs/c.1/strings/0x409"
	echo "rndis" > $CONFIGFS/g1/configs/c.1/strings/0x409/configuration \
		|| echo "  Couldn't write configration name"
	echo 500  > $CONFIGFS/g1/configs/c.1/MaxPower
	echo 0x80 > $CONFIGFS/g1/configs/c.1/bmAttributes

	# Link the rndis instance to the configuration
	ln -s $CONFIGFS/g1/functions/"$usb_rndis_function" $CONFIGFS/g1/configs/c.1 \
		|| echo "  Couldn't symlink $usb_rndis_function"

	# Microsoft OS 1.0/2.0 descriptors so Windows auto-binds its
	# in-box RNDIS driver instead of failing the device.
	echo 1         > "$CONFIGFS/g1/os_desc/use"
	echo 0xbc      > "$CONFIGFS/g1/os_desc/b_vendor_code"
	echo "MSFT100" > "$CONFIGFS/g1/os_desc/qw_sign"
	echo "RNDIS"   > "$CONFIGFS/g1/functions/$usb_rndis_function/os_desc/interface.rndis/compatible_id" \
		|| echo "  Couldn't write RNDIS compatible_id"
	echo "5162001" > "$CONFIGFS/g1/functions/$usb_rndis_function/os_desc/interface.rndis/sub_compatible_id" \
		|| echo "  Couldn't write RNDIS sub_compatible_id"
	ln -s "$CONFIGFS/g1/configs/c.1" "$CONFIGFS/g1/os_desc/" \
		|| echo "  Couldn't link c.1 to os_desc"

		# Boot default is gadget: pin device role first.
	if [ -f /sys/kernel/debug/usb/a600000.usb/mode ]; then
		echo device > /sys/kernel/debug/usb/a600000.usb/mode 2>/dev/null || true
	fi

	# Check if there's an USB Device Controller
	if [ -z "$(ls /sys/class/udc)" ]; then
		echo "  No USB Device Controller available"
		return
	fi

	# Link the gadget instance to an USB Device Controller. This activates the gadget.
	# See also: https://github.com/postmarketOS/pmbootstrap/issues/338
	# shellcheck disable=SC2005
	echo "$(ls /sys/class/udc)" > $CONFIGFS/g1/UDC || echo "  Couldn't write UDC"

}

start_udhcpd() {
	# Only run once
	[ -e /etc/udhcpd.conf ] && return

	echo "Starting udhcpd"
	# Get usb interface
	INTERFACE=""
	ifconfig rndis0 "$IP" 2>/dev/null && INTERFACE=rndis0
	if [ -z $INTERFACE ]; then
		ifconfig usb0 "$IP" 2>/dev/null && INTERFACE=usb0
	fi
	if [ -z $INTERFACE ]; then
		ifconfig eth0 "$IP" 2>/dev/null && INTERFACE=eth0
	fi

	if [ -z $INTERFACE ]; then
		echo "  Could not find an interface to run a dhcp server on"
		echo "  Interfaces:"
		ip link
		return
	fi

	echo "  Using interface $INTERFACE"

	# Create /etc/udhcpd.conf
	{
		echo "start 172.16.42.2"
		echo "end 172.16.42.2"
		echo "auto_time 0"
		echo "decline_time 0"
		echo "conflict_time 0"
		echo "lease_file /var/udhcpd.leases"
		echo "interface $INTERFACE"
		echo "option subnet 255.255.255.0"
	} >/etc/udhcpd.conf

	echo "  Start the dhcpcd daemon (forks into background)" > /dev/kmsg
	udhcpd
}

start_telnetd() {
	mkdir -p /dev/shm
	mount -t tmpfs tmpfs /dev/shm
	telnetd -l /bin/sh
}

setup_firmware_path() {
	# Add the postmarketOS-specific path to the firmware search paths.
	# This should be sufficient on kernel 3.10+, before that we need
	# the kernel calling udev (and in our case /usr/lib/firmwareload.sh)
	# to load the firmware for the kernel.
	echo "Configuring kernel firmware image search path"
	SYS=/sys/module/firmware_class/parameters/path
	if ! [ -e "$SYS" ]; then
		echo "Kernel does not support setting the firmware image search path. Skipping."
		return
	fi
	# shellcheck disable=SC2039
	echo -n /lib/firmware/postmarketos > "$SYS"
}

# $1: param to get
get_cmdline_param() {
	if grep -q "$1=" /proc/cmdline; then
		# shellcheck disable=SC2013
		for x in $(cat /proc/cmdline); do
			case "${x}" in
			"${1}="*)
				echo "${x#*=}"
				;;
			esac
		done
	fi
}

inject_loop() {
    INJ_DIR="/init-ctl"
    INJ_STDIN="$INJ_DIR/stdin"

    mkdir -p "$INJ_DIR"
    mkfifo "$INJ_STDIN"
    echo "This entire directory is for debugging init - it can safely be removed" > "$INJ_DIR/README"

    echo "########################## Beginning inject loop" > /dev/kmsg
    while : ; do
        while read -r IN; do
	    if [ "$IN" = "continue" ]; then break 2;fi
            $IN > /dev/kmsg
        done <"$INJ_STDIN"
    done
    rm -rf "$INJ_DIR" # Clean up if we exited nicely
    echo "########################## inject loop done"
}

# Read factory WiFi/BT MACs from the persist partition and apply them to the
# new root. Called after bind_vendormod so the vendor store is already
# visible. Idempotent: each file is only written when content differs, so a
# normal boot performs zero writes. Fail-soft: anything unreadable keeps the
# baked-in LAA addresses.
# $1 = new-root path (/mnt or /newroot).
apply_persist_macs() {
	_root="$1"
	[ -n "$_root" ] || return 0

	# sirius persist is mmcblk0p68 (mmcblk0p69 is the backup copy).
	_persist_part="$(get_cmdline_param persist_part)"
	[ -n "$_persist_part" ] || _persist_part="mmcblk0p68"

	mkdir -p /persist_ro /run/persistmac
	_stage=/run/persistmac
	_mounted=""
	for _p in "$_persist_part" mmcblk0p69; do
		if mount -o ro "/dev/$_p" /persist_ro 2>/dev/null; then
			_mounted="$_p"
			break
		fi
	done
	if [ -z "$_mounted" ]; then
		echo "persistmac: no persist partition, keeping baked-in MACs" > /dev/kmsg
		return 0
	fi

	# --- WiFi: wlan_mac.bin holds text "wlan0=482ca04bc60d" ---
	_wlan_hex=""
	if [ -f /persist_ro/wlan_mac.bin ]; then
		_wlan_hex="$(sed -n 's/^wlan0=\([0-9a-fA-F][0-9a-fA-F]*\).*$/\1/p' /persist_ro/wlan_mac.bin)"
	fi
	if [ "${#_wlan_hex}" = 12 ]; then
		case "$_wlan_hex" in
		*[!0-9a-fA-F]* | 000000000000)
			echo "persistmac: bad wlan_mac.bin content, keeping baked-in WiFi MAC" > /dev/kmsg
			;;
		*)
			_first="${_wlan_hex%${_wlan_hex#?}}"
			case "$_first" in
			[02468aceACE])
				_wlan_mac="$(echo "$_wlan_hex" | sed 's/\(..\)/\1:/g;s/:$//')"
				_link="$_root/etc/systemd/network/10-wlan0.link"
				mkdir -p "$_root/etc/systemd/network"
				{
					echo "[Match]"
					echo "OriginalName=wlan0"
					echo ""
					echo "[Link]"
					echo "MACAddress=$_wlan_mac"
				} > "$_stage/wlan0.link.new"
				if [ ! -s "$_stage/wlan0.link.new" ]; then
					echo "persistmac: cannot stage link file" > /dev/kmsg
				elif [ -f "$_link" ] && cmp -s "$_stage/wlan0.link.new" "$_link"; then
					echo "persistmac: wlan0 already $_wlan_mac" > /dev/kmsg
				else
					if cat "$_stage/wlan0.link.new" > "$_link"; then
						echo "persistmac: wlan0 -> $_wlan_mac" > /dev/kmsg
					else
						echo "persistmac: cannot write $_link" > /dev/kmsg
					fi
				fi
				rm -f "$_stage/wlan0.link.new"
				;;
			*)
				echo "persistmac: wlan MAC not unicast, keeping baked-in WiFi MAC" > /dev/kmsg
				;;
			esac
			;;
		esac
	else
		echo "persistmac: no valid wlan_mac.bin, keeping baked-in WiFi MAC" > /dev/kmsg
	fi

	# --- Bluetooth: wlan_bt/bt.mac holds 6 raw bytes, LSB-first, which is
	# exactly the byte order of the BD_ADDR TLV (tag 2) at file offset
	# 0x14 in qca/crnv21.bin. Patch the vendor copy only on difference.
	_btmac=/persist_ro/wlan_bt/bt.mac
	_nvm="$_root/mnt/vendormod/lib/firmware/qca/crnv21.bin"
	if [ -f "$_btmac" ] && [ -f "$_nvm" ]; then
		_sz="$(stat -c %s "$_btmac" 2>/dev/null)"
		_nsz="$(stat -c %s "$_nvm" 2>/dev/null)"
		if [ "$_sz" = 6 ] && [ -n "$_nsz" ] && [ "$_nsz" -gt 26 ] 2>/dev/null; then
			# NB: cmp against /dev/zero itself always reports EOF-differ,
			# so compare against a finite zero reference instead.
			if dd if=/dev/zero of="$_stage/btzero" bs=6 count=1 2>/dev/null && cmp -s "$_btmac" "$_stage/btzero" 2>/dev/null; then
				echo "persistmac: bt.mac all zero, keeping baked-in BD addr" > /dev/kmsg
			elif dd if="$_nvm" of="$_stage/bdcur" bs=1 skip=20 count=6 2>/dev/null && [ "$(stat -c %s "$_stage/bdcur" 2>/dev/null)" = 6 ] && cmp -s "$_stage/bdcur" "$_btmac"; then
				echo "persistmac: hci0 BD addr already applied" > /dev/kmsg
			else
					if mount -o remount,rw "$_root/mnt/vendormod" 2>/dev/null; then
						if dd if="$_btmac" of="$_nvm" bs=1 seek=20 count=6 conv=notrunc 2>/dev/null; then
							echo "persistmac: hci0 BD addr updated from persist" > /dev/kmsg
						else
							echo "persistmac: NVM patch write failed" > /dev/kmsg
						fi
						mount -o remount,ro "$_root/mnt/vendormod" 2>/dev/null || true
					else
						echo "persistmac: vendor remount rw failed, keeping baked-in BD addr" > /dev/kmsg
					fi
				rm -f "$_stage/bdcur"
			fi
			rm -f "$_stage/btzero"
		else
			echo "persistmac: bad bt.mac or crnv21.bin size, keeping baked-in BD addr" > /dev/kmsg
		fi
	fi

	umount /persist_ro 2>/dev/null || true
	return 0
}

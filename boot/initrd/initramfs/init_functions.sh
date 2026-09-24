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
	usb_idVendor="${deviceinfo_usb_idVendor:-0x18D1}"   # default: Google Inc.
	usb_idProduct="${deviceinfo_usb_idProduct:-0xD001}" # default: Nexus 4 (fastboot)
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

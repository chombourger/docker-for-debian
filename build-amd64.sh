#!/bin/bash
#---------------------------------------------------------------------------------------------------
# Build docker-ce for Debian/amd64
#---------------------------------------------------------------------------------------------------

source build-defaults.conf

#---------------------------------------------------------------------------------------------------
# Build settings
#---------------------------------------------------------------------------------------------------

ARCH=amd64
MACHINE=pc
QEMU=qemu-system-x86_64
EXTRA_PACKAGES="linux-headers-${ARCH}"

DRIVE_OPTS=
SCSI_OPTS=
NETDEV_OPTS=" \
    -net nic,model=e1000 \
    -net user${GUESTFWD}${HOSTFWD} \
"

#---------------------------------------------------------------------------------------------------
# Debian installer
#---------------------------------------------------------------------------------------------------

DI_PATH=main/installer-${ARCH}/current/images/netboot/debian-installer/${ARCH}
DI_KERNEL=linux
DI_INITRD=initrd.gz

#---------------------------------------------------------------------------------------------------
# Build scripts
#---------------------------------------------------------------------------------------------------

source build-common.sh
source deploy-apt.sh

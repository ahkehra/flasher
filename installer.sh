#!/sbin/sh
#
###########################################
#
# Copyright (C) 2021 FlameGApps Project
#
# This file is part of the FlameGApps Project by ayandebnath <ayandebnath000@gmail.com>
#
# The FlameGApps scripts are free software, you can redistribute it and/or modify it
# 
# These scripts are distributed in the hope that they will be useful, but WITHOUT ANY WARRANTY
#
# Edited github@akirasupr
#
###########################################
# File Name    : installer.sh
###########################################
##

# List of the addon files
addon_list="
"

# Pre-installed unnecessary app list
remove_list="
"

# Pre-installed app/files
remove_installed="
"

##

ui_print() {
  echo "ui_print $1
    ui_print" >> $OUTFD
}

set_progress() { echo "set_progress $1" >> $OUTFD; }

is_mounted() { mount | grep -q " $1 "; }

setup_mountpoint() {
  test -L $1 && mv -f $1 ${1}_link
  if [ ! -d $1 ]; then
    rm -f $1
    mkdir $1
  fi
}

recovery_actions() {
  OLD_LD_LIB=$LD_LIBRARY_PATH
  OLD_LD_PRE=$LD_PRELOAD
  OLD_LD_CFG=$LD_CONFIG_FILE
  unset LD_LIBRARY_PATH
  unset LD_PRELOAD
  unset LD_CONFIG_FILE
}

recovery_cleanup() {
  [ -z $OLD_LD_LIB ] || export LD_LIBRARY_PATH=$OLD_LD_LIB
  [ -z $OLD_LD_PRE ] || export LD_PRELOAD=$OLD_LD_PRE
  [ -z $OLD_LD_CFG ] || export LD_CONFIG_FILE=$OLD_LD_CFG
}

clean_up() {
  rm -rf /tmp/tar_gapps
  rm -rf /tmp/unzip_dir
}

get_file_prop() {
  grep -m1 "^$2=" "$1" | cut -d= -f2
}

get_prop() {
  #check known .prop files using get_file_prop
  for f in $PROPFILES; do
    if [ -e "$f" ]; then
      prop="$(get_file_prop "$f" "$1")"
      if [ -n "$prop" ]; then
        break #if an entry has been found, break out of the loop
      fi
    fi
  done
  #if prop is still empty; try to use recovery's built-in getprop method; otherwise output current result
  if [ -z "$prop" ]; then
    getprop "$1" | cut -c1-
  else
    printf "$prop"
  fi
}

remove_fd() {
  local LIST="$1"
  for f in $LIST; do
    rm -rf $SYSTEM/$f
    rm -rf $SYSTEM/product/$f
    if [ "$rom_sdk" -gt "29" ]; then
      rm -rf $SYSTEM/system_ext/$f
    fi
  done
}

abort() {
  sleep 1
  ui_print "- Aborting..."
  sleep 3
  unmount_all
  clean_up
  recovery_cleanup
  exit 1;
}

exit_all() {
  sleep 0.5
  unmount_all
  sleep 0.5
  set_progress 0.90
  clean_up
  recovery_cleanup
  sleep 0.5
  ui_print " "
  ui_print "- Installation Successful..!"
  ui_print " "
  set_progress 1.00
  exit 0;
}

mount_apex() {
  # For reference, check: https://github.com/osm0sis/AnyKernel3/blob/master/META-INF/com/google/android/update-binary
  if [ -d $SYSTEM/apex ]; then
    local apex dest loop minorx num
    setup_mountpoint /apex
    test -e /dev/block/loop1 && minorx=$(ls -l /dev/block/loop1 | awk '{ print $6 }') || minorx=1
    num=0
    for apex in $SYSTEM/apex/*; do
      dest=/apex/$(basename $apex .apex)
      test "$dest" = /apex/com.android.runtime.release && dest=/apex/com.android.runtime
      mkdir -p $dest
      case $apex in
        *.apex)
          unzip -qo $apex apex_payload.img -d /apex
          mv -f /apex/apex_payload.img $dest.img
          mount -t ext4 -o ro,noatime $dest.img $dest 2>/dev/null
          if [ $? != 0 ]; then
            while [ $num -lt 64 ]; do
              loop=/dev/block/loop$num
              (mknod $loop b 7 $((num * minorx))
              losetup $loop $dest.img) 2>/dev/null
              num=$((num + 1))
              losetup $loop | grep -q $dest.img && break
            done
            mount -t ext4 -o ro,loop,noatime $loop $dest
            if [ $? != 0 ]; then
              losetup -d $loop 2>/dev/null
            fi
          fi
        ;;
        *) mount -o bind $apex $dest;;
      esac
    done
    export ANDROID_RUNTIME_ROOT=/apex/com.android.runtime
    export ANDROID_TZDATA_ROOT=/apex/com.android.tzdata
    export BOOTCLASSPATH=/apex/com.android.runtime/javalib/core-oj.jar:/apex/com.android.runtime/javalib/core-libart.jar:/apex/com.android.runtime/javalib/okhttp.jar:/apex/com.android.runtime/javalib/bouncycastle.jar:/apex/com.android.runtime/javalib/apache-xml.jar:/system/framework/framework.jar:/system/framework/ext.jar:/system/framework/telephony-common.jar:/system/framework/voip-common.jar:/system/framework/ims-common.jar:/system/framework/android.test.base.jar:/apex/com.android.conscrypt/javalib/conscrypt.jar:/apex/com.android.media/javalib/updatable-media.jar
  fi
}

unmount_apex() {
  if [ -d $SYSTEM/apex ]; then
    local dest loop
    for dest in $(find /apex -type d -mindepth 1 -maxdepth 1); do
      if [ -f $dest.img ]; then
        loop=$(mount | grep $dest | cut -d" " -f1)
      fi
      (umount -l $dest
      losetup -d $loop) 2>/dev/null
    done
    rm -rf /apex 2>/dev/null
    unset ANDROID_RUNTIME_ROOT ANDROID_TZDATA_ROOT BOOTCLASSPATH
  fi
}

mount_all() {
  set_progress 0.10
  ui_print "- Mounting partitions"
  sleep 1
  dynamic_partitions=`getprop ro.boot.dynamic_partitions`
  SLOT=`getprop ro.boot.slot_suffix`
  [ ! -z "$SLOT" ] && ui_print "- Current boot slot: $SLOT"

  if [ -n "$(cat /etc/fstab | grep /system_root)" ]; then
    MOUNT_POINT=/system_root
  else
    MOUNT_POINT=/system
  fi

  for p in "/cache" "/data" "$MOUNT_POINT" "/product" "/system_ext" "/vendor"; do
    if [ -d "$p" ] && grep -q "$p" "/etc/fstab" && ! is_mounted "$p"; then
      mount "$p"
    fi
  done

  if [ "$dynamic_partitions" = "true" ]; then
    ui_print "- Dynamic partition detected"
    for m in "/system" "/system_root" "/product" "/system_ext" "/vendor"; do
      (umount "$m"
      umount -l "$m") 2>/dev/null
    done
    mount -o ro -t auto /dev/block/mapper/system$SLOT /system_root
    mount -o ro -t auto /dev/block/mapper/vendor$SLOT /vendor 2>/dev/null
    mount -o ro -t auto /dev/block/mapper/product$SLOT /product 2>/dev/null
    mount -o ro -t auto /dev/block/mapper/system_ext$SLOT /system_ext 2>/dev/null
  else
    mount -o ro -t auto /dev/block/bootdevice/by-name/system$SLOT $MOUNT_POINT 2>/dev/null
  fi

  if [ "$dynamic_partitions" = "true" ]; then
    for block in system vendor product system_ext; do
      for slot in "" _a _b; do
        blockdev --setrw /dev/block/mapper/$block$slot 2>/dev/null
      done
    done
    mount -o rw,remount -t auto /dev/block/mapper/system$SLOT /system_root
    mount -o rw,remount -t auto /dev/block/mapper/vendor$SLOT /vendor 2>/dev/null
    mount -o rw,remount -t auto /dev/block/mapper/product$SLOT /product 2>/dev/null
    mount -o rw,remount -t auto /dev/block/mapper/system_ext$SLOT /system_ext 2>/dev/null
  else
    mount -o rw,remount -t auto $MOUNT_POINT
    mount -o rw,remount -t auto /vendor 2>/dev/null
    mount -o rw,remount -t auto /product 2>/dev/null
    mount -o rw,remount -t auto /system_ext 2>/dev/null
  fi

  sleep 0.3

  if is_mounted /system_root; then
    ui_print "- Device is system-as-root"
    if [ -f /system_root/build.prop ]; then
      mount -o bind /system_root /system
      SYSTEM=/system_root
      ui_print "- System is $SYSTEM"
    else
      mount -o bind /system_root/system /system
      SYSTEM=/system_root/system
      ui_print "- System is $SYSTEM"
    fi
  elif is_mounted /system; then
    if [ -f /system/build.prop ]; then
      SYSTEM=/system
      ui_print "- System is $SYSTEM"
    elif [ -f /system/system/build.prop ]; then
      ui_print "- Device is system-as-root"
      mkdir -p /system_root
      mount --move /system /system_root
      mount -o bind /system_root/system /system
      SYSTEM=/system_root/system
      ui_print "- System is /system/system"
    fi
  else
    ui_print "- Failed to mount/detect system"
    abort
  fi
  mount_apex
}

unmount_all() {
  unmount_apex
  ui_print " "
  ui_print "- Unmounting partitions"
  for m in "/system" "/system_root" "/product" "/system_ext" "/vendor"; do
    if [ -e $m ]; then
      (umount $m
      umount -l $m) 2>/dev/null
    fi
  done
}

mount -o bind /dev/urandom /dev/random
unmount_all
mount_all

recovery_actions

PROPFILES="$SYSTEM/build.prop"
GAPPS_DIR="$TMP/tar_gapps"
UNZIP_FOLDER="$TMP/unzip_dir"
EX_SYSTEM="$UNZIP_FOLDER/system"
zip_dir="$(dirname "$ZIPFILE")"
overlay_installed="true"
mkdir -p $UNZIP_FOLDER

# Get ROM, device & package information
rom_version=`get_prop ro.build.version.release`
rom_sdk=`get_prop ro.build.version.sdk`
device_architecture=`get_prop ro.product.cpu.abilist`
device_code=`get_prop ro.product.device`

if [ -z "$device_architecture" ]; then
  device_architecture=`get_prop ro.product.cpu.abi`
fi

case "$device_architecture" in
  *x86_64*) arch="x86_64"
    ;;
  *x86*) arch="x86"
    ;;
  *arm64*) arch="arm64"
    ;;
  *armeabi*) arch="arm"
    ;;
  *) arch="unknown"
    ;;
esac

# Get prop details before compatibility checks
cat $SYSTEM/build.prop

set_progress 0.20
sleep 1
ui_print " "
ui_print "- Android: $rom_version, SDK: $rom_sdk, ARCH: $arch"
sleep 1

# remove_line <file> <line match string> by osm0sis @xda-developers
remove_line() {
  if grep -q "$2" $1; then
    local line=$(grep -n "$2" $1 | head -n1 | cut -d: -f1);
    sed -i "${line}d" $1;
  fi
}

install_gapps() {
  ui_print " "
  set_progress 0.70
  gapps_list="$addon_apps_list"
  for g in $gapps_list; do
    ui_print "- Installing $g"
    unzip -o "$ZIPFILE" "tar_gapps/$g.tar.xz" -d $TMP
    tar -xf "$GAPPS_DIR/$g.tar.xz" -C $UNZIP_FOLDER
    rm -rf $GAPPS_DIR/$g.tar.xz
    file_list="$(find "$EX_SYSTEM/" -mindepth 1 -type f | cut -d/ -f5-)"
    dir_list="$(find "$EX_SYSTEM/" -mindepth 1 -type d | cut -d/ -f5-)"
    for file in $file_list; do
      install -D "$EX_SYSTEM/${file}" "$SYSTEM/${file}"
      if echo "${file}" | grep -q "Overlay.apk"; then
        overlay_installed="true"
        chcon -h u:object_r:vendor_overlay_file:s0 "$SYSTEM/${file}"
      else
        chcon -h u:object_r:system_file:s0 "$SYSTEM/${file}"
      fi
      chmod 0644 "$SYSTEM/${file}"
    done
    for dir in $dir_list; do
      chcon -h u:object_r:system_file:s0 "$SYSTEM/${dir}"
      chmod 0755 "$SYSTEM/${dir}"
    done
    rm -rf $UNZIP_FOLDER/*
  done
}

# Install gapps files
if [ ! -f $SYSTEM/priv-app/Lawnchair/Lawnchair.apk ]; then
  # Remove pre-installed unnecessary system apps
  ui_print " "
  ui_print "- Removing unnecessary system apps"
  set_progress 0.30
  sleep 0.5
  remove_fd "$remove_list"
  install_gapps
else
  # Remove pre-installed system apps
  ui_print " "
  ui_print "- Removing installed system apps"
  set_progress 0.30
  sleep 0.5
  remove_fd "$remove_installed"
fi

sleep 0.5
set_progress 0.80
ui_print " "
ui_print "- Performing other tasks"
# Fix context
if [ "$overlay_installed" = "true" ]; then
  chcon -h u:object_r:vendor_overlay_file:s0 "$SYSTEM/product/overlay"
fi

exit_all

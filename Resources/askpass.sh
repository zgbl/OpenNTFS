#!/bin/sh
# sudo -A 的密码输入框（SUDO_ASKPASS）。由 OpenNTFS 直接启动 sudo，
# 这样 ntfs-3g 的「发起 App」仍是 OpenNTFS，macOS 的完全磁盘访问权限才能生效。
exec /usr/bin/osascript \
  -e 'set r to display dialog "OpenNTFS 需要管理员权限来读写挂载 NTFS 磁盘。" & return & return & "请输入你的 Mac 登录密码：" default answer "" with hidden answer with title "OpenNTFS" with icon caution buttons {"取消", "好"} default button "好" cancel button "取消"' \
  -e 'text returned of r'

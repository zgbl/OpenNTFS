#!/bin/sh
# OpenNTFS 特权助手 —— 以 root 身份运行，只做挂载/卸载这几件事，并严格校验参数。
#
# 用法:
#   ntfs-helper.sh ping
#   ntfs-helper.sh mount   <diskXsY> <卷名> <uid> <gid> <kext|fskit>
#   ntfs-helper.sh unmount <diskXsY> <挂载点>
#   ntfs-helper.sh fdmount <diskXsY> <uid> <gid> <ntfs-3g路径> <挂载点> <卷名>   # FSKit 读写挂载
#   ntfs-helper.sh setup-passwordless <用户名>   # 安装本脚本到系统目录，并允许该用户免密码运行它
#   ntfs-helper.sh remove-passwordless
#
# 退出码: 0 成功；2 参数错误；3 找不到 ntfs-3g；4 找不到 macFUSE；
#         其他为 ntfs-3g 返回值（14 = Windows 休眠，15 = 未正常卸载）

set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

die() { echo "$2" >&2; exit "$1"; }

valid_dev() {
    case "$1" in
        disk[0-9]*s[0-9]*) ;;
        *) die 2 "非法设备名: $1" ;;
    esac
    printf '%s' "$1" | grep -Eq '^disk[0-9]+s[0-9]+$' || die 2 "非法设备名: $1"
    [ -b "/dev/$1" ] || die 2 "设备不存在: /dev/$1"
}

valid_num() {
    printf '%s' "$1" | grep -Eq '^[0-9]+$' || die 2 "非法数字参数: $1"
}

find_ntfs3g() {
    for p in /opt/homebrew/bin/ntfs-3g /opt/homebrew/sbin/ntfs-3g \
             /usr/local/bin/ntfs-3g /usr/local/sbin/ntfs-3g; do
        if [ -x "$p" ]; then echo "$p"; return 0; fi
    done
    return 1
}

# 返回设备当前挂载点（空则未挂载）
mount_point_of() {
    mount | awk -v d="/dev/$1" '$1 == d { sub(/^[^ ]+ on /, ""); sub(/ \([^)]*\)$/, ""); print; exit }'
}

is_mounted_at() {
    mount | grep -Fq " on $1 ("
}

cmd="${1:-}"

case "$cmd" in
ping)
    echo pong
    ;;

mount)
    [ $# -eq 6 ] || [ $# -eq 7 ] || die 2 "参数个数错误"
    dev="$2"; uid="$4"; gid="$5"; backend="$6"; bundled="${7:-}"
    valid_dev "$dev"; valid_num "$uid"; valid_num "$gid"
    case "$backend" in kext|fskit) ;; *) die 2 "非法后端: $backend" ;; esac

    if [ -n "$bundled" ]; then
        case "$bundled" in /*/ntfs-3g) ;; *) die 2 "非法 ntfs-3g 路径: $bundled" ;; esac
        [ -x "$bundled" ] || die 3 "找不到内置 ntfs-3g: $bundled"
        NTFS3G="$bundled"
    else
        NTFS3G=$(find_ntfs3g) || die 3 "未找到 ntfs-3g，请先安装: brew install gromgit/fuse/ntfs-3g-mac"
    fi
    [ -d /Library/Filesystems/macfuse.fs ] || die 4 "未找到 macFUSE，请先安装: brew install --cask macfuse"

    # 清理卷名：去掉 / 和 :，去掉开头的点，限制长度
    name=$(printf '%s' "$3" | tr -d '\000-\037' | tr '/:' '__' | sed 's/^\.*//' | cut -c1-64)
    [ -n "$name" ] || name="NTFS"

    # 先卸载系统的只读挂载
    cur=$(mount_point_of "$dev")
    if [ -n "$cur" ]; then
        diskutil unmount "/dev/$dev" >/dev/null 2>&1 || die 16 "无法卸载 /dev/$dev（可能有程序正在使用该磁盘）"
    fi

    # 选一个可用的挂载点
    mp="/Volumes/$name"; i=1
    while [ -e "$mp" ] && { is_mounted_at "$mp" || [ -n "$(ls -A "$mp" 2>/dev/null)" ]; }; do
        mp="/Volumes/$name $i"; i=$((i + 1))
    done
    mkdir -p "$mp" || die 2 "无法创建挂载点 $mp"

    set -- -o local -o allow_other -o auto_xattr -o auto_cache -o noappledouble \
           -o windows_names -o "volname=$name" -o "uid=$uid" -o "gid=$gid"
    if [ "$backend" = "fskit" ]; then
        set -- "$@" -o backend=fskit -o noalerts
    fi

    # ntfs-3g 会先 fork 到后台再真正挂载，所以返回 0 并不代表成功：
    # 把它的输出写到日志，然后轮询挂载表确认。
    log=$(mktemp /tmp/openntfs.XXXXXX)
    "$NTFS3G" "/dev/$dev" "$mp" "$@" >"$log" 2>&1
    rc=$?
    if [ $rc -eq 0 ]; then
        n=0
        while [ $n -lt 40 ] && ! is_mounted_at "$mp"; do
            sleep 0.25; n=$((n + 1))
        done
        is_mounted_at "$mp" || rc=1
    fi
    if [ $rc -ne 0 ]; then
        if [ "$backend" = "fskit" ] && grep -Eiq 'file system extension.*(not enabled|not found)' "$log"; then
            rc=5
        fi
        # 挂载卡住时 ntfs-3g 会一直占着设备，必须强制结束
        pkill -9 -f "ntfs-3g /dev/$dev " 2>/dev/null
        sleep 0.5
        [ -s "$log" ] || echo "挂载超时：系统 FSKit 服务没有响应（10 秒）" >"$log"
        grep -v -e '^$' "$log" | tail -5 >&2
        rm -f "$log"
        rmdir "$mp" 2>/dev/null
        # 读写挂载失败时，恢复系统只读挂载，保证用户至少还能读
        diskutil mount "/dev/$dev" >/dev/null 2>&1
        exit $rc
    fi
    rm -f "$log"
    echo "$mp"
    ;;

fdmount)
    # FSKit 后端要求 ntfs-3g 以普通用户身份运行（root 运行会卡住），而 macOS 不允许修改实体硬盘设备文件的权限。
    # 做法：root 以读写方式打开分区得到 fd 3，然后彻底降权为该用户，再执行 ntfs-3g /dev/fd/3。
    # 设备文件权限不做任何修改，ntfs-3g 退出后句柄自动关闭。
    [ $# -eq 7 ] || die 2 "参数个数错误"
    dev="$2"; uid="$3"; gid="$4"; bin="$5"; mp="$6"; vol="$7"
    valid_dev "$dev"; valid_num "$uid"; valid_num "$gid"
    [ "$uid" -ne 0 ] || die 2 "不能以 root 运行 ntfs-3g"
    # 通过 sudo 免密码调用时，只允许给调用者本人挂载
    if [ -n "${SUDO_UID:-}" ] && [ "$SUDO_UID" != "$uid" ]; then die 2 "uid 与调用者不符"; fi
    case "$bin" in /*/ntfs-3g) ;; *) die 2 "非法 ntfs-3g 路径: $bin" ;; esac
    [ -x "$bin" ] || die 3 "找不到内置 ntfs-3g: $bin"
    case "$mp" in /Volumes/*) ;; *) die 2 "非法挂载点: $mp" ;; esac
    case "$mp" in *..*) die 2 "非法挂载点: $mp" ;; esac
    # 只允许 NTFS 分区
    diskutil info "/dev/$dev" 2>/dev/null | grep -Eiq '(Type \(Bundle\)|File System Personality): +(ntfs|ufsd_ntfs)' \
        || die 2 "/dev/$dev 不是 NTFS 分区"
    [ -d /Library/Filesystems/macfuse.fs ] || die 4 "未找到 macFUSE"

    cur=$(mount_point_of "$dev")
    if [ -n "$cur" ]; then
        diskutil unmount "/dev/$dev" >/dev/null 2>&1 || die 16 "无法卸载 /dev/$dev（可能有程序正在使用该磁盘）"
    fi
    name=$(printf '%s' "$vol" | tr -d '\000-\037' | tr ',' ' ' | cut -c1-64)
    [ -n "$name" ] || name="NTFS"

    # perl：打开设备 → 降权 → exec。不用 launchctl asuser：它会切断「发起 App」的归属，
    # 导致 macOS 隐私保护（完全磁盘访问权限）认不到 OpenNTFS 头上；osascript 本身已在用户会话中。
    exec /usr/bin/perl -e '
        use POSIX ();
        use Fcntl qw(F_GETFD F_SETFD FD_CLOEXEC);
        my ($dev, $uid, $gid, $bin, $mp, $name) = @ARGV;
        $^F = 255;   # 否则 perl 会给新句柄设 close-on-exec，exec 后 ntfs-3g 拿不到 fd 3
        sysopen(my $fh, $dev, POSIX::O_RDWR()) or do { print STDERR "无法打开 $dev: $!\n"; exit 16 };
        if (fileno($fh) != 3) { POSIX::dup2(fileno($fh), 3) or do { print STDERR "dup2: $!\n"; exit 16 }; }
        open(my $fd3, "+<&=", 3) or exit 16;
        fcntl($fd3, F_SETFD, fcntl($fd3, F_GETFD, 0) & ~FD_CLOEXEC) or exit 16;
        POSIX::setgid($gid) or exit 2;
        $) = "$gid $gid";
        POSIX::setuid($uid) or exit 2;
        exit 2 if $< == 0 || $> == 0;
        exec { $bin } "ntfs-3g", "/dev/fd/3", $mp,
            "-o", "backend=fskit", "-o", "noalerts", "-o", "local", "-o", "noappledouble",
            "-o", "windows_names", "-o", "streams_interface=openxattr", "-o", "volname=$name";
        print STDERR "exec $bin: $!\n"; exit 3;
    ' "/dev/$dev" "$uid" "$gid" "$bin" "$mp" "$name"
    ;;

unmount)
    [ $# -eq 3 ] || die 2 "参数个数错误"
    dev="$2"; mp="$3"
    valid_dev "$dev"
    case "$mp" in
        /Volumes/*) ;;
        *) die 2 "非法挂载点: $mp" ;;
    esac
    case "$mp" in *..*) die 2 "非法挂载点: $mp" ;; esac
    is_mounted_at "$mp" || exit 0
    diskutil unmount "$mp" >/dev/null 2>&1 || umount "$mp" 2>/dev/null || \
        die 16 "无法卸载 $mp（可能有程序正在使用该磁盘）"
    rmdir "$mp" 2>/dev/null
    exit 0
    ;;

setup-passwordless)
    # 把本脚本复制到 root 拥有的系统目录，并在 sudoers 中只允许该用户免密码运行这一个文件
    [ $# -eq 2 ] || die 2 "参数个数错误"
    user="$2"
    printf '%s' "$user" | grep -Eq '^[A-Za-z0-9._-]+$' || die 2 "非法用户名: $user"
    id -u "$user" >/dev/null 2>&1 || die 2 "用户不存在: $user"
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "$user" ]; then die 2 "用户与调用者不符"; fi
    dest=/Library/PrivilegedHelperTools/local.openntfs.helper
    sudoers=/etc/sudoers.d/openntfs
    install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools || exit 1
    install -o root -g wheel -m 755 "$0" "$dest" || exit 1
    tmp=$(mktemp /tmp/openntfs.sudoers.XXXXXX) || exit 1
    printf '%s ALL=(root) NOPASSWD: %s\n' "$user" "$dest" > "$tmp"
    visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die 1 "sudoers 校验失败"; }
    install -o root -g wheel -m 440 "$tmp" "$sudoers" || { rm -f "$tmp"; exit 1; }
    rm -f "$tmp"
    ;;

remove-passwordless)
    rm -f /etc/sudoers.d/openntfs /Library/PrivilegedHelperTools/local.openntfs.helper
    ;;

*)
    die 2 "未知命令: $cmd"
    ;;
esac

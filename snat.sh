#!/usr/bin/sh
#
# vpn-fw-helper.sh
#
# 功能:
# 1. 判断系统类型
# 2. 自动识别当前可用/活跃防火墙后端: firewalld / ufw / nftables / iptables
# 3. 检测并配置 IPv4 转发
# 4. 检测并展示默认防火墙策略: 入站 / 出站 / 转发
# 5. 显示当前网卡，用户按编号选择“当前配置接口”
# 6. 按接口分别维护 SNAT 源网段
# 7. 按接口分别维护端口/协议放行规则（仅服务器本机 INPUT）
# 8. 应用并持久化保存配置
#
# 设计原则:
# - 不关闭系统防火墙
# - 不把 INPUT/OUTPUT/FORWARD 默认策略改成全允许
# - 只放行用户指定的协议/端口
# - SNAT 只针对用户指定的源网段 + 所属接口
# - 支持多个出口接口并行配置，互不覆盖
#

PROGRAM_NAME="vpn-fw-helper"
BASE_DIR="/etc/${PROGRAM_NAME}"
CONFIG_FILE="${BASE_DIR}/config.env"
SNAT_STORE="${BASE_DIR}/snat.rules"
PORT_STORE="${BASE_DIR}/port.rules"
SYSCTL_FILE="/etc/sysctl.d/99-${PROGRAM_NAME}.conf"

UFW_BEFORE_RULES="/etc/ufw/before.rules"
UFW_SYSCTL_FILE="/etc/ufw/sysctl.conf"

UFW_NAT_BEGIN="# VPNFWHELPER NAT START"
UFW_NAT_END="# VPNFWHELPER NAT END"
UFW_FILTER_BEGIN="# VPNFWHELPER FILTER START"
UFW_FILTER_END="# VPNFWHELPER FILTER END"

IPTABLES_CHAIN_INPUT="VPNFWHELPER_INPUT"
IPTABLES_CHAIN_FORWARD="VPNFWHELPER_FORWARD"
IPTABLES_CHAIN_POSTROUTING="VPNFWHELPER_POSTROUTING"

NFT_RULES_FILE="${BASE_DIR}/nftables.rules"
NFT_APPLY_SCRIPT="/usr/local/sbin/${PROGRAM_NAME}-nft-apply.sh"
NFT_SYSTEMD_SERVICE="/etc/systemd/system/${PROGRAM_NAME}-nftables.service"
NFT_OPENRC_SERVICE="/etc/init.d/${PROGRAM_NAME}-nftables"

IPTABLES_RULES_FILE="${BASE_DIR}/iptables.rules"
IPTABLES_APPLY_SCRIPT="/usr/local/sbin/${PROGRAM_NAME}-iptables-restore.sh"
IPTABLES_SYSTEMD_SERVICE="/etc/systemd/system/${PROGRAM_NAME}-iptables.service"
IPTABLES_OPENRC_SERVICE="/etc/init.d/${PROGRAM_NAME}-iptables"

INITIAL_BACKUP_DIR="${BASE_DIR}/initial-backup"
INITIAL_BACKUP_META="${INITIAL_BACKUP_DIR}/metadata.env"
INITIAL_BACKUP_CONFIG_ARCHIVE="${INITIAL_BACKUP_DIR}/host-config.tar.gz"
INITIAL_BACKUP_IPTABLES="${INITIAL_BACKUP_DIR}/iptables.rules"
INITIAL_BACKUP_IP6TABLES="${INITIAL_BACKUP_DIR}/ip6tables.rules"
INITIAL_BACKUP_NFTABLES="${INITIAL_BACKUP_DIR}/nftables.rules"

SNAPSHOT_DIR="${BASE_DIR}/snapshots"
INITIAL_SNAPSHOT_ID="000-initial"

TTY_IN="/dev/tty"
SELF_UPDATE_URL_PRIMARY="https://www.feijiangkeji.com/assets/uploads/snat.sh"
SELF_UPDATE_URL_SECONDARY="https://pan.yydy.link:2023/d/share/script/snat.sh"

TMP_BASE="${TMPDIR:-/tmp}"
SNAT_TMP="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.snat.XXXXXX")"
PORT_TMP="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.port.XXXXXX")"
IFACE_TMP="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.iface.XXXXXX")"
VIEW_TMP1="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.view1.XXXXXX")"
VIEW_TMP2="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.view2.XXXXXX")"
WORK_TMP1="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.work1.XXXXXX")"
WORK_TMP2="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.work2.XXXXXX")"
WORK_TMP3="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.work3.XXXXXX")"
WORK_TMP4="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.work4.XXXXXX")"
SELF_UPDATE_TMP="$(mktemp "${TMP_BASE}/${PROGRAM_NAME}.self.XXXXXX")"

OS_ID=""
OS_LIKE=""
OS_NAME=""
OS_FAMILY=""
PKG_MGR=""
BACKEND=""
CURRENT_IF=""
DEFAULT_WAN_IF=""
IP_FORWARD_PLAN="nochange"
FW_INPUT_PLAN=""
FW_OUTPUT_PLAN=""
FW_FORWARD_PLAN=""

fw_in_policy=""
fw_out_policy=""
fw_fwd_policy=""
fw_policy_detail=""

SELECTED_IF=""
SELECTED_PROTO=""
USER_INPUT=""

FIREWALLD_POLICY_ALLOW_PRIO="0"
FIREWALLD_POLICY_DENY_PRIO="32000"

COLOR_ENABLED="0"
CLR_RESET=""
CLR_RED=""
CLR_GREEN=""
CLR_YELLOW=""
CLR_BLUE=""
CLR_PURPLE=""
SCRIPT_SELF=""

cleanup() {
    rm -f "$SNAT_TMP" "$PORT_TMP" "$IFACE_TMP" "$VIEW_TMP1" "$VIEW_TMP2" \
          "$WORK_TMP1" "$WORK_TMP2" "$WORK_TMP3" "$WORK_TMP4" "$SELF_UPDATE_TMP"
}
trap cleanup EXIT INT TERM

msg() {
    printf '%s\n' "$*"
}

err() {
    printf '错误: %s\n' "$*" >&2
}

init_colors() {
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        COLOR_ENABLED="1"
        _esc="$(printf '\033')"
        CLR_RESET="${_esc}[0m"
        CLR_RED="${_esc}[31m"
        CLR_GREEN="${_esc}[32m"
        CLR_YELLOW="${_esc}[33m"
        CLR_BLUE="${_esc}[34m"
        CLR_PURPLE="${_esc}[35m"
    else
        COLOR_ENABLED="0"
        CLR_RESET=""
        CLR_RED=""
        CLR_GREEN=""
        CLR_YELLOW=""
        CLR_BLUE=""
        CLR_PURPLE=""
    fi
}

color_wrap() {
    _color="$1"
    shift
    if [ "$COLOR_ENABLED" = "1" ] && [ -n "$_color" ]; then
        printf '%s%s%s' "$_color" "$*" "$CLR_RESET"
    else
        printf '%s' "$*"
    fi
}

format_policy_value() {
    case "$1" in
        允许|默认允许|allow|ACCEPT|accept) color_wrap "$CLR_GREEN" "$1" ;;
        拒绝|默认拒绝|deny|DROP|drop|REJECT|reject) color_wrap "$CLR_RED" "$1" ;;
        不修改|nochange) color_wrap "$CLR_YELLOW" "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

format_plan_value() {
    _label="$(policy_plan_label "$1")"
    format_policy_value "$_label"
}

format_iface_value() {
    color_wrap "$CLR_BLUE" "$1"
}

format_count_value() {
    color_wrap "$CLR_PURPLE" "$1"
}

read_tty() {
    USER_INPUT=""
    if [ ! -e "$TTY_IN" ]; then
        err "当前环境没有可用的交互终端 /dev/tty"
        exit 1
    fi
    IFS= read -r USER_INPUT < "$TTY_IN"
}

pause() {
    printf '按回车继续...' > "$TTY_IN"
    read_tty
}

confirm() {
    printf '%s [y/N]: ' "$1" > "$TTY_IN"
    read_tty
    case "$USER_INPUT" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

require_root() {
    if [ "$(id -u 2>/dev/null)" != "0" ]; then
        err "请使用 root 运行此脚本。"
        exit 1
    fi
}

count_nonempty_lines() {
    if [ ! -f "$1" ]; then
        echo 0
        return
    fi
    awk 'NF { c++ } END { print c+0 }' "$1"
}

backup_file() {
    _f="$1"
    if [ -f "$_f" ]; then
        _ts="$(date +%Y%m%d%H%M%S 2>/dev/null || echo now)"
        cp -f "$_f" "${_f}.bak.${_ts}" 2>/dev/null || true
    fi
}

capture_initial_host_backup() {
    # The baseline is intentionally write-once so "rollback" always means
    # the host state from before this tool made its first change.
    [ -f "$INITIAL_BACKUP_META" ] && return 0

    mkdir -p "$INITIAL_BACKUP_DIR" || {
        err "无法创建首次运行备份目录: ${INITIAL_BACKUP_DIR}"
        return 1
    }
    chmod 700 "$INITIAL_BACKUP_DIR" 2>/dev/null || true

    _initial_backend="$(detect_backend)"
    _initial_ip_forward="$(get_ip_forward_runtime_value)"
    _initial_ufw_active="no"
    _initial_firewalld_active="no"
    _archive_items=""

    if command_exists ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        _initial_ufw_active="yes"
    fi
    if command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        _initial_firewalld_active="yes"
    fi

    for _path in /etc/sysctl.conf /etc/sysctl.d /etc/ufw /etc/firewalld; do
        [ -e "$_path" ] || continue
        _archive_items="${_archive_items} ${_path#/}"
    done
    if [ -n "$_archive_items" ]; then
        # shellcheck disable=SC2086
        tar -C / -czpf "$INITIAL_BACKUP_CONFIG_ARCHIVE" $_archive_items 2>/dev/null || {
            err "首次运行配置归档失败。"
            return 1
        }
    else
        : > "$INITIAL_BACKUP_CONFIG_ARCHIVE"
    fi

    if command_exists iptables-save; then
        iptables-save > "$INITIAL_BACKUP_IPTABLES" 2>/dev/null || true
    fi
    if command_exists ip6tables-save; then
        ip6tables-save > "$INITIAL_BACKUP_IP6TABLES" 2>/dev/null || true
    fi
    if nft_is_usable; then
        get_nft_ruleset_quiet > "$INITIAL_BACKUP_NFTABLES" 2>/dev/null || true
    fi

    cat > "$INITIAL_BACKUP_META" <<EOF
BACKUP_CREATED_AT='$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)'
INITIAL_BACKEND='${_initial_backend}'
INITIAL_IP_FORWARD='${_initial_ip_forward}'
INITIAL_UFW_ACTIVE='${_initial_ufw_active}'
INITIAL_FIREWALLD_ACTIVE='${_initial_firewalld_active}'
EOF
    chmod 600 "$INITIAL_BACKUP_META" "$INITIAL_BACKUP_CONFIG_ARCHIVE" \
        "$INITIAL_BACKUP_IPTABLES" "$INITIAL_BACKUP_IP6TABLES" \
        "$INITIAL_BACKUP_NFTABLES" 2>/dev/null || true
    return 0
}

initial_backup_status() {
    if [ -f "$INITIAL_BACKUP_META" ]; then
        printf '已建立'
    else
        printf '未建立'
    fi
}

initial_backup_created_at() {
    if [ -f "$INITIAL_BACKUP_META" ]; then
        awk -F"'" '/^BACKUP_CREATED_AT=/{print $2; exit}' "$INITIAL_BACKUP_META"
    else
        printf '未建立'
    fi
}

remove_tool_persistence() {
    rm -f "$CONFIG_FILE" "$SNAT_STORE" "$PORT_STORE" "$SYSCTL_FILE" \
          "$NFT_RULES_FILE" "$IPTABLES_RULES_FILE" \
          "$NFT_APPLY_SCRIPT" "$IPTABLES_APPLY_SCRIPT" \
          "$NFT_SYSTEMD_SERVICE" "$IPTABLES_SYSTEMD_SERVICE" \
          "$NFT_OPENRC_SERVICE" "$IPTABLES_OPENRC_SERVICE"
    if has_systemd; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

restore_initial_host_backup() {
    if [ ! -f "$INITIAL_BACKUP_META" ]; then
        err "未找到首次运行备份，无法执行回退。"
        return 1
    fi
    # The file is generated by this script and only contains quoted scalar values.
    . "$INITIAL_BACKUP_META"

    msg "将恢复首次运行时的宿主机防火墙和 IPv4 转发状态。"
    msg "这会覆盖 /etc/sysctl.d、/etc/ufw 和 /etc/firewalld 的当前配置。"
    if ! confirm "确认回退到首次运行前的初始配置吗"; then
        msg "已取消回退。"
        return 1
    fi

    if command_exists systemctl; then
        systemctl disable --now "${PROGRAM_NAME}-nftables.service" "${PROGRAM_NAME}-iptables.service" >/dev/null 2>&1 || true
    fi
    remove_tool_persistence

    rm -rf /etc/sysctl.conf /etc/sysctl.d /etc/ufw /etc/firewalld
    if [ -s "$INITIAL_BACKUP_CONFIG_ARCHIVE" ]; then
        tar -C / -xzpf "$INITIAL_BACKUP_CONFIG_ARCHIVE" || {
            err "恢复宿主机配置文件失败。"
            return 1
        }
    fi

    case "${INITIAL_BACKEND:-}" in
        firewalld)
            if command_exists firewall-cmd; then
                if [ "${INITIAL_FIREWALLD_ACTIVE:-no}" = "yes" ]; then
                    systemctl enable --now firewalld >/dev/null 2>&1 || true
                    firewall-cmd --reload >/dev/null 2>&1 || true
                else
                    systemctl stop firewalld >/dev/null 2>&1 || true
                fi
            fi
            ;;
        ufw)
            if command_exists ufw; then
                if [ "${INITIAL_UFW_ACTIVE:-no}" = "yes" ]; then
                    ufw --force enable >/dev/null 2>&1 || true
                    ufw reload >/dev/null 2>&1 || true
                else
                    ufw --force disable >/dev/null 2>&1 || true
                fi
            fi
            ;;
        nftables)
            if nft_is_usable && [ -f "$INITIAL_BACKUP_NFTABLES" ]; then
                nft flush ruleset >/dev/null 2>&1 || true
                nft -f "$INITIAL_BACKUP_NFTABLES" || return 1
            fi
            ;;
        iptables|*)
            if command_exists iptables-restore && [ -s "$INITIAL_BACKUP_IPTABLES" ]; then
                iptables-restore < "$INITIAL_BACKUP_IPTABLES" || return 1
            fi
            if command_exists ip6tables-restore && [ -s "$INITIAL_BACKUP_IP6TABLES" ]; then
                ip6tables-restore < "$INITIAL_BACKUP_IP6TABLES" || true
            fi
            ;;
    esac

    if [ -n "${INITIAL_IP_FORWARD:-}" ] && [ -w /proc/sys/net/ipv4/ip_forward ]; then
        printf '%s' "$INITIAL_IP_FORWARD" > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
    fi
    if command_exists sysctl; then
        sysctl -p /etc/sysctl.conf >/dev/null 2>&1 || true
    fi
    : > "$SNAT_TMP"
    : > "$PORT_TMP"
    CURRENT_IF="$(get_default_wan_if)"
    DEFAULT_WAN_IF="$CURRENT_IF"
    IP_FORWARD_PLAN="nochange"
    FW_INPUT_PLAN=""
    FW_OUTPUT_PLAN=""
    FW_FORWARD_PLAN=""
    choose_backend_if_needed
    detect_firewall_policies
    msg "已回退到首次运行时的宿主机配置。首次备份仍保留在: ${INITIAL_BACKUP_DIR}"
    return 0
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

nft_is_usable() {
    command_exists nft || return 1
    /bin/sh -c 'nft list ruleset >/dev/null 2>&1' >/dev/null 2>&1
}

get_nft_ruleset_quiet() {
    command_exists nft || return 1
    /bin/sh -c 'nft list ruleset 2>/dev/null' 2>/dev/null
}

resolve_script_self() {
    _candidate="$0"

    if [ -n "$_candidate" ] && [ -f "$_candidate" ]; then
        case "$_candidate" in
            /*) SCRIPT_SELF="$_candidate" ;;
            *) SCRIPT_SELF="$(cd "$(dirname "$_candidate")" 2>/dev/null && pwd)/$(basename "$_candidate")" ;;
        esac
        return 0
    fi

    _resolved="$(command -v "$_candidate" 2>/dev/null | head -n 1)"
    if [ -n "$_resolved" ] && [ -f "$_resolved" ]; then
        SCRIPT_SELF="$_resolved"
        return 0
    fi

    SCRIPT_SELF=""
    return 1
}

has_systemd() {
    command_exists systemctl && [ -d /run/systemd/system ]
}

has_openrc() {
    command_exists rc-service && command_exists rc-update
}

enable_service() {
    _svc="$1"
    if has_systemd; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable "$_svc" >/dev/null 2>&1 || true
        return 0
    fi
    if has_openrc; then
        rc-update add "$_svc" default >/dev/null 2>&1 || true
        return 0
    fi
    return 0
}

download_to_file() {
    _url="$1"
    _dst="$2"

    if command_exists curl; then
        curl -fsSL --connect-timeout 15 --max-time 120 "$_url" -o "$_dst"
        return $?
    fi

    if command_exists wget; then
        wget -q -T 15 -O "$_dst" "$_url"
        return $?
    fi

    ensure_package curl curl || return 1
    curl -fsSL --connect-timeout 15 --max-time 120 "$_url" -o "$_dst"
}

normalize_downloaded_script() {
    _src="$1"
    _dst="$2"
    awk '{ sub(/\r$/, ""); print }' "$_src" > "$_dst"
}

validate_downloaded_script() {
    _file="$1"
    [ -s "$_file" ] || return 1
    _first_line="$(awk 'NR==1 { sub(/^\xef\xbb\xbf/, ""); print; exit }' "$_file")"

    case "$_first_line" in
        '#!/bin/sh'|'#!/usr/bin/sh'|'#!/usr/bin/env sh'|'#!/bin/bash'|'#!/usr/bin/bash'|'#!/usr/bin/env bash')
            ;;
        *)
            return 1
            ;;
    esac

    grep -q '^PROGRAM_NAME="vpn-fw-helper"$' "$_file" || return 1
    grep -q '^main_menu() {$' "$_file" || return 1
    return 0
}

download_with_retries() {
    _url="$1"
    _tries="$2"
    _n=1

    while [ "$_n" -le "$_tries" ]; do
        : > "$SELF_UPDATE_TMP"
        msg "尝试更新(${_n}/${_tries}): ${_url}"
        if download_to_file "$_url" "$WORK_TMP1"; then
            normalize_downloaded_script "$WORK_TMP1" "$SELF_UPDATE_TMP"
            if validate_downloaded_script "$SELF_UPDATE_TMP"; then
                return 0
            fi
            err "下载内容校验失败，内容不像有效的 snat.sh。"
        else
            err "下载失败。"
        fi
        _n=$((_n + 1))
    done

    return 1
}

update_self_script() {
    if ! resolve_script_self; then
        err "无法确定当前脚本路径，不能执行自更新。"
        return 1
    fi

    msg "当前脚本路径: ${SCRIPT_SELF}"
    msg "开始从主地址更新..."
    if ! download_with_retries "$SELF_UPDATE_URL_PRIMARY" 3; then
        msg "主地址连续 3 次更新失败，开始切换备用地址..."
        if ! download_with_retries "$SELF_UPDATE_URL_SECONDARY" 3; then
            err "主地址和备用地址都更新失败。"
            return 1
        fi
    fi

    if [ -f "$SCRIPT_SELF" ]; then
        backup_file "$SCRIPT_SELF"
    fi

    if cmp -s "$SELF_UPDATE_TMP" "$SCRIPT_SELF" 2>/dev/null; then
        msg "当前脚本已经是最新内容，无需覆盖。"
        return 0
    fi

    cat "$SELF_UPDATE_TMP" > "$SCRIPT_SELF" || {
        err "覆盖当前脚本失败。"
        return 1
    }
    chmod 755 "$SCRIPT_SELF" >/dev/null 2>&1 || true

    msg ""
    msg "脚本更新成功。"
    msg "已备份旧文件，建议立即重新执行最新的 snat.sh。"
    exit 0
}

start_service() {
    _svc="$1"
    if has_systemd; then
        systemctl start "$_svc" >/dev/null 2>&1 || true
        return 0
    fi
    if has_openrc; then
        rc-service "$_svc" start >/dev/null 2>&1 || true
        return 0
    fi
    return 0
}

detect_os() {
    if [ -r /etc/os-release ]; then
        OS_ID="$(awk -F= '/^ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release)"
        OS_LIKE="$(awk -F= '/^ID_LIKE=/{gsub(/"/,"",$2); print $2}' /etc/os-release)"
        OS_NAME="$(awk -F= '/^PRETTY_NAME=/{sub(/^PRETTY_NAME=/,""); gsub(/"/,""); print}' /etc/os-release)"
    else
        OS_ID="unknown"
        OS_LIKE=""
        OS_NAME="unknown"
    fi

    case " ${OS_ID} ${OS_LIKE} " in
        *" ubuntu "*|*" debian "*|*" kali "*)
            OS_FAMILY="debian"
            PKG_MGR="apt"
            ;;
        *" centos "*|*" rhel "*|*" rocky "*|*" almalinux "*|*" fedora "*)
            OS_FAMILY="rhel"
            if command_exists dnf; then
                PKG_MGR="dnf"
            else
                PKG_MGR="yum"
            fi
            ;;
        *" alpine "*)
            OS_FAMILY="alpine"
            PKG_MGR="apk"
            ;;
        *" arch "*)
            OS_FAMILY="arch"
            PKG_MGR="pacman"
            ;;
        *)
            if command_exists apt-get; then
                OS_FAMILY="debian"
                PKG_MGR="apt"
            elif command_exists dnf; then
                OS_FAMILY="rhel"
                PKG_MGR="dnf"
            elif command_exists yum; then
                OS_FAMILY="rhel"
                PKG_MGR="yum"
            elif command_exists apk; then
                OS_FAMILY="alpine"
                PKG_MGR="apk"
            elif command_exists pacman; then
                OS_FAMILY="arch"
                PKG_MGR="pacman"
            else
                OS_FAMILY="unknown"
                PKG_MGR=""
            fi
            ;;
    esac
}

pkg_update() {
    case "$PKG_MGR" in
        apt) apt-get update ;;
        dnf) dnf makecache -y ;;
        yum) yum makecache -y ;;
        apk) apk update ;;
        pacman) pacman -Sy --noconfirm ;;
        *)
            err "无法识别包管理器，无法自动安装依赖。"
            return 1
            ;;
    esac
}

pkg_install() {
    case "$PKG_MGR" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        dnf) dnf install -y "$@" ;;
        yum) yum install -y "$@" ;;
        apk) apk add "$@" ;;
        pacman) pacman -S --noconfirm --needed "$@" ;;
        *)
            err "无法识别包管理器，无法自动安装依赖。"
            return 1
            ;;
    esac
}

ensure_package() {
    _cmd="$1"
    _pkg="$2"
    if command_exists "$_cmd"; then
        return 0
    fi
    msg "检测到缺少命令: ${_cmd}，准备安装软件包: ${_pkg}"
    pkg_update || return 1
    pkg_install "$_pkg" || return 1
}

detect_backend() {
    if command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        echo "firewalld"
        return
    fi

    if command_exists ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        echo "ufw"
        return
    fi

    if nft_is_usable; then
        echo "nftables"
        return
    fi

    if command_exists iptables; then
        echo "iptables"
        return
    fi

    echo "iptables"
}

get_ip_forward_runtime_value() {
    if [ -r /proc/sys/net/ipv4/ip_forward ]; then
        cat /proc/sys/net/ipv4/ip_forward 2>/dev/null
        return
    fi
    if command_exists sysctl; then
        sysctl -n net.ipv4.ip_forward 2>/dev/null
        return
    fi
    echo "unknown"
}

ip_forward_runtime_label() {
    _v="$(get_ip_forward_runtime_value)"
    case "$_v" in
        1) echo "已开启" ;;
        0) echo "未开启" ;;
        *) echo "未知" ;;
    esac
}

ip_forward_plan_label() {
    case "$IP_FORWARD_PLAN" in
        permanent) echo "永久开启" ;;
        temporary) echo "临时开启" ;;
        nochange|"") echo "不修改" ;;
        *) echo "$IP_FORWARD_PLAN" ;;
    esac
}

policy_plan_label() {
    case "$1" in
        allow) echo "默认允许" ;;
        deny) echo "默认拒绝" ;;
        *) echo "未知" ;;
    esac
}

get_policy_plan_value() {
    case "$1" in
        input) printf '%s\n' "$FW_INPUT_PLAN" ;;
        output) printf '%s\n' "$FW_OUTPUT_PLAN" ;;
        forward) printf '%s\n' "$FW_FORWARD_PLAN" ;;
        *) printf '%s\n' "unknown" ;;
    esac
}

set_policy_plan_value() {
    case "$1" in
        input) FW_INPUT_PLAN="$2" ;;
        output) FW_OUTPUT_PLAN="$2" ;;
        forward) FW_FORWARD_PLAN="$2" ;;
    esac
}

reset_fw_policy_cache() {
    fw_in_policy="未知"
    fw_out_policy="未知"
    fw_fwd_policy="未知"
    fw_policy_detail=""
}

normalize_policy_label() {
    case "$1" in
        ACCEPT|accept|ALLOW|allow) echo "允许" ;;
        DROP|drop|REJECT|reject|DENY|deny) echo "拒绝" ;;
        *) echo "未知" ;;
    esac
}

policy_plan_from_runtime_label() {
    case "$1" in
        允许) printf '%s\n' "allow" ;;
        拒绝) printf '%s\n' "deny" ;;
        *) printf '%s\n' "unknown" ;;
    esac
}

normalize_security_policy_plans() {
    case "$FW_INPUT_PLAN" in allow|deny) ;; *) FW_INPUT_PLAN="$(policy_plan_from_runtime_label "$fw_in_policy")" ;; esac
    case "$FW_OUTPUT_PLAN" in allow|deny) ;; *) FW_OUTPUT_PLAN="$(policy_plan_from_runtime_label "$fw_out_policy")" ;; esac
    case "$FW_FORWARD_PLAN" in allow|deny) ;; *) FW_FORWARD_PLAN="$(policy_plan_from_runtime_label "$fw_fwd_policy")" ;; esac
}

validate_security_policy_plans() {
    for _policy_plan in "$FW_INPUT_PLAN" "$FW_OUTPUT_PLAN" "$FW_FORWARD_PLAN"; do
        case "$_policy_plan" in
            allow|deny) ;;
            *)
                err "存在未识别的安全策略，请先在 03 配置安全策略后再应用。"
                return 1
                ;;
        esac
    done
    return 0
}

detect_iptables_policies() {
    _input_raw="$(iptables -L INPUT 2>/dev/null | awk '/^Chain INPUT / {gsub(/[()]/,""); for(i=1;i<=NF;i++){if($i=="policy"){print $(i+1); exit}}}')"
    _output_raw="$(iptables -L OUTPUT 2>/dev/null | awk '/^Chain OUTPUT / {gsub(/[()]/,""); for(i=1;i<=NF;i++){if($i=="policy"){print $(i+1); exit}}}')"
    _forward_raw="$(iptables -L FORWARD 2>/dev/null | awk '/^Chain FORWARD / {gsub(/[()]/,""); for(i=1;i<=NF;i++){if($i=="policy"){print $(i+1); exit}}}')"

    fw_in_policy="$(normalize_policy_label "$_input_raw")"
    fw_out_policy="$(normalize_policy_label "$_output_raw")"
    fw_fwd_policy="$(normalize_policy_label "$_forward_raw")"
    fw_policy_detail="iptables原始策略: INPUT=${_input_raw:-unknown}, OUTPUT=${_output_raw:-unknown}, FORWARD=${_forward_raw:-unknown}"
}

detect_nftables_policies() {
    _ruleset="$(get_nft_ruleset_quiet)" || {
        fw_in_policy="未知"
        fw_out_policy="未知"
        fw_fwd_policy="未知"
        fw_policy_detail="nftables 原始策略读取失败: nft 命令在当前系统执行异常"
        return 0
    }

    _input_raw="$(printf '%s\n' "$_ruleset" | awk '
        /hook input/ {
            for (i=1;i<=NF;i++) {
                if ($i=="policy") {
                    gsub(/;/,"",$(i+1))
                    print $(i+1)
                    exit
                }
            }
        }'
    )"

    _output_raw="$(printf '%s\n' "$_ruleset" | awk '
        /hook output/ {
            for (i=1;i<=NF;i++) {
                if ($i=="policy") {
                    gsub(/;/,"",$(i+1))
                    print $(i+1)
                    exit
                }
            }
        }'
    )"

    _forward_raw="$(printf '%s\n' "$_ruleset" | awk '
        /hook forward/ {
            for (i=1;i<=NF;i++) {
                if ($i=="policy") {
                    gsub(/;/,"",$(i+1))
                    print $(i+1)
                    exit
                }
            }
        }'
    )"

    fw_in_policy="$(normalize_policy_label "$_input_raw")"
    fw_out_policy="$(normalize_policy_label "$_output_raw")"
    fw_fwd_policy="$(normalize_policy_label "$_forward_raw")"
    fw_policy_detail="nftables原始策略: input=${_input_raw:-unknown}, output=${_output_raw:-unknown}, forward=${_forward_raw:-unknown}"
}

detect_ufw_policies() {
    _status="$(ufw status verbose 2>/dev/null)"

    _incoming_raw="$(printf '%s\n' "$_status" | awk -F': ' '/Default:/{
        split($2,a,",")
        gsub(/^[ \t]+|[ \t]+$/,"",a[1])
        print a[1]
        exit
    }')"

    _outgoing_raw="$(printf '%s\n' "$_status" | awk -F': ' '/Default:/{
        split($2,a,",")
        gsub(/^[ \t]+|[ \t]+$/,"",a[2])
        print a[2]
        exit
    }')"

    _routed_raw="$(printf '%s\n' "$_status" | awk -F': ' '/Default:/{
        split($2,a,",")
        gsub(/^[ \t]+|[ \t]+$/,"",a[3])
        print a[3]
        exit
    }')"

    fw_in_policy="$(normalize_policy_label "$_incoming_raw")"
    fw_out_policy="$(normalize_policy_label "$_outgoing_raw")"
    fw_fwd_policy="$(normalize_policy_label "$_routed_raw")"
    fw_policy_detail="ufw原始默认策略: incoming=${_incoming_raw:-unknown}, outgoing=${_outgoing_raw:-unknown}, routed=${_routed_raw:-unknown}"
}

detect_firewalld_policies() {
    _default_zone="$(firewall-cmd --get-default-zone 2>/dev/null | head -n 1)"
    _zone_target=""
    _zone_info=""
    _forward_flag=""
    _direct_rules="$(firewall-cmd --direct --get-all-rules 2>/dev/null)"
    if [ -n "$_default_zone" ]; then
        _zone_info="$(firewall-cmd --info-zone="$_default_zone" 2>/dev/null)"
        _zone_target="$(printf '%s\n' "$_zone_info" | awk -F': ' '/^[[:space:]]*target:/ {print $2; exit}')"
        _forward_flag="$(printf '%s\n' "$_zone_info" | awk -F': ' '/^[[:space:]]*forward:/ {print $2; exit}')"
    fi

    case "$_zone_target" in
        ACCEPT|accept)
            fw_in_policy="允许"
            ;;
        DROP|drop|REJECT|reject)
            fw_in_policy="拒绝"
            ;;
        default|DEFAULT|"")
            fw_in_policy="拒绝"
            ;;
        *)
            fw_in_policy="拒绝"
            ;;
    esac

    # firewalld 的常规主机模型下，未显式允许的入站默认阻断，出站默认允许。
    fw_out_policy="允许"

    case "$_forward_flag" in
        yes|true|on)
            fw_fwd_policy="拒绝"
            fw_policy_detail="firewalld默认区域=${_default_zone:-unknown}, zone target=${_zone_target:-default}, intra-zone forward=${_forward_flag}, inter-zone默认拒绝"
            ;;
        no|false|off|"")
            fw_fwd_policy="拒绝"
            fw_policy_detail="firewalld默认区域=${_default_zone:-unknown}, zone target=${_zone_target:-default}, intra-zone forward=${_forward_flag:-no}, inter-zone默认拒绝"
            ;;
        *)
            fw_fwd_policy="拒绝"
            fw_policy_detail="firewalld默认区域=${_default_zone:-unknown}, zone target=${_zone_target:-default}, intra-zone forward=${_forward_flag:-unknown}, inter-zone默认拒绝"
            ;;
    esac

    _input_direct="$(printf '%s\n' "$_direct_rules" | awk -v ap="$FIREWALLD_POLICY_ALLOW_PRIO" -v dp="$FIREWALLD_POLICY_DENY_PRIO" '
        $1=="ipv4" && $2=="filter" && $3=="INPUT" && $4==ap && $0 ~ /-j ACCEPT$/ { print "允许"; exit }
        $1=="ipv4" && $2=="filter" && $3=="INPUT" && $4==dp && $0 ~ /-j DROP$/ { print "拒绝"; exit }
    ')"
    _output_direct="$(printf '%s\n' "$_direct_rules" | awk -v ap="$FIREWALLD_POLICY_ALLOW_PRIO" -v dp="$FIREWALLD_POLICY_DENY_PRIO" '
        $1=="ipv4" && $2=="filter" && $3=="OUTPUT" && $4==ap && $0 ~ /-j ACCEPT$/ { print "允许"; exit }
        $1=="ipv4" && $2=="filter" && $3=="OUTPUT" && $4==dp && $0 ~ /-j DROP$/ { print "拒绝"; exit }
    ')"
    _forward_direct="$(printf '%s\n' "$_direct_rules" | awk -v ap="$FIREWALLD_POLICY_ALLOW_PRIO" -v dp="$FIREWALLD_POLICY_DENY_PRIO" '
        $1=="ipv4" && $2=="filter" && $3=="FORWARD" && $4==ap && $0 ~ /-j ACCEPT$/ { print "允许"; exit }
        $1=="ipv4" && $2=="filter" && $3=="FORWARD" && $4==dp && $0 ~ /-j DROP$/ { print "拒绝"; exit }
    ')"

    [ -n "$_input_direct" ] && fw_in_policy="$_input_direct"
    [ -n "$_output_direct" ] && fw_out_policy="$_output_direct"
    [ -n "$_forward_direct" ] && fw_fwd_policy="$_forward_direct"
}

detect_firewall_policies() {
    reset_fw_policy_cache

    case "$BACKEND" in
        iptables)
            detect_iptables_policies
            ;;
        nftables)
            detect_nftables_policies
            ;;
        ufw)
            detect_ufw_policies
            ;;
        firewalld)
            detect_firewalld_policies
            ;;
        *)
            fw_in_policy="未知"
            fw_out_policy="未知"
            fw_fwd_policy="未知"
            fw_policy_detail="未识别后端，无法判断默认策略"
            ;;
    esac
}

configure_ip_forward_menu() {
    while :; do
        msg ""
        msg "===== IPv4 转发配置 ====="
        msg "当前系统运行状态: $(ip_forward_runtime_label)"
        msg "当前脚本计划: $(ip_forward_plan_label)"
        msg ""
        msg "1) 永久开启"
        msg "2) 临时开启"
        msg "3) 不修改"
        msg "4) 仅刷新查看当前状态"
        msg "0) 返回主菜单"
        printf '请选择: ' > "$TTY_IN"
        read_tty
        case "$USER_INPUT" in
            1)
                IP_FORWARD_PLAN="permanent"
                msg "已设置: IPv4 转发 = 永久开启"
                pause
                return 0
                ;;
            2)
                IP_FORWARD_PLAN="temporary"
                msg "已设置: IPv4 转发 = 临时开启"
                pause
                return 0
                ;;
            3)
                IP_FORWARD_PLAN="nochange"
                msg "已设置: IPv4 转发 = 不修改"
                pause
                return 0
                ;;
            4)
                msg "当前系统 IPv4 转发运行状态: $(ip_forward_runtime_label)"
                pause
                ;;
            0)
                return 0
                ;;
            *)
                err "无效选项。"
                pause
                ;;
        esac
    done
}

configure_single_default_policy() {
    _key="$1"
    _label="$2"
    while :; do
        msg ""
        msg "===== ${_label} 默认策略 ====="
        msg "当前计划: $(policy_plan_label "$(get_policy_plan_value "$_key")")"
        msg ""
        msg "1) 默认允许"
        msg "2) 默认拒绝"
        msg "0) 返回上一级"
        printf '请选择: ' > "$TTY_IN"
        read_tty
        case "$USER_INPUT" in
            1)
                set_policy_plan_value "$_key" "allow"
                msg "已设置: ${_label} = 默认允许"
                pause
                return 0
                ;;
            2)
                set_policy_plan_value "$_key" "deny"
                msg "已设置: ${_label} = 默认拒绝"
                pause
                return 0
                ;;
            0)
                return 0
                ;;
            *)
                err "无效选项。"
                pause
                ;;
        esac
    done
}

configure_default_policy_menu() {
    while :; do
        msg ""
        msg "===== 默认策略配置 ====="
        msg "入站计划: $(policy_plan_label "$FW_INPUT_PLAN")"
        msg "出站计划: $(policy_plan_label "$FW_OUTPUT_PLAN")"
        msg "转发计划: $(policy_plan_label "$FW_FORWARD_PLAN")"
        msg ""
        msg "1) 配置默认入站策略"
        msg "2) 配置默认出站策略"
        msg "3) 配置默认转发策略"
        msg "4) 全部设为默认允许"
        msg "5) 全部设为默认拒绝"
        msg "0) 返回主菜单"
        printf '请选择: ' > "$TTY_IN"
        read_tty
        case "$USER_INPUT" in
            1) configure_single_default_policy "input" "入站" ;;
            2) configure_single_default_policy "output" "出站" ;;
            3) configure_single_default_policy "forward" "转发" ;;
            4)
                FW_INPUT_PLAN="allow"
                FW_OUTPUT_PLAN="allow"
                FW_FORWARD_PLAN="allow"
                msg "已设置: 入站/出站/转发 = 默认允许"
                pause
                ;;
            5)
                FW_INPUT_PLAN="deny"
                FW_OUTPUT_PLAN="deny"
                FW_FORWARD_PLAN="deny"
                msg "已设置: 入站/出站/转发 = 默认拒绝"
                pause
                ;;
            0) return 0 ;;
            *)
                err "无效选项。"
                pause
                ;;
        esac
    done
}

get_default_wan_if() {
    ip route show default 2>/dev/null | awk '
        /default/ {
            for (i=1; i<=NF; i++) {
                if ($i == "dev") {
                    print $(i+1)
                    exit
                }
            }
        }
    '
}

build_interface_cache() {
    : > "$IFACE_TMP"

    if command_exists ip; then
        ip -o link show 2>/dev/null | awk -F': ' '
            {
                name=$2
                sub(/@.*/, "", name)
                if (name != "" && name != "lo" && !seen[name]++) {
                    print name
                }
            }
        ' > "$IFACE_TMP"
    fi

    if [ ! -s "$IFACE_TMP" ] && [ -d /sys/class/net ]; then
        for _path in /sys/class/net/*; do
            [ -e "$_path" ] || continue
            _name="$(basename "$_path")"
            [ "$_name" = "lo" ] && continue
            printf '%s\n' "$_name" >> "$IFACE_TMP"
        done
        trim_file_nonempty_unique "$IFACE_TMP"
    fi
}

list_interfaces() {
    _default_if="$1"
    build_interface_cache
    if [ ! -s "$IFACE_TMP" ]; then
        msg "未检测到可用网卡。"
        return 1
    fi

    awk -v def="$_default_if" '
        {
            mark=""
            if ($0 == def) mark="  [默认出口]"
            printf "%d) %s%s\n", NR, $0, mark
        }
    ' "$IFACE_TMP"
}

choose_interface_by_number() {
    _title="$1"
    _default_if="$2"
    SELECTED_IF=""

    build_interface_cache
    if [ ! -s "$IFACE_TMP" ]; then
        err "未检测到可用网卡。"
        return 1
    fi

    while :; do
        msg ""
        msg "===== ${_title} ====="
        list_interfaces "$_default_if"
        printf '请输入网卡编号 [0返回]: ' > "$TTY_IN"
        read_tty

        case "$USER_INPUT" in
            0)
                return 0
                ;;
            '')
                err "请输入编号。"
                ;;
            *)
                if echo "$USER_INPUT" | awk '$0 ~ /^[0-9]+$/ { ok=1 } END { exit ok ? 0 : 1 }'; then
                    _chosen="$(awk -v n="$USER_INPUT" 'NR==n { print; exit }' "$IFACE_TMP")"
                    if [ -n "$_chosen" ]; then
                        SELECTED_IF="$_chosen"
                        return 0
                    fi
                fi
                err "编号无效。"
                ;;
        esac
    done
}

trim_file_nonempty_unique() {
    _src="$1"
    [ -f "$_src" ] || return 0
    awk 'NF && !seen[$0]++ { print }' "$_src" > "$WORK_TMP1"
    cat "$WORK_TMP1" > "$_src"
}

normalize_snat_file() {
    _src="$1"
    _dst="$2"
    _fallback_if="$3"
    : > "$_dst"
    [ -f "$_src" ] || return 0
    awk -F'|' -v fi="$_fallback_if" '
        NF==2 && $1 != "" && $2 != "" { print $1 "|" $2; next }
        NF==1 && $1 != "" && fi != "" { print fi "|" $1; next }
    ' "$_src" > "$_dst"
}

normalize_port_file() {
    _src="$1"
    _dst="$2"
    _fallback_if="$3"
    : > "$_dst"
    [ -f "$_src" ] || return 0
    awk -F'|' -v fi="$_fallback_if" '
        NF==3 && $1 != "" && $2 != "" && $3 != "" { print $1 "|" $2 "|" $3; next }
        NF==2 && $1 != "" && $2 != "" && fi != "" { print fi "|" $1 "|" $2; next }
    ' "$_src" > "$_dst"
}

load_saved_config() {
    mkdir -p "$BASE_DIR"
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
    fi

    if [ -z "$CURRENT_IF" ] && [ -n "${WAN_IF:-}" ]; then
        CURRENT_IF="$WAN_IF"
    fi

    [ -n "$IP_FORWARD_PLAN" ] || IP_FORWARD_PLAN="nochange"
    [ -n "$FW_INPUT_PLAN" ] || FW_INPUT_PLAN="unknown"
    [ -n "$FW_OUTPUT_PLAN" ] || FW_OUTPUT_PLAN="unknown"
    [ -n "$FW_FORWARD_PLAN" ] || FW_FORWARD_PLAN="unknown"

    normalize_snat_file "$SNAT_STORE" "$SNAT_TMP" "$CURRENT_IF"
    normalize_port_file "$PORT_STORE" "$PORT_TMP" "$CURRENT_IF"

    trim_file_nonempty_unique "$SNAT_TMP"
    trim_file_nonempty_unique "$PORT_TMP"
}

proto_label() {
    case "$1" in
        tcp) echo "tcp" ;;
        udp) echo "udp" ;;
        tcpudp) echo "tcp+udp" ;;
        icmp) echo "icmp" ;;
        *) echo "$1" ;;
    esac
}

save_current_config() {
    mkdir -p "$BASE_DIR"
    cat > "$CONFIG_FILE" <<EOF
CURRENT_IF='${CURRENT_IF}'
BACKEND='${BACKEND}'
OS_FAMILY='${OS_FAMILY}'
PKG_MGR='${PKG_MGR}'
IP_FORWARD_PLAN='${IP_FORWARD_PLAN}'
FW_INPUT_PLAN='${FW_INPUT_PLAN}'
FW_OUTPUT_PLAN='${FW_OUTPUT_PLAN}'
FW_FORWARD_PLAN='${FW_FORWARD_PLAN}'
EOF
    cp -f "$SNAT_TMP" "$SNAT_STORE"
    cp -f "$PORT_TMP" "$PORT_STORE"
}

write_snapshot_config() {
    _snapshot_path="$1"
    cat > "${_snapshot_path}/config.env" <<EOF
CURRENT_IF='${CURRENT_IF}'
BACKEND='${BACKEND}'
OS_FAMILY='${OS_FAMILY}'
PKG_MGR='${PKG_MGR}'
IP_FORWARD_PLAN='${IP_FORWARD_PLAN}'
FW_INPUT_PLAN='${FW_INPUT_PLAN}'
FW_OUTPUT_PLAN='${FW_OUTPUT_PLAN}'
FW_FORWARD_PLAN='${FW_FORWARD_PLAN}'
EOF
    cp -f "$SNAT_TMP" "${_snapshot_path}/snat.rules"
    cp -f "$PORT_TMP" "${_snapshot_path}/port.rules"
}

create_configuration_snapshot() {
    _snapshot_id="$1"
    _snapshot_type="$2"
    _snapshot_path="${SNAPSHOT_DIR}/${_snapshot_id}"

    [ -d "$_snapshot_path" ] && return 1
    mkdir -p "$_snapshot_path" || return 1
    chmod 700 "$_snapshot_path" 2>/dev/null || true
    write_snapshot_config "$_snapshot_path" || return 1
    cat > "${_snapshot_path}/metadata.env" <<EOF
SNAPSHOT_ID='${_snapshot_id}'
SNAPSHOT_TYPE='${_snapshot_type}'
CREATED_AT='$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)'
EOF
    chmod 600 "${_snapshot_path}"/* 2>/dev/null || true
    return 0
}

capture_initial_configuration_snapshot() {
    mkdir -p "$SNAPSHOT_DIR" || return 1
    chmod 700 "$SNAPSHOT_DIR" 2>/dev/null || true
    [ -d "${SNAPSHOT_DIR}/${INITIAL_SNAPSHOT_ID}" ] && return 0

    create_configuration_snapshot "$INITIAL_SNAPSHOT_ID" "initial" || {
        err "无法创建初始化配置快照。"
        return 1
    }
    return 0
}

save_configuration_snapshot() {
    mkdir -p "$SNAPSHOT_DIR" || return 1
    _snapshot_id="$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo snapshot)"
    _base_id="$_snapshot_id"
    _n=1
    while [ -e "${SNAPSHOT_DIR}/${_snapshot_id}" ]; do
        _snapshot_id="${_base_id}-${_n}"
        _n=$((_n + 1))
    done

    if create_configuration_snapshot "$_snapshot_id" "manual"; then
        msg "配置快照已保存: ${_snapshot_id}"
        return 0
    fi
    err "配置快照保存失败。"
    return 1
}

build_snapshot_list() {
    mkdir -p "$SNAPSHOT_DIR"
    {
        for _snapshot_path in "$SNAPSHOT_DIR"/*; do
            [ -d "$_snapshot_path" ] || continue
            [ -f "${_snapshot_path}/metadata.env" ] || continue
            _snapshot_id="$(awk -F"'" '/^SNAPSHOT_ID=/{print $2; exit}' "${_snapshot_path}/metadata.env")"
            _snapshot_type="$(awk -F"'" '/^SNAPSHOT_TYPE=/{print $2; exit}' "${_snapshot_path}/metadata.env")"
            _snapshot_time="$(awk -F"'" '/^CREATED_AT=/{print $2; exit}' "${_snapshot_path}/metadata.env")"
            [ -n "$_snapshot_id" ] || continue
            printf '%s|%s|%s\n' "$_snapshot_id" "$_snapshot_type" "${_snapshot_time:-未知}"
        done
    } | sort > "$WORK_TMP1"
    awk -F'|' '{printf "%d|%s\n", NR, $0}' "$WORK_TMP1" > "$VIEW_TMP1"
}

latest_snapshot_time() {
    build_snapshot_list
    awk -F'|' 'END {print $4}' "$VIEW_TMP1"
}

show_configuration_snapshots() {
    build_snapshot_list
    msg ""
    msg "===== 配置快照列表 ====="
    if [ ! -s "$VIEW_TMP1" ]; then
        msg "当前没有可用的配置快照。"
        return 1
    fi
    awk -F'|' '
        {
            label=($3=="initial") ? "初始化快照（不可删除）" : "用户快照"
            printf "%d) %s  %s  创建时间: %s\n", $1, $2, label, $4
        }
    ' "$VIEW_TMP1"
}

restore_configuration_snapshot() {
    _snapshot_no="$1"
    build_snapshot_list
    _snapshot_id="$(awk -F'|' -v n="$_snapshot_no" '$1==n {print $2; exit}' "$VIEW_TMP1")"
    _snapshot_path="${SNAPSHOT_DIR}/${_snapshot_id}"
    if [ -z "$_snapshot_id" ] || [ ! -f "${_snapshot_path}/config.env" ]; then
        err "快照编号无效。"
        return 1
    fi
    if ! confirm "确认载入快照 ${_snapshot_id} 吗（载入后请使用 10 应用保存）"; then
        msg "已取消。"
        return 1
    fi

    . "${_snapshot_path}/config.env"
    normalize_snat_file "${_snapshot_path}/snat.rules" "$SNAT_TMP" "$CURRENT_IF"
    normalize_port_file "${_snapshot_path}/port.rules" "$PORT_TMP" "$CURRENT_IF"
    trim_file_nonempty_unique "$SNAT_TMP"
    trim_file_nonempty_unique "$PORT_TMP"
    detect_firewall_policies
    normalize_security_policy_plans
    msg "已载入快照 ${_snapshot_id}，尚未应用到宿主机。请选择 10 应用保存。"
    return 0
}

delete_configuration_snapshot() {
    _snapshot_no="$1"
    build_snapshot_list
    _snapshot_id="$(awk -F'|' -v n="$_snapshot_no" '$1==n {print $2; exit}' "$VIEW_TMP1")"
    _snapshot_type="$(awk -F'|' -v n="$_snapshot_no" '$1==n {print $3; exit}' "$VIEW_TMP1")"
    _snapshot_path="${SNAPSHOT_DIR}/${_snapshot_id}"
    if [ -z "$_snapshot_id" ] || [ ! -d "$_snapshot_path" ]; then
        err "快照编号无效。"
        return 1
    fi
    if [ "$_snapshot_type" = "initial" ] || [ "$_snapshot_id" = "$INITIAL_SNAPSHOT_ID" ]; then
        err "初始化配置快照不可删除。"
        return 1
    fi
    if ! confirm "确认删除用户快照 ${_snapshot_id} 吗"; then
        msg "已取消。"
        return 1
    fi
    rm -rf "$_snapshot_path"
    msg "已删除配置快照: ${_snapshot_id}"
}

configuration_snapshot_menu() {
    while :; do
        show_configuration_snapshots || {
            pause
            return 1
        }
        msg ""
        msg "输入编号载入快照；输入 d+编号删除用户快照（例如 d2）；输入 0 返回。"
        printf '请选择: ' > "$TTY_IN"
        read_tty
        case "$USER_INPUT" in
            0) return 0 ;;
            d[0-9]*)
                _snapshot_no="${USER_INPUT#d}"
                delete_configuration_snapshot "$_snapshot_no"
                pause
                ;;
            *[!0-9]*|"")
                err "请输入有效的快照编号。"
                pause
                ;;
            *)
                restore_configuration_snapshot "$USER_INPUT"
                pause
                ;;
        esac
    done
}

read_saved_value() {
    _key="$1"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo ""
        return
    fi
    (
        . "$CONFIG_FILE" 2>/dev/null
        if [ -z "${CURRENT_IF:-}" ] && [ -n "${WAN_IF:-}" ]; then
            CURRENT_IF="$WAN_IF"
        fi
        case "$_key" in
            CURRENT_IF) printf '%s' "${CURRENT_IF:-}" ;;
            BACKEND) printf '%s' "${BACKEND:-}" ;;
            IP_FORWARD_PLAN) printf '%s' "${IP_FORWARD_PLAN:-}" ;;
            FW_INPUT_PLAN) printf '%s' "${FW_INPUT_PLAN:-}" ;;
            FW_OUTPUT_PLAN) printf '%s' "${FW_OUTPUT_PLAN:-}" ;;
            FW_FORWARD_PLAN) printf '%s' "${FW_FORWARD_PLAN:-}" ;;
            *) printf '' ;;
        esac
    )
}

require_current_interface() {
    if [ -z "$CURRENT_IF" ]; then
        err "请先在主菜单选择一个当前配置接口。"
        return 1
    fi
    return 0
}

add_port_rule() {
    require_current_interface || return
    choose_port_proto
    _proto="$SELECTED_PROTO"
    [ -n "$_proto" ] || return

    if [ "$_proto" = "icmp" ]; then
        if grep -Fxq "${CURRENT_IF}|icmp|-" "$PORT_TMP"; then
            err "该接口下 ICMP 放行规则已存在。"
            return
        fi
        printf '%s|%s|%s\n' "$CURRENT_IF" "icmp" "-" >> "$PORT_TMP"
        trim_file_nonempty_unique "$PORT_TMP"
        msg "已添加: 接口=${CURRENT_IF}  协议=icmp"
        return
    fi

    printf '请输入端口号 [1-65535]: ' > "$TTY_IN"
    read_tty
    _port="$USER_INPUT"
    if ! is_valid_port "$_port"; then
        err "端口号不正确。"
        return
    fi

    if grep -Fxq "${CURRENT_IF}|${_proto}|${_port}" "$PORT_TMP"; then
        err "该接口下该端口规则已存在。"
        return
    fi

    printf '%s|%s|%s\n' "$CURRENT_IF" "$_proto" "$_port" >> "$PORT_TMP"
    trim_file_nonempty_unique "$PORT_TMP"
    msg "已添加: 接口=${CURRENT_IF}  协议=$(proto_label "$_proto")  端口=${_port}"
}

choose_port_proto() {
    SELECTED_PROTO=""
    while :; do
        msg ""
        msg "请选择要放行的协议类型:"
        msg "1) tcp"
        msg "2) udp"
        msg "3) tcp_udp"
        msg "4) icmp"
        printf '请选择 [1-4]: ' > "$TTY_IN"
        read_tty
        case "$USER_INPUT" in
            1) SELECTED_PROTO="tcp"; return 0 ;;
            2) SELECTED_PROTO="udp"; return 0 ;;
            3) SELECTED_PROTO="tcpudp"; return 0 ;;
            4) SELECTED_PROTO="icmp"; return 0 ;;
            *) err "无效选项，请重新输入。" ;;
        esac
    done
}

edit_port_rule() {
    require_current_interface || return
    build_current_port_view
    if [ ! -s "$VIEW_TMP2" ]; then
        err "接口 ${CURRENT_IF} 当前没有可修改的端口规则。"
        return
    fi

    show_current_port_rules
    printf '请输入要修改的编号: ' > "$TTY_IN"
    read_tty
    _display_no="$USER_INPUT"

    _actual_line="$(awk -F'|' -v n="$_display_no" '$1==n {print $2; exit}' "$VIEW_TMP2")"
    _old_proto="$(awk -F'|' -v n="$_display_no" '$1==n {print $3; exit}' "$VIEW_TMP2")"
    _old_port="$(awk -F'|' -v n="$_display_no" '$1==n {print $4; exit}' "$VIEW_TMP2")"
    if [ -z "$_actual_line" ] || [ -z "$_old_proto" ]; then
        err "编号无效。"
        return
    fi

    msg "当前规则: 接口=${CURRENT_IF}  协议=$(proto_label "$_old_proto")  端口=${_old_port}"
    choose_port_proto
    _new_proto="$SELECTED_PROTO"
    [ -n "$_new_proto" ] || return

    if [ "$_new_proto" = "icmp" ]; then
        _new_port="-"
    else
        if [ "$_old_proto" != "icmp" ] && [ -n "$_old_port" ] && [ "$_old_port" != "-" ]; then
            printf '请输入新的端口号 [1-65535] [%s]: ' "$_old_port" > "$TTY_IN"
        else
            printf '请输入新的端口号 [1-65535]: ' > "$TTY_IN"
        fi
        read_tty
        _new_port="$USER_INPUT"
        if [ -z "$_new_port" ] && [ "$_old_proto" != "icmp" ] && [ -n "$_old_port" ] && [ "$_old_port" != "-" ]; then
            _new_port="$_old_port"
        fi
        if ! is_valid_port "$_new_port"; then
            err "端口号不正确。"
            return
        fi
    fi

    awk -F'|' -v ln="$_actual_line" -v ifc="$CURRENT_IF" -v proto="$_new_proto" -v port="$_new_port" '
        NR==ln { print ifc "|" proto "|" port; next }
        { print }
    ' "$PORT_TMP" > "$WORK_TMP1"
    cat "$WORK_TMP1" > "$PORT_TMP"
    trim_file_nonempty_unique "$PORT_TMP"
    msg "已修改。"
}

delete_port_rule() {
    require_current_interface || return
    build_current_port_view
    if [ ! -s "$VIEW_TMP2" ]; then
        err "接口 ${CURRENT_IF} 当前没有可删除的端口规则。"
        return
    fi
    show_current_port_rules
    printf '请输入要删除的编号: ' > "$TTY_IN"
    read_tty
    _display_no="$USER_INPUT"

    _actual_line="$(awk -F'|' -v n="$_display_no" '$1==n {print $2; exit}' "$VIEW_TMP2")"
    _old_proto="$(awk -F'|' -v n="$_display_no" '$1==n {print $3; exit}' "$VIEW_TMP2")"
    _old_port="$(awk -F'|' -v n="$_display_no" '$1==n {print $4; exit}' "$VIEW_TMP2")"
    if [ -z "$_actual_line" ] || [ -z "$_old_proto" ]; then
        err "编号无效。"
        return
    fi

    awk -v ln="$_actual_line" 'NR!=ln { print }' "$PORT_TMP" > "$WORK_TMP1"
    cat "$WORK_TMP1" > "$PORT_TMP"
    msg "已删除: 接口=${CURRENT_IF}  协议=$(proto_label "$_old_proto")  端口=${_old_port}"
}

build_current_snat_view() {
    : > "$VIEW_TMP1"
    awk -F'|' -v ifc="$CURRENT_IF" '
        $1==ifc {
            c++
            printf "%d|%d|%s\n", c, NR, $2
        }
    ' "$SNAT_TMP" > "$VIEW_TMP1"
}

build_current_port_view() {
    : > "$VIEW_TMP2"
    awk -F'|' -v ifc="$CURRENT_IF" '
        $1==ifc {
            c++
            printf "%d|%d|%s|%s\n", c, NR, $2, $3
        }
    ' "$PORT_TMP" > "$VIEW_TMP2"
}

show_current_snat_rules() {
    require_current_interface || return
    build_current_snat_view
    if [ ! -s "$VIEW_TMP1" ]; then
        msg "接口 ${CURRENT_IF} 当前没有 SNAT 源网段。"
        return
    fi
    awk -F'|' '{printf "%d) %s\n", $1, $3}' "$VIEW_TMP1"
}

show_current_port_rules() {
    require_current_interface || return
    build_current_port_view
    if [ ! -s "$VIEW_TMP2" ]; then
        msg "接口 ${CURRENT_IF} 当前没有端口放行规则。"
        return
    fi
    awk -F'|' '
        {
            proto=$3
            port=$4
            if (proto=="tcpudp") proto_show="tcp+udp"; else proto_show=proto
            if (proto=="icmp") {
                printf "%d) 协议=%s\n", $1, proto_show
            } else {
                printf "%d) 协议=%s  端口=%s\n", $1, proto_show, port
            }
        }
    ' "$VIEW_TMP2"
}

add_snat_rule() {
    require_current_interface || return
    printf '请输入需要在接口 %s 上做 SNAT 的源网段，例如 10.8.0.0/24: ' "$CURRENT_IF" > "$TTY_IN"
    read_tty
    _subnet="$USER_INPUT"
    if ! is_valid_ipv4_cidr "$_subnet"; then
        err "网段格式不正确。"
        return
    fi
    if grep -Fxq "${CURRENT_IF}|${_subnet}" "$SNAT_TMP"; then
        err "该接口下该网段已存在。"
        return
    fi
    printf '%s|%s\n' "$CURRENT_IF" "$_subnet" >> "$SNAT_TMP"
    trim_file_nonempty_unique "$SNAT_TMP"
    msg "已添加: 接口=${CURRENT_IF}  源网段=${_subnet}"
}

edit_snat_rule() {
    require_current_interface || return
    build_current_snat_view
    if [ ! -s "$VIEW_TMP1" ]; then
        err "接口 ${CURRENT_IF} 当前没有可修改的 SNAT 源网段。"
        return
    fi
    show_current_snat_rules
    printf '请输入要修改的编号: ' > "$TTY_IN"
    read_tty
    _display_no="$USER_INPUT"
    _actual_line="$(awk -F'|' -v n="$_display_no" '$1==n {print $2; exit}' "$VIEW_TMP1")"
    _old_subnet="$(awk -F'|' -v n="$_display_no" '$1==n {print $3; exit}' "$VIEW_TMP1")"
    if [ -z "$_actual_line" ] || [ -z "$_old_subnet" ]; then
        err "编号无效。"
        return
    fi

    printf '请输入新的网段 [%s]: ' "$_old_subnet" > "$TTY_IN"
    read_tty
    _new_subnet="$USER_INPUT"
    [ -n "$_new_subnet" ] || _new_subnet="$_old_subnet"

    if ! is_valid_ipv4_cidr "$_new_subnet"; then
        err "网段格式不正确。"
        return
    fi

    awk -F'|' -v ln="$_actual_line" -v ifc="$CURRENT_IF" -v subnet="$_new_subnet" '
        NR==ln { print ifc "|" subnet; next }
        { print }
    ' "$SNAT_TMP" > "$WORK_TMP1"
    cat "$WORK_TMP1" > "$SNAT_TMP"
    trim_file_nonempty_unique "$SNAT_TMP"
    msg "已修改。"
}

delete_snat_rule() {
    require_current_interface || return
    build_current_snat_view
    if [ ! -s "$VIEW_TMP1" ]; then
        err "接口 ${CURRENT_IF} 当前没有可删除的 SNAT 源网段。"
        return
    fi
    show_current_snat_rules
    printf '请输入要删除的编号: ' > "$TTY_IN"
    read_tty
    _display_no="$USER_INPUT"
    _actual_line="$(awk -F'|' -v n="$_display_no" '$1==n {print $2; exit}' "$VIEW_TMP1")"
    _old_subnet="$(awk -F'|' -v n="$_display_no" '$1==n {print $3; exit}' "$VIEW_TMP1")"
    if [ -z "$_actual_line" ] || [ -z "$_old_subnet" ]; then
        err "编号无效。"
        return
    fi

    awk -v ln="$_actual_line" 'NR!=ln { print }' "$SNAT_TMP" > "$WORK_TMP1"
    cat "$WORK_TMP1" > "$SNAT_TMP"
    msg "已删除: 接口=${CURRENT_IF}  源网段=${_old_subnet}"
}

count_config_ifaces() {
    {
        awk -F'|' 'NF>=2 {print $1}' "$SNAT_TMP"
        awk -F'|' 'NF>=3 {print $1}' "$PORT_TMP"
    } | awk 'NF && !seen[$0]++ { c++ } END { print c+0 }'
}

build_config_iface_list() {
    {
        awk -F'|' 'NF>=2 {print $1}' "$SNAT_TMP"
        awk -F'|' 'NF>=3 {print $1}' "$PORT_TMP"
    } | awk 'NF && !seen[$0]++ { print }' > "$WORK_TMP4"
}

config_type_label() {
    _snat_count="$(count_nonempty_lines "$SNAT_TMP")"
    _port_count="$(count_nonempty_lines "$PORT_TMP")"

    if [ "$_snat_count" -gt 0 ] && [ "$_port_count" -gt 0 ]; then
        echo "已同时配置 SNAT 和端口放行"
    elif [ "$_snat_count" -gt 0 ]; then
        echo "仅配置 SNAT"
    elif [ "$_port_count" -gt 0 ]; then
        echo "仅配置端口放行"
    else
        echo "当前没有任何配置"
    fi
}

show_summary() {
    detect_firewall_policies
    msg ""
    msg "===== 当前配置摘要 ====="
    msg "系统名称: ${OS_NAME}"
    msg "系统家族: ${OS_FAMILY}"
    msg "包管理器: ${PKG_MGR}"
    msg "防火墙后端: ${BACKEND}"
    msg "默认出口接口: $(format_iface_value "${DEFAULT_WAN_IF:-未识别}")"
    msg "当前配置接口: $(format_iface_value "${CURRENT_IF:-未设置}")"
    msg "当前系统 IPv4 转发: $(ip_forward_runtime_label)"
    msg "IPv4 转发计划: $(ip_forward_plan_label)"
    msg "默认入站策略: $(format_policy_value "${fw_in_policy:-未知}")"
    msg "默认出站策略: $(format_policy_value "${fw_out_policy:-未知}")"
    msg "默认转发策略: $(format_policy_value "${fw_fwd_policy:-未知}")"
    msg "默认入站策略计划: $(format_plan_value "$FW_INPUT_PLAN")"
    msg "默认出站策略计划: $(format_plan_value "$FW_OUTPUT_PLAN")"
    msg "默认转发策略计划: $(format_plan_value "$FW_FORWARD_PLAN")"
    msg "策略原始信息: ${fw_policy_detail:-未知}"
    msg "配置类型: $(config_type_label)"
    msg "已配置接口数量: $(format_count_value "$(count_config_ifaces)")"
    msg "SNAT 规则总数: $(format_count_value "$(count_nonempty_lines "$SNAT_TMP")")"
    msg "端口放行总数: $(format_count_value "$(count_nonempty_lines "$PORT_TMP")")"
}

render_main_dashboard() {
    if [ -t 1 ] && command_exists clear; then
        clear
    fi
    detect_firewall_policies

    _backend_display="$(color_wrap "$CLR_YELLOW" "$BACKEND")"
    _forward_display="$(format_policy_value "$(ip_forward_runtime_label)")"
    _iface_display="$(format_iface_value "${CURRENT_IF:-未设置}")"
    _policy_display="入/${fw_in_policy:-未知}  出/${fw_out_policy:-未知}  转/${fw_fwd_policy:-未知}"
    _latest_snapshot="$(latest_snapshot_time)"
    [ -n "$_latest_snapshot" ] || _latest_snapshot="尚无快照"

    printf '\n'
    ui_dashboard_title "VPN SNAT Firewall Helper"
    printf '%s\n' "----------------------------------------------------------------------------------------"
    printf '  防火墙软件: %s    IPv4 转发: %s    当前接口: %s\n' \
        "$_backend_display" "$_forward_display" "$_iface_display"
    printf '%s\n' "----------------------------------------------------------------------------------------"
    printf '%s\n' "+--------------------------+-----------------------------------------------------------+"
    ui_dashboard_row "导航" "概览"
    printf '%s\n' "+--------------------------+-----------------------------------------------------------+"
    ui_dashboard_row "01) 重检本机环境" "系统: ${OS_NAME:-未知}"
    ui_dashboard_row "02) 选择配置接口" "默认路由出口: ${DEFAULT_WAN_IF:-未识别}"
    ui_dashboard_row "03) 配置安全策略" "${_policy_display}"
    ui_dashboard_row "04) 配置路由转发" "IPv4 转发: $(ip_forward_runtime_label)"
    ui_dashboard_row "05) 配置端口策略" "端口放行: $(count_nonempty_lines "$PORT_TMP") 条"
    ui_dashboard_row "06) 配置NAT规则" "SNAT 规则: $(count_nonempty_lines "$SNAT_TMP") 条"
    ui_dashboard_row "07) 查询配置明细" "NAT 规则: $(count_nonempty_lines "$SNAT_TMP") 条；端口放行: $(count_nonempty_lines "$PORT_TMP") 条"
    ui_dashboard_row "08) 保存配置快照" "上一个快照时间: ${_latest_snapshot}"
    ui_dashboard_row "09) 回退快照配置" "选择需要载入的快照版本。"
    ui_dashboard_row "10) 应用保存配置" "应用并保存当前策略和规则。"
    ui_dashboard_row "11) 更新最新脚本" "检查主/备用地址后更新当前脚本。"
    ui_dashboard_row "99) 退出脚本" ""
    printf '%s\n' "+--------------------------+-----------------------------------------------------------+"
    printf '%s\n' "+--------------------------------------------------------------------------------------+"
    ui_dashboard_full_row "初始化宿主机备份时间: $(initial_backup_created_at)"
    ui_dashboard_full_row "初始化宿主机备份路径: ${INITIAL_BACKUP_DIR}"
    ui_dashboard_full_row "配置快照路径: ${SNAPSHOT_DIR}"
    printf '%s\n' "+--------------------------------------------------------------------------------------+"
    printf '%s\n' "----------------------------------------------------------------------------------------"
    printf '%s' "  请输入菜单编号: " > "$TTY_IN"
}

ui_display_width() {
    # UTF-8 terminals render non-ASCII characters as two columns in this UI.
    printf '%s' "$1" | awk '{
        ascii=$0
        non_ascii=$0
        gsub(/[^ -~]/, "", ascii)
        gsub(/[ -~]/, "", non_ascii)
        print length(ascii) + (length(non_ascii) * 2)
    }'
}

ui_pad() {
    _ui_text="$1"
    _ui_target="$2"
    _ui_width="$(ui_display_width "$_ui_text")"
    _ui_spaces=$((_ui_target - _ui_width))
    [ "$_ui_spaces" -lt 0 ] && _ui_spaces=0
    printf '%s' "$_ui_text"
    printf '%*s' "$_ui_spaces" ""
}

ui_dashboard_row() {
    printf '| '
    ui_pad "$1" 24
    printf ' | '
    ui_pad "$2" 57
    printf ' |\n'
}

ui_dashboard_full_row() {
    printf '| '
    ui_pad "$1" 84
    printf ' |\n'
}

ui_dashboard_title() {
    _ui_title="$1"
    _ui_title_width="$(ui_display_width "$_ui_title")"
    _ui_title_left=$(((88 - _ui_title_width) / 2))
    [ "$_ui_title_left" -lt 0 ] && _ui_title_left=0
    printf '%*s' "$_ui_title_left" ""
    color_wrap "$CLR_GREEN" "$_ui_title"
    printf '\n'
}

get_firewalld_zone_of_if() {
    _if="$1"
    _zone="$(firewall-cmd --get-zone-of-interface="$_if" 2>/dev/null | head -n 1)"
    case "$_zone" in
        ""|"no zone")
            firewall-cmd --get-default-zone 2>/dev/null | head -n 1
            ;;
        *)
            printf '%s\n' "$_zone"
            ;;
    esac
}

print_detailed_config() {
    detect_firewall_policies

    msg ""
    msg "================ 当前已保存/待应用配置明细 ================"
    msg "系统名称: ${OS_NAME}"
    msg "系统家族: ${OS_FAMILY}"
    msg "包管理器: ${PKG_MGR}"
    msg "防火墙后端: ${BACKEND}"
    msg "当前配置接口: $(format_iface_value "${CURRENT_IF:-未设置}")"
    msg "当前系统 IPv4 转发运行状态: $(ip_forward_runtime_label)"
    msg "本脚本 IPv4 转发计划: $(ip_forward_plan_label)"
    msg "默认入站策略: $(format_policy_value "${fw_in_policy:-未知}")"
    msg "默认出站策略: $(format_policy_value "${fw_out_policy:-未知}")"
    msg "默认转发策略: $(format_policy_value "${fw_fwd_policy:-未知}")"
    msg "默认入站策略计划: $(format_plan_value "$FW_INPUT_PLAN")"
    msg "默认出站策略计划: $(format_plan_value "$FW_OUTPUT_PLAN")"
    msg "默认转发策略计划: $(format_plan_value "$FW_FORWARD_PLAN")"
    msg "策略原始信息: ${fw_policy_detail:-未知}"
    msg "配置类型: $(config_type_label)"
    msg "已配置接口数量: $(format_count_value "$(count_config_ifaces)")"
    msg ""

    build_config_iface_list

    if [ ! -s "$WORK_TMP4" ]; then
        msg "当前还没有任何接口配置。"
        msg "========================================================"
        return
    fi

    while IFS= read -r _ifc; do
        [ -n "$_ifc" ] || continue
        msg "--------------------------------------------------------"
        msg "接口: $(format_iface_value "${_ifc}")"
        if [ "$BACKEND" = "firewalld" ]; then
            _zone="$(get_firewalld_zone_of_if "$_ifc")"
            [ -n "$_zone" ] && msg "firewalld zone: ${_zone}"
        fi
        msg ""
        msg "[${_ifc} 下的 SNAT 源网段]"
        awk -F'|' -v ifc="$_ifc" '
            $1==ifc { c++; printf "  %d) %s\n", c, $2 }
            END { if (c==0) print "  无" }
        ' "$SNAT_TMP"

        msg ""
        msg "[${_ifc} 下的端口/协议放行（仅本机）]"
        awk -F'|' -v ifc="$_ifc" '
            $1==ifc {
                c++
                proto=$2
                port=$3
                if (proto=="tcpudp") proto_show="tcp+udp"; else proto_show=proto
                if (proto=="icmp") {
                    printf "  %d) 协议=%s\n", c, proto_show
                } else {
                    printf "  %d) 协议=%s  端口=%s\n", c, proto_show, port
                }
            }
            END { if (c==0) print "  无" }
        ' "$PORT_TMP"
        msg ""
    done < "$WORK_TMP4"

    msg "========================================================"
}

snat_menu() {
    require_current_interface || return
    while :; do
        msg ""
        msg "===== SNAT 配置 ====="
        msg "当前配置接口: ${CURRENT_IF}"
        show_current_snat_rules
        msg ""
        msg "1) 查看当前接口下的 SNAT"
        msg "2) 添加"
        msg "3) 修改"
        msg "4) 删除"
        msg "0) 返回主菜单"
        printf '请选择: ' > "$TTY_IN"
        read_tty
        case "$USER_INPUT" in
            1) show_current_snat_rules; pause ;;
            2) add_snat_rule; pause ;;
            3) edit_snat_rule; pause ;;
            4) delete_snat_rule; pause ;;
            0) return 0 ;;
            *) err "无效选项。"; pause ;;
        esac
    done
}

port_menu() {
    require_current_interface || return
    while :; do
        msg ""
        msg "===== 端口放行配置 ====="
        msg "当前配置接口: ${CURRENT_IF}"
        show_current_port_rules
        msg ""
        msg "1) 查看当前接口下的端口放行"
        msg "2) 添加"
        msg "3) 修改"
        msg "4) 删除"
        msg "0) 返回主菜单"
        printf '请选择: ' > "$TTY_IN"
        read_tty
        case "$USER_INPUT" in
            1) show_current_port_rules; pause ;;
            2) add_port_rule; pause ;;
            3) edit_port_rule; pause ;;
            4) delete_port_rule; pause ;;
            0) return 0 ;;
            *) err "无效选项。"; pause ;;
        esac
    done
}

is_valid_ipv4_cidr() {
    echo "$1" | awk -F'[./]' '
        NF==5 &&
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ &&
        $1>=0 && $1<=255 &&
        $2>=0 && $2<=255 &&
        $3>=0 && $3<=255 &&
        $4>=0 && $4<=255 &&
        $5>=0 && $5<=32 { ok=1 }
        END { exit ok ? 0 : 1 }
    '
}

is_valid_port() {
    echo "$1" | awk '
        $0 ~ /^[0-9]+$/ && $0 >= 1 && $0 <= 65535 { ok=1 }
        END { exit ok ? 0 : 1 }
    '
}

set_sysctl_kv() {
    _file="$1"
    _key="$2"
    _value="$3"
    [ -f "$_file" ] || touch "$_file"
    awk -v k="$_key" -v v="$_value" '
        BEGIN { done=0 }
        {
            if ($0 ~ "^[[:space:]]*#?[[:space:]]*" k "[[:space:]]*=" && !done) {
                print k "=" v
                done=1
                next
            }
            print
        }
        END {
            if (!done) print k "=" v
        }
    ' "$_file" > "$WORK_TMP1"
    cat "$WORK_TMP1" > "$_file"
}

firewalld_add_forward_any_rule() {
    _iface="$1"
    _subnet="$2"
    firewall-cmd --permanent --direct --add-rule ipv4 filter FORWARD 0 -o "$_iface" -s "$_subnet" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || true
}

firewalld_remove_forward_any_rule() {
    _iface="$1"
    _subnet="$2"
    firewall-cmd --permanent --direct --remove-rule ipv4 filter FORWARD 0 -o "$_iface" -s "$_subnet" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || true
}

firewalld_add_port_rule() {
    _iface="$1"
    _proto="$2"
    _port="$3"
    _zone="$(get_firewalld_zone_of_if "$_iface")"
    [ -n "$_zone" ] || _zone="public"

    case "$_proto" in
        tcp)
            firewall-cmd --permanent --zone="$_zone" --add-port="${_port}/tcp" >/dev/null 2>&1 || true
            ;;
        udp)
            firewall-cmd --permanent --zone="$_zone" --add-port="${_port}/udp" >/dev/null 2>&1 || true
            ;;
        tcpudp)
            firewall-cmd --permanent --zone="$_zone" --add-port="${_port}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --permanent --zone="$_zone" --add-port="${_port}/udp" >/dev/null 2>&1 || true
            ;;
        icmp)
            firewall-cmd --permanent --zone="$_zone" --add-rich-rule='rule family="ipv4" protocol value="icmp" accept' >/dev/null 2>&1 || true
            ;;
    esac
}

firewalld_remove_port_rule() {
    _iface="$1"
    _proto="$2"
    _port="$3"
    _zone="$(get_firewalld_zone_of_if "$_iface")"
    [ -n "$_zone" ] || _zone="public"

    case "$_proto" in
        tcp)
            firewall-cmd --permanent --zone="$_zone" --remove-port="${_port}/tcp" >/dev/null 2>&1 || true
            ;;
        udp)
            firewall-cmd --permanent --zone="$_zone" --remove-port="${_port}/udp" >/dev/null 2>&1 || true
            ;;
        tcpudp)
            firewall-cmd --permanent --zone="$_zone" --remove-port="${_port}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --permanent --zone="$_zone" --remove-port="${_port}/udp" >/dev/null 2>&1 || true
            ;;
        icmp)
            firewall-cmd --permanent --zone="$_zone" --remove-rich-rule='rule family="ipv4" protocol value="icmp" accept' >/dev/null 2>&1 || true
            ;;
    esac
}

firewalld_apply_default_policy_rule() {
    _chain="$1"
    _plan="$2"
    firewall-cmd --permanent --direct --remove-rule ipv4 filter "$_chain" "$FIREWALLD_POLICY_ALLOW_PRIO" -j ACCEPT >/dev/null 2>&1 || true
    firewall-cmd --permanent --direct --remove-rule ipv4 filter "$_chain" "$FIREWALLD_POLICY_DENY_PRIO" -j DROP >/dev/null 2>&1 || true
    case "$_plan" in
        allow)
            firewall-cmd --permanent --direct --add-rule ipv4 filter "$_chain" "$FIREWALLD_POLICY_ALLOW_PRIO" -j ACCEPT >/dev/null 2>&1 || true
            ;;
        deny)
            firewall-cmd --permanent --direct --add-rule ipv4 filter "$_chain" "$FIREWALLD_POLICY_DENY_PRIO" -j DROP >/dev/null 2>&1 || true
            ;;
    esac
}

apply_firewalld() {
    ensure_package firewall-cmd firewalld || return 1
    start_service firewalld
    enable_service firewalld

    firewalld_apply_default_policy_rule "INPUT" "$FW_INPUT_PLAN"
    firewalld_apply_default_policy_rule "OUTPUT" "$FW_OUTPUT_PLAN"
    firewalld_apply_default_policy_rule "FORWARD" "$FW_FORWARD_PLAN"

    _saved_current_if="$(read_saved_value CURRENT_IF)"
    normalize_snat_file "$SNAT_STORE" "$WORK_TMP1" "${_saved_current_if:-$CURRENT_IF}"
    normalize_port_file "$PORT_STORE" "$WORK_TMP2" "${_saved_current_if:-$CURRENT_IF}"

    while IFS='|' read -r _iface _proto _port; do
        [ -n "$_iface" ] || continue
        firewalld_remove_port_rule "$_iface" "$_proto" "$_port"
    done < "$WORK_TMP2"

    while IFS='|' read -r _iface _subnet; do
        [ -n "$_iface" ] || continue
        _zone="$(get_firewalld_zone_of_if "$_iface")"
        [ -n "$_zone" ] || _zone="public"
        firewall-cmd --permanent --zone="$_zone" --remove-source="$_subnet" >/dev/null 2>&1 || true
        firewalld_remove_forward_any_rule "$_iface" "$_subnet"
        firewall-cmd --permanent --direct --remove-rule ipv4 filter FORWARD 0 -i "$_iface" -d "$_subnet" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || true
        firewall-cmd --permanent --direct --remove-rule ipv4 nat POSTROUTING 0 -s "$_subnet" -o "$_iface" -j MASQUERADE >/dev/null 2>&1 || true
    done < "$WORK_TMP1"

    while IFS='|' read -r _iface _proto _port; do
        [ -n "$_iface" ] || continue
        firewalld_add_port_rule "$_iface" "$_proto" "$_port"
    done < "$PORT_TMP"

    while IFS='|' read -r _iface _subnet; do
        [ -n "$_iface" ] || continue
        _zone="$(get_firewalld_zone_of_if "$_iface")"
        [ -n "$_zone" ] || _zone="public"
        firewall-cmd --permanent --zone="$_zone" --add-source="$_subnet" >/dev/null 2>&1 || true
        firewall-cmd --permanent --zone="$_zone" --add-forward >/dev/null 2>&1 || true
        firewalld_add_forward_any_rule "$_iface" "$_subnet"
        firewall-cmd --permanent --direct --add-rule ipv4 filter FORWARD 0 -i "$_iface" -d "$_subnet" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || true
        firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s "$_subnet" -o "$_iface" -j MASQUERADE >/dev/null 2>&1 || true
    done < "$SNAT_TMP"

    firewall-cmd --reload >/dev/null 2>&1 || return 1
    return 0
}

strip_marked_block() {
    _begin="$1"
    _end="$2"
    _file="$3"
    awk -v s="$_begin" -v e="$_end" '
        index($0, s) { skip=1; next }
        index($0, e) { skip=0; next }
        !skip { print }
    ' "$_file"
}

build_ufw_nat_block() {
    if [ "$(count_nonempty_lines "$SNAT_TMP")" -eq 0 ]; then
        return 0
    fi

    printf '%s\n' "$UFW_NAT_BEGIN"
    printf '%s\n' '*nat'
    printf '%s\n' ':POSTROUTING ACCEPT [0:0]'
    while IFS='|' read -r _iface _subnet; do
        [ -n "$_iface" ] || continue
        printf '%s\n' "-A POSTROUTING -s ${_subnet} -o ${_iface} -j MASQUERADE"
    done < "$SNAT_TMP"
    printf '%s\n' 'COMMIT'
    printf '%s\n' "$UFW_NAT_END"
}

build_ufw_filter_block() {
    _has_any=0
    if [ "$(count_nonempty_lines "$SNAT_TMP")" -gt 0 ]; then
        _has_any=1
    fi
    if [ "$(count_nonempty_lines "$PORT_TMP")" -gt 0 ]; then
        _has_any=1
    fi
    if [ "$_has_any" -eq 0 ]; then
        return 0
    fi

    printf '%s\n' "$UFW_FILTER_BEGIN"

    while IFS='|' read -r _iface _subnet; do
        [ -n "$_iface" ] || continue
        printf '%s\n' "-A ufw-before-forward -o ${_iface} -s ${_subnet} -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT"
        printf '%s\n' "-A ufw-before-forward -i ${_iface} -d ${_subnet} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
    done < "$SNAT_TMP"

    while IFS='|' read -r _iface _proto _port; do
        [ -n "$_iface" ] || continue
        case "$_proto" in
            tcp)
                printf '%s\n' "-A ufw-before-input -i ${_iface} -p tcp --dport ${_port} -m conntrack --ctstate NEW -j ACCEPT"
                ;;
            udp)
                printf '%s\n' "-A ufw-before-input -i ${_iface} -p udp --dport ${_port} -j ACCEPT"
                ;;
            tcpudp)
                printf '%s\n' "-A ufw-before-input -i ${_iface} -p tcp --dport ${_port} -m conntrack --ctstate NEW -j ACCEPT"
                printf '%s\n' "-A ufw-before-input -i ${_iface} -p udp --dport ${_port} -j ACCEPT"
                ;;
            icmp)
                printf '%s\n' "-A ufw-before-input -i ${_iface} -p icmp -j ACCEPT"
                ;;
        esac
    done < "$PORT_TMP"

    printf '%s\n' "$UFW_FILTER_END"
}

apply_ufw() {
    ensure_package ufw ufw || return 1

    backup_file "$UFW_BEFORE_RULES"
    [ -f "$UFW_BEFORE_RULES" ] || touch "$UFW_BEFORE_RULES"

    case "$FW_INPUT_PLAN" in
        allow) ufw --force default allow incoming >/dev/null 2>&1 || true ;;
        deny) ufw --force default deny incoming >/dev/null 2>&1 || true ;;
    esac
    case "$FW_OUTPUT_PLAN" in
        allow) ufw --force default allow outgoing >/dev/null 2>&1 || true ;;
        deny) ufw --force default deny outgoing >/dev/null 2>&1 || true ;;
    esac
    case "$FW_FORWARD_PLAN" in
        allow) ufw --force default allow routed >/dev/null 2>&1 || true ;;
        deny) ufw --force default deny routed >/dev/null 2>&1 || true ;;
    esac

    strip_marked_block "$UFW_NAT_BEGIN" "$UFW_NAT_END" "$UFW_BEFORE_RULES" > "$WORK_TMP1"
    strip_marked_block "$UFW_FILTER_BEGIN" "$UFW_FILTER_END" "$WORK_TMP1" > "$WORK_TMP2"

    _nat_block="$(build_ufw_nat_block)"
    if [ -n "$_nat_block" ]; then
        awk -v block="$_nat_block" '
            BEGIN { inserted=0 }
            {
                if (!inserted && $0 ~ /^\*filter$/) {
                    print block
                    inserted=1
                }
                print
            }
            END {
                if (!inserted) print block
            }
        ' "$WORK_TMP2" > "$WORK_TMP3"
    else
        cat "$WORK_TMP2" > "$WORK_TMP3"
    fi

    _filter_block="$(build_ufw_filter_block)"
    if [ -n "$_filter_block" ]; then
        awk -v block="$_filter_block" '
            BEGIN { in_filter=0; inserted=0 }
            {
                if ($0 ~ /^\*filter$/) in_filter=1
                if (in_filter && $0 ~ /^COMMIT$/ && !inserted) {
                    print block
                    inserted=1
                    in_filter=0
                }
                print
            }
            END {
                if (!inserted) {
                    print "*filter"
                    print block
                    print "COMMIT"
                }
            }
        ' "$WORK_TMP3" > "$WORK_TMP4"
    else
        cat "$WORK_TMP3" > "$WORK_TMP4"
    fi

    cat "$WORK_TMP4" > "$UFW_BEFORE_RULES"
    if [ "$IP_FORWARD_PLAN" = "permanent" ]; then
        set_sysctl_kv "$UFW_SYSCTL_FILE" "net/ipv4/ip_forward" "1"
    fi

    if command_exists ufw; then
        ufw reload >/dev/null 2>&1 || true
        ufw --force enable >/dev/null 2>&1 || true
    fi
    return 0
}

install_iptables_restore_service() {
    mkdir -p /usr/local/sbin
    cat > "$IPTABLES_APPLY_SCRIPT" <<EOF
#!/bin/sh
[ -f "$IPTABLES_RULES_FILE" ] || exit 0
iptables-restore < "$IPTABLES_RULES_FILE"
exit \$?
EOF
    chmod 700 "$IPTABLES_APPLY_SCRIPT"

    if has_systemd; then
        cat > "$IPTABLES_SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Restore ${PROGRAM_NAME} iptables rules
After=local-fs.target
Before=network-online.target

[Service]
Type=oneshot
ExecStart=${IPTABLES_APPLY_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        enable_service "$(basename "$IPTABLES_SYSTEMD_SERVICE")"
    elif has_openrc; then
        cat > "$IPTABLES_OPENRC_SERVICE" <<'EOF'
#!/sbin/openrc-run
name="vpn-fw-helper-iptables"
description="Restore vpn-fw-helper iptables rules"

depend() {
    need net
    use firewall
}

start() {
    ebegin "Restoring vpn-fw-helper iptables rules"
    /usr/local/sbin/vpn-fw-helper-iptables-restore.sh
    eend $?
}
EOF
        chmod 755 "$IPTABLES_OPENRC_SERVICE"
        enable_service "$(basename "$IPTABLES_OPENRC_SERVICE")"
    fi
}

apply_iptables() {
    ensure_package iptables iptables || return 1

    case "$FW_INPUT_PLAN" in
        allow) iptables -P INPUT ACCEPT ;;
        deny) iptables -P INPUT DROP ;;
    esac
    case "$FW_OUTPUT_PLAN" in
        allow) iptables -P OUTPUT ACCEPT ;;
        deny) iptables -P OUTPUT DROP ;;
    esac
    case "$FW_FORWARD_PLAN" in
        allow) iptables -P FORWARD ACCEPT ;;
        deny) iptables -P FORWARD DROP ;;
    esac

    iptables -N "$IPTABLES_CHAIN_INPUT" 2>/dev/null || true
    iptables -F "$IPTABLES_CHAIN_INPUT"

    iptables -N "$IPTABLES_CHAIN_FORWARD" 2>/dev/null || true
    iptables -F "$IPTABLES_CHAIN_FORWARD"

    iptables -t nat -N "$IPTABLES_CHAIN_POSTROUTING" 2>/dev/null || true
    iptables -t nat -F "$IPTABLES_CHAIN_POSTROUTING"

    iptables -C INPUT -j "$IPTABLES_CHAIN_INPUT" >/dev/null 2>&1 || iptables -I INPUT 1 -j "$IPTABLES_CHAIN_INPUT"
    iptables -C FORWARD -j "$IPTABLES_CHAIN_FORWARD" >/dev/null 2>&1 || iptables -I FORWARD 1 -j "$IPTABLES_CHAIN_FORWARD"
    iptables -t nat -C POSTROUTING -j "$IPTABLES_CHAIN_POSTROUTING" >/dev/null 2>&1 || iptables -t nat -I POSTROUTING 1 -j "$IPTABLES_CHAIN_POSTROUTING"

    while IFS='|' read -r _iface _proto _port; do
        [ -n "$_iface" ] || continue
        case "$_proto" in
            tcp)
                iptables -A "$IPTABLES_CHAIN_INPUT" -i "$_iface" -p tcp --dport "$_port" -m conntrack --ctstate NEW -j ACCEPT
                ;;
            udp)
                iptables -A "$IPTABLES_CHAIN_INPUT" -i "$_iface" -p udp --dport "$_port" -j ACCEPT
                ;;
            tcpudp)
                iptables -A "$IPTABLES_CHAIN_INPUT" -i "$_iface" -p tcp --dport "$_port" -m conntrack --ctstate NEW -j ACCEPT
                iptables -A "$IPTABLES_CHAIN_INPUT" -i "$_iface" -p udp --dport "$_port" -j ACCEPT
                ;;
            icmp)
                iptables -A "$IPTABLES_CHAIN_INPUT" -i "$_iface" -p icmp -j ACCEPT
                ;;
        esac
    done < "$PORT_TMP"

    while IFS='|' read -r _iface _subnet; do
        [ -n "$_iface" ] || continue
        iptables -A "$IPTABLES_CHAIN_FORWARD" -o "$_iface" -s "$_subnet" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
        iptables -A "$IPTABLES_CHAIN_FORWARD" -i "$_iface" -d "$_subnet" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        iptables -t nat -A "$IPTABLES_CHAIN_POSTROUTING" -s "$_subnet" -o "$_iface" -j MASQUERADE
    done < "$SNAT_TMP"

    mkdir -p "$BASE_DIR"
    iptables-save > "$IPTABLES_RULES_FILE" || return 1

    install_iptables_restore_service
    return 0
}

install_nft_apply_service() {
    mkdir -p /usr/local/sbin
    cat > "$NFT_APPLY_SCRIPT" <<EOF
#!/bin/sh
nft delete table inet vpnfwhelper_filter >/dev/null 2>&1 || true
nft delete table ip vpnfwhelper_nat >/dev/null 2>&1 || true
[ -f "$NFT_RULES_FILE" ] || exit 0
nft -f "$NFT_RULES_FILE"
exit \$?
EOF
    chmod 700 "$NFT_APPLY_SCRIPT"

    if has_systemd; then
        cat > "$NFT_SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Apply ${PROGRAM_NAME} nftables rules
After=local-fs.target
Before=network-online.target

[Service]
Type=oneshot
ExecStart=${NFT_APPLY_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        enable_service "$(basename "$NFT_SYSTEMD_SERVICE")"
    elif has_openrc; then
        cat > "$NFT_OPENRC_SERVICE" <<'EOF'
#!/sbin/openrc-run
name="vpn-fw-helper-nftables"
description="Apply vpn-fw-helper nftables rules"

depend() {
    need net
    use firewall
}

start() {
    ebegin "Applying vpn-fw-helper nftables rules"
    /usr/local/sbin/vpn-fw-helper-nft-apply.sh
    eend $?
}
EOF
        chmod 755 "$NFT_OPENRC_SERVICE"
        enable_service "$(basename "$NFT_OPENRC_SERVICE")"
    fi
}

apply_nftables() {
    ensure_package nft nftables || return 1
    if ! nft_is_usable; then
        err "检测到 nft 命令在当前系统执行异常，无法安全使用 nftables 后端。"
        return 1
    fi

    mkdir -p "$BASE_DIR"
    _nft_input_policy="accept"
    _nft_output_policy="accept"
    _nft_forward_policy="accept"
    case "$FW_INPUT_PLAN" in
        deny) _nft_input_policy="drop" ;;
        allow) _nft_input_policy="accept" ;;
    esac
    case "$FW_OUTPUT_PLAN" in
        deny) _nft_output_policy="drop" ;;
        allow) _nft_output_policy="accept" ;;
    esac
    case "$FW_FORWARD_PLAN" in
        deny) _nft_forward_policy="drop" ;;
        allow) _nft_forward_policy="accept" ;;
    esac

    {
        printf '%s\n' 'table inet vpnfwhelper_filter {'
        printf '%s\n' '    chain input {'
        printf '        type filter hook input priority 0; policy %s;\n' "$_nft_input_policy"
        while IFS='|' read -r _iface _proto _port; do
            [ -n "$_iface" ] || continue
            case "$_proto" in
                tcp)
                    printf '        iifname "%s" tcp dport %s ct state new accept\n' "$_iface" "$_port"
                    ;;
                udp)
                    printf '        iifname "%s" udp dport %s accept\n' "$_iface" "$_port"
                    ;;
                tcpudp)
                    printf '        iifname "%s" tcp dport %s ct state new accept\n' "$_iface" "$_port"
                    printf '        iifname "%s" udp dport %s accept\n' "$_iface" "$_port"
                    ;;
                icmp)
                    printf '        iifname "%s" ip protocol icmp accept\n' "$_iface"
                    ;;
            esac
        done < "$PORT_TMP"
        printf '%s\n' '    }'
        printf '%s\n' '    chain output {'
        printf '        type filter hook output priority 0; policy %s;\n' "$_nft_output_policy"
        printf '%s\n' '    }'
        printf '%s\n' '    chain forward {'
        printf '        type filter hook forward priority 0; policy %s;\n' "$_nft_forward_policy"
        while IFS='|' read -r _iface _subnet; do
            [ -n "$_iface" ] || continue
            printf '        iifname "%s" ip daddr %s ct state { established, related } accept\n' "$_iface" "$_subnet"
            printf '        oifname "%s" ip saddr %s ct state { new, established, related } accept\n' "$_iface" "$_subnet"
        done < "$SNAT_TMP"
        printf '%s\n' '    }'
        printf '%s\n' '}'
        printf '%s\n' 'table ip vpnfwhelper_nat {'
        printf '%s\n' '    chain postrouting {'
        printf '%s\n' '        type nat hook postrouting priority 100; policy accept;'
        while IFS='|' read -r _iface _subnet; do
            [ -n "$_iface" ] || continue
            printf '        ip saddr %s oifname "%s" masquerade\n' "$_subnet" "$_iface"
        done < "$SNAT_TMP"
        printf '%s\n' '    }'
        printf '%s\n' '}'
    } > "$NFT_RULES_FILE"

    install_nft_apply_service
    sh "$NFT_APPLY_SCRIPT" || return 1
    return 0
}

apply_ip_forward_setting() {
    case "$IP_FORWARD_PLAN" in
        permanent)
            msg "应用 IPv4 转发设置: 永久开启"
            if command_exists sysctl; then
                sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
            fi
            if [ -w /proc/sys/net/ipv4/ip_forward ]; then
                echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
            fi
            mkdir -p /etc/sysctl.d
            printf '%s\n' 'net.ipv4.ip_forward = 1' > "$SYSCTL_FILE"
            if command_exists sysctl; then
                sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
            fi
            if [ "$BACKEND" = "ufw" ]; then
                set_sysctl_kv "$UFW_SYSCTL_FILE" "net/ipv4/ip_forward" "1"
            fi
            ;;
        temporary)
            msg "应用 IPv4 转发设置: 临时开启"
            if command_exists sysctl; then
                sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
            fi
            if [ -w /proc/sys/net/ipv4/ip_forward ]; then
                echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
            fi
            ;;
        nochange|"")
            msg "IPv4 转发设置: 不修改"
            ;;
        *)
            err "未知的 IPv4 转发计划: $IP_FORWARD_PLAN"
            return 1
            ;;
    esac
    return 0
}

apply_backend() {
    case "$BACKEND" in
        firewalld) apply_firewalld ;;
        ufw) apply_ufw ;;
        nftables)
            if nft_is_usable; then
                apply_nftables
            elif command_exists iptables; then
                err "检测到 nft 命令在当前系统异常退出，已自动切换为 iptables 后端。"
                BACKEND="iptables"
                apply_iptables
            else
                err "检测到 nft 命令在当前系统异常退出，且没有可用的 iptables 后端。"
                return 1
            fi
            ;;
        iptables) apply_iptables ;;
        *)
            err "不支持的防火墙后端: $BACKEND"
            return 1
            ;;
    esac
}

choose_backend_if_needed() {
    BACKEND="$(detect_backend)"
}

apply_and_save_all() {
    validate_security_policy_plans || return 1
    print_detailed_config
    if ! confirm "确认开始应用并保存以上全部配置吗"; then
        msg "已取消。"
        return 1
    fi

    apply_ip_forward_setting || return 1
    apply_backend || return 1
    save_current_config || return 1
    detect_firewall_policies

    msg ""
    msg "配置已成功应用并保存。"
    print_detailed_config
    return 0
}

main_menu() {
    while :; do
        render_main_dashboard
        read_tty

        case "$USER_INPUT" in
            01|1)
                detect_os
                choose_backend_if_needed
                detect_firewall_policies
                msg "本机环境已重新检测。"
                pause
                ;;
            02|2)
                choose_interface_by_number "选择当前配置接口" "${CURRENT_IF:-${DEFAULT_WAN_IF}}"
                if [ -n "$SELECTED_IF" ]; then
                    CURRENT_IF="$SELECTED_IF"
                    msg "当前配置接口已切换为: $(format_iface_value "$CURRENT_IF")"
                    pause
                fi
                ;;
            03|3)
                configure_default_policy_menu
                ;;
            04|4)
                configure_ip_forward_menu
                ;;
            05|5)
                port_menu
                ;;
            06|6)
                snat_menu
                ;;
            07|7)
                print_detailed_config
                pause
                ;;
            08|8)
                save_configuration_snapshot
                pause
                ;;
            09|9)
                configuration_snapshot_menu
                ;;
            10)
                if apply_and_save_all; then
                    pause
                else
                    err "应用失败，请检查上方输出。"
                    pause
                fi
                ;;
            11)
                if update_self_script; then
                    pause
                else
                    pause
                fi
                ;;
            99)
                exit 0
                ;;
            *)
                err "无效选项。"
                pause
                ;;
        esac
    done
}

init_defaults() {
    detect_os
    resolve_script_self >/dev/null 2>&1 || true
    capture_initial_host_backup || exit 1
    load_saved_config

    DEFAULT_WAN_IF="$(get_default_wan_if)"
    [ -n "$CURRENT_IF" ] || CURRENT_IF="$DEFAULT_WAN_IF"
    [ -n "$IP_FORWARD_PLAN" ] || IP_FORWARD_PLAN="nochange"
    [ -n "$FW_INPUT_PLAN" ] || FW_INPUT_PLAN="unknown"
    [ -n "$FW_OUTPUT_PLAN" ] || FW_OUTPUT_PLAN="unknown"
    [ -n "$FW_FORWARD_PLAN" ] || FW_FORWARD_PLAN="unknown"

    choose_backend_if_needed
    detect_firewall_policies
    normalize_security_policy_plans
    capture_initial_configuration_snapshot || exit 1
}

require_root
init_colors
init_defaults
main_menu

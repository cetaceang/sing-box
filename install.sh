#!/bin/bash

author=233boy # upstream attribution; download source is independent below
# Fork: https://github.com/cetaceang/sing-box

# bash fonts colors
red='\e[31m'
yellow='\e[33m'
gray='\e[90m'
green='\e[92m'
blue='\e[94m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'
_red() { echo -e "${red}$*${none}"; }
_blue() { echo -e "${blue}$*${none}"; }
_cyan() { echo -e "${cyan}$*${none}"; }
_green() { echo -e "${green}$*${none}"; }
_yellow() { echo -e "${yellow}$*${none}"; }
_magenta() { echo -e "${magenta}$*${none}"; }
_red_bg() { echo -e "\e[41m$*${none}"; }

is_err=$(_red_bg 错误!)
is_warn=$(_red_bg 警告!)

err() {
    echo -e "\n$is_err $*\n" && exit 1
}

warn() {
    echo -e "\n$is_warn $*\n"
}

# apt-get, yum, zypper or apk
cmd=$(type -P apt-get || type -P yum || type -P zypper || type -P apk)
[[ ! $cmd ]] && err "此脚本仅支持 ${yellow}(Ubuntu or Debian or CentOS or SUSE or Alpine)${none}."

# systemd or openrc
is_systemd=$(type -P systemctl)
is_openrc=$(type -P rc-service)
[[ ! $is_systemd && ! $is_openrc ]] && {
    err "此系统缺少 ${yellow}(systemctl 或 rc-service)${none}, 请安装 systemd 或确认 OpenRC 已启用."
}

# wget installed or none
is_wget=$(type -P wget)

# x64
case $(uname -m) in
amd64 | x86_64)
    is_arch=amd64
    ;;
*aarch64* | *armv8*)
    is_arch=arm64
    ;;
*)
    err "此脚本仅支持 64 位系统..."
    ;;
esac

is_core=sing-box
is_core_name=sing-box
is_core_dir=/etc/$is_core
is_core_bin=$is_core_dir/bin/$is_core
is_core_repo=SagerNet/$is_core
is_conf_dir=$is_core_dir/conf
is_log_dir=/var/log/$is_core
is_sh_bin=/usr/local/bin/$is_core
is_sh_dir=$is_core_dir/sh
is_sh_repo=cetaceang/sing-box
is_pkg="wget tar bash"
# Alpine: gcompat provides glibc compatibility for prebuilt binaries
[[ $cmd =~ apk ]] && is_pkg="$is_pkg gcompat jq"
is_config_json=$is_core_dir/config.json
is_shell_rc=/root/.bashrc
tmp_var_lists=(
    tmpcore
    tmpsh
    tmpjq
    is_core_ok
    is_sh_ok
    is_jq_ok
    is_pkg_ok
)

# tmp dir
tmpdir=$(mktemp -d) || err '无法创建临时目录'
trap 'rm -rf "$tmpdir"' EXIT

# set up var
for i in ${tmp_var_lists[*]}; do
    export $i=$tmpdir/$i
done

# load bash script.
load() {
    . $is_sh_dir/src/$1
}

# Always verify HTTPS certificates, especially when downloading executable code.
_wget() {
    [[ $proxy ]] && export https_proxy=$proxy
    wget "$@"
}

# Resolve main once, then download that immutable commit over verified HTTPS.
# No Release is required, and no upstream fallback is permitted.
prepare_scripts() {
    local target=$1 sha entry kind file archive_sha256 archive=$tmpdir/source.tar.gz
    mkdir -p "$target" || return 1
    if [[ $local_install ]]; then
        mkdir -p "$target/src" || return 1
        cp "$PWD/install.sh" "$PWD/sing-box.sh" "$target/" || return 1
        cp "$PWD"/src/*.sh "$target/src/" || return 1
        printf 'repo=%s\nsource=local\n' "$is_sh_repo" >"$target/.source"
    else
        sha=$(_wget -qO- "https://api.github.com/repos/$is_sh_repo/commits/main" |
            sed -n 's/^ *"sha": "\([a-f0-9]*\)",*$/\1/p' | head -n1)
        [[ $sha =~ ^[a-f0-9]{40}$ ]] || {
            msg err '无法解析 fork 的 main 提交；未使用其他仓库。'; return 1;
        }
        _wget -q -t 3 -O "$archive" "https://codeload.github.com/$is_sh_repo/tar.gz/$sha" || return 1
        tar -tzf "$archive" >"$tmpdir/archive.list" || return 1
        while IFS= read -r entry; do
            [[ $entry == "sing-box-$sha/"* && $entry != *'/../'* && $entry != *'/./'* ]] || return 1
        done <"$tmpdir/archive.list"
        tar -tvzf "$archive" >"$tmpdir/archive.types" || return 1
        while IFS= read -r kind; do
            [[ $kind == [-d]* ]] || return 1
        done <"$tmpdir/archive.types"
        # Extract only the two entry scripts and src/*.sh, never an install tree.
        while IFS= read -r entry; do
            file=${entry#"sing-box-$sha/"}
            case $file in
                install.sh|sing-box.sh|src/*.sh)
                    [[ $file != src/*/* ]] || return 1
                    tar -xzf "$archive" --strip-components=1 -C "$target" "$entry" || return 1 ;;
            esac
        done <"$tmpdir/archive.list"
        printf 'repo=%s\ncommit=%s\n' "$is_sh_repo" "$sha" >"$target/.source"
        archive_sha256=$(sha256sum "$archive") || return 1
        printf 'archive_sha256=%s\n' "${archive_sha256%% *}" >>"$target/.source"
        msg ok "管理脚本来源: $is_sh_repo@$sha"
    fi
    for file in "$target"/*.sh "$target"/src/*.sh; do
        [[ -f $file && ! -L $file ]] && bash -n "$file" || return 1
    done
    [[ -f $target/src/manager.sh ]] || return 1
    # The archive was fetched from the pinned fork commit, not user-supplied URLs.
    . "$target/src/manager.sh"
    validate_scripts "$target"
}

# print a mesage
msg() {
    case $1 in
    warn)
        local color=$yellow
        ;;
    err)
        local color=$red
        ;;
    ok)
        local color=$green
        ;;
    esac

    echo -e "${color}$(date +'%T')${none}) ${2}"
}

# show help msg
show_help() {
    echo -e "Usage: $0 [-f xxx | -l | -p xxx | -v xxx | -h]"
    echo -e "  -f, --core-file <path>          自定义 $is_core_name 文件路径, e.g., -f /root/$is_core-linux-amd64.tar.gz"
    echo -e "  -l, --local-install             本地获取安装脚本, 使用当前目录"
    echo -e "      --adopt-existing            接管已有 233boy 安装；只更新管理脚本，不重启服务"
    echo -e "  -p, --proxy <addr>              使用代理下载, e.g., -p http://127.0.0.1:2333"
    echo -e "  -v, --core-version <ver>        自定义 $is_core_name 版本, e.g., -v v1.8.13"
    echo -e "  -h, --help                      显示此帮助界面\n"

    exit 0
}

# install dependent pkg
install_pkg() {
    cmd_not_found=
    for i in $*; do
        [[ ! $(type -P $i) ]] && cmd_not_found="$cmd_not_found,$i"
    done
    if [[ $cmd_not_found ]]; then
        pkg=$(echo $cmd_not_found | sed 's/,/ /g')
        msg warn "安装依赖包 >${pkg}"
        if [[ $cmd =~ apk ]]; then
            apk update &>/dev/null
            apk add $pkg &>/dev/null
        else
            $cmd install -y $pkg &>/dev/null
            if [[ $? != 0 ]]; then
                [[ $cmd =~ yum ]] && yum install epel-release -y &>/dev/null
                if [[ $cmd =~ zypper ]]; then
                    $cmd --non-interactive refresh &>/dev/null
                else
                    $cmd update -y &>/dev/null
                fi
                $cmd install -y $pkg &>/dev/null
            fi
        fi
        [[ $? == 0 ]] && >$is_pkg_ok
    else
        >$is_pkg_ok
    fi
}

# download file
download() {
    case $1 in
    core)
        [[ ! $is_core_ver ]] && is_core_ver=$(_wget -qO- "https://api.github.com/repos/${is_core_repo}/releases/latest?v=$RANDOM" | grep tag_name | grep -E -o 'v([0-9.]+)')
        [[ $is_core_ver ]] && link="https://github.com/${is_core_repo}/releases/download/${is_core_ver}/${is_core}-${is_core_ver:1}-linux-${is_arch}.tar.gz"
        name=$is_core_name
        tmpfile=$tmpcore
        is_ok=$is_core_ok
        ;;
    sh)
        prepare_scripts "$tmpdir/scripts" && touch "$is_sh_ok"
        return ;;
    jq)
        link=https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$is_arch
        name="jq"
        tmpfile=$tmpjq
        is_ok=$is_jq_ok
        ;;
    esac

    [[ $link ]] && {
        msg warn "下载 ${name} > ${link}"
        if _wget -t 3 -q -c $link -O $tmpfile; then
            mv -f $tmpfile $is_ok
        fi
    }
}

# get server ip
get_ip() {
    export "$(_wget -4 -qO- https://one.one.one.one/cdn-cgi/trace | grep ip=)" &>/dev/null
    [[ -z $ip ]] && export "$(_wget -6 -qO- https://one.one.one.one/cdn-cgi/trace | grep ip=)" &>/dev/null
}

# check background tasks status
check_status() {
    # dependent pkg install fail
    [[ ! -f $is_pkg_ok ]] && {
        msg err "安装依赖包失败"
        if [[ $cmd =~ apk ]]; then
            msg err "请尝试手动安装依赖包: apk update; apk add $is_pkg"
        else
            msg err "请尝试手动安装依赖包: $cmd update -y; $cmd install -y $is_pkg"
        fi
        is_fail=1
    }

    # download file status
    if [[ $is_wget ]]; then
        [[ ! -f $is_core_ok ]] && {
            msg err "下载 ${is_core_name} 失败"
            is_fail=1
        }
        [[ ! -f $is_sh_ok ]] && {
            msg err "下载 ${is_core_name} 脚本失败"
            is_fail=1
        }
        [[ ! -f $is_jq_ok ]] && {
            msg err "下载 jq 失败"
            is_fail=1
        }
    else
        [[ ! $is_fail ]] && {
            is_wget=1
            [[ ! $is_core_file ]] && download core &
            [[ ! $local_install ]] && download sh &
            [[ $jq_not_found ]] && download jq &
            get_ip
            wait
            check_status
        }
    fi

    # found fail status, remove tmp dir and exit.
    [[ $is_fail ]] && {
        exit_and_del_tmpdir
    }
}

# parameters check
pass_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
        -f | --core-file)
            [[ -z $2 ]] && {
                err "($1) 缺少必需参数, 正确使用示例: [$1 /root/$is_core-linux-amd64.tar.gz]"
            } || [[ ! -f $2 ]] && {
                err "($2) 不是一个常规的文件."
            }
            is_core_file=$2
            shift 2
            ;;
        -l | --local-install)
            [[ ! -f ${PWD}/src/core.sh || ! -f ${PWD}/$is_core.sh ]] && {
                err "当前目录 (${PWD}) 非完整的脚本目录."
            }
            local_install=1
            shift 1
            ;;
        --adopt-existing)
            adopt_existing=1
            shift
            ;;
        -p | --proxy)
            [[ -z $2 ]] && {
                err "($1) 缺少必需参数, 正确使用示例: [$1 http://127.0.0.1:2333 or -p socks5://127.0.0.1:2333]"
            }
            proxy=$2
            shift 2
            ;;
        -v | --core-version)
            [[ -z $2 ]] && {
                err "($1) 缺少必需参数, 正确使用示例: [$1 v1.8.13]"
            }
            is_core_ver=v${2//v/}
            shift 2
            ;;
        -h | --help)
            show_help
            ;;
        *)
            echo -e "\n${is_err} ($*) 为未知参数...\n"
            show_help
            ;;
        esac
    done
    [[ $is_core_ver && $is_core_file ]] && {
        err "无法同时自定义 ${is_core_name} 版本和 ${is_core_name} 文件."
    }
    [[ $adopt_existing && ( $is_core_ver || $is_core_file ) ]] &&
        err '--adopt-existing 不允许更换内核版本或文件。'
    return 0
}

# exit and remove tmpdir
exit_and_del_tmpdir() {
    rm -rf $tmpdir
    [[ ! $1 ]] && {
        msg err "哦豁.."
        msg err "安装过程出现错误..."
        echo -e "反馈问题) https://github.com/${is_sh_repo}/issues"
        echo
        exit 1
    }
    exit 0
}

# main
install_main() {
    # Parse before the old-install guard: adoption never enters fresh installation.
    [[ $# -eq 0 ]] || pass_args "$@"
    if [[ $adopt_existing ]]; then
        command -v jq >/dev/null && command -v wget >/dev/null ||
            err '接管需要已安装的 jq 和 wget；请先手动安装依赖。'
        prepare_scripts "$tmpdir/scripts" || err '准备 fork 管理脚本失败，原安装未改动。'
        replace_scripts "$tmpdir/scripts" || err '接管失败；请查看上述原因和备份。'
        return 0
    fi
    # check old version
    [[ -e $is_core_dir || -e $is_sh_bin || -L $is_sh_bin ]] && {
        err "检测到已有安装或目录；安全接管请显式使用 --adopt-existing。"
    }

    # show welcome msg
    clear
    echo
    echo "........... $is_core_name cetaceang fork (upstream $author) .........."
    echo

    # start installing...
    msg warn "开始安装..."
    [[ $is_core_ver ]] && msg warn "${is_core_name} 版本: ${yellow}$is_core_ver${none}"
    [[ $proxy ]] && msg warn "使用代理: ${yellow}$proxy${none}"
    # create tmpdir
    mkdir -p $tmpdir
    # if is_core_file, copy file
    [[ $is_core_file ]] && {
        cp -f $is_core_file $is_core_ok
        msg warn "${yellow}${is_core_name} 文件使用 > $is_core_file${none}"
    }
    # local dir install sh script
    [[ $local_install ]] && {
        prepare_scripts "$tmpdir/scripts" || err '本地管理脚本检查失败'
        >"$is_sh_ok"
        msg warn "${yellow}本地获取安装脚本 > $PWD ${none}"
    }

    if [[ $is_systemd ]]; then
        timedatectl set-ntp true &>/dev/null
        [[ $? != 0 ]] && {
            is_ntp_on=1
        }
    fi

    # install dependent pkg
    if [[ $cmd =~ apk ]]; then
        # Alpine: force install full versions to replace BusyBox applets
        apk update &>/dev/null
        apk add $is_pkg &>/dev/null
        [[ $? == 0 ]] && >$is_pkg_ok
    else
        install_pkg $is_pkg &
    fi

    # jq
    if [[ $(type -P jq) ]]; then
        >$is_jq_ok
    else
        jq_not_found=1
    fi
    # if wget installed. download core, sh, jq, get ip
    [[ $is_wget ]] && {
        [[ ! $is_core_file ]] && download core &
        [[ ! $local_install ]] && download sh &
        [[ $jq_not_found ]] && download jq &
        get_ip
    }

    # waiting for background tasks is done
    wait

    # check background tasks status
    check_status

    # test $is_core_file
    if [[ $is_core_file ]]; then
        mkdir -p $tmpdir/testzip
        tar zxf $is_core_ok --strip-components 1 -C $tmpdir/testzip &>/dev/null
        [[ $? != 0 ]] && {
            msg err "${is_core_name} 文件无法通过测试."
            exit_and_del_tmpdir
        }
        [[ ! -f $tmpdir/testzip/$is_core ]] && {
            msg err "${is_core_name} 文件无法通过测试."
            exit_and_del_tmpdir
        }
    fi

    # get server ip.
    [[ ! $ip ]] && {
        msg err "获取服务器 IP 失败."
        exit_and_del_tmpdir
    }

    # create sh dir...
    mkdir -p $is_sh_dir

    # copy sh file or unzip sh zip file.
    cp -a "$tmpdir/scripts/." "$is_sh_dir/" || err '复制管理脚本失败'

    # create core bin dir
    mkdir -p $is_core_dir/bin
    # copy core file or unzip core zip file
    if [[ $is_core_file ]]; then
        cp -rf $tmpdir/testzip/* $is_core_dir/bin
    else
        tar zxf $is_core_ok --strip-components 1 -C $is_core_dir/bin
    fi

    # add alias
    echo "alias sb=$is_sh_bin" >>"$is_shell_rc"
    echo "alias $is_core=$is_sh_bin" >>"$is_shell_rc"

    # core command
    ln -sf $is_sh_dir/$is_core.sh $is_sh_bin
    ln -sf "$is_sh_dir/$is_core.sh" "${is_sh_bin%/*}/sb"

    # jq
    [[ $jq_not_found ]] && { mv -f "$is_jq_ok" /usr/bin/jq && chmod +x /usr/bin/jq; }

    # chmod
    chmod +x "$is_core_bin" "$is_sh_bin" "${is_sh_bin%/*}/sb"

    # create log dir
    mkdir -p $is_log_dir

    # show a tips msg
    msg ok "生成配置文件..."

    # create service
    load systemd.sh
    is_new_install=1
    install_service $is_core &>/dev/null

    # create condf dir
    mkdir -p $is_conf_dir

    load manager.sh
    load core.sh
    # create a reality config
    add reality
    # wait for background tasks (e.g., OpenRC service start)
    wait
    # remove tmp dir and exit.
    exit_and_del_tmpdir ok
}

# start.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    [[ $EUID == 0 ]] || err "当前非 ${yellow}ROOT用户.${none}"
    install_main "$@"
fi

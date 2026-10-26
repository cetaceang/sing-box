#!/bin/bash
# Shared, non-destructive management transactions. Never source the old installer.

manager_error() { printf '%s\n' "$*" >&2; return 1; }

# Read the effective unit, including drop-ins. Do not eval systemd output.
# Unknown arguments/layouts are rejected instead of checking a different config.
service_check_args() {
    check_args=()
    local raw argv option value have_config='' have_conf=''
    local -a words
    if [[ $is_systemd ]]; then
        raw=$(systemctl show "$is_core.service" --property=ExecStart --value) || return 1
        [[ $raw == *'argv[]='* && $raw != *'} {'* ]] || {
            manager_error '无法识别 systemd ExecStart，停止操作。'; return 1;
        }
        argv=${raw#*argv[]=}
        [[ $argv != *'argv[]='* ]] || {
            manager_error '不支持包含多条 ExecStart 的服务。'; return 1;
        }
        argv=${argv%% ;*}
        # Supported 233boy units have plain, absolute paths without quoting.
        [[ $argv != *[\"\'\$\`\\]* && $argv != *$'\n'* ]] || {
            manager_error 'ExecStart 含不支持的引用或变量，停止操作。'; return 1;
        }
        read -r -a words <<<"$argv"
        [[ ${words[0]} == "$is_core_bin" && ${words[1]} == run ]] || {
            manager_error 'ExecStart 的内核路径或运行方式不兼容。'; return 1;
        }
        words=("${words[@]:2}")
        while ((${#words[@]})); do
            option=${words[0]}
            case $option in
                -c|--config|-C|--config-directory|-D|--directory)
                    ((${#words[@]} >= 2)) || return 1
                    value=${words[1]}
                    case $option in
                        -c|--config)
                            [[ ! $have_config && $value == "$is_config_json" ]] || return 1
                            have_config=1 ;;
                        -C|--config-directory)
                            [[ ! $have_conf && $value == "$is_conf_dir" ]] || return 1
                            have_conf=1 ;;
                        -D|--directory) [[ $value == /* && -d $value ]] || return 1 ;;
                    esac
                    check_args+=("$option" "$value")
                    words=("${words[@]:2}") ;;
                --disable-color)
                    check_args+=("$option"); words=("${words[@]:1}") ;;
                *) manager_error 'ExecStart 含不支持的参数，停止操作。'; return 1 ;;
            esac
        done
        [[ $have_config && $have_conf ]] || {
            manager_error 'ExecStart 必须使用现有 config.json 和 conf/。'; return 1;
        }
    else
        # Original OpenRC layout (adoption itself deliberately requires systemd).
        [[ $is_openrc ]] || return 1
        check_args=(-c "$is_config_json" -C "$is_conf_dir")
    fi
}

check_current_config() {
    service_check_args || return 1
    # Kernel diagnostics may contain credentials; never print them to logs.
    "$is_core_bin" check "${check_args[@]}" >/dev/null 2>&1
}

# Only these files belong to the management program. Metadata elsewhere in sh/
# (including subscriptions) is carried forward byte for byte.
validate_scripts() {
    local dir=$1 file
    for file in install.sh sing-box.sh src/{init,core,download,manager,systemd,help,caddy,dns,log,import,bbr}.sh; do
        [[ -f $dir/$file && ! -L $dir/$file ]] && bash -n "$dir/$file" || {
            manager_error "管理脚本缺失或语法检查失败: $file"; return 1;
        }
    done
    grep -qx 'is_sh_repo=cetaceang/sing-box' "$dir/src/init.sh" &&
        grep -qx 'is_sh_repo=cetaceang/sing-box' "$dir/install.sh"
}

validate_existing_layout() {
    local file target
    [[ $is_systemd && -d $is_sh_dir && ! -L $is_sh_dir &&
       -d $is_conf_dir && ! -L $is_conf_dir && -f $is_config_json &&
       ! -L $is_config_json && -x $is_core_bin ]] || {
        manager_error '安装布局不兼容：需要标准 systemd、config.json、conf/、bin/ 和 sh/。'; return 1;
    }
    for file in sing-box.sh install.sh src/init.sh src/core.sh src/download.sh; do
        [[ -f $is_sh_dir/$file && ! -L $is_sh_dir/$file ]] || {
            manager_error "旧版管理脚本缺失或为符号链接: $file"; return 1;
        }
    done
    grep -Eq '^author=233boy$|^is_sh_repo=cetaceang/sing-box$' "$is_sh_dir/src/init.sh" || {
        manager_error '未识别到 233boy 或本 fork 的管理脚本。'; return 1;
    }
    for file in "$is_sh_bin" "${is_sh_bin%/*}/sb"; do
        if [[ -e $file || -L $file ]]; then
            target=$(readlink -f "$file") || return 1
            [[ $target == "$is_sh_dir/sing-box.sh" ]] || {
                manager_error "管理命令指向不兼容的位置: $file"; return 1;
            }
        elif [[ $file == "$is_sh_bin" ]]; then
            manager_error '缺少原有 sing-box 管理命令。'; return 1
        fi
    done
    service_check_args || { manager_error 'systemd 配置路径不兼容。'; return 1; }
    check_current_config || { manager_error '现有配置未通过内核检查，接管已停止（未修改任何文件）。'; return 1; }
}

# Called by both --adopt-existing and update.sh. Rollback is also installed as a
# standalone script in each backup, so it works even if management cannot start.
replace_scripts() (
    umask 077
    local source_dir=$1 backup stage='' old_tree='' switched='' committed='' file
    local lock=$is_core_dir/.management-lock
    validate_scripts "$source_dir" || return 1
    validate_existing_layout || return 1
    mkdir "$lock" 2>/dev/null || { manager_error '另一个管理操作正在进行。'; return 1; }
    cleanup_scripts() {
        local status=$?
        trap - EXIT INT TERM HUP
        if [[ $switched && ! $committed ]]; then
            [[ -d $is_sh_dir ]] && mv "$is_sh_dir" "$stage/failed"
            mv "$old_tree" "$is_sh_dir" || {
                manager_error "自动恢复失败，请执行 $backup/rollback.sh"; exit 1;
            }
            for file in "$is_sh_bin" "${is_sh_bin%/*}/sb"; do
                rm -f "$file"
                [[ -e $backup/commands/${file##*/} || -L $backup/commands/${file##*/} ]] &&
                    cp -a "$backup/commands/${file##*/}" "$file"
            done
            manager_error '接管/更新失败，已恢复原管理脚本。'
        fi
        [[ $stage ]] && rm -rf "$stage"
        rmdir "$lock"
        exit "$status"
    }
    trap cleanup_scripts EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    mkdir -p "$is_core_dir/backups" || return 1
    chmod 700 "$is_core_dir/backups" || return 1
    backup=$(mktemp -d "$is_core_dir/backups/scripts-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX") || return 1
    mkdir "$backup/commands" || return 1
    cp -a "$is_sh_dir" "$backup/sh" || return 1
    for file in "$is_sh_bin" "${is_sh_bin%/*}/sb"; do
        [[ ! -e $file && ! -L $file ]] || cp -a "$file" "$backup/commands/" || return 1
    done
    systemctl cat "$is_core.service" >"$backup/service.txt" || return 1
    systemctl show "$is_core.service" --property=ExecStart --value >"$backup/exec-start.txt" || return 1
    # Store paths as shell literals, never interpolate them as executable code.
    {
        printf '#!/bin/bash\nset -e\numask 077\n'
        printf 'backup=%q\nscript_dir=%q\ncommand_dir=%q\nlock=%q\n' "$backup" "$is_sh_dir" "${is_sh_bin%/*}" "$lock"
        cat <<'ROLLBACK'
mkdir "$lock" 2>/dev/null || { echo '另一个管理操作正在进行。' >&2; exit 1; }
trap 'rmdir "$lock"' EXIT
work=$(mktemp -d "${script_dir%/*}/.rollback-XXXXXX")
cp -a "$backup/sh" "$work/sh"
mv "$script_dir" "$work/current"
if ! mv "$work/sh" "$script_dir"; then
    mv "$work/current" "$script_dir"
    exit 1
fi
for name in sing-box sb; do
    rm -f "$command_dir/$name"
    if [[ -e $backup/commands/$name || -L $backup/commands/$name ]]; then
        cp -a "$backup/commands/$name" "$command_dir/$name"
    fi
done
rm -rf "$work"
echo '已恢复接管/更新前的管理脚本；未改动配置、内核或服务。'
ROLLBACK
    } >"$backup/rollback.sh" || return 1
    chmod 700 "$backup/rollback.sh" || return 1
    stage=$(mktemp -d "$is_core_dir/.scripts-XXXXXX") || return 1
    cp -a "$is_sh_dir" "$stage/sh" || return 1
    for file in install.sh sing-box.sh; do
        rm -f "$stage/sh/$file" || return 1
        cp -p "$source_dir/$file" "$stage/sh/$file" || return 1
    done
    [[ ! -L $stage/sh/src ]] || { manager_error 'sh/src 为符号链接，停止操作。'; return 1; }
    for file in "$source_dir"/src/*.sh; do
        rm -f "$stage/sh/src/${file##*/}" || return 1
        cp -p "$file" "$stage/sh/src/" || return 1
    done
    rm -f "$stage/sh/.source"
    [[ ! -f $source_dir/.source ]] || cp "$source_dir/.source" "$stage/sh/.source" || return 1
    validate_scripts "$stage/sh" || return 1
    chmod +x "$stage/sh/sing-box.sh" || return 1
    old_tree=$stage/original
    mv "$is_sh_dir" "$old_tree" || return 1
    switched=1
    mv "$stage/sh" "$is_sh_dir" || return 1
    ln -sfn "$is_sh_dir/sing-box.sh" "$is_sh_bin" || return 1
    ln -sfn "$is_sh_dir/sing-box.sh" "${is_sh_bin%/*}/sb" || return 1
    # Do not execute init.sh: it may create certificates or manage Caddy.
    validate_scripts "$is_sh_dir" && check_current_config || return 1
    committed=1
    printf '管理脚本已切换到 cetaceang/sing-box；未重启服务。\n备份及回滚脚本: %s\n' "$backup"
)

# Validate a complete staged configuration, then atomically replace one JSON.
# The original remains available in a private backup, also on check failure.
commit_config() (
    umask 077
    local destination=$1 candidate=$2 original=${3:-$1}
    local work='' backup='' changed='' done='' option value
    local -a staged_args
    local lock=$is_core_dir/.management-lock
    [[ $destination == "$is_config_json" || ${destination%/*} == "$is_conf_dir" ]] || return 1
    [[ ! -L $destination && ! -L $original ]] || return 1
    [[ $destination == "$original" || ! -e $destination ]] || {
        manager_error '目标配置文件已存在，停止操作。'; return 1;
    }
    service_check_args || return 1
    mkdir "$lock" 2>/dev/null || { manager_error '另一个管理操作正在进行。'; return 1; }
    cleanup_config() {
        local status=$?
        trap - EXIT INT TERM HUP
        if [[ $changed && ! $done ]]; then
            rm -f "$destination"
            [[ ! -f $backup/original ]] || cp -p "$backup/original" "$original"
            manager_error '配置验证失败，已恢复原文件；未重启服务。'
        fi
        [[ ! $work ]] || rm -rf "$work"
        rmdir "$lock"
        exit "$status"
    }
    trap cleanup_config EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    mkdir -p "$is_core_dir/backups" || return 1
    chmod 700 "$is_core_dir/backups" || return 1
    backup=$(mktemp -d "$is_core_dir/backups/config-XXXXXX") || return 1
    [[ ! -f $original ]] || cp -p "$original" "$backup/original" || return 1
    printf '%s\n' "$original" >"$backup/path"
    work=$(mktemp -d "$is_core_dir/.config-XXXXXX") || return 1
    cp -a "$is_conf_dir" "$work/conf" || return 1
    cp -p "$is_config_json" "$work/config.json" || return 1
    printf '%s\n' "$candidate" >"$work/candidate" || return 1
    jq -e 'type == "object"' "$work/candidate" >/dev/null 2>&1 || return 1
    if [[ $destination == "$is_config_json" ]]; then
        cp "$work/candidate" "$work/config.json" || return 1
    else
        rm -f "$work/conf/${original##*/}"
        cp "$work/candidate" "$work/conf/${destination##*/}" || return 1
    fi
    staged_args=()
    while ((${#check_args[@]})); do
        option=${check_args[0]}; check_args=("${check_args[@]:1}")
        staged_args+=("$option")
        case $option in
            -c|--config) value=$work/config.json ;;
            -C|--config-directory) value=$work/conf ;;
            -D|--directory) value=${check_args[0]} ;;
            *) continue ;;
        esac
        staged_args+=("$value"); check_args=("${check_args[@]:1}")
    done
    "$is_core_bin" check "${staged_args[@]}" >/dev/null 2>&1 || {
        manager_error '新配置未通过内核检查，原文件保持不变。'; return 1;
    }
    if [[ -f $original ]]; then
        cp -p "$original" "$work/install" || return 1
        cat "$work/candidate" >"$work/install" || return 1
    else
        cp "$work/candidate" "$work/install" || return 1
    fi
    changed=1
    mv "$work/install" "$destination" || return 1
    [[ $original == "$destination" ]] || rm -f "$original" || return 1
    check_current_config || return 1
    done=1
)

valid_handshake() {
    [[ $1 && $1 != *[[:space:]/\"\\]* && $2 =~ ^[1-9][0-9]{0,4}$ && $2 -le 65535 ]]
}

ask_handshake() {
    local server port
    read -r -p "handshake 地址 [${is_handshake_server:-$is_servername}]: " server
    read -r -p "handshake 端口 [${is_handshake_port:-443}]: " port
    is_handshake_server=${server:-${is_handshake_server:-$is_servername}}
    is_handshake_port=${port:-${is_handshake_port:-443}}
    valid_handshake "$is_handshake_server" "$is_handshake_port" || {
        manager_error 'handshake 地址或端口无效（端口范围 1–65535）。'; return 1;
    }
}

change_handshake() {
    [[ $is_reality ]] || { manager_error '仅 REALITY 节点支持 handshake。'; return 1; }
    if [[ $# -gt 0 ]]; then
        is_handshake_server=${1:-$is_handshake_server}
        is_handshake_port=${2:-$is_handshake_port}
    else
        ask_handshake || return 1
    fi
    valid_handshake "$is_handshake_server" "$is_handshake_port" || {
        manager_error 'handshake 地址或端口无效（端口范围 1–65535）。'; return 1;
    }
    local candidate
    candidate=$(jq --arg server "$is_handshake_server" --argjson port "$is_handshake_port" \
        '.inbounds[0].tls.reality.handshake |= (.server = $server | .server_port = $port)' \
        "$is_conf_dir/$is_config_file") || return 1
    commit_config "$is_conf_dir/$is_config_file" "$candidate" || return 1
    manage restart &
    msg "已更新 REALITY handshake: $is_handshake_server:$is_handshake_port"
}

# Change only the requested fields, leaving other inbounds/users/outbounds and
# unknown extensions intact. New JSON is a source of values, never a replacement.
preserve_config() {
    is_new_json=$(jq --arg mode "$is_change_id" --arg old_name "$is_config_file" \
        --argjson new "$is_new_json" '
        $new.inbounds[0] as $n |
        if $mode == "1" or $mode == "full" then .inbounds[0].listen_port = $n.listen_port else . end |
        if $mode == "2" then .inbounds[0].transport.headers.host = $n.transport.headers.host else . end |
        if $mode == "3" then .inbounds[0].transport.path = $n.transport.path else . end |
        if $mode == "4" or $mode == "full" then
            if $n.users[0].password != null then .inbounds[0].users[0].password = $n.users[0].password else . end |
            if $n.password != null then .inbounds[0].password = $n.password else . end
        else . end |
        if ($mode == "5" or $mode == "full") and $n.users[0].uuid != null then
            .inbounds[0].users[0].uuid = $n.users[0].uuid else . end |
        if $mode == "6" then .inbounds[0].method = $n.method | .inbounds[0].password = $n.password else . end |
        if $mode == "7" then .inbounds[0].override_address = $n.override_address else . end |
        if $mode == "8" then .inbounds[0].override_port = $n.override_port else . end |
        if $mode == "9" then
            .inbounds[0].tls.reality.private_key = $n.tls.reality.private_key |
            (.outbounds[] | select((.tag? // "") | startswith("public_key_"))).tag = $new.outbounds[1].tag
        else . end |
        if $mode == "10" or ($mode == "full" and $n.tls.reality != null) then
            .inbounds[0].tls.server_name = $n.tls.server_name else . end |
        if $mode == "12" then .inbounds[0].users[0].username = $n.users[0].username else . end |
        if $mode == "full" and $n.transport.path != null then .inbounds[0].transport.path = $n.transport.path else . end |
        if .inbounds[0].tag == $old_name then .inbounds[0].tag = $n.tag else . end
        ' "$is_conf_dir/$is_config_file" 2>/dev/null) || {
            manager_error '无法保留旧配置字段；原文件保持不变。'; return 1;
        }
}

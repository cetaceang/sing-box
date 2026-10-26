# sing-box 管理脚本（cetaceang fork）

基于 [233boy/sing-box](https://github.com/233boy/sing-box)，保留上游作者署名和 GPL-3.0 许可。管理脚本固定来自 **cetaceang/sing-box**；内核仍来自 **SagerNet/sing-box**。支持原有协议和命令，新增 REALITY handshake 管理及原地接管。

## 原地接管已有 233boy 安装

先获取本 fork 的代码，再显式运行接管模式：

```bash
git clone https://github.com/cetaceang/sing-box.git
cd sing-box
sudo bash install.sh --adopt-existing --local-install
```

也可单独下载入口脚本，由它获取本 fork 的固定 main 提交：

```bash
wget -O /tmp/cetaceang-sing-box-install.sh https://raw.githubusercontent.com/cetaceang/sing-box/main/install.sh
sudo bash /tmp/cetaceang-sing-box-install.sh --adopt-existing
```

入口脚本依赖 Bash、wget、tar；接管还要求现有 jq 可用。所有 HTTPS 下载均验证证书。接管必须显式提供 `--adopt-existing`，不允许同时指定内核文件或版本。普通安装遇到已有目录会停止，不会转入覆盖或重装。

接管会核对原版脚本身份、管理命令、目录及 systemd 的有效 ExecStart（包括 drop-in）。支持标准的 `/etc/sing-box/bin/sing-box run -c /etc/sing-box/config.json -C /etc/sing-box/conf`，以及对应长参数、`-D`/`--directory`、`--disable-color`。多条 ExecStart、额外配置路径、变量/引用或不认识的参数会被拒绝，明确报告原因。接管模式目前要求 systemd；不会猜测或改写第三方/OpenRC 布局。

接管前先用原内核检查现有完整配置，然后保存私有备份到 `/etc/sing-box/backups/scripts-时间-随机串/`，其中包含原 `sh/`、命令链接及 systemd 配置快照。

接管时：

| 内容 | 行为 |
|---|---|
| `/etc/sing-box/sh/install.sh`、`sing-box.sh`、`src/*.sh` | 替换为本 fork 的管理脚本 |
| `sh/.source` | 记录仓库、固定提交及下载包 SHA-256；本地安装记录 local |
| `/usr/local/bin/sing-box`、`sb` | 指向管理入口；缺少 sb 时补齐 |
| `config.json`、`conf/` 所有 JSON | 字节保持不变 |
| `bin/` 内核、版本、证书及密钥 | 保持不变 |
| 其他订阅文件、`sh/` 内非脚本元数据 | 保持不变 |
| systemd unit、drop-in、ExecStart、运行中的进程 | 保持不变，不 reload、不 restart |

不会新建默认节点，不会调用卸载、重装或删除原安装目录。可重复接管，每次独立备份。脚本替换失败或最终检查失败会自动恢复原脚本和命令链接。请确保没有其他管理员同时修改配置；进程间管理锁会阻止本 fork 的并发修改。

### 回滚接管或脚本更新

使用接管完成时显示的**对应备份目录**：

```bash
sudo bash /etc/sing-box/backups/scripts-具体时间-随机串/rollback.sh
```

回滚只恢复该次操作前的管理脚本和命令，不会改变配置、内核或服务，也不重启代理。不要通过 `reinstall` 回滚。备份包含敏感安装数据，目录权限为 0700；请妥善保管，不要上传到日志或 issue。异常断电/SIGKILL 无法触发 Shell trap，可用保留的 `rollback.sh` 手动恢复；确认没有管理进程后才能手工移除遗留 `.management-lock`。

## REALITY handshake

支持 VLESS REALITY 和 VLESS HTTP2 REALITY。SNI、握手目标地址和端口互相独立；新节点未指定时仍使用 `SNI:443`。

在 `sing-box` 菜单中选择「添加配置」→ REALITY 协议，可输入 SNI、handshake 地址与端口，回车采用默认值。修改已有节点：选择「更改配置」→ 节点 →「更改 REALITY handshake」。查看节点会显示当前 handshake。

```bash
# 修改现有节点（name 可使用原来的文件名/端口筛选）
sing-box handshake 39149 127.0.0.1 8443
sing-box change 39149 handshake 127.0.0.1 8443

# 只改地址；省略端口则保留原端口
sing-box handshake 39149 localhost
# 只改端口，地址传空字符串
sing-box handshake 39149 '' 9443
# 交互选择节点及握手参数
sing-box handshake

# 新建：协议、入站端口、UUID、SNI、握手地址、握手端口
sing-box add reality 39149 auto node.cetaceang.de 127.0.0.1 8443
sing-box add rh2 34138 auto node2.cetaceang.de 127.0.0.1 8443
```

修改 SNI 不会跟随修改现有握手目标（即使原握手原本等于旧 SNI）。修改 UUID、端口、密钥等也只更新对应字段，保留其他用户、short_id、额外握手参数和其他未编辑字段。相同协议的修改优先采用 jq 定点更新，不再删除旧 JSON 后重建。切换协议会按新协议生成配置；在两种 REALITY 间切换仍保留原握手对象。

修改配置前先备份到 `/etc/sing-box/backups/config-随机串/`，在隔离的配置副本中运行完整 `sing-box check`，采用有效 systemd 服务相同的参数（验证副本使用临时路径）；通过后替换目标，再按原路径检查一次。失败则恢复原文件且不重启。成功的节点参数修改沿用原脚本的服务重启行为。

`fix` 和 `fix-all` 对有效的已有 JSON 采用完整配置验证并保留原始文件，包括格式及未知字段。无参数的修复不会用默认值覆盖自定义配置；配置无效时报告失败并保留原文件，需要根据实际错误人工修复。`fix-config.json` 同样保留已有主配置的 DNS、路由等字段。

本仓库不设置 Nginx、证书或防火墙。使用本地 HTTPS 回落前，请自行确保 `127.0.0.1:8443` 按对应 SNI 提供有效证书，且节点客户端仍使用节点域名作为 SNI。

## 全新安装和更新

```bash
# 仅对没有已有安装的服务器
sudo bash install.sh
# 或用当前完整检出安装
sudo bash install.sh --local-install

# 只更新管理脚本：使用与接管相同的备份、替换及恢复流程，不重启
sing-box update.sh
# 同等命令
sing-box update sh

# 内核更新仍使用 SagerNet 官方 Release；这是单独的显式操作
sing-box update core
```

管理脚本采用一个简单下载通道：通过 GitHub API 获取 **本 fork main 的完整 commit SHA**，再从本 fork 的 codeload 固定 SHA 下载源码。验证归档根目录、路径、文件类型、所需文件和 Bash 语法，仅提取 Shell 管理代码，并记录 SHA-256。不会回退到 233boy、不会从浮动的归档直接覆盖安装目录，也不依赖 fork 是否存在 Release。SHA-256 用于本地审计，下载真实性依靠经过验证的 GitHub HTTPS 和固定提交，不代表独立签名。

GitHub Actions 会在 main 更新时运行测试，推送与脚本版本一致的 `v*` tag 时发布 `code.tar.gz` 及 SHA256SUMS，供人工核验或分发。脚本自身的安装/更新始终使用上述 main 固定提交方案，不接受脚本 Release 版本号；内核版本选项保持原有用途。

`sing-box reinstall` 仍是原版的破坏性重装命令，会卸载配置。接管、更新和回滚都不调用它。

## 验证旧节点与测试

接管前后可以分别生成仅包含摘要的配置清单（不要打印节点 JSON 或私钥）：

```bash
sudo sh -c 'find /etc/sing-box/conf -type f -name "*.json" -exec sha256sum {} +; sha256sum /etc/sing-box/config.json /etc/sing-box/bin/sing-box' > /tmp/sing-box-before.sha256
systemctl show sing-box --property=ExecStart --property=MainPID --property=ActiveState
# 执行接管后：摘要、有效 ExecStart 和 MainPID 应保持一致
sudo sha256sum -c /tmp/sing-box-before.sha256
systemctl show sing-box --property=ExecStart --property=MainPID --property=ActiveState
sing-box info
sing-box fix-all
```

对每个原有客户端实际连接，验证网站访问和代理请求。`sing-box check` 能验证格式及内核配置兼容性，不能代替真实网络连通性测试。握手目标可单独验证证书：

```bash
openssl s_client -connect 127.0.0.1:8443 -servername node.cetaceang.de -verify_hostname node.cetaceang.de -verify_return_error </dev/null
```

开发测试全部在临时目录进行，不修改 `/etc`、真实服务或生产服务器：

```bash
for file in install.sh sing-box.sh src/*.sh; do bash -n "$file" || exit; done
python3 -m unittest discover -s tests -v
# 可选：用自行下载的官方内核运行真实集成检查
SING_BOX_TEST_CORE=/absolute/path/to/official/sing-box python3 -m unittest discover -s tests -v
shellcheck --extended-analysis=false -s bash -S error install.sh sing-box.sh src/{init,core,download,help,manager,dns,log}.sh
```

新事务辅助文件额外运行完整 ShellCheck；原版代码仍有非 error 级的历史风格/引用告警。旧版本配置只有在其原内核本身能通过检查时才能接管，不会为了接管强制升级内核或改写不兼容字段。

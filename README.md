# socks5m

基于 [microsocks](https://github.com/rofl0r/microsocks) 的多用户 SOCKS5 代理管理脚本。每个用户独占一个端口，并提供密码修改、端口修改、流量统计、重置统计和卸载等命令。

## 特性

- **多用户**：每个用户对应一个独立端口和一个 systemd 实例（`socks5m@端口`），互不影响
- **用户管理**：添加、删除、修改密码、修改端口、列出所有用户及运行状态
- **流量统计**：基于 iptables 按端口统计上传 / 下载流量，支持全部或单个端口查看与重置
- **开机自启**：通过 systemd 管理，异常退出自动拉起
- **防火墙联动**：自动检测 ufw / firewalld 并放行或关闭对应端口
- **一键卸载**：清理所有服务、规则、配置和程序本身

## 系统要求

- Debian / Ubuntu / CentOS / RHEL / Rocky / AlmaLinux
- root 权限
- systemd
- 可访问 GitHub（用于克隆并编译 microsocks）

## 安装

```bash
# 1. 将脚本保存为 socks5m.sh
# 2. 运行安装（会自动创建一个随机用户）
sudo bash socks5m.sh install

# 或指定首个用户的端口、用户名、密码
sudo bash socks5m.sh install 20001 alice Pass1234
```

安装完成后会将脚本复制到 `/usr/local/sbin/socks5m`，之后可直接使用 `socks5m` 命令。

## 命令一览

| 命令 | 说明 |
| --- | --- |
| `socks5m install [端口 用户名 密码]` | 安装依赖、编译 microsocks，并创建首个用户 |
| `socks5m add [端口 用户名 密码]` | 添加用户，参数不填则随机生成 |
| `socks5m del <端口>` | 删除指定端口的用户 |
| `socks5m passwd <端口> [新密码]` | 修改密码，不填则随机生成 |
| `socks5m port <旧端口> <新端口>` | 修改用户端口 |
| `socks5m list` | 列出所有用户、密码及运行状态 |
| `socks5m stats [端口]` | 查看流量统计，不填则显示全部 |
| `socks5m reset [端口]` | 重置流量统计，不填则重置全部 |
| `socks5m restart` | 重启所有代理服务 |
| `socks5m uninstall` | 卸载（会删除所有用户，需确认） |

## 使用示例

```bash
# 添加用户
socks5m add                        # 随机端口、用户名、密码
socks5m add 20001 alice Pass1234   # 指定端口、用户名、密码

# 查看用户
socks5m list

# 修改密码与端口
socks5m passwd 20001 NewPass888
socks5m port 20001 20002

# 流量统计
socks5m stats
socks5m stats 20002
socks5m reset 20002

# 删除用户
socks5m del 20002

# 卸载
socks5m uninstall
```

## 客户端连接

添加用户后会输出连接信息，格式如下：

```
服务器 IP : 1.2.3.4
端口     : 20001
用户名   : alice
密码     : Pass1234
连接串   : socks5://alice:Pass1234@1.2.3.4:20001
```

在支持 SOCKS5 的客户端（如 v2rayN、Proxifier、浏览器代理插件等）中填写以上信息即可。

## 目录与文件

| 路径 | 说明 |
| --- | --- |
| `/usr/local/sbin/socks5m` | 管理脚本本体 |
| `/usr/local/bin/microsocks` | 编译后的 microsocks 程序 |
| `/etc/socks5m/users.db` | 用户数据库，每行格式：`端口 用户名 密码` |
| `/etc/socks5m/<端口>.env` | 单个用户的环境变量文件（权限 600） |
| `/etc/systemd/system/socks5m@.service` | systemd 模板服务 |

## 流量统计说明

- 统计方式：在代理端口上挂载 iptables 无目标计数规则，`stats` 显示入站（上传）与出站（下载）字节数。
- 统计范围仅限经过代理端口的数据量。
- 计数在服务启动时重新挂载，**系统重启后计数清零**。如需长期累计，可通过 cron 定期记录 `socks5m stats` 的输出。
- 需要系统可用 `iptables` 命令（nftables 系统可通过 `iptables-nft` 兼容）。若不可用，统计功能会被跳过，其他功能不受影响。

## 注意事项

1. **云服务器**：阿里云、腾讯云、AWS 等需在安全组中手动放行对应端口，脚本只能处理系统本机防火墙。
2. **仅支持 TCP**：microsocks 不支持 UDP。
3. **无流量限制**：当前版本不支持按用户限速或超额自动禁用。
4. **用户名与密码限制**：
   - 用户名：字母、数字及 `_.-`，1–32 位
   - 密码：字母、数字及 `_.@%+=-`，6–64 位
   - 限制字符是为了避免配置解析出错。
5. **明文密码**：用户数据库以明文保存密码，请注意 `/etc/socks5m/` 目录的访问权限（脚本已设为 700）。
6. **卸载会删除所有用户**，操作前请先备份连接信息。

## 常见问题

**服务启动失败？**
执行 `journalctl -u socks5m@<端口> -n 50` 查看日志，并确认端口未被其他程序占用。

**客户端无法连接？**
依次检查：云安全组是否放行、系统防火墙（`ufw status` 或 `firewall-cmd --list-ports`）是否放行、`socks5m list` 中状态是否为 `active`。

**统计全部为 0？**
确认服务正在运行，并且系统中存在 `iptables` 命令。服务重启后计数会从零开始。

## 许可

本脚本仅供学习和个人管理使用。使用者需遵守所在地区的法律法规及服务商的使用条款。

# DNS 切换面板 · 飞牛 fnOS 应用包

把 `dashboard/` 里的 `cfdash.py` + `index.html` 打成飞牛私有云（fnOS）可安装的原生应用，桌面点开就是一个面板。

- 应用名：`cfdns`，显示名「DNS 切换面板」
- 类型：`native`（不依赖 Docker，只用 NAS 自带的 `python3`）
- 入口：走飞牛统一网关 `/app/cfdns/`，**不占端口**，外网经 FN Connect 也能打开
- 产物：`dist/cfdns-1.0.0.fpk`（约 34 KB）
- 开发者 / 发布者：Linus（<https://github.com/jhonlinus/cf-dns-failover>）

## 安装

1. 把 `.fpk` 传到 NAS（任意目录）
2. 桌面 →「应用中心」→ 右上角「设置」→「手动安装应用」→ 选文件
3. 安装完成后桌面出现「DNS 切换面板」，点开直接在桌面内打开

装完后应用在：

```
/vol1/@appcenter/cfdns/        # 程序（server/ 下是 cfdash.py 与 index.html）
/vol1/@appdata/cfdns/          # 运行时目录，日志 cfdns.log 在这里
/var/apps/cfdns                # 指向 @appcenter 的软链
```

面板**只读**系统上已有的 cf-failover：`/etc/cf-failover/config`、`/var/log/cf-failover.log`、`/var/tmp/cf-failover/`，或 1Panel 计划任务里那份内联脚本。所以要先装好 cf-failover，面板才有数据可看。

## 为什么是 root

`config/privilege` 里是 `run-as: root`：

- `/etc/cf-failover/config` 权限是 `600`，里面是 Cloudflare token
- 「立即检测」要执行 `cf-failover`（读配置、写 `/var/log`、写 `/var/tmp` 状态文件）

`username` / `groupname` 填的是 `cfdns`。这两个字段是安装器用来创建系统用户的，**不能写 `root`** —— 写 `root` 会触发 `useradd root`，安装直接失败（`APP_INSTALL_FAILED_USER_ALREADY_EXISTS`）。

不想给 root：把 `run-as` 改成 `package`，同时在 `cmd/main` 的启动命令后面加 `--no-run`，面板就只剩查看功能。

## 打包

```bash
# 在仓库根目录
python3 /path/to/fnos-fpk/scripts/make_icons.py fnos --glyph swap
python3 /path/to/fnos-fpk/scripts/fpk_pack.py fnos -o fnos/dist/cfdns-1.0.0.fpk
```

`fpk_pack.py` 会校验：manifest 必须是 CRLF、`cmd/*` 必须是 LF 且有执行位、`config/privilege` 的 `username` 不能是 root、`ui/config` 必须是 Socket 型网关。任何一项不通过都不会出包。

改了 `dashboard/` 的代码记得同步：

```bash
cp dashboard/cfdash.py dashboard/index.html fnos/app/server/
```

## 三种入口写法（踩过的坑）

飞牛的 `app/ui/config` 有三种写法，只有第三种会生成 `/app/<name>/` 路径：

| 写法 | 桌面打开的效果 | 外网 |
|---|---|---|
| `type: "url"` + `url: "http://ip:port"` | 跳到 IP:端口 | 打不开 |
| `type: "iframe"` + `service_port` + `url` | 桌面内嵌 IP:端口 | 打不开 |
| `type: "iframe"` + `gatewaySocket` + `gatewayPrefix` | 桌面内嵌 `/app/cfdns/` | 能打开 |

本项目用的是第三种。应用侧要做两件事：

1. 在 `$TRIM_APPDEST/app.sock` 上监听 HTTP（`cfdash.py --sock`）
2. 服务端剥离 `/app/cfdns` 前缀（`cfdash.py` 里的 `_strip_prefix`）

改完 `ui/config` 要重启一次网关：

```bash
systemctl restart trim_app_center trim_http_cgi
```

## 排错

```bash
# 应用起来没有
cat /vol1/@appdata/cfdns/cfdns.log

# 进程在不在
ps -ef | grep cfdash

# 直接打 socket，绕过飞牛网关
curl -s -o /dev/null -w '%{http_code}\n' \
  --unix-socket /vol1/@appcenter/cfdns/app.sock http://localhost/app/cfdns/

# 手动起停
TRIM_APPDEST=/vol1/@appcenter/cfdns \
TRIM_PKGVAR=/vol1/@appdata/cfdns \
TRIM_APPETC=/vol1/@appconf/cfdns \
bash /vol1/@appcenter/cfdns/cmd/main restart
```

`sock=000` 通常是应用没起来或者 `app.sock` 残留：删掉 `$TRIM_APPDEST/app.sock` 再 `restart`。

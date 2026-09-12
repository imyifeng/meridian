# 服务器 Compose 部署（Trial Build）

把 Meridian 服务端在本机用 docker compose 跑起来。产物不对对外分发——
这是试用构建（Trial Build），数据只属于你自己的实例。

## 前置

- Linux 主机，装好 Docker Engine 与 compose v2 插件（`docker-compose-plugin`
  包）。装好后 `docker compose version` 应能跑通。

## 一条命令构建并启动

在仓库根目录：

```sh
docker compose up -d --build
```

这一条命令会从源码完成全部构建并启动：

1. 在容器里用仓库开发所用的 Flutter 3.47.2 稳定版构建 Web 管理控制台
   与 Web 简易客户端两个 SPA；
2. 编译静态 Go 二进制，并把两个 SPA 内嵌进去；
3. 打出运行镜像 `meridian:trial` 并启动容器。

服务只监听高位端口 8080（宿主机 8080 → 容器 8080）；HTTPS 由前置反代负
责，实例本身不做 TLS。首次启动进入 Setup Wizard（见下）。

首次构建要下载 Flutter 工具链与依赖，需要几分钟；之后由 Docker 层缓存加
速。要强制走完整构建，加 `--no-cache`。

## 数据持久化

备忘录数据（SQLite）放在命名卷 `meridian-data` 里，挂载到容器的 `/data`。

```sh
docker compose down      # 停掉并删除容器，卷保留
docker compose up -d     # 重建容器，数据原样还在
```

只有 `docker compose down -v`（显式删卷）才会清掉数据——平时升级镜像重
建容器不会丢数据。

## 验证初始化向导可用

```sh
curl http://127.0.0.1:8080/api/v1/instance
# {"initialized":false}   ← 未初始化
```

浏览器打开 `http://<主机IP>:8080/web/` 走初始化向导创建首个管理员
（向导只在主应用里；`/console/` 的 Web 管理控制台只有登录）。之后
`initialized` 变为 `true`，普通用户在同一入口登录 Web 简易客户端，
管理员在 `http://<主机IP>:8080/console/` 登录 Web 管理控制台，
Windows/Android 客户端填 `http://<主机IP>:8080`。

## 停止与清理

```sh
docker compose down      # 停止（保留数据卷）
docker compose down -v   # 停止并删除数据卷（慎用）
```

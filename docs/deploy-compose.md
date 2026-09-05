# 服务器 Compose 部署（Trial Build）

把 Meridian 服务端在本机用 podman compose 跑起来。只要求 podman compose
可用，不承诺 Docker 兼容。产物不对对外分发——这是试用构建（Trial Build），
数据只属于你自己的实例。

## 前置

- Linux 主机，装好 `podman`（本手册验证于 podman 5.x）
- compose 提供者：`podman-compose`（`pip install --user podman-compose`）
  或 `docker-compose` 二者其一。装好后 `podman compose version` 应能跑通

## 一条命令构建并启动

在仓库根目录：

```sh
podman compose up -d --build
```

这一条命令会从源码完成全部构建并启动：

1. 在容器里用与 `client/pubspec.lock` 匹配的 Flutter 3.47.2 稳定版构建
   Web 管理控制台与 Web 简易客户端两个 SPA；
2. 编译静态 Go 二进制，并把两个 SPA 内嵌进去；
3. 打出运行镜像 `localhost/meridian:trial` 并启动容器。

服务只监听高位端口 8080（宿主机 8080 → 容器 8080）；HTTPS 由前置反代负
责，实例本身不做 TLS。首次启动进入 Setup Wizard（见下）。

首次构建要下载 Flutter 工具链与依赖，需要几分钟；之后由 podman 层缓存加
速。要强制走完整构建，加 `--no-cache`。

## 数据持久化

备忘录数据（SQLite）放在命名卷 `meridian-data` 里，挂载到容器的 `/data`。

```sh
podman compose down      # 停掉并删除容器，卷保留
podman compose up -d     # 重建容器，数据原样还在
```

只有 `podman compose down -v`（显式删卷）才会清掉数据——平时升级镜像重
建容器不会丢数据。

## 验证初始化向导可用

```sh
curl http://127.0.0.1:8080/api/v1/instance
# {"initialized":false}   ← 未初始化
```

浏览器打开 `http://<主机IP>:8080/console/` 走初始化向导创建首个管理员；
之后 `initialized` 变为 `true`，普通用户在 `http://<主机IP>:8080/web/`
登录 Web 简易客户端，Windows/Android 客户端填 `http://<主机IP>:8080`。

## 停止与清理

```sh
podman compose down      # 停止（保留数据卷）
podman compose down -v   # 停止并删除数据卷（慎用）
```

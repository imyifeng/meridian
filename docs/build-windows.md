# Windows 客户端编译手册（Trial Build）

在 Windows 上从源码编译出 Meridian 的 exe。手册只管到编译产物，不含分发
与连接配置——产物装在自己电脑上试用，不对对外发布。

## 工具链前置

1. **Flutter SDK**
   - 到 <https://docs.flutter.dev/get-started/install/windows> 下载
     Flutter stable 版（本仓库用 3.x 稳定版，要求 Dart SDK
     ^3.13.2，任意满足该约束的新版 stable 均可）
   - 解压到不含空格与中文的路径，例如 `C:\dev\flutter`
   - 把 `C:\dev\flutter\bin` 加入 `PATH`（系统设置 → 环境变量）
2. **Visual Studio C++ 工具链**（编译 Windows 桌面 runner 用，不需要装整
   个 Visual Studio IDE）
   - 到 <https://visualstudio.microsoft.com/zh-hans/downloads/> 下载
     **Visual Studio 2022 Community**（或仅 Build Tools）
   - 安装时勾选工作负载 **"使用 C++ 的桌面开发"**（Desktop development
     with C++），保持默认勾选项（含 MSVC、Windows SDK、CMake）
3. 验证：开一个 PowerShell 或 CMD：

   ```sh
   flutter doctor
   ```

   `[√] Flutter` 与 `[√] Visual Studio - develop Windows apps` 两行都打
   勾即可。首次运行 `flutter` 会自动下载 Dart SDK，等它跑完。

## 获取源码并编译

```sh
git clone https://github.com/imyifeng/meridian.git
cd meridian\client
flutter pub get
flutter build windows --release
```

> `client` 目录里的 Flutter Web 产物（服务端要内嵌的 Web 管理控制台与
> Web 简易客户端）不需要在 Windows 上构建——那只影响服务端二进制，与
> Windows 客户端无关。

## 编译产物

在 `build\windows\x64\runner\Release\` 下：

- `Meridian.exe` —— 主程序（exe 文件属性的 ProductName 也是 Meridian）
- 同目录的 `data\`、若干 DLL —— 必须和 exe 在一起，整个 `Release` 目录
  是完整应用，别单独拷走 exe

双击 `Meridian.exe` 运行，窗口标题为 Meridian。

## 试用连接

启动服务端（见 [deploy-compose.md](deploy-compose.md)）后，首次进入应用
时填服务器地址（局域网内 `http://<主机IP>:8080`）登录。地址会记住，下次
启动自动带出。

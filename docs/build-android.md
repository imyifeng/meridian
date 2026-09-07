# Android 客户端构建（Trial Build）

在本机 Linux 上从源码构建 debug 签名的 Meridian Android APK。产物装在自
己的设备上试用，不对对外发布。

## 前置工具链

1. **Flutter SDK**：本仓库用 Flutter 3.x 稳定版（依赖要求 Dart SDK
   ^3.13.2，见 `client/pubspec.yaml`）。装到任意路径，例如
   `~/development/flutter`，并把 `bin` 加进 `PATH`。
2. **JDK**：17 及以上（Android Gradle Plugin 需要）。本机验证于 OpenJDK
   21（`sudo dnf install java-21-openjdk` 或任意等价安装）。

## 安装 Android SDK（cmdline-tools 方式，无需 Android Studio）

```sh
# 1. 目录约定：SDK 放在 ~/Android/Sdk
mkdir -p ~/Android/Sdk/cmdline-tools

# 2. 下载最新 commandline-tools（版本号会更新，取 repository XML 里的最大值）
cd ~/Android/Sdk/cmdline-tools
curl -fsSL -o cmdtools.zip \
  https://dl.google.com/android/repository/commandlinetools-linux-16111833_latest.zip
unzip cmdtools.zip && mv cmdline-tools latest && rm cmdtools.zip

# 3. 接受 licenses 并安装基础包（平台 37 为依赖插件所需，
#    新版 cmdline-tools 里叫 android-37.0）
export ANDROID_HOME=~/Android/Sdk
yes | $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --licenses
$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager \
  "platform-tools" "platforms;android-36" "platforms;android-37.0" \
  "build-tools;36.0.0"

# 4. 告诉 Flutter SDK 在哪，并确认工具链就绪
flutter config --android-sdk ~/Android/Sdk
flutter doctor
```

> 注：新版 cmdline-tools 的 `flutter doctor` 可能仍显示
> “Android license status unknown”，这是它对新版输出格式的解析问题；
> 只要第 3 步执行过、`~/Android/Sdk/licenses/` 里有 license 文件，构建
> 不受影响。

## 构建 debug 签名 APK

```sh
cd client
flutter build apk --debug
```

产物在 `client/build/app/outputs/flutter-apk/app-debug.apk`，用 debug
keystore 签名（构建时自动生成），直接可装。

## 安装到设备

- USB 调试：开启开发者选项后 `adb install build/app/outputs/flutter-apk/app-debug.apk`
- 或把 APK 拷到手机上点击安装（允许未知来源）

## 试用连接

启动服务端（见 [deploy-compose.md](deploy-compose.md)），手机与主机在同一
局域网。首次进入应用会直接落在登录页（编译期默认地址指向手机自身，探测
不可达时不再卡死）：在「服务器地址」框填 `http://<主机IP>:8080`，输入账
号密码即可登录，无需构建时用 `--dart-define=MERIDIAN_SERVER` 预置地址。
地址会记住，下次启动自动带出。

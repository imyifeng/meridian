# 所有前端（Windows、Android、Web）用同一套 Flutter 代码

需求要求 Windows 与 Android 客户端一次开发、两端部署，此外还有 Web 管理控制台与简易客户端。考虑过 React Native（原可与 TS 服务端共享类型，但服务端已定 Go，共享论点消失，且 react-native-windows 成熟度明显偏弱）、Kotlin/Compose Multiplatform（Windows 桌面生态较新）、.NET MAUI（跨端一致性与生态一般）。决定所有前端统一 Flutter：Windows 与 Android 共享同一套应用代码，Web 控制台与简易客户端用 Flutter Web，由 Go 服务端托管静态文件。接受的代价：Flutter Web 首次加载偏重——控制台与定位为"临时使用"的简易客户端对该项不敏感。

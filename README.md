# ChargeLmt

简体中文 | [English](README_en.md)  

ChargeLmt 是一个菜单栏 macOS 应用，用于设置电池充电上限和下限，并提供一次性充满、放电到上限、登录自启动和 Sparkle 自动更新。  
造这个轮子是因为[Battery-Toolkit](https://github.com/mhaeuser/Battery-Toolkit)停止更新了，在macos 15后面更新的版本无法正常使用，而AlDente收费又臃肿，我很不喜欢。  

## 适用

装有 `macOS Tahoe 26.4` 及以上版本系统的 `搭载 Apple 芯片的 Mac` 支持自定义 MacBook 充电上限，所以本软件只适合装有低版本MacOS或使用x86结构CPU的Mac使用。  
官方说明：[关于 Mac 的“优化电池充电”和“充电上限”](https://support.apple.com/zh-cn/102338)  

## 实现方式

- 本体是菜单栏应用，自动更新使用 Sparkle。  
- 登录启动由独立 helper 完成。  
- 充电控制由 privileged helper 写 SMC 完成，按机型选择 Legacy Intel、Golden Gate Apple Silicon、Tahoe 等后端。  
- 电量区间控制是应用层迟滞状态机：刚启动或插上适配器时，若电量在区间内则写入下限不充电；电量低于下限时写入上限开始充电，直至达到上限；达到上限后写入下限停止充电，避免反复小区间充电（航海模式），等电量自然降到下限后再恢复充电。  

本项目在 Apple Silicon 上优先使用 Golden Gate `bfD0`/`bfE0`/`bfF0` 阈值键，旧 Apple Silicon 回退到 `CHTE`/`CH0C`/`CH0B`；Intel 优先使用 `CH0B`/`CH0C` 充电开关，旧机型回退到 `BCLM`/`BFCL`。对于支持硬件电量阈值的机型（如 Intel BCLM 或 Golden Gate），低于下限时向控制器写入上限启动充电，充至上限后立即写回下限停止充电；对于开关型机型则在低于下限时接通开关，达到上限时切断开关。`CHIE`/`CH0J` 用于临时关闭适配器输出以放电；没有这些键的机型会显示不支持强制放电。充电或放电期间持有 idle-sleep assertion，避免睡眠后系统绕过阈值控制。  

Golden Gate 写入顺序为：`bfF0=0`、`bfD0=上限<<24`、`bfE0=(上限-1)<<24`、`bfF0=2`。低于下限开始充电时写入用户上限，达到上限后写入用户下限避免反复小区间充电。Xcode Debug 构建使用本机 legacy daemon 以避开开发签名 profile 限制；正式分发使用 SMAppService。  

## 构建

```bash
xcodebuild -project ChargeLmt.xcodeproj -scheme ChargeLmt -configuration Release build
```

Sparkle 通过 Swift Package Manager 引用并锁定在 `Package.resolved`，不需要提交二进制框架。首次构建会自动解析依赖。构建后可在设置窗口安装 root daemon；macOS 会在系统设置中要求批准。  

## 自动更新发布配置

发布前通过构建设置配置 `SPARKLE_FEED_URL` 和 `SPARKLE_PUBLIC_ED_KEY`；`Support/App-Info.plist` 中的 `SUFeedURL`、`SUPublicEDKey` 会在构建时展开。自动检查和自动安装由 Sparkle 完成。  
  
可使用 Sparkle 官方发行包中的 `bin/generate_keys --account chargelmt` 生成 EdDSA 密钥；`Scripts/release.sh` 会调用 `generate_appcast --account chargelmt` 生成签名。  
本项目默认打 universal 包，一个 appcast 指向 universal zip 即可；如果后续拆分 arm64/x86_64 包，需按架构分别提供 appcast 与下载地址。  

## 安全说明

正式分发前应使用稳定的 Developer ID 签名并公证。root daemon 只暴露阈值与模式命令，不提供任意命令执行接口；发布版还可以进一步按团队 ID 和 bundle ID 校验 XPC 客户端。  

## 致谢

SMC 用户态调用结构和 Apple Silicon 电源键参考了 Marvin Häuser 的 [Battery Toolkit](https://github.com/mhaeuser/Battery-Toolkit)（BSD-3-Clause）。Intel `BCLM`/`BFCL` 行为参考了 Zack Elia 的 [bclm](https://github.com/zachelia/bclm)（MIT）。自动更新使用 [Sparkle](https://github.com/sparkle-project/Sparkle)（MIT）。各组件的完整许可证文本见对应上游仓库。本项目自身使用 MIT，见 `LICENSE`。  

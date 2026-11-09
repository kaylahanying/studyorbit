# Study Executive Assistant

Internal codename: **StudyOrbit**. Package names, bundle identifiers, storage keys,
and repository names retain `studyorbit`.

## On-device task understanding

On supported iPhones running iOS 26 or later, Apple Intelligence uses the native
Foundation Models framework to interpret a paragraph and draft separate study
tasks, including subjects, due dates, estimated durations, and steps. Large
assignments can be broken into stages. Completed voice transcription and photo
OCR automatically begin task drafting when the model is available. Typed input
uses **Create task drafts**. Review and edit drafts before confirming them.

Apple Intelligence must be enabled and its model downloaded. Availability is
checked on the device; no API key, server, or cloud inference is used. Other
devices retain explicitly labeled basic splitting (one task per line). Model
failure preserves the original input and offers a manual basic fallback.
The minimum deployment target stays iOS 15.5; Foundation Models is weak-linked
and runtime-gated behind iOS 26 availability. Inputs are limited to 3,000
characters and model output to 15 tasks per request. Dates and durations are
validated before any drafts are displayed; model estimates still need review.

面向高中生的 Flutter 学习计划 MVP。英文界面，支持 Android、iOS，以及用于演示文字录入流程的 Web 版本。由用户提供的《StudyOrbit 手机 App 商业计划（精简版）》实现。

## 运行

开发和验证环境：Flutter **3.47.9 stable** / Dart **3.13.7**。

```sh
flutter pub get
flutter run -d chrome        # 浏览器预览
flutter run                 # 连接 Android / iOS 设备
```

本次开发下载的 SDK 位于 `/tmp/studyorbit-flutter`，可临时使用 `/tmp/studyorbit-flutter/bin/flutter`；`/tmp` 可能被系统清理，长期开发请自行安装 Flutter 并加入 PATH。

已编译的 Web 预览位于 `build/web`。可运行：

```sh
python3 -m http.server 8080 --bind 127.0.0.1 --directory build/web
```

然后访问 http://127.0.0.1:8080 。Web 版的拍照 OCR 和语音入口会明确提示需要手机，不会生成伪造识别结果。浏览器会按当前 origin 分开保存数据。

界面截图：[手机](docs/preview-mobile.png) · [桌面](docs/preview-desktop.png)

## 已实现

- 文字批量录入、设备端拍照 OCR（中英文）、设备端英文语音输入。
- 录入 → 草稿提取 → 学生确认/编辑 → 添加任务；保留照片预览用于核对。
- 科目、任务类型、截止日期、预计用时、难度、薄弱科目标记及可编辑步骤。
- 16:00–21:00 自动排程：截止日期、薄弱科目、难度、明日课程和预计用时参与评分。
- 最长 45 分钟连续学习、10 分钟短休息、18:00–18:30 晚餐、20:40–21:00 休闲。
- 长任务分段；容量不足时明确显示剩余未安排分钟；手动从当前时间重新排程。
- 完成、重新打开、延后、编辑、删除任务；日历按截止日显示任务。
- 专注倒计时、暂停/继续、5 分钟休息、本次步骤清单、累计用时和操作历史。
- 选择明日课程并生成准备清单，预习/复习任务清单。
- 本地持久化、照片副本清理、历史清理、全部数据删除和异常读取保护。
- 手机底部导航、宽屏侧栏，首启为空数据；可主动加载示例任务。

## 手机配置

### Android

- 应用最低 Android 7.0 / API 24；需要 Android SDK、Java 17+ 和 Flutter 支持的构建环境。
- **设备端语音要求 Android 12 / API 31+** 且设备报告支持 `createOnDeviceSpeechRecognizer`，并已具备英文离线模型。低版本和无模型设备不会回退云端。
- 麦克风权限在首次语音录入时请求。拍照使用系统相机/图片选择器。
- 中文 ML Kit 模型依赖已加入 `android/app/build.gradle.kts`。
- 发行签名仍为 Flutter 模板的开发签名，发布前需配置正式签名。

### iOS

- 最低 iOS **15.5**，需要完整 Xcode 和 CocoaPods。
- 已配置相机、相册、麦克风和语音权限说明；中文 ML Kit 依赖位于 `ios/Podfile`。
- 语音仅在 `supportsOnDeviceRecognition == true` 时启动，并强制 `requiresOnDeviceRecognition = true`。
- 第一次构建可执行 `flutter pub get`，在 `ios` 目录执行 `pod install`，用 Xcode 打开 `Runner.xcworkspace` 配置开发团队。
- iOS 发行包已通过 Codemagic 构建并上传 TestFlight；尚未验证真机相机/麦克风/OCR/原生语音通道。

## 隐私与当前边界

没有账号、后端或应用内网络上传接口。任务与记录使用 `SharedPreferencesAsync` 保存，**没有应用层加密**；这是轻量原型存储，不能当作关键数据数据库。生产版本应迁移事务数据库、添加加密备份和恢复。

照片使用系统图片选择器生成的临时副本，默认在识别尝试结束后删除；可选择保留并在“我的”页面清理。原始相册文件不受影响。预览、转录和未确认草稿仅在当前录入页面内存中；语音不保存录音文件。确认后任务名称可能包含学生录入的原文，可单独删除任务或清空全部数据。系统层面的设备备份策略需要在正式发布前继续审核（Android 已关闭自动备份）。

支持的 iPhone 使用 Apple Intelligence 本地大语言模型理解输入和拆分任务，详情见上方说明。其他设备可使用明确标注的基础规则：每行一个任务，默认截止日期为明天，用时为 30 分钟；支持 today、tomorrow、the day after tomorrow、月/日以及 minutes（兼容中文文字录入）。排程仍为本地规则。所有生成草稿都需要学生确认；基础规则不得称为 AI 理解。

专注页面离开前台时自动暂停并保存；提醒只在专注页面打开时显示，**没有后台通知**。日历当前展示任务/考试的截止日期，没有重复课程编辑或外部学校平台同步。明日科目为学生自行更新的准备偏好，不是完整周期课表。没有订阅扣费、家庭账户、任务时间锁定、云端同步、长期学习分析或加密备份。不会显示伪造付费成功或 AI 结果。

## 验证

```sh
flutter analyze
flutter test
flutter build web
```

测试覆盖排程边界、晚餐与休闲、任务拆分和容量守恒、截止日期与薄弱科目优先级、明日科目、完成/延后、用时扣减、晚餐中途重排、21:00 后溢出、批量草稿唯一 ID、手机录入与确认、日历导航、宽屏布局、本地恢复/删除和损坏数据保护。

## 代码

- `lib/domain/`：任务模型、草稿提取、独立排程逻辑。
- `lib/services/`：本地持久化与照片清理。
- `lib/app.dart`：导航、仪表盘、任务、日历、设置、录入和专注页面。
- `android/.../MainActivity.kt`、`ios/Runner/AppDelegate.swift`：严格设备端语音通道。
- `test/`：排程与应用交互测试。

依赖和平台能力依据：[Flutter 本地存储](https://docs.flutter.dev/cookbook/persistence/key-value)、[ML Kit Flutter OCR](https://pub.dev/packages/google_mlkit_text_recognition)、[image_picker](https://pub.dev/packages/image_picker)、[Android SpeechRecognizer](https://developer.android.com/reference/android/speech/SpeechRecognizer)、[Apple Speech](https://developer.apple.com/documentation/speech)。

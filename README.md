# Study Executive Assistant

Internal codename: **StudyOrbit**. Flutter 学习规划应用；保留当前界面与手机 OCR / 离线语音，接入托管 AI、加密本地数据和密码备份。Schoology 自动同步、账号云同步及订阅不在本次范围内。

## 架构与职责

- Flutter 界面通过 `StudyController` 修改状态；持久化成功后才发布新状态，失败不能伪装成已保存。
- AI 服务负责理解文字、提出任务草稿、分析批改反馈、建议优先级及依赖。任务与建议必须经学生确认，模型不能直接分配钟点时间块。
- 本地确定性引擎执行 16:00–21:00、18:00–18:30 晚餐、20:40–21:00 自由时间和最长 45 分钟连续学习的限制。
- Node 同源 API 保存服务端模型凭据、提示词和会话/配额元数据，不保存学习资料或模型回答。
- 旧 Apple Intelligence 专用通道已退出。托管 AI 不再要求 iOS 26 或学生自行填写 API key；原生 OCR 与离线语音仍在设备上执行。

## 本地运行完整体验

工具链：Flutter **3.47.9** / Dart **3.13.7**；Node **26.5.0**（使用内置 `node:sqlite`）。依赖解析版本记录在 `pubspec.lock`。

```sh
flutter pub get
cp .env.example .env
# 编辑 .env：配置允许运营方托管使用的模型 key、base URL 和 model。
flutter build web --release --no-web-resources-cdn
STUDYORBIT_PORT=3214 node --env-file-if-exists=.env server/index.mjs
```

访问 http://127.0.0.1:3214 。`.env` 必须保留在本机，不能提交。模型密钥不能通过 `--dart-define` 打进应用。

**不要用静态 Python 服务器替代 Node 来测试完整 AI 体验**：静态服务器没有 `/api/session` 与 `/api/ai`。Web 的模型请求与页面必须同源；本地存储需要 HTTPS 或 loopback 安全上下文。`--no-web-resources-cdn` 让 Flutter 渲染资源由本应用提供。

原生开发连接设备后运行：

```sh
flutter run --dart-define=STUDYORBIT_API_ORIGIN=https://your-pilot.example
```

这是公开的 API origin，不是模型供应商地址或秘密。手机无法通过自己的 `127.0.0.1` 访问开发电脑。对外手机测试需先部署 HTTPS 服务；未配置服务或模型失败时必须明确报错，不能展示假的 AI 成功。

## 学习流程

1. 输入文字，或在支持的手机上拍照 OCR / 离线语音转录。
2. 检查文字；明确同意后才发送文字及必要学习上下文给服务器与模型供应商。照片和录音不随模型请求上传。
3. 检查草稿、原文依据、截止日期、估时与步骤，再确认加入任务。未知截止日保持未知，不默认变成明天；题号范围不能当日期。
4. 批改反馈可单独保存为证据，不强行变成新作业。后续复习建议必须有原文或学生明确提供的背景依据。
5. 选择 AI 规划或明确选择本地规划；模型建议仍是待审阅草稿，不能阻断已有计划的执行。
6. 专注记录实际未暂停秒数；完成作业是独立操作。时间达到原估算但尚未完成时，应补充剩余工作量，而不是从计划中悄悄消失。

明日科目绑定具体日期。旧版无日期的科目会保留供重新确认，但不能自动当作当前明天的课程。用户仍需手动维护课程，这不是同步课表。

## 隐私、迁移与备份

- 任务、草稿、文字证据、历史与实际专注记录保存在本机的 Hive 加密库；内容采用 **AES-256-GCM**，随机库密钥单独放在平台安全存储。
- 升级会先验证旧 `SharedPreferencesAsync` 的 `studyorbit.v1` 数据，成功写入加密库后才清除旧数据。损坏、解密或写入失败不能自动改成空库。
- 浏览器安全仍依赖 origin 和用户配置文件；同源恶意代码、共享设备或清除站点数据仍可能暴露或移除访问。这里不声称浏览器拥有安全硬件隔离。
- 便携备份采用 **PBKDF2-HMAC-SHA256（600,000 次）+ AES-256-GCM**，每次生成新盐和 nonce，密码至少 12 个字符且无法找回。
- 导入先解密与验证，再展示记录数量，明确确认后才替换；取消不修改当前数据，失败不得覆盖原库。
- 备份不包含服务端凭据、会话 cookie、原始照片或录音。保留的设备照片文件不是跨设备备份；原始相册文件不受应用删除影响。
- 清理历史不清零累计实际用时；删除全部本地数据也会尝试结束 AI 会话。离线时本地删除仍应完成，重新联网后需确认邀请会话是否已结束。
- 用户录入的学习文字可能含个人信息。发送前应去除不需要的身份信息，并遵守供应商保留政策及学生/未成年人数据要求。

## 封闭测试服务部署

服务只监听 loopback；生产环境由同机 HTTPS 反向代理转发并保留公共 `Host`。页面与 API 使用同一 origin。生产环境必须配置：

```dotenv
STUDYORBIT_MODE=production
STUDYORBIT_PORT=8787
STUDYORBIT_ORIGIN=https://your-pilot.example
STUDYORBIT_SESSION_SECRET=<32-or-more-random-characters>
STUDYORBIT_INVITE_CODE=<12-or-more-random-characters>
STUDYORBIT_API_KEY=<operator-provider-key>
STUDYORBIT_BASE_URL=https://your-provider.example/v1
STUDYORBIT_MODEL=<structured-JSON-capable-model>
STUDYORBIT_DATABASE=/var/lib/studyorbit/studyorbit.sqlite
```

配置文件放在源码和 `build/web` 之外，数据库目录仅服务用户可读写，并使用持久磁盘。每个数据库运行一个应用实例；不能把配额数据库放在会随部署消失的临时文件系统里。

会话使用 HttpOnly / SameSite=Strict cookie；生产环境加 Secure。API 执行 Origin、CSRF、明确同意、文本大小及精确结构校验。会话与全局日配额、并发预留跨重启保留；已派发但失败的模型请求也计入额度，因为上游可能已经计费。邀请只是 AI 访问权限，不是云账号。

**必须使用允许面向终端用户托管的正式模型服务。** 以前本机开发可用的 coding-plan 凭据不能直接视作具备产品托管授权。这里没有部署公网服务，也没有替运营方接受供应商条款。

## 手机能力与发布边界

- Android：最低 API 24；离线语音要求 API 31+、设备支持 on-device recognizer 且英文模型已安装。不回退云端语音。
- iOS：最低 15.5；语音强制 on-device recognition。需要完整且兼容的 Xcode、CocoaPods、签名和真机权限验证。
- Web：可以使用托管 AI 与文字流程；原生相机 OCR、离线语音入口必须说明需要手机，不生成伪造识别结果。
- 当前原生 OCR 使用 Latin 脚本，离线语音使用 `en-US`；支持中文文字显示不代表已经支持中文 OCR 或中文离线语音。
- 专注离开前台时暂停与保存；没有新增后台系统通知保证。
- 这次迁移版本不因为旧版本曾上传 TestFlight 就自动视作已经通过 iOS 发布验收。
- Codemagic 构建原生包前要求 `STUDYORBIT_API_ORIGIN` 为 HTTPS，并将其作为公开配置传入 Flutter；详见 [iOS 构建说明](docs/codemagic-ios.md)。
- Android 当前仍使用模板 debug release 签名，正式发行前必须由所有者配置正式签名。
- 没有 Schoology 自动同步、账号云同步、订阅扣费或家庭账户。

## 验证命令

```sh
flutter analyze
flutter test
node --test server/security.test.mjs
flutter build web --release --no-web-resources-cdn
```

实际运行结果应与编译、浏览器交互、真实模型请求和原生真机验证分开记录；不能用 mocked 模型测试证明真实模型质量。

### 本次集成实际验收

- Dart 分析与领域、AI、仓库、控制器回归已通过；修复集成问题后，10 项组件交互与 4 项离线语音交互测试分组通过。Web release 已构建。
- Node 14 项安全回归通过。iOS plist / Xcode 工程语法及 Android 权限配置已检查，不能据此声称原生构建或真机通过。
- 真实 GLM 调用仅使用虚构资料：提取两项作业，区分明确截止时刻与未知截止日；基于批改评语、日期课程和实际专注记录生成带原文引用的可选复习草稿。
- 首次真实规划返回了虚构的草稿依赖，被客户端拒绝，原计划未变；强化服务端提示词后，真实规划通过，未放宽 ID 或证据校验。
- 浏览器拒绝同意后没有 AI 请求，单独保存反馈也没有新增 AI 请求；真实记录并保存了 10 秒未暂停专注时间。
- 实际下载并导入密码备份：错误密码不修改资料；预览取消保留备份后的 50 分钟剩余工作量，确认替换恢复为备份中的 35 分钟，并保留反馈、待审草稿及实际专注记录。刷新后资料仍在。
- 已观察 375 像素窄屏、减少动态效果设置和中文正文渲染；中文字体由同源提供。尚未进行原生相机 / 麦克风权限、签名包、TestFlight 或公网生产验收。

## 代码

- `lib/app.dart`、`lib/ui/`：现有界面与同意、审阅、服务访问、备份交互。
- `lib/services/study_controller.dart`：串行业务变更与提交后通知。
- `lib/services/study_ai.dart`、`hosted_ai*.dart`：结构化模型结果校验与托管传输。
- `lib/domain/`：任务、来源证据、日期语义与确定性排程。
- `lib/data/`：加密仓库、旧数据迁移和密码备份。
- `server/`：同源服务、提示词、模型适配和 SQLite 会话/配额。
- `android/.../MainActivity.kt`、`ios/Runner/AppDelegate.swift`：严格设备端语音。
- `test/`：领域、迁移/恢复、AI 边界与实际界面行为回归。

## 字体资源

中文回退使用随包提供的 [Noto Sans SC Regular（Google Fonts v41）](https://fonts.gstatic.com/s/notosanssc/v41/k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_Fra5HaA.ttf)，约 2.5 MB；[SIL Open Font License 1.1](assets/fonts/OFL.txt) 同样随包提供。没有为外部字体放宽服务器 CSP。

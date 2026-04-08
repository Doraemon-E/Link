# Link Demo

## 启动客户端

### 1. 准备环境

首次启动前请先确认本机具备：

- Xcode
- CocoaPods
- 可用的网络连接（App 首次下载模型时需要）
- 支持ios26

如果本机还没有安装 CocoaPods，可以先执行：

```bash
sudo gem install cocoapods
```

### 2. 安装 iOS 依赖

在客户端目录执行：

```bash
cd Link
pod install
```

项目仓库里已经包含 `Pods/`，但第一次拉代码后仍建议执行一次 `pod install`，确保 workspace、Podfile.lock 和本地 CocoaPods 环境一致。

### 3. 用 Xcode 打开工程

请打开 workspace，而不是直接打开 `xcodeproj`：

```text
Link/link.xcworkspace
```

然后在 Xcode 中：

1. 选择 `link` scheme
2. 选择一个 iPhone 模拟器或真机
3. 点击 Run

### 4. 首次运行说明

App 首次启动时会：

- 读取内置的 `translation-catalog.json` 和 `speech-catalog.json`
- 后台尝试刷新远端 catalog
- 在你首次使用某个翻译方向或语音识别功能时，按需下载对应模型包

首次体验语音功能时，系统会申请麦克风权限。

### 5. 常见问题

如果 Xcode 编译时报错提示 Pod sandbox 不一致：

```text
The sandbox is not in sync with the Podfile.lock
```

重新执行下面命令即可：

```bash
cd Link
pod install
```

如果 App 能启动但翻译/语音功能不可用，请优先检查：

- 当前网络是否能访问模型下载地址
- 是否已授予麦克风权限
- 是否已经在下载页完成对应模型安装

## 开发日志

### Day 1

- 需求分析
- 技术选型
- 对话页面开发
- 语言选择页面开发
- 实现会话历史保存和展示
- 实现翻译模型适配端侧
- 实现模型下载断点续传
- 实现文字发送触发翻译
- 实现语音发送触发翻译

### Day 2

- 会话页面布局优化
- TSS 文字转语音输出开发
- 自动识别文字所属语言开发
- VAD门控加入，使用简单的RMS 能量阈值VAD
- 会话页面实现语言选择，触发再次翻译
- 会话内容支持复制
- 会话历史删除功能
- 优化底部输入框样式
- 修复语音文件丢失问题
- 优化语言是否支持的判断逻辑

### Day 3

- 新增流式翻译页面
- 翻译文本的优化
- 固定中文只识别简体中文，防止被识别为繁体中文
- 优化历史会话页面
- 优化会话页面的背景颜色，延伸到整个页面
- 优化语音录入，降低外部噪音
- 重构优化部分模块

### Day 4

- 交付文档输出
- 性能测试
  - 文字翻译性能测试
  - 流式翻译性能测试
- 模型benchmark性能测试

## 交付内容

- [技术选型说明](link/Resource/Doc/技术选型说明.md)
- [架构设计说明](link/Resource/Doc/架构设计说明.md)
- [AI使用方法与总结](link/Resource/Doc/AI%20使用方法与总结.md)
- [性能测试](link/Resource/Doc/性能测试.md)
- [个人软件设计哲学](link/Resource/Doc/个人软件设计哲学.md)
- [模型benchmark](link/Resource/Doc/模型benchmark.md)

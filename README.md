# 📦 WebUnzipper: 极客级私有云自动解压与沉浸式阅读引擎

![Platform](https://img.shields.io/badge/Platform-Ubuntu%20%7C%20Linux-blue?logo=linux)
![Python](https://img.shields.io/badge/Python-3.8%2B-blue?logo=python)
![FileBrowser](https://img.shields.io/badge/WebUI-FileBrowser-00ADD8)
![License](https://img.shields.io/badge/License-MIT-green)

WebUnzipper 是一套部署在 Linux 服务器上的高性能、全自动文件处理流与在线阅读中枢。它专为有重度小说/文档阅读需求、且追求极致纯净体验的极客设计。

通过整合 Python 守护进程、P7zip 引擎、Samba 局域网共享与深度魔改的前端 Web 面板，本项目彻底解决了从“下载压缩包”到“移动端全屏沉浸阅读”链路中的所有痛点（如密码提取、GBK 乱码、UI 遮挡等）。

---

## ✨ 核心特性 (Core Features)

- **🚀 智能侦测与全自动解压**
  - 监听主数据盘，自动识别 `.zip`, `.rar`, `.7z` 及其分卷（如 `.part1.rar`, `.001`）。
  - 基于文件名正则化（Regex）自动提取潜在密码（如 `[密码1234]`，`@解压码`），并建立本地密码动态学习库。
- **📄 物理级智能转码与 MD 升级**
  - 自动探测原始 `.txt` 文件的底层编码，完美解决 GBK / BIG5 在 Web 端的乱码惨案。
  - 无损清洗并强行重写为标准的 UTF-8 编码，同时升级为 `.md` 格式以获得更好的排版支持。
- **🔥 阅后即焚与自动化生命周期**
  - 压缩包解压成功后触发“阅后即焚”，自动销毁原包（包含所有分卷），极致节省空间。
  - 内置存储巡航机制：超过 7 天的文件自动清理；磁盘占用达 85% 时触发强制瘦身。
- **📖 终极沉浸式阅读模式 (Kiosk Mode)**
  - 针对 Web 面板（FileBrowser）进行底层 CSS 核平级注入。
  - 彻底抹杀顶栏、路径、文件名、行号与侧边距，在移动端（鸿蒙/iOS）配合 PWA 添加到桌面，实现 **100% 纯享全屏、零 UI 干扰** 的电子书体验。
- **🖧 Samba 原生级挂载**
  - 深度绑定 Linux 实体账号权限，支持 Windows `Z:` 盘高速映射与移动端原生“网络邻居”流式访问。

---

## 🏗️ 系统架构设计 (Architecture)

本系统采用“双轨制”架构：后台 Python 守护进程负责繁重的 I/O 与解压逻辑，前台 FileBrowser 提供轻量级的 Web 呈现。

```mermaid
graph TD
    A[外部设备 Windows/手机] -->|Samba/Web 上传| B[(数据主盘 /data)]
    
    subgraph 核心守护进程 auto_extractor.py
        C[文件稳定度探测 LSOF] --> D{是否为合法压缩包?}
        D -->|是| E[正则提取密码并查阅字典]
        E --> F[多进程解压至 /buffer]
        F -->|解压成功| G[阅后即焚销毁原包]
        F -->|解压失败| H[清理缓冲并标记错误]
        
        G --> I[GBK/BIG5 智能探针]
        I --> J[重写为 UTF-8 .md]
        J --> K[从缓冲盘原子移动至主盘]
    end
    
    B -.-> C
    K -.-> B
    
    subgraph 沉浸式阅读终端
        B -->|挂载| L[FileBrowser 引擎]
        M[底层 Branding CSS 注入] --> L
        L -->|PWA 全屏输出| N[移动端无 UI 阅读器]
    end

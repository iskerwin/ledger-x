# 安全问题报告

## 怎么报告

发现可能的安全问题，请**不要**开公开 Issue，在本仓库的 **Security → Report a vulnerability** 私下提交（GitHub 私密漏洞报告，只有维护者能看到）。

请写清：

- 影响的版本与构建号（设置 → 关于 Ledger X）、iOS 版本；
- 复现步骤，以及你认为可能造成的后果；
- 用的存储方式（本机文件夹、GitHub、GitLab、Gitea/Forgejo、WebDAV）。

只用虚构数据复现，不要在报告里附真实账本、访问令牌或密码。

## 支持的版本

只修最新的正式版和开发版；旧版本请先更新到最新再确认问题是否还在。

## 范围

Ledger X 没有自己的服务器，账本只在手机与你选择的存储之间传输。下面这些都在范围内：

- 访问令牌与密码的保存（钥匙串，仅本机；钥匙串不可用时存受保护的本机文件，不进备份）；
- 与各存储后端的连接、同步与推送（包括重放、覆盖他人修改）；
- App 锁、快捷指令与 Siri 对账本的读写；
- 导入文件（账单、CSV、源文件）的解析，导出 CSV；
- IPA 源与安装包的完整性（源里每个版本带 sha256）。

你的 Git 托管平台、WebDAV 服务器或 iOS 本身的问题，请报告给相应的提供方。

---

**English:** please report security issues privately via **Security → Report a vulnerability** in this repository, not as a public issue. Include the version and build, iOS version, the storage backend and steps to reproduce, using made-up data only. Only the latest release and development builds are supported.

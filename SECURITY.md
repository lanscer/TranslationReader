# 安全策略

## 密钥与本机数据

本仓库**不包含**任何 API Key、账号凭据、本机配置、历史数据库或日志。

应用运行时的敏感数据都落在这台机器上：

- API Key：`~/Library/Application Support/TranslationReader/apikey.bin`（权限 0600，可选钥匙串）
- 设置：`UserDefaults`（`com.local.translationreader`）
- 历史：`~/Library/Application Support/TranslationReader/store.sqlite3`
- 日志：`~/Library/Logs/TranslationReader/app.log`

请不要把这些文件、`.env`、签名私钥（`Resources/signing/*.key`、`*.p12`）提交到仓库。

## 报告问题

如果你发现安全问题（例如凭据泄露、命令注入、越权读取），请不要开公开 Issue，直接通过 GitHub 的私密安全公告（Security → Report a vulnerability）联系维护者。

## 已知边界

- 机器翻译会把待译文本发送给第三方公开接口（有道 / MyMemory / 谷歌）。
- AI 翻译会把文本发送给你自己配置的端点。
- 应用未做 Apple 公证，使用自签名证书；这不影响本地运行，但请不要用它处理高敏感数据之外的合规场景。

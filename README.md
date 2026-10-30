# Pi Agent 一键部署脚本

在新环境（macOS / Linux / Windows Git Bash）跑一个命令，即可部署一套完整的 Pi Agent 开发环境。

> 说明：本脚本基于 Pi 官方文档（quickstart / extensions / skills / packages / mcp / models / settings / providers）与社区成熟配置构建，**非**知乎某文章的直接转录（该文有反爬墙，无法读取正文）。

## 一键安装

```bash
bash install.sh
```

或直接远程执行：

```bash
curl -fsSL <本脚本 URL>/install.sh | bash
```

## 脚本会做什么

| 步骤 | 内容 |
|---|---|
| 1 | 检测并（尽量）自动补齐 `curl` `git` `node(>=22)` `npm` |
| 2 | 安装 Pi：macOS/Linux 走官方安装器，Windows 走 `npm install -g` |
| 3 | 安装 **18 个精选插件**（Pi Packages） |
| 4 | 克隆 Skills（`badlogic/pi-skills` + `anthropics/skills`）到 `~/.pi/agent/skills/` |
| 5 | 配置 MCP：`context7`（文档检索）、`filesystem`（项目内）、`github`（有 `GITHUB_TOKEN` 时） |
| 6 | 写入 `settings.json` 默认项（只补缺失键，不覆盖已有配置） |
| 7 | 检测模型 API key（`ANTHROPIC_API_KEY` / `DEEPSEEK_API_KEY` / `OPENAI_API_KEY` 等） |
| 8 | 自检 + 汇总报告 |
| 9 | 询问是否启动 pi-web：密码保护 + 局域网远程访问（可跳过） |

## 精选插件清单（18 个）

```
pi-subagents                多智能体子代理
pi-mcp-adapter             MCP 适配（替换内置 MCP 支持）
pi-web-access              联网搜索/抓取
pi-lens                    LSP/ast-grep 代码智能
context-mode               上下文管理/裁剪
pi-hermes-memory           跨会话记忆
@juicesharp/rpiv-todo      待办事项
@narumitw/pi-statusline    状态栏
pi-marketplace             插件市场
@narumitw/pi-github-pr     GitHub PR
@narumitw/pi-plan-mode     计划模式
@narumitw/pi-goal          目标模式
pi-playwright              浏览器自动化
pi-simplify                简化/摘要
@firstpick/pi-prompts-git-pr   PR 提示词模板
@firstpick/pi-skill-deep-research  深度研究 skill
@victor-software-house/pi-curated-themes  精选主题
pi-web                     Web UI（浏览器界面）
```

## 可选环境变量

| 变量 | 作用 |
|---|---|
| `PI_INSTALL_METHOD=installer\|npm\|auto` | 指定 Pi 安装方式（默认 auto） |
| `PI_SETUP_NO_PREREQ=1` | 只检测依赖，不自动安装 |
| `PI_SETUP_PLUGINS=0` | 跳过插件安装 |
| `PI_SETUP_SKILLS=0` | 跳过 Skills 安装 |
| `PI_SETUP_MCP=0` | 跳过 MCP 配置 |
| `PI_SETUP_WEB=0` | 跳过 pi-web 启动询问（`PI_WEB_PORT` 可自定义端口，默认 30141） |

## 幂等性

脚本可重复运行：已有 `settings.json` / `mcp.json` 只做合并、不覆盖；Skills 已存在则 `git pull` 更新；`pi install` 自动去重。

## 装完后

```bash
cd <你的项目目录> && pi
# 在 Pi 里：
#   /login  选择并登录模型 provider
#   Ctrl+P  循环切换模型
#   Shift+Tab 切 thinking 档
#   /mcp    查看 MCP 连接状态
```

## pi-web（浏览器 Web UI）

部署脚本第 9 步会询问是否启动 pi-web：输入密码后后台启动，绑定 `0.0.0.0`，局域网内可用 `http://<本机IP>:30141` 访问（浏览器密码登录，API 走 Basic Auth 用户名 `pi`）。

```bash
# 手动启动（密码走环境变量）
PI_WEB_PASSWORD='你的密码' pi-web --hostname 0.0.0.0

# 查看状态 / 停止
pi-web status
pi-web stop
```

> 安全提示：密码走明文 HTTP，仅限可信局域网使用；公网暴露请配 HTTPS 反向代理或 Tailscale。

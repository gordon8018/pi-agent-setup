#!/usr/bin/env bash
# =============================================================================
#  pi-agent-setup.sh —— Pi Agent 全自动一键部署脚本
# -----------------------------------------------------------------------------
#  作用：在新环境（macOS / Linux / Windows Git Bash）一键部署完整的 Pi Agent
#        开发环境，包含：
#          1. 检测并补齐前置依赖（curl / git / node / npm）
#          2. 安装 Pi（@earendil-works/pi-coding-agent）
#          3. 安装精选插件 / 扩展（Pi Packages）
#          4. 安装 Skills（官方 + Anthropic 技能库）
#          5. 配置 MCP servers（context7 / filesystem / github[可选]）
#          6. 写入 settings.json 默认项（不动已有配置）
#          7. 检测模型 API key 并给出 /login 指引
#          8. 自检验证 + 汇总报告
#          9. 可选：交互式启动 pi-web（密码保护 + 局域网远程访问）
#
#  用法：
#      curl -fsSL <本脚本地址> | bash      # 或：
#      bash install.sh
#
#  可选环境变量（覆盖默认行为）：
#      PI_INSTALL_METHOD   auto | installer | npm    默认 auto
#      PI_SETUP_NO_PREREQ  1   跳过前置依赖自动安装（只检测不装）
#      PI_SETUP_SKILLS     0   跳过 Skills 安装
#      PI_SETUP_MCP        0   跳过 MCP 配置
#      PI_SETUP_PLUGINS    0   跳过插件安装
#      PI_SETUP_WEB        0   跳过 pi-web 启动询问
#
#  幂等：可重复运行，已存在配置不会被覆盖。
# =============================================================================

set -uo pipefail

# ----------------------------- 颜色输出 ------------------------------------
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_RED=$'\033[31m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_BLUE=$'\033[34m'
C_CYAN=$'\033[36m'

# 非 TTY 或 Windows 老终端时关闭颜色
if [ -t 1 ]; then :; else C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; fi

step()  { printf '\n%s==>%s %s%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD$*$C_RESET"; }
ok()    { printf '   %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '   %s⚠%s %s%s\n' "$C_YELLOW" "$C_RESET" "$*" "$C_RESET"; }
err()   { printf '   %s✗%s %s%s\n' "$C_RED" "$C_RESET" "$*" "$C_RESET"; }
info()  { printf '   %s%s\n' "$C_DIM$*$C_RESET"; }

# ----------------------------- 基础配置 ------------------------------------
AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
SKILLS_DIR="$AGENT_DIR/skills"
MCP_FILE="$AGENT_DIR/mcp.json"
SETTINGS_FILE="$AGENT_DIR/settings.json"
NODE_MIN_MAJOR=22

# 精选插件清单（Pi Packages，来自社区成熟配置）
PACKAGES=(
  pi-subagents
  pi-mcp-adapter
  pi-web-access
  pi-lens
  context-mode
  pi-hermes-memory
  @juicesharp/rpiv-todo
  @narumitw/pi-statusline
  pi-marketplace
  @narumitw/pi-github-pr
  @narumitw/pi-plan-mode
  @narumitw/pi-goal
  pi-playwright
  pi-simplify
  @firstpick/pi-prompts-git-pr
  @firstpick/pi-skill-deep-research
  @victor-software-house/pi-curated-themes
  pi-web
)

# Skills 仓库（克隆后 Pi 递归发现其中的 SKILL.md）
SKILL_REPOS=(
  "https://github.com/badlogic/pi-skills.git|pi-skills"
  "https://github.com/anthropics/skills.git|anthropic-skills"
)

# ----------------------------- 工具函数 ------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
  case "$(uname -s)" in
    Darwin)             OS=macos ;;
    Linux)              OS=linux ;;
    MINGW*|MSYS*|CYGWIN*) OS=windows ;;
    *)                  OS=unknown ;;
  esac
}

# 检查 node 主版本是否满足要求
node_ok() {
  have node || return 1
  local maj
  maj="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  [ "$maj" -ge "$NODE_MIN_MAJOR" ] 2>/dev/null
}

# 填充默认 settings（只补缺失键，绝不覆盖已有值）
fill_settings_defaults() {
  local defaults="$1"
  if have node; then
    node -e '
      const fs = require("fs");
      const target = process.argv[1];
      const defaults = JSON.parse(process.argv[2]);
      let existing = {};
      if (fs.existsSync(target)) {
        try { existing = JSON.parse(fs.readFileSync(target, "utf8")); }
        catch (e) { console.error("  ⚠ settings.json 解析失败，保留原文件:", e.message); process.exit(0); }
      }
      const merged = Object.assign({}, defaults, existing);
      fs.writeFileSync(target, JSON.stringify(merged, null, 2) + "\n");
      console.log("  ✓ 已写入 settings.json（仅填充缺失默认项）");
    ' "$SETTINGS_FILE" "$defaults"
  else
    if [ ! -f "$SETTINGS_FILE" ]; then
      printf '%s\n' "$defaults" > "$SETTINGS_FILE"
      ok "已写入 settings.json（无 node，直接写入）"
    else
      warn "无 node 且 settings.json 已存在，跳过默认项填充"
    fi
  fi
}

# 合并 MCP 配置（保留已有 server，新增缺失的）
merge_mcp() {
  local incoming="$1"
  if have node; then
    node -e '
      const fs = require("fs");
      const target = process.argv[1], incoming = process.argv[2];
      let existing = {};
      if (fs.existsSync(target)) {
        try { existing = JSON.parse(fs.readFileSync(target, "utf8")); }
        catch (e) { console.error("  ⚠ mcp.json 解析失败，将重建:", e.message); }
      }
      const inc = JSON.parse(fs.readFileSync(incoming, "utf8"));
      existing.mcpServers = Object.assign({}, inc.mcpServers || {}, existing.mcpServers || {});
      fs.writeFileSync(target, JSON.stringify(existing, null, 2) + "\n");
      console.log("  ✓ 已合并 MCP servers:", Object.keys(existing.mcpServers).join(", "));
    ' "$MCP_FILE" "$incoming"
  else
    if [ ! -f "$MCP_FILE" ]; then
      cp "$incoming" "$MCP_FILE"
      ok "已写入 mcp.json（无 node，直接写入）"
    else
      warn "无 node 且 mcp.json 已存在，跳过合并"
    fi
  fi
}

# ----------------------------- 主流程 --------------------------------------

echo ""
printf '%s' "$C_CYAN"
cat <<'BANNER'
   ____  _   _____            _             _              ____       _
  |  _ \(_) |_   _|          / \   __ _  ___| |_           / ___|  ___| |_ _   _ _ __
  | |_) | |   | |   _____   / _ \ / _` |/ __| __|  _____  \___ \ / _ \ __| | | | '_ \
  |  __/| |   | |  |_____| / ___ \ (_| | (__| |_  |_____|  ___) |  __/ |_| |_| | |_) |
  |_|   |_|   |_|         /_/   \_ \__,_|\___|\__|         |____/ \___|\__|\__,_| .__/
                                                                            |_|
BANNER
printf '%s' "$C_RESET"
printf '%s Pi Agent 全自动部署脚本 %s\n' "$C_DIM" "$C_RESET"
echo ""

detect_os
info "检测到操作系统: $OS"
info "配置目录: $AGENT_DIR"

mkdir -p "$AGENT_DIR"

# ---------- 1. 前置依赖 ----------
step "1/9 检查前置依赖"
missing=0
for c in curl git; do
  if have "$c"; then ok "$c 已就绪"; else err "缺少 $c"; missing=$((missing+1)); fi
done
if node_ok; then
  ok "node $(node -v) 已就绪（npm $(npm -v 2>/dev/null || echo '?'))"
else
  if have node; then
    warn "node 版本过低（当前 $(node -v)，需要 >= ${NODE_MIN_MAJOR}）"
  else
    warn "未检测到 node"
  fi
  missing=$((missing+1))
fi

if [ "$missing" -gt 0 ]; then
  echo ""
  warn "存在缺失/过旧依赖。以下给出各平台安装方式："
  case "$OS" in
    macos)
      info "  macOS（推荐 Homebrew）:"
      info "    brew install node@22 git curl"
      info "    brew link --overwrite node@22"
      ;;
    linux)
      info "  Linux（按发行版选其一）:"
      info "    Debian/Ubuntu: sudo apt-get update && sudo apt-get install -y curl git nodejs npm"
      info "    Fedora:        sudo dnf install -y curl git nodejs npm"
      info "    Arch:          sudo pacman -S --noconfirm curl git nodejs npm"
      info "    （Node 官方源更稳：https://nodejs.org）"
      ;;
    windows)
      info "  Windows（Git Bash 内执行）:"
      info "    winget install OpenJS.NodeJS.LTS Git.Git"
      info "    装完后重开 Git Bash 再运行本脚本。"
      ;;
  esac
  if [ "${PI_SETUP_NO_PREREQ:-0}" = "1" ]; then
    warn "已设置 PI_SETUP_NO_PREREQ=1，跳过自动安装，继续尝试……"
  else
    # 尝试自动安装
    auto_installed=0
    case "$OS" in
      macos)
        if have brew && [ "$missing" -gt 0 ]; then
          step "尝试用 Homebrew 安装缺失依赖……"
          brew install node@22 git curl 2>/dev/null && { brew link --overwrite node@22 2>/dev/null || true; auto_installed=1; }
        fi
        ;;
      linux)
        if have apt-get; then
          step "尝试用 apt-get 安装缺失依赖……"
          sudo apt-get update -y >/dev/null 2>&1 && sudo apt-get install -y curl git nodejs npm >/dev/null 2>&1 && auto_installed=1
        elif have dnf; then
          step "尝试用 dnf 安装缺失依赖……"
          sudo dnf install -y curl git nodejs npm >/dev/null 2>&1 && auto_installed=1
        elif have pacman; then
          step "尝试用 pacman 安装缺失依赖……"
          sudo pacman -S --noconfirm curl git nodejs npm >/dev/null 2>&1 && auto_installed=1
        fi
        ;;
    esac
    if [ "$auto_installed" = "1" ] && node_ok && have curl && have git; then
      ok "依赖已补齐"
    else
      err "依赖未就绪（本机无法自动安装或安装失败）。请按上面的提示手动安装后重跑本脚本。"
      exit 1
    fi
  fi
fi

# ---------- 2. 安装 Pi ----------
step "2/9 安装 / 更新 Pi"

PI_INSTALL_METHOD="${PI_INSTALL_METHOD:-auto}"
if [ "$PI_INSTALL_METHOD" = "auto" ]; then
  if [ "$OS" = "windows" ]; then PI_INSTALL_METHOD="npm"; else PI_INSTALL_METHOD="installer"; fi
fi

if have pi; then
  ok "Pi 已安装：$(pi --version 2>/dev/null | head -1)"
  info "尝试更新到最新……"
  pi update >/dev/null 2>&1 && ok "Pi 已更新" || warn "pi update 失败（可忽略，继续使用现有版本）"
else
  case "$PI_INSTALL_METHOD" in
    installer)
      step "使用官方安装器（curl | sh）安装……"
      curl -fsSL https://pi.dev/install.sh | sh
      ;;
    npm)
      step "使用 npm 全局安装……"
      if node_ok; then
        npm install -g --ignore-scripts @earendil-works/pi-coding-agent
      else
        err "npm 方式需要 node >= ${NODE_MIN_MAJOR}，但当前环境不满足。"
        exit 1
      fi
      ;;
    *)
      err "未知 PI_INSTALL_METHOD: $PI_INSTALL_METHOD"
      exit 1
      ;;
  esac
fi

# 确认 pi 在 PATH 中
if ! have pi; then
  # 尝试补充 npm 全局 bin 到 PATH
  if have npm; then
    NPMPREFIX="$(npm config get prefix 2>/dev/null)"
    if [ -n "$NPMPREFIX" ] && [ -x "$NPMPREFIX/bin/pi" ]; then
      export PATH="$NPMPREFIX/bin:$PATH"
      info "已把 $NPMPREFIX/bin 加入 PATH"
    fi
  fi
fi

if ! have pi; then
  err "安装后仍找不到 pi 命令。请重新打开终端后再运行，或检查 PATH。"
  exit 1
fi
ok "Pi 就绪：$(pi --version 2>/dev/null | head -1)"

# ---------- 3. 安装插件 ----------
step "3/9 安装精选插件（${#PACKAGES[@]} 个 Pi Packages）"
if [ "${PI_SETUP_PLUGINS:-1}" != "1" ]; then
  warn "已设置 PI_SETUP_PLUGINS=0，跳过插件安装"
else
  for pkg in "${PACKAGES[@]}"; do
    if pi install "npm:$pkg" >/dev/null 2>&1; then
      ok "npm:$pkg"
    else
      warn "安装失败（可稍后手动重试）: npm:$pkg"
    fi
  done
  info "正在 reconcile 包安装……"
  pi update --extensions >/dev/null 2>&1 && ok "包安装已 reconcile" || warn "pi update --extensions 未成功（可忽略）"
fi

# ---------- 4. 安装 Skills ----------
step "4/9 安装 Skills"
if [ "${PI_SETUP_SKILLS:-1}" != "1" ]; then
  warn "已设置 PI_SETUP_SKILLS=0，跳过 Skills 安装"
else
  mkdir -p "$SKILLS_DIR"
  for entry in "${SKILL_REPOS[@]}"; do
    url="${entry%%|*}"
    name="${entry##*|}"
    dest="$SKILLS_DIR/$name"
    if [ -d "$dest/.git" ]; then
      info "更新已有技能库: $name"
      ( git -C "$dest" pull --ff-only >/dev/null 2>&1 && ok "已更新 $name" ) || warn "更新失败: $name"
    else
      info "克隆技能库: $name"
      if git clone --depth 1 "$url" "$dest" >/dev/null 2>&1; then
        ok "已安装 $name"
      else
        warn "克隆失败（网络原因可稍后重试）: $url"
      fi
    fi
  done
fi

# ---------- 5. 配置 MCP ----------
step "5/9 配置 MCP servers"
if [ "${PI_SETUP_MCP:-1}" != "1" ]; then
  warn "已设置 PI_SETUP_MCP=0，跳过 MCP 配置"
else
  MCP_TMP="$(mktemp)"
  # github server 只在存在 token 时启用
  GITHUB_MCP=""
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    GITHUB_MCP=', "github": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"], "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}" } }'
  fi
  cat > "$MCP_TMP" <<EOF
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp@latest"]
    },
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "."]
    }${GITHUB_MCP}
  }
}
EOF
  merge_mcp "$MCP_TMP"
  rm -f "$MCP_TMP"
  info "更多 MCP（如 chrome-devtools）需本地二进制，可按需在 $MCP_FILE 中添加。"
fi

# ---------- 6. 写入 settings.json 默认项 ----------
step "6/9 写入 settings.json 默认项（不覆盖已有）"
SETTINGS_DEFAULTS='{
  "$schema": "https://pi.dev/schemas/settings.schema.json",
  "defaultThinkingLevel": "high",
  "steeringMode": "all",
  "followUpMode": "all"
}'
fill_settings_defaults "$SETTINGS_DEFAULTS"

# ---------- 7. 模型 API key 检测 ----------
step "7/9 检测模型 API key"
KEYS=(
  "ANTHROPIC_API_KEY|Anthropic"
  "OPENAI_API_KEY|OpenAI"
  "DEEPSEEK_API_KEY|DeepSeek"
  "GEMINI_API_KEY|Google Gemini"
  "ANT_LING_API_KEY|Ant Ling"
  "OPENROUTER_API_KEY|OpenRouter"
  "XAI_API_KEY|xAI"
  "GROQ_API_KEY|Groq"
  "MISTRAL_API_KEY|Mistral"
  "MOONSHOT_API_KEY|Moonshot"
  "KIMI_API_KEY|Kimi"
)
found=0
for kv in "${KEYS[@]}"; do
  var="${kv%%|*}"; label="${kv##*|}"
  if [ -n "${!var:-}" ]; then
    ok "检测到 $label（$var）—— Pi 将自动使用该 key"
    found=$((found+1))
  fi
done
if [ "$found" -eq 0 ]; then
  info "未检测到任何模型 API key。启动 Pi 后运行 /login 选择并登录一个 provider，"
  info "或在 shell 中 export 对应 key（如 ANTHROPIC_API_KEY / DEEPSEEK_API_KEY）后重开 Pi。"
fi
if [ -f "$AGENT_DIR/auth.json" ]; then
  ok "检测到已有 auth.json（已登录的凭据会保留）"
fi

# ---------- 8. 验证 ----------
step "8/9 自检验证"
ok "Pi 版本: $(pi --version 2>/dev/null | head -1)"
info "已配置的 packages："
pi list 2>/dev/null | sed 's/^/     /' || warn "pi list 无输出"
echo ""
info "MCP servers 状态（首次连接 npx 可能较慢）："
pi mcp list 2>&1 | sed 's/^/     /' || warn "pi mcp list 失败（可稍后手动验证）"

# ---------- 9. 可选：启动 pi-web ----------
step "9/9 启动 pi-web Web UI（可选）"
if [ "${PI_SETUP_WEB:-1}" != "1" ]; then
  warn "已设置 PI_SETUP_WEB=0，跳过 pi-web 启动"
elif ! have pi-web; then
  warn "未检测到 pi-web 命令，跳过（可先执行: npm install -g @agegr/pi-web）"
else
  PI_WEB_PORT="${PI_WEB_PORT:-30141}"
  if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$PI_WEB_PORT/" 2>/dev/null; then
    warn "端口 $PI_WEB_PORT 已有 pi-web 在运行（pi-web status 查看），跳过重复启动"
  else
    printf '是否现在启动 pi-web（浏览器 Web UI，密码保护 + 局域网远程访问）? [y/N] '
    read -r PI_WEB_ANSWER
    case "$PI_WEB_ANSWER" in
      y|Y|yes|YES)
        printf '设置 pi-web 访问密码（输入不回显）: '
        read -rs PI_WEB_PASSWORD; echo ""
        printf '再次确认密码: '
        read -rs PI_WEB_PASSWORD2; echo ""
        if [ -z "$PI_WEB_PASSWORD" ]; then
          err "密码为空，跳过启动 pi-web"
        elif [ "$PI_WEB_PASSWORD" != "$PI_WEB_PASSWORD2" ]; then
          err "两次输入不一致，跳过启动 pi-web"
        else
          info "后台启动 pi-web（监听 0.0.0.0:$PI_WEB_PORT）……"
          if nohup env PI_WEB_PASSWORD="$PI_WEB_PASSWORD" pi-web --hostname 0.0.0.0 --port "$PI_WEB_PORT" --no-open >"$AGENT_DIR/pi-web.log" 2>&1 &
          then
            PI_WEB_UP=0
            for _ in 1 2 3 4 5 6 7 8 9 10; do
              sleep 2
              if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$PI_WEB_PORT/" 2>/dev/null; then PI_WEB_UP=1; break; fi
            done
            if [ "$PI_WEB_UP" = "1" ]; then
              ok "pi-web 已启动（日志: $AGENT_DIR/pi-web.log）"
              info "本机访问:   http://127.0.0.1:$PI_WEB_PORT （密码为刚设置的值）"
              PI_WEB_IPS="$(node -e 'const os=require("os");const out=[];for(const k of Object.keys(os.networkInterfaces())){for(const a of os.networkInterfaces()[k]||[]){if(a.family==="IPv4"&&!a.internal)out.push(a.address)}}console.log(out.join(" "))' 2>/dev/null || true)"
              for ip in $PI_WEB_IPS; do
                info "局域网访问: http://$ip:$PI_WEB_PORT"
              done
              info "管理命令:   pi-web status / pi-web stop"
              warn "注意: 密码走明文 HTTP，仅限可信局域网；公网暴露请配 HTTPS 反向代理或 Tailscale"
            else
              err "pi-web 启动后未响应，请查看 $AGENT_DIR/pi-web.log"
            fi
          else
            err "pi-web 启动失败，请查看 $AGENT_DIR/pi-web.log"
          fi
          unset PI_WEB_PASSWORD PI_WEB_PASSWORD2
        fi
        ;;
      *)
        info "已跳过。之后可手动启动: PI_WEB_PASSWORD='你的密码' pi-web --hostname 0.0.0.0"
        ;;
    esac
  fi
fi

# ---------- 汇总 ----------
echo ""
printf '%s' "$C_GREEN$C_BOLD"
echo "════════════════════════════════════════════════════════════════"
echo "  ✅ 部署完成"
echo "════════════════════════════════════════════════════════════════"
printf '%s' "$C_RESET"
echo ""
echo "  已完成的动作："
echo "    • 前置依赖：curl / git / node / npm"
echo "    • Pi 本体：$(pi --version 2>/dev/null | head -1)"
echo "    • 插件包：${#PACKAGES[@]} 个（见上，个别失败的可重跑本脚本补齐）"
echo "    • Skills：已克隆到 $SKILLS_DIR"
echo "    • MCP：$MCP_FILE"
echo "    • settings：$SETTINGS_FILE"
echo "    • 配置目录：$AGENT_DIR"
echo ""
echo "  下一步（本脚本不代为执行）："
echo "    1. 启动 Pi：  cd <你的项目目录> && pi"
echo "    2. 登录模型： 在 Pi 里运行 /login 选择 provider"
echo "       或 export ANTHROPIC_API_KEY=sk-... 后再启动"
echo "    3. 切模型 / 思考档： Ctrl+P 循环模型，Shift+Tab 切 thinking，Ctrl+L 调模型"
echo "    4. 常用插件命令见各插件文档；/mcp 查看 MCP 连接状态"
echo "    5. 远程访问 Web UI: PI_WEB_PASSWORD='你的密码' pi-web --hostname 0.0.0.0"
echo "       （浏览器登录同密码；pi-web status / stop 管理服务）"
echo ""
echo "  卸载：npm uninstall -g @earendil-works/pi-coding-agent（配置保留在 $AGENT_DIR）"
echo ""

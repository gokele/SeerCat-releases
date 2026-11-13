#!/bin/bash
# SeerCat 节点安装 / 更新 / 卸载脚本
#
# 用法:
#   bash agent.sh -a 面板地址:端口 -s 节点密钥   安装 (面板「节点管理」里复制的命令)
#   bash agent.sh                               交互菜单
#   bash agent.sh update                        更新到最新版本 (旧版 flux_agent 会自动迁移)
#   bash agent.sh uninstall                     卸载
#
# 可选环境变量:
#   SEERCAT_VERSION    安装指定版本 (如 v2.1.0)，默认最新版
#   SEERCAT_AGENT_BIN  使用本地程序文件 (离线包)

REPO="gokele/SeerCat-releases"
INSTALL_DIR="/etc/seercat"
BIN="$INSTALL_DIR/seercat-agent"
SERVICE="seercat-agent"
SERVICE_FILE="/etc/systemd/system/$SERVICE.service"

# 旧版 flux-panel 节点
OLD_DIR="/etc/flux_agent"
OLD_SERVICE="flux_agent"

red()   { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
info()  { echo -e "\033[36m$*\033[0m"; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    red "请使用 root 用户运行"
    exit 1
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    red "当前系统没有 systemd，暂不支持"
    exit 1
  fi
}

arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) red "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
}

download_url() {
  local a file
  a="$(arch)" || exit 1
  file="seercat-agent-linux-$a"
  local url
  if [[ -n "$SEERCAT_VERSION" ]]; then
    url="https://github.com/$REPO/releases/download/$SEERCAT_VERSION/$file"
  else
    url="https://github.com/$REPO/releases/latest/download/$file"
  fi
  if [[ "$(curl -s --max-time 5 https://ipinfo.io/country 2>/dev/null)" == "CN" ]]; then
    url="https://ghfast.top/$url"
  fi
  echo "$url"
}

fetch_binary() {
  local dest="$1"
  if [[ -n "$SEERCAT_AGENT_BIN" ]]; then
    info "使用本地程序: $SEERCAT_AGENT_BIN"
    cp -f "$SEERCAT_AGENT_BIN" "$dest" || return 1
  else
    local url
    url="$(download_url)"
    info "下载: $url"
    curl -fL --retry 3 -o "$dest" "$url" || { red "下载失败"; rm -f "$dest"; return 1; }
  fi
  chmod +x "$dest"
  if ! "$dest" -V >/dev/null 2>&1; then
    red "程序无法运行 (下载不完整或架构不匹配)"
    rm -f "$dest"
    return 1
  fi
  info "版本: $("$dest" -V)"
}

# 端口更新 / 删除转发时断开旧连接需要 tcpkill (dsniff)
install_tcpkill() {
  command -v tcpkill >/dev/null 2>&1 && return 0
  info "安装 tcpkill..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update >/dev/null 2>&1; apt-get install -y dsniff >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y epel-release >/dev/null 2>&1; dnf install -y dsniff >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release >/dev/null 2>&1; yum install -y dsniff >/dev/null 2>&1
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache dsniff >/dev/null 2>&1
  elif command -v pacman >/dev/null 2>&1; then
    pacman -S --noconfirm dsniff >/dev/null 2>&1
  elif command -v zypper >/dev/null 2>&1; then
    zypper install -y dsniff >/dev/null 2>&1
  fi
  command -v tcpkill >/dev/null 2>&1 || info "tcpkill 未能安装，不影响转发，仅修改端口时旧连接不会被立即断开"
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=SeerCat Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$BIN
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1
}

old_installed() {
  [[ -d "$OLD_DIR" ]] || [[ -f "/etc/systemd/system/$OLD_SERVICE.service" ]]
}

# 迁移旧版 flux_agent: 沿用面板地址、密钥与本地规则 (gost.json)，旧目录改名备份
migrate_old() {
  info "检测到旧版节点 flux_agent，开始迁移..."
  systemctl stop "$OLD_SERVICE" 2>/dev/null || true
  systemctl disable "$OLD_SERVICE" 2>/dev/null || true
  mkdir -p "$INSTALL_DIR"
  for f in config.json gost.json; do
    if [[ -f "$OLD_DIR/$f" && ! -f "$INSTALL_DIR/$f" ]]; then
      cp -f "$OLD_DIR/$f" "$INSTALL_DIR/$f"
    fi
  done
  rm -f "/etc/systemd/system/$OLD_SERVICE.service"
  systemctl daemon-reload
  if [[ -d "$OLD_DIR" ]]; then
    local bak
    bak="$OLD_DIR.bak-$(date +%Y%m%d%H%M%S)"
    mv "$OLD_DIR" "$bak"
    green "旧目录已备份为 $bak (确认新版正常后可删除)"
  fi
}

write_config() {
  mkdir -p "$INSTALL_DIR"
  cat > "$INSTALL_DIR/config.json" <<EOF
{
  "addr": "$SERVER_ADDR",
  "secret": "$SECRET"
}
EOF
  [[ -f "$INSTALL_DIR/gost.json" ]] || echo '{}' > "$INSTALL_DIR/gost.json"
  chmod 600 "$INSTALL_DIR"/*.json
}

start_and_check() {
  systemctl restart "$SERVICE"
  sleep 2
  if systemctl is-active --quiet "$SERVICE"; then
    green "✅ 节点已启动 ($("$BIN" -V | awk '{print $1, $2}'))"
    echo "  配置目录: $INSTALL_DIR    日志: journalctl -u $SERVICE -f"
    return 0
  fi
  red "❌ 节点启动失败，请查看日志: journalctl -u $SERVICE -n 100"
  return 1
}

install_agent() {
  need_root
  mkdir -p "$INSTALL_DIR"
  fetch_binary "$BIN.new" || exit 1
  install_tcpkill
  if old_installed; then
    migrate_old
  fi
  systemctl stop "$SERVICE" 2>/dev/null || true
  mv -f "$BIN.new" "$BIN"
  if [[ -n "$SERVER_ADDR" && -n "$SECRET" ]]; then
    write_config
  elif [[ ! -f "$INSTALL_DIR/config.json" ]]; then
    read -r -p "面板地址 (如 1.2.3.4:6366): " SERVER_ADDR
    read -r -p "节点密钥: " SECRET
    if [[ -z "$SERVER_ADDR" || -z "$SECRET" ]]; then
      red "参数不完整，已取消"
      exit 1
    fi
    write_config
  fi
  write_service
  start_and_check || exit 1
}

update_agent() {
  need_root
  if [[ ! -x "$BIN" ]]; then
    if old_installed; then
      info "将旧版 flux_agent 迁移并升级为 SeerCat 节点"
      install_agent
      return
    fi
    red "节点未安装，请先安装"
    exit 1
  fi
  fetch_binary "$BIN.new" || exit 1
  install_tcpkill
  systemctl stop "$SERVICE" || true
  cp -f "$BIN" "$BIN.bak"
  mv -f "$BIN.new" "$BIN"
  if ! start_and_check; then
    red "回滚到旧版本"
    systemctl stop "$SERVICE" || true
    mv -f "$BIN.bak" "$BIN"
    systemctl start "$SERVICE"
    exit 1
  fi
}

uninstall_agent() {
  need_root
  read -r -p "确认卸载 SeerCat 节点？(y/N): " confirm
  [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "已取消"; return; }
  systemctl stop "$SERVICE" 2>/dev/null || true
  systemctl disable "$SERVICE" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  rm -rf "$INSTALL_DIR"
  green "✅ 卸载完成"
}

menu() {
  echo "==============================================="
  echo "              SeerCat 节点管理"
  echo "==============================================="
  echo "1. 安装"
  echo "2. 更新 (自动迁移旧版 flux_agent)"
  echo "3. 卸载"
  echo "4. 退出"
  echo "==============================================="
  read -r -p "请输入选项 (1-4): " choice
  case "$choice" in
    1) install_agent ;;
    2) update_agent ;;
    3) uninstall_agent ;;
    *) exit 0 ;;
  esac
}

case "$1" in
  update) update_agent; exit $? ;;
  uninstall) uninstall_agent; exit $? ;;
  install) shift ;;
esac

while getopts "a:s:" opt; do
  case $opt in
    a) SERVER_ADDR="$OPTARG" ;;
    s) SECRET="$OPTARG" ;;
    *) echo "用法: $0 -a 面板地址:端口 -s 节点密钥"; exit 1 ;;
  esac
done

if [[ -n "$SERVER_ADDR" && -n "$SECRET" ]]; then
  install_agent
else
  menu
fi

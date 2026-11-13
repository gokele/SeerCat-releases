#!/bin/bash
# SeerCat 主控安装 / 更新 / 卸载脚本
#
# 用法:
#   bash panel.sh            交互菜单
#   bash panel.sh install    安装 (检测到旧版 flux-panel 时自动迁移数据)
#   bash panel.sh update     更新到最新版本
#   bash panel.sh uninstall  卸载
#
# 可选环境变量:
#   SEERCAT_VERSION  安装指定版本 (如 v2.1.0)，默认最新版
#   SEERCAT_BIN      使用本地程序文件安装 / 更新 (离线包)
#   SEERCAT_PORT     全新安装时的端口 (跳过询问)
set -e

REPO="gokele/SeerCat-releases"
INSTALL_DIR="/opt/seercat"
BIN="$INSTALL_DIR/seercat"
ENV_FILE="$INSTALL_DIR/seercat.env"
DATA_DIR="$INSTALL_DIR/data"
DB_FILE="$DATA_DIR/seercat.db"
SERVICE="seercat"
SERVICE_FILE="/etc/systemd/system/$SERVICE.service"

# 旧版 flux-panel (Docker) 的容器名
OLD_BACKEND="springboot-backend"
OLD_FRONTEND="vite-frontend"

red()   { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
info()  { echo -e "\033[36m$*\033[0m"; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    red "请使用 root 用户运行 (sudo bash $0)"
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
  file="seercat-linux-$a"
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

# fetch_binary <目标文件>: 下载 (或复制本地离线包) 并确认能运行
fetch_binary() {
  local dest="$1"
  if [[ -n "$SEERCAT_BIN" ]]; then
    info "使用本地程序: $SEERCAT_BIN"
    cp -f "$SEERCAT_BIN" "$dest"
  else
    local url
    url="$(download_url)"
    info "下载: $url"
    curl -fL --retry 3 -o "$dest" "$url"
  fi
  chmod +x "$dest"
  if ! "$dest" -v >/dev/null 2>&1; then
    red "程序无法运行 (下载不完整或架构不匹配)"
    rm -f "$dest"
    exit 1
  fi
  info "版本: $("$dest" -v)"
}

random_secret() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32; }

listen_ports() {
  grep -E '^SEERCAT_LISTEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr ',' ' ' | tr -d ':'
}

# 等待服务就绪 (用 /flow/test 检查)
wait_ready() {
  local port
  port="$(listen_ports | awk '{print $1}')"
  for _ in $(seq 1 30); do
    if [[ "$(curl -s --max-time 2 "http://127.0.0.1:$port/flow/test" 2>/dev/null)" == "test" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=SeerCat Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$BIN
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1
}

old_installed() {
  command -v docker >/dev/null 2>&1 && docker inspect "$OLD_BACKEND" >/dev/null 2>&1
}

# 从旧容器读取环境变量
old_env() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$OLD_BACKEND" 2>/dev/null | grep -E "^$1=" | head -1 | cut -d= -f2-
}

# 旧容器映射到宿主机的端口 (读容器配置，容器已停止也能取到)
old_port() {
  docker inspect -f "{{with index .HostConfig.PortBindings \"$2/tcp\"}}{{(index . 0).HostPort}}{{end}}" "$1" 2>/dev/null
}

# 从旧版 flux-panel (Docker) 迁移: 复制数据库、沿用 JWT 密钥与端口，删除旧容器 (数据卷与镜像保留)
migrate_from_docker() {
  info "检测到旧版 flux-panel (Docker)，开始迁移..."
  local secret front back
  secret="$(old_env JWT_SECRET)"
  front="$(old_port "$OLD_FRONTEND" 80)"
  back="$(old_port "$OLD_BACKEND" 6365)"
  [[ -z "$secret" ]] && secret="$(random_secret)"
  info "原前端端口: ${front:-无}  原后端端口: ${back:-无}"

  info "停止旧版服务 (等待数据写盘)..."
  docker stop -t 30 "$OLD_BACKEND" >/dev/null 2>&1 || true
  docker stop -t 10 "$OLD_FRONTEND" >/dev/null 2>&1 || true
  sleep 2

  mkdir -p "$DATA_DIR"
  local tmp
  tmp="$(mktemp -d)"
  if ! docker cp "$OLD_BACKEND:/app/data/." "$tmp/" >/dev/null 2>&1 || [[ ! -s "$tmp/gost.db" ]]; then
    red "无法从旧容器复制数据库，迁移中止 (旧版未改动，可执行 docker start $OLD_BACKEND $OLD_FRONTEND 恢复)"
    rm -rf "$tmp"
    exit 1
  fi
  cp -f "$tmp/gost.db" "$DB_FILE"
  [[ -f "$tmp/gost.db-wal" ]] && cp -f "$tmp/gost.db-wal" "$DB_FILE-wal"
  [[ -f "$tmp/gost.db-shm" ]] && cp -f "$tmp/gost.db-shm" "$DB_FILE-shm"
  mkdir -p "$INSTALL_DIR/backup"
  cp -f "$tmp"/gost.db* "$INSTALL_DIR/backup/" 2>/dev/null || true
  rm -rf "$tmp"
  green "数据库已复制 (另存一份在 $INSTALL_DIR/backup)"

  local listen=""
  for p in $front $back; do
    [[ -n "$p" ]] && listen="${listen:+$listen,}:$p"
  done
  [[ -z "$listen" ]] && listen=":6366"

  cat > "$ENV_FILE" <<EOF
SEERCAT_LISTEN=$listen
SEERCAT_DB=$DB_FILE
JWT_SECRET=$secret
TZ=Asia/Shanghai
EOF
  chmod 600 "$ENV_FILE"

  info "删除旧容器 (数据卷 sqlite_data 与镜像保留，确认无误后可自行删除)..."
  docker rm "$OLD_BACKEND" "$OLD_FRONTEND" >/dev/null 2>&1 || true
}

fresh_config() {
  local port="$SEERCAT_PORT"
  if [[ -z "$port" ]]; then
    read -r -p "面板端口 (默认 6366): " port
  fi
  port="${port:-6366}"
  mkdir -p "$DATA_DIR"
  cat > "$ENV_FILE" <<EOF
SEERCAT_LISTEN=:$port
SEERCAT_DB=$DB_FILE
JWT_SECRET=$(random_secret)
TZ=Asia/Shanghai
EOF
  chmod 600 "$ENV_FILE"
}

install_panel() {
  need_root
  if [[ -x "$BIN" ]]; then
    info "SeerCat 已安装，将执行更新"
    update_panel
    return
  fi
  mkdir -p "$INSTALL_DIR"
  fetch_binary "$BIN.new"

  local migrated=0
  if old_installed; then
    migrate_from_docker
    migrated=1
  else
    fresh_config
  fi
  mv -f "$BIN.new" "$BIN"
  write_service
  systemctl restart "$SERVICE"

  if wait_ready; then
    green "✅ SeerCat 已启动"
  else
    red "❌ 服务未就绪，请查看日志: journalctl -u $SERVICE -n 100"
    if [[ $migrated -eq 1 ]]; then
      red "如需回到旧版: systemctl stop $SERVICE && 重新运行旧版安装脚本 (数据卷 sqlite_data 仍在)"
    fi
    exit 1
  fi
  echo ""
  for p in $(listen_ports); do
    echo "  访问地址: http://服务器IP:$p"
  done
  if [[ $migrated -eq 1 ]]; then
    echo "  已从旧版迁移: 账号、节点、隧道、转发全部保留，节点无需改动，登录状态继续有效"
    echo "  节点程序请在各节点上运行 agent.sh 更新 (会自动迁移旧的 flux_agent)"
  else
    echo "  默认管理员: admin_user / admin_user (登录后请立即修改)"
    echo "  请先在「网站配置」里填写面板地址 (节点连接用)"
  fi
  echo "  配置文件: $ENV_FILE    数据目录: $DATA_DIR"
}

update_panel() {
  need_root
  if [[ ! -x "$BIN" ]]; then
    if old_installed; then
      info "检测到旧版 flux-panel，将执行迁移安装"
      install_panel
      return
    fi
    red "SeerCat 未安装，请先安装"
    exit 1
  fi
  fetch_binary "$BIN.new"
  info "当前版本: $("$BIN" -v 2>/dev/null || echo 未知)"
  systemctl stop "$SERVICE" || true
  cp -f "$BIN" "$BIN.bak"
  mkdir -p "$INSTALL_DIR/backup"
  [[ -f "$DB_FILE" ]] && cp -f "$DB_FILE" "$INSTALL_DIR/backup/seercat.db.$(date +%Y%m%d%H%M%S)"
  mv -f "$BIN.new" "$BIN"
  systemctl start "$SERVICE"
  if wait_ready; then
    green "✅ 更新完成，当前版本: $("$BIN" -v)"
    # 只保留最近 5 份数据库备份
    ls -1t "$INSTALL_DIR"/backup/seercat.db.* 2>/dev/null | tail -n +6 | xargs -r rm -f
  else
    red "新版本启动失败，回滚到旧版本"
    systemctl stop "$SERVICE" || true
    mv -f "$BIN.bak" "$BIN"
    systemctl start "$SERVICE"
    red "已回滚，请查看日志: journalctl -u $SERVICE -n 100"
    exit 1
  fi
}

uninstall_panel() {
  need_root
  read -r -p "确认卸载 SeerCat 主控？(y/N): " confirm
  [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "已取消"; return; }
  systemctl stop "$SERVICE" 2>/dev/null || true
  systemctl disable "$SERVICE" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  rm -f "$BIN" "$BIN.bak" "$BIN.new"
  read -r -p "是否同时删除数据 (账号、节点、转发等，无法恢复)？(y/N): " del
  if [[ "$del" == "y" || "$del" == "Y" ]]; then
    rm -rf "$INSTALL_DIR"
    green "✅ 已卸载并删除数据"
  else
    green "✅ 已卸载，数据保留在 $INSTALL_DIR"
  fi
}

menu() {
  echo "==============================================="
  echo "              SeerCat 主控管理"
  echo "==============================================="
  echo "1. 安装 (自动迁移旧版 flux-panel)"
  echo "2. 更新"
  echo "3. 卸载"
  echo "4. 退出"
  echo "==============================================="
  read -r -p "请输入选项 (1-4): " choice
  case "$choice" in
    1) install_panel ;;
    2) update_panel ;;
    3) uninstall_panel ;;
    *) exit 0 ;;
  esac
}

case "$1" in
  install) install_panel ;;
  update) update_panel ;;
  uninstall) uninstall_panel ;;
  "") menu ;;
  *) echo "用法: $0 [install|update|uninstall]"; exit 1 ;;
esac

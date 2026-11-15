#!/usr/bin/env bash

# ============================================================
# Argosbx IDX / gVisor 专用版
# VMess + WebSocket + Cloudflared
# 禁用 Xray WARP / WireGuard
#
# 支持官方参数：
# uuid、vmpt、argo、agn、agk、name
#
# 管理命令：
# list、res、upx、upa、del
# ============================================================

set -Ee

BASE="$HOME/agsbx"
WORK="$HOME/argosbx-idx-work"
OFFICIAL_URL="https://raw.githubusercontent.com/godycg2/argosbx/main/argosbx.sh"

UUID="${uuid:-dfd8c497-a3cc-4c1d-859b-0d15411ecc35}"
VMESS_PORT="${vmpt:-${VMESS_PORT:-22388}}"
ARGO_MODE="${argo:-vmpt}"
ARGO_DOMAIN="${agn:-${ARGO_DOMAIN:-}}"
ARGO_TOKEN="${agk:-${ARGO_AUTH:-}}"
NODE_NAME="${name:-IDX-Argosbx-VMess}"

# 支持直接传入 key=value 参数
for arg in "$@"; do
    case "$arg" in
        uuid=*) UUID="${arg#uuid=}" ;;
        vmpt=*) VMESS_PORT="${arg#vmpt=}" ;;
        argo=*) ARGO_MODE="${arg#argo=}" ;;
        agn=*) ARGO_DOMAIN="${arg#agn=}" ;;
        agk=*) ARGO_TOKEN="${arg#agk=}" ;;
        name=*) NODE_NAME="${arg#name=}" ;;
        help|-h|--help) SHOW_HELP=1 ;;
        list|res|upx|upa|ups|del) ACTION="$arg" ;;
        *) echo "[WARN] 忽略未知参数：$arg" ;;
    esac
done

title() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

ok()   { echo "[OK] $*"; }
warn() { echo "[WARN] $*"; }
err()  { echo "[ERROR] $*" >&2; }

show_help() {
    cat <<HELP
Argosbx IDX/gVisor 专用脚本

安装参数：
  uuid=UUID             指定 VMess UUID
  vmpt=PORT             指定 VMess 端口，默认 22388
  argo=vmpt             启用 VMess-WS Argo
  agn=DOMAIN            固定 Argo 域名
  agk=TOKEN             Cloudflare Tunnel Token
  name=NAME             节点名称

固定 Argo 示例：
  bash ~/argosbx-idx.sh agn=vm.example.com agk=TOKEN vmpt=22388

临时 Argo：
  bash ~/argosbx-idx.sh vmpt=22388

管理命令：
  list                  查看当前节点信息
  res                   重启 Xray 和 Cloudflared
  upx                   调用官方脚本更新 Xray
  upa                   调用官方脚本更新 Cloudflared
  del                   调用官方脚本卸载
  help                  显示帮助

也支持官方环境变量形式：
  agn=vm.example.com agk=TOKEN vmpt=22388 bash ~/argosbx-idx.sh
HELP
}

stop_services() {
    pkill -f "^$BASE/xray run" 2>/dev/null || true
    pkill -f "^$BASE/cloudflared tunnel" 2>/dev/null || true
    sleep 1
}

get_url() {
    if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_TOKEN" ]; then
        printf 'https://%s' "$ARGO_DOMAIN"
    else
        grep -aoE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' \
            "$BASE/argo-idx.log" 2>/dev/null | head -n 1 || true
    fi
}

make_node() {
    local url="$1"
    local host="${url#https://}"
    host="${host%%/*}"

    [ -n "$host" ] || return 1

    local json b64 link

    json=$(cat <<NODEJSON
{
  "v": "2",
  "ps": "$NODE_NAME",
  "add": "$host",
  "port": "443",
  "id": "$UUID",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "$host",
  "path": "/",
  "tls": "tls",
  "sni": "$host"
}
NODEJSON
)

    b64=$(printf '%s' "$json" | base64 -w 0)
    link="vmess://$b64"

    printf '%s\n' "$json" > "$BASE/vmess-node.json"

    cat > "$BASE/vmess-node.txt" <<NODETXT
============================================================
IDX / Argosbx VMess 节点
============================================================

节点名称：$NODE_NAME
协议：VMess
地址：$host
端口：443
UUID：$UUID
加密：auto
传输：WebSocket
WebSocket Path：/
TLS：开启
SNI：$host

Cloudflared 地址：
$url

============================================================
VMess 节点链接
============================================================

$link

============================================================
NODETXT

    echo
    echo "============================================================"
    echo "最终节点信息"
    echo "============================================================"
    echo
    echo "节点名称：$NODE_NAME"
    echo "协议：VMess"
    echo "地址：$host"
    echo "端口：443"
    echo "UUID：$UUID"
    echo "加密：auto"
    echo "传输：WebSocket"
    echo "路径：/"
    echo "TLS：开启"
    echo "SNI：$host"
    echo
    echo "Cloudflared：$url"
    echo
    echo "------------------------------------------------------------"
    echo "VMess 节点链接"
    echo "------------------------------------------------------------"
    echo
    echo "$link"
    echo
    ok "节点信息已保存到 $BASE/vmess-node.txt"
    ok "VMess JSON 已保存到 $BASE/vmess-node.json"
}

start_services() {
    title "启动 Xray"

    stop_services
    rm -f "$BASE/xray-idx.log" "$BASE/argo-idx.log"

    nohup "$BASE/xray" run \
        -config "$BASE/xr.json" \
        > "$BASE/xray-idx.log" 2>&1 &

    sleep 2

    if ! pgrep -f "^$BASE/xray run" >/dev/null 2>&1; then
        err "Xray 启动失败"
        cat "$BASE/xray-idx.log" 2>/dev/null || true
        return 1
    fi

    ok "Xray 已启动"

    title "启动 Cloudflared"

    if [ -n "$ARGO_DOMAIN" ] || [ -n "$ARGO_TOKEN" ]; then
        if [ -z "$ARGO_DOMAIN" ] || [ -z "$ARGO_TOKEN" ]; then
            err "固定 Argo 必须同时提供 agn 域名和 agk Token"
            return 1
        fi

        echo "模式：固定 Argo"
        echo "域名：$ARGO_DOMAIN"

        nohup "$BASE/cloudflared" tunnel \
            --no-autoupdate \
            --edge-ip-version auto \
            --protocol http2 \
            run --token "$ARGO_TOKEN" \
            > "$BASE/argo-idx.log" 2>&1 &

    else
        echo "模式：临时 Quick Tunnel"

        nohup "$BASE/cloudflared" tunnel \
            --url "http://127.0.0.1:$VMESS_PORT" \
            --edge-ip-version auto \
            --no-autoupdate \
            --protocol http2 \
            > "$BASE/argo-idx.log" 2>&1 &
    fi

    sleep 5

    if ! pgrep -f "^$BASE/cloudflared tunnel" >/dev/null 2>&1; then
        err "Cloudflared 启动失败"
        tail -n 30 "$BASE/argo-idx.log" 2>/dev/null || true
        return 1
    fi

    ok "Cloudflared 已启动"

    title "获取 Argo 域名"

    local url=""
    for i in $(seq 1 30); do
        url=$(get_url)
        [ -n "$url" ] && break
        sleep 1
    done

    if [ -z "$url" ]; then
        warn "尚未获取到 Argo 域名"
        tail -n 20 "$BASE/argo-idx.log" 2>/dev/null || true
        return 0
    fi

    make_node "$url"
}

# ============================================================
# 管理命令
# ============================================================

if [ "${SHOW_HELP:-0}" = "1" ]; then
    show_help
    exit 0
fi

case "${ACTION:-}" in
    list)
        if [ -f "$BASE/vmess-node.txt" ]; then
            cat "$BASE/vmess-node.txt"
        else
            echo "节点文件不存在，请先安装。"
        fi
        exit 0
        ;;
    res)
        if [ ! -x "$BASE/xray" ]; then
            err "未安装 Xray"
            exit 1
        fi
        start_services
        exit $?
        ;;
    upx|upa|ups|del)
        if [ ! -f "$WORK/argosbx.sh" ]; then
            mkdir -p "$WORK"
            curl -fLsS "$OFFICIAL_URL" -o "$WORK/argosbx.sh"
            chmod +x "$WORK/argosbx.sh"
        fi
        echo "调用官方 Argosbx 命令：$ACTION"
        bash "$WORK/argosbx.sh" "$ACTION"
        exit $?
        ;;
esac

# ============================================================
# 参数检查
# ============================================================

if ! [[ "$VMESS_PORT" =~ ^[0-9]+$ ]] || \
   [ "$VMESS_PORT" -lt 1 ] || [ "$VMESS_PORT" -gt 65535 ]; then
    err "VMess 端口不合法：$VMESS_PORT"
    exit 1
fi

if [ -n "$ARGO_DOMAIN" ] && [ -z "$ARGO_TOKEN" ]; then
    err "设置固定 Argo 域名时必须同时提供 agk=Cloudflare_Tunnel_Token"
    exit 1
fi

if [ -z "$ARGO_DOMAIN" ] && [ -n "$ARGO_TOKEN" ]; then
    err "设置固定 Argo Token 时必须同时提供 agn=固定域名"
    exit 1
fi

if [ "$ARGO_MODE" != "vmpt" ]; then
    warn "当前专用版只支持 VMess-WS Argo，自动使用 argo=vmpt"
fi

title "检查 IDX / gVisor 环境"
uname -a

if uname -a | grep -qi gvisor; then
    ok "检测到 gVisor"
else
    warn "未检测到 gVisor，继续执行"
fi

title "检查基础命令"

for cmd in curl grep awk base64 nohup pgrep pkill; do
    command -v "$cmd" >/dev/null 2>&1 || {
        err "缺少命令：$cmd"
        exit 1
    }
done

mkdir -p "$WORK"

# ============================================================
# 下载官方脚本
# ============================================================

title "下载官方 Argosbx"

curl -fLsS "$OFFICIAL_URL" -o "$WORK/argosbx.sh"
chmod +x "$WORK/argosbx.sh"

echo "官方脚本：$WORK/argosbx.sh"
echo "版本信息："
grep -m1 '当前版本' "$WORK/argosbx.sh" || true

# ============================================================
# 执行官方安装
# ============================================================

title "执行官方 Argosbx 安装"

echo "UUID：$UUID"
echo "VMess 端口：$VMESS_PORT"
echo "Argo 模式：$ARGO_MODE"

if [ -n "$ARGO_DOMAIN" ]; then
    echo "固定 Argo 域名：$ARGO_DOMAIN"
    echo "固定 Argo Token：已设置"
else
    echo "Argo：临时 Quick Tunnel"
fi

# 将固定 Argo 参数传给官方脚本，使官方安装阶段也识别这些参数。
uuid="$UUID" \
vmpt="$VMESS_PORT" \
alns="y" \
argo="vmpt" \
agn="$ARGO_DOMAIN" \
agk="$ARGO_TOKEN" \
bash "$WORK/argosbx.sh"

# ============================================================
# 检查文件
# ============================================================

title "检查安装文件"

[ -x "$BASE/xray" ] || {
    err "没有找到 $BASE/xray"
    exit 1
}

[ -x "$BASE/cloudflared" ] || {
    err "没有找到 $BASE/cloudflared"
    exit 1
}

ok "Xray 和 Cloudflared 文件存在"

# ============================================================
# 备份官方配置
# ============================================================

if [ -f "$BASE/xr.json" ]; then
    cp "$BASE/xr.json" "$BASE/xr-official-$(date +%Y%m%d-%H%M%S).json"
fi

# ============================================================
# 重建 gVisor 专用配置
# ============================================================

title "生成无 WARP 的 Xray 配置"

cat > "$BASE/xr.json" <<XRJSON
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $VMESS_PORT,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "ForceIPv4"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "direct"
      }
    ]
  }
}
XRJSON

if grep -Eiq 'wireguard|x-warp-out|warp-out' "$BASE/xr.json"; then
    err "检测到 WARP/WireGuard 配置"
    exit 1
fi

"$BASE/xray" run -test -config "$BASE/xr.json"
ok "Xray 配置测试通过"

# ============================================================
# 创建启动脚本
# ============================================================

title "生成管理脚本"

cat > "$BASE/idx-start.sh" <<'START'
#!/usr/bin/env bash
BASE="$HOME/agsbx"
UUID='__UUID__'
VMESS_PORT='__PORT__'
ARGO_DOMAIN='__DOMAIN__'
ARGO_TOKEN='__TOKEN__'
NODE_NAME='__NAME__'

pkill -f "^$BASE/xray run" 2>/dev/null || true
pkill -f "^$BASE/cloudflared tunnel" 2>/dev/null || true
sleep 1

nohup "$BASE/xray" run -config "$BASE/xr.json" \
    > "$BASE/xray-idx.log" 2>&1 &

sleep 2

if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_TOKEN" ]; then
    nohup "$BASE/cloudflared" tunnel \
        --no-autoupdate --edge-ip-version auto --protocol http2 \
        run --token "$ARGO_TOKEN" \
        > "$BASE/argo-idx.log" 2>&1 &
else
    nohup "$BASE/cloudflared" tunnel \
        --url "http://127.0.0.1:$VMESS_PORT" \
        --edge-ip-version auto --no-autoupdate --protocol http2 \
        > "$BASE/argo-idx.log" 2>&1 &
fi

sleep 5

if [ -n "$ARGO_DOMAIN" ]; then
    URL="https://$ARGO_DOMAIN"
else
    URL=$(grep -aoE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' \
        "$BASE/argo-idx.log" 2>/dev/null | head -n 1 || true)
fi

if [ -z "$URL" ]; then
    echo "[WARN] 尚未获取到 Argo 域名"
    tail -n 20 "$BASE/argo-idx.log"
    exit 1
fi

HOST="${URL#https://}"
HOST="${HOST%%/*}"

JSON=$(cat <<NODEJSON
{
  "v":"2",
  "ps":"$NODE_NAME",
  "add":"$HOST",
  "port":"443",
  "id":"$UUID",
  "aid":"0",
  "scy":"auto",
  "net":"ws",
  "type":"none",
  "host":"$HOST",
  "path":"/",
  "tls":"tls",
  "sni":"$HOST"
}
NODEJSON
)

B64=$(printf '%s' "$JSON" | base64 -w 0)
LINK="vmess://$B64"

printf '%s\n' "$JSON" > "$BASE/vmess-node.json"

cat > "$BASE/vmess-node.txt" <<NODETXT
节点名称：$NODE_NAME
协议：VMess
地址：$HOST
端口：443
UUID：$UUID
传输：WebSocket
路径：/
TLS：开启
SNI：$HOST

Argo 地址：
$URL

VMess 链接：
$LINK
NODETXT

echo
echo "================ 最终节点信息 ================"
cat "$BASE/vmess-node.txt"
START

# 将参数安全写入启动脚本，避免重启后丢失固定域名配置。
sed -i \
    -e "s|__UUID__|$UUID|g" \
    -e "s|__PORT__|$VMESS_PORT|g" \
    -e "s|__DOMAIN__|$ARGO_DOMAIN|g" \
    -e "s|__TOKEN__|$ARGO_TOKEN|g" \
    -e "s|__NAME__|$NODE_NAME|g" \
    "$BASE/idx-start.sh"

chmod +x "$BASE/idx-start.sh"

cat > "$BASE/idx-stop.sh" <<'STOP'
#!/usr/bin/env bash
BASE="$HOME/agsbx"
pkill -f "^$BASE/xray run" 2>/dev/null || true
pkill -f "^$BASE/cloudflared tunnel" 2>/dev/null || true
echo "Xray / Cloudflared 已停止"
STOP
chmod +x "$BASE/idx-stop.sh"

cat > "$BASE/idx-status.sh" <<'STATUS'
#!/usr/bin/env bash
BASE="$HOME/agsbx"

echo "================ Xray ================"
pgrep -af "^$BASE/xray run" || echo "未运行"

echo
echo "================ Cloudflared ================"
pgrep -af "^$BASE/cloudflared tunnel" || echo "未运行"

echo
echo "================ Argo 地址 ================"
grep -aoE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' \
    "$BASE/argo-idx.log" 2>/dev/null | tail -n 1 || true

echo
echo "================ 节点信息 ================"
cat "$BASE/vmess-node.txt" 2>/dev/null || echo "节点文件不存在"

echo
echo "================ Xray 日志 ================"
tail -n 10 "$BASE/xray-idx.log" 2>/dev/null || true

echo
echo "================ Argo 日志 ================"
tail -n 10 "$BASE/argo-idx.log" 2>/dev/null || true
STATUS
chmod +x "$BASE/idx-status.sh"

# ============================================================
# 启动服务
# ============================================================

title "启动 IDX/gVisor 服务"
"$BASE/idx-start.sh"

# ============================================================
# 安装管理快捷命令
# ============================================================

mkdir -p "$HOME/bin"

cat > "$HOME/bin/agsbx" <<'CMD'
#!/usr/bin/env bash
case "${1:-help}" in
    list) exec "$HOME/agsbx/idx-status.sh" ;;
    res)  exec "$HOME/agsbx/idx-start.sh" ;;
    del)  exec "$HOME/agsbx/idx-stop.sh" ;;
    upx|upa|ups)
        exec bash "$HOME/argosbx-idx-work/argosbx.sh" "$1"
        ;;
    start) exec "$HOME/agsbx/idx-start.sh" ;;
    stop)  exec "$HOME/agsbx/idx-stop.sh" ;;
    status) exec "$HOME/agsbx/idx-status.sh" ;;
    *) echo "用法：agsbx {list|res|upx|upa|del|start|stop|status}" ;;
esac
CMD

chmod +x "$HOME/bin/agsbx"

case ":$PATH:" in
    *":$HOME/bin:"*) ;;
    *) export PATH="$HOME/bin:$PATH" ;;
esac

# 写入 bashrc，供后续终端使用
if ! grep -q 'export PATH="$HOME/bin:$PATH"' "$HOME/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
fi

title "安装完成"

echo "管理命令："
echo "  agsbx list"
echo "  agsbx res"
echo "  agsbx upx"
echo "  agsbx upa"
echo "  agsbx del"
echo
echo "专用管理脚本："
echo "  $BASE/idx-start.sh"
echo "  $BASE/idx-stop.sh"
echo "  $BASE/idx-status.sh"
echo
echo "节点文件："
echo "  $BASE/vmess-node.txt"
echo "  $BASE/vmess-node.json"
echo
echo "查看完整状态："
echo "  $BASE/idx-status.sh"

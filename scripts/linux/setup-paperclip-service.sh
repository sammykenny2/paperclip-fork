#!/bin/bash
#
# Setup and Patch Paperclip Managed CLI & systemd User Service on Linux / WSL2
#
# Repairs known npm packaging issues in published paperclipai releases (e.g. 2026.1106.0)
# and configures the systemd user service for automatic background startup:
#   1. Repairs missing shared library (.so) soname symlinks in @embedded-postgres/linux-x64
#   2. Syncs the patched embedded-postgres entrypoint from @paperclipai/db to top-level node_modules
#   3. Syncs pinned @openai/codex (0.160.0) and patched @agentclientprotocol/codex-acp (1.6.2)
#      from @paperclipai/server to top-level node_modules
#   4. Configures ~/.local/bin and Node (nvm) PATH for systemd --user and the paperclipai shim
#   5. Runs onboarding (if not yet configured) and installs/starts paperclipai.service
#
# Usage:
#   ./setup-paperclip-service.sh install          Install (if needed), patch, onboard, and start service
#   ./setup-paperclip-service.sh install --force  Force re-patch and service restart
#   ./setup-paperclip-service.sh patch            Apply npm packaging & PATH patches only
#   ./setup-paperclip-service.sh verify           Verify patches, systemd service, and HTTP health
#   ./setup-paperclip-service.sh remove           Stop and remove systemd user service configuration
#   ./setup-paperclip-service.sh remove -y        Remove without confirmation
#

set -euo pipefail

# --- 顏色定義 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
WHITE='\033[1;37m'
NC='\033[0m'

# --- 自動載入 nvm 與 ~/.local/bin (避免非互動 shell 找不到 node/claude) ---
export PATH="$HOME/.local/bin:$PATH"
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck disable=SC1090
    . "$NVM_DIR/nvm.sh"
fi

# --- 路徑定義 ---
PAPERCLIP_HOME="${PAPERCLIP_HOME:-$HOME/.paperclip}"
CLI_CURRENT_DIR="$PAPERCLIP_HOME/cli/current"
SHIM_PATH="$HOME/.local/bin/paperclipai"
DEFAULT_CONFIG_PATH="$PAPERCLIP_HOME/instances/default/config.json"
ENV_D_DIR="$HOME/.config/environment.d"
ENV_D_FILE="$ENV_D_DIR/10-paperclip-path.conf"
SERVICE_NAME="paperclipai.service"
SERVICE_FILE="$HOME/.config/systemd/user/$SERVICE_NAME"
DEFAULT_PORT="3100"

echo -e "${CYAN}--- Paperclip Linux / WSL2 修補與背景服務設置腳本 ---${NC}"

# --- 解析參數 ---
ACTION=""
FORCE=false
NON_INTERACTIVE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        install)  ACTION="install" ;;
        patch)    ACTION="patch" ;;
        verify)   ACTION="verify" ;;
        remove)   ACTION="remove" ;;
        --force)  FORCE=true ;;
        -y|--yes) NON_INTERACTIVE=true ;;
        *)
            echo -e "${RED}未知參數：$1${NC}"
            exit 1
            ;;
    esac
    shift
done

if [ -z "$ACTION" ]; then
    echo -e "\n${RED}請指定操作：install, patch, verify, 或 remove${NC}"
    echo ""
    echo -e "${CYAN}使用範例：${NC}"
    echo -e "   ./setup-paperclip-service.sh install"
    echo -e "   ./setup-paperclip-service.sh patch"
    echo -e "   ./setup-paperclip-service.sh verify"
    echo -e "   ./setup-paperclip-service.sh remove"
    exit 1
fi

# --- 輔助函數：讀取配置端口 ---
read_configured_port() {
    if [ -f "$DEFAULT_CONFIG_PATH" ] && command -v node &>/dev/null; then
        local port
        port=$(node -e '
            try {
                const fs = require("fs");
                const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
                if (cfg && cfg.server && cfg.server.port) console.log(cfg.server.port);
            } catch {}
        ' "$DEFAULT_CONFIG_PATH" 2>/dev/null || true)
        if [ -n "$port" ]; then
            echo "$port"
            return
        fi
    fi
    echo "$DEFAULT_PORT"
}

# --- 輔助函數：修補單一 node_modules 目錄 ---
patch_node_modules_tree() {
    local nm_dir="$1"
    local label="$2"

    if [ ! -d "$nm_dir" ]; then
        return 0
    fi

    echo -e "   ${GRAY}- 正在檢查並修補 [$label] ($nm_dir)...${NC}"

    # 1. 修補 @embedded-postgres/linux-x64/native/lib 的 .so soname symlinks
    local pg_lib_dir="$nm_dir/@embedded-postgres/linux-x64/native/lib"
    local pg_bin_dir="$nm_dir/@embedded-postgres/linux-x64/native/bin"
    if [ -d "$pg_lib_dir" ]; then
        local created_links=0
        pushd "$pg_lib_dir" >/dev/null
        shopt -s nullglob
        for f in lib*.so.*.* lib*.so.*.*.*; do
            [ -e "$f" ] || continue
            # 產生去尾版 symlink (例如 libicuuc.so.60.2 -> libicuuc.so.60, libpq.so.5.18 -> libpq.so.5)
            local base_soname="${f%.*}"
            if [ "$base_soname" != "$f" ] && [ ! -e "$base_soname" ]; then
                ln -sf "$f" "$base_soname"
                created_links=$((created_links + 1))
            fi
            # 若為三段版號 (例如 libcrypto.so.1.1.1)，額外確保二段版號存在
            local two_part
            two_part=$(echo "$f" | sed -nE 's/^(lib[^.]+\.so\.[0-9]+)\..*$/\1/p')
            if [ -n "$two_part" ] && [ "$two_part" != "$f" ] && [ ! -e "$two_part" ]; then
                ln -sf "$f" "$two_part"
                created_links=$((created_links + 1))
            fi
        done
        shopt -u nullglob
        popd >/dev/null

        if [ -x "$pg_bin_dir/initdb" ] && [ -x "$pg_bin_dir/postgres" ]; then
            if LD_LIBRARY_PATH="$pg_lib_dir" ldd "$pg_bin_dir/initdb" "$pg_bin_dir/postgres" 2>/dev/null | grep -q "not found"; then
                echo -e "     ${RED}✗ PostgreSQL native binary 仍有缺漏的動態連結庫：${NC}"
                LD_LIBRARY_PATH="$pg_lib_dir" ldd "$pg_bin_dir/initdb" "$pg_bin_dir/postgres" | grep "not found" || true
                return 1
            else
                echo -e "     ${GREEN}✓ PostgreSQL 動態連結庫 (.so symlinks) 完整 (新增 $created_links 個連結)${NC}"
            fi
        fi
    fi

    # 2. 同步 @paperclipai/db 內已打補丁的 embedded-postgres/dist/index.js 到頂層
    local db_ep_index="$nm_dir/@paperclipai/db/node_modules/embedded-postgres/dist/index.js"
    local top_ep_index="$nm_dir/embedded-postgres/dist/index.js"
    if [ -f "$db_ep_index" ] && [ -f "$top_ep_index" ]; then
        if ! cmp -s "$db_ep_index" "$top_ep_index"; then
            cp -f "$db_ep_index" "$top_ep_index"
            echo -e "     ${GREEN}✓ 已同步 @paperclipai/db 的 embedded-postgres 補丁至頂層${NC}"
        else
            echo -e "     ${GREEN}✓ 頂層 embedded-postgres 補丁已是最新${NC}"
        fi
    fi

    # 3. 同步 @paperclipai/server 內綁定的 @openai/codex (0.160.0) 與 @agentclientprotocol/codex-acp (1.6.2) 到頂層
    local srv_nm="$nm_dir/@paperclipai/server/node_modules"
    if [ -d "$srv_nm/@openai/codex" ]; then
        local srv_codex_ver=""
        local top_codex_ver=""
        srv_codex_ver=$(node -p "require('$srv_nm/@openai/codex/package.json').version" 2>/dev/null || echo "")
        if [ -f "$nm_dir/@openai/codex/package.json" ]; then
            top_codex_ver=$(node -p "require('$nm_dir/@openai/codex/package.json').version" 2>/dev/null || echo "")
        fi

        if [ -n "$srv_codex_ver" ] && [ "$srv_codex_ver" != "$top_codex_ver" ]; then
            rm -rf "$nm_dir/@openai/codex" "$nm_dir/@openai/codex-linux-x64"
            mkdir -p "$nm_dir/@openai"
            cp -a "$srv_nm/@openai/codex" "$nm_dir/@openai/codex"
            if [ -d "$srv_nm/@openai/codex-linux-x64" ]; then
                cp -a "$srv_nm/@openai/codex-linux-x64" "$nm_dir/@openai/codex-linux-x64"
            fi
            mkdir -p "$nm_dir/.bin"
            ln -sf "../@openai/codex/bin/codex.js" "$nm_dir/.bin/codex"
            echo -e "     ${GREEN}✓ 已將頂層 @openai/codex 由 ${top_codex_ver:-無} 更新為 ${srv_codex_ver}${NC}"
        else
            echo -e "     ${GREEN}✓ 頂層 @openai/codex 版本已對齊 (${srv_codex_ver:-未知})${NC}"
        fi
    fi

    if [ -d "$srv_nm/@agentclientprotocol/codex-acp" ]; then
        local srv_acp_dist="$srv_nm/@agentclientprotocol/codex-acp/dist/index.js"
        local top_acp_dist="$nm_dir/@agentclientprotocol/codex-acp/dist/index.js"
        if [ -f "$srv_acp_dist" ] && { [ ! -f "$top_acp_dist" ] || ! cmp -s "$srv_acp_dist" "$top_acp_dist"; }; then
            rm -rf "$nm_dir/@agentclientprotocol/codex-acp"
            mkdir -p "$nm_dir/@agentclientprotocol"
            cp -a "$srv_nm/@agentclientprotocol/codex-acp" "$nm_dir/@agentclientprotocol/codex-acp"
            echo -e "     ${GREEN}✓ 已同步 @paperclipai/server 的 @agentclientprotocol/codex-acp 補丁至頂層${NC}"
        else
            echo -e "     ${GREEN}✓ 頂層 @agentclientprotocol/codex-acp 補丁已是最新${NC}"
        fi
    fi
}

# --- 輔助函數：執行所有修補 (含 managed CLI、npx 快取、shim 與 systemd PATH) ---
apply_all_patches() {
    echo -e "\n${YELLOW}正在套用 Paperclip Linux / WSL2 修補...${NC}"

    # A. 修補受管安裝 ~/.paperclip/cli/current
    if [ -d "$CLI_CURRENT_DIR/node_modules" ]; then
        patch_node_modules_tree "$CLI_CURRENT_DIR/node_modules" "managed CLI (~/.paperclip/cli/current)"
    else
        echo -e "   ${YELLOW}- 尚未找到 $CLI_CURRENT_DIR/node_modules，跳過受管安裝修補${NC}"
    fi

    # B. 修補 ~/.npm/_npx 快取中已存在的 paperclipai
    if [ -d "$HOME/.npm/_npx" ]; then
        for npx_nm in "$HOME"/.npm/_npx/*/node_modules; do
            [ -d "$npx_nm/paperclipai" ] || continue
            patch_node_modules_tree "$npx_nm" "npx cache ($(basename "$(dirname "$npx_nm")"))"
        done
    fi

    # C. 確保 ~/.local/bin/paperclipai shim 將 $HOME/.local/bin 放進 PATH
    if [ -f "$SHIM_PATH" ]; then
        if ! grep -q '\.local/bin' "$SHIM_PATH"; then
            sed -i 's|^export PATH="|export PATH="$HOME/.local/bin:|' "$SHIM_PATH"
            chmod 755 "$SHIM_PATH"
            echo -e "   ${GREEN}✓ 已將 \$HOME/.local/bin 注入 $SHIM_PATH 的 PATH${NC}"
        else
            echo -e "   ${GREEN}✓ $SHIM_PATH 已包含 \$HOME/.local/bin PATH 設定${NC}"
        fi
    fi

    # D. 設定 ~/.config/environment.d 與 systemd --user 環境變數
    local node_bin_dir=""
    if command -v node &>/dev/null; then
        node_bin_dir=$(dirname "$(command -v node)")
    fi

    local desired_path="$HOME/.local/bin"
    if [ -n "$node_bin_dir" ] && [ "$node_bin_dir" != "$HOME/.local/bin" ]; then
        desired_path="$desired_path:$node_bin_dir"
    fi
    desired_path="$desired_path:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    mkdir -p "$ENV_D_DIR"
    cat > "$ENV_D_FILE" <<EOF
PATH=$desired_path
EOF
    echo -e "   ${GREEN}✓ 已寫入 systemd user 環境設定：$ENV_D_FILE${NC}"

    if command -v systemctl &>/dev/null && systemctl --user show-environment &>/dev/null; then
        systemctl --user set-environment PATH="$desired_path"
        echo -e "   ${GREEN}✓ 已更新目前 systemd --user session 的 PATH${NC}"
    fi
}

# =============================================================================
# === 驗證操作 (verify) ===
# =============================================================================
if [ "$ACTION" = "verify" ]; then
    echo -e "\n${CYAN}=== 開始驗證 Paperclip 服務與修補狀態 ===${NC}"
    ALL_GOOD=true
    PORT=$(read_configured_port)

    echo -e "\n${YELLOW}1. 檢查受管 CLI 與套件修補狀態...${NC}"
    if [ -x "$SHIM_PATH" ]; then
        CLI_VER=$("$SHIM_PATH" --version 2>/dev/null || echo "unknown")
        echo -e "   ${GREEN}- 受管 CLI 存在：$SHIM_PATH (版本: $CLI_VER)${NC}"
    else
        echo -e "   ${RED}- 未找到受管 CLI：$SHIM_PATH${NC}"
        ALL_GOOD=false
    fi

    PG_LIB="$CLI_CURRENT_DIR/node_modules/@embedded-postgres/linux-x64/native/lib"
    PG_BIN="$CLI_CURRENT_DIR/node_modules/@embedded-postgres/linux-x64/native/bin"
    if [ -x "$PG_BIN/initdb" ] && [ -x "$PG_BIN/postgres" ]; then
        if LD_LIBRARY_PATH="$PG_LIB" ldd "$PG_BIN/initdb" "$PG_BIN/postgres" 2>/dev/null | grep -q "not found"; then
            echo -e "   ${RED}- PostgreSQL native binary 動態連結庫有缺漏 (請執行 ./setup-paperclip-service.sh patch)${NC}"
            ALL_GOOD=false
        else
            PG_VER=$(LD_LIBRARY_PATH="$PG_LIB" "$PG_BIN/postgres" --version 2>/dev/null || echo "ok")
            echo -e "   ${GREEN}- PostgreSQL native binary 動態連結庫正常 ($PG_VER)${NC}"
        fi
    else
        echo -e "   ${RED}- 未找到 @embedded-postgres/linux-x64 binary${NC}"
        ALL_GOOD=false
    fi

    if [ -x "$CLI_CURRENT_DIR/node_modules/.bin/codex" ]; then
        CODEX_BUNDLED_VER=$("$CLI_CURRENT_DIR/node_modules/.bin/codex" --version 2>/dev/null || echo "unknown")
        echo -e "   ${GREEN}- 頂層內建 Codex CLI 版本：$CODEX_BUNDLED_VER${NC}"
    fi

    if command -v claude &>/dev/null; then
        CLAUDE_VER=$(claude --version 2>/dev/null || echo "installed")
        echo -e "   ${GREEN}- Claude Code CLI 已安裝：$(command -v claude) ($CLAUDE_VER)${NC}"
    else
        echo -e "   ${YELLOW}- 提示：未在 ~/.local/bin 或 PATH 找到 claude (若只使用 Codex 可忽略)${NC}"
    fi

    echo -e "\n${YELLOW}2. 檢查 systemd user service 狀態...${NC}"
    if [ -f "$SERVICE_FILE" ]; then
        echo -e "   ${GREEN}- Service 定義檔存在：$SERVICE_FILE${NC}"
        if systemctl --user is-enabled "$SERVICE_NAME" &>/dev/null; then
            echo -e "   ${GREEN}- Service 已設定開機自啟 (enabled)${NC}"
        else
            echo -e "   ${RED}- Service 未啟用開機自啟 (disabled)${NC}"
            ALL_GOOD=false
        fi
        if systemctl --user is-active "$SERVICE_NAME" &>/dev/null; then
            MAIN_PID=$(systemctl --user show -p MainPID --value "$SERVICE_NAME" 2>/dev/null || echo "")
            echo -e "   ${GREEN}- Service 運行中 (PID: ${MAIN_PID:-unknown})${NC}"
            if [ -n "$MAIN_PID" ] && [ "$MAIN_PID" != "0" ] && [ -r "/proc/$MAIN_PID/environ" ]; then
                PROC_PATH=$(tr '\0' '\n' < "/proc/$MAIN_PID/environ" | grep '^PATH=' || true)
                if echo "$PROC_PATH" | grep -q '\.local/bin'; then
                    echo -e "   ${GREEN}- Service 進程 PATH 已包含 ~/.local/bin${NC}"
                else
                    echo -e "   ${YELLOW}- 警告：Service 進程 PATH 未包含 ~/.local/bin ($PROC_PATH)${NC}"
                    ALL_GOOD=false
                fi
            fi
        else
            echo -e "   ${RED}- Service 未在運行${NC}"
            ALL_GOOD=false
        fi
    else
        echo -e "   ${RED}- Service 定義檔不存在：$SERVICE_FILE${NC}"
        ALL_GOOD=false
    fi

    echo -e "\n${YELLOW}3. 檢查 HTTP 健康端點 (http://127.0.0.1:$PORT/api/health)...${NC}"
    HEALTH_JSON=$(curl -fsS --connect-timeout 5 "http://127.0.0.1:$PORT/api/health" 2>/dev/null || echo "")
    if echo "$HEALTH_JSON" | grep -q '"status":"ok"'; then
        echo -e "   ${GREEN}- HTTP 服務健康：$HEALTH_JSON${NC}"
    else
        echo -e "   ${RED}- HTTP 服務無法連線或狀態異常：${HEALTH_JSON:-無回應}${NC}"
        ALL_GOOD=false
    fi

    echo ""
    if [ "$ALL_GOOD" = true ]; then
        echo -e "${GREEN}所有檢查項目皆通過！可透過 http://127.0.0.1:$PORT/ 存取 Paperclip。${NC}"
        exit 0
    else
        echo -e "${YELLOW}部分檢查未通過，請參考上方訊息或執行 ./setup-paperclip-service.sh install --force${NC}"
        exit 1
    fi
fi

# =============================================================================
# === 僅修補操作 (patch) ===
# =============================================================================
if [ "$ACTION" = "patch" ]; then
    apply_all_patches
    if systemctl --user is-active "$SERVICE_NAME" &>/dev/null && [ -x "$SHIM_PATH" ]; then
        echo -e "\n${YELLOW}偵測到 $SERVICE_NAME 運行中，正在重啟以套用修補...${NC}"
        "$SHIM_PATH" service restart >/dev/null
        echo -e "   ${GREEN}✓ 服務已重啟${NC}"
    fi
    echo -e "\n${GREEN}修補完成！${NC}"
    exit 0
fi

# =============================================================================
# === 移除操作 (remove) ===
# =============================================================================
if [ "$ACTION" = "remove" ]; then
    echo -e "\n${CYAN}=== 開始移除 Paperclip systemd 自動啟動配置 ===${NC}"
    if [ "$NON_INTERACTIVE" = false ]; then
        echo ""
        echo -e "${YELLOW}此操作將停止並移除：${NC}"
        echo -e "   - systemd user service ($SERVICE_FILE)"
        echo -e "   - systemd PATH 設定檔 ($ENV_D_FILE)"
        echo -e "   ${GRAY}(不會刪除 ~/.paperclip 內的資料庫與設定檔)${NC}"
        echo ""
        read -rp "   確定要繼續嗎？(Y/N) " CONFIRM
        if [[ "$CONFIRM" != "Y" && "$CONFIRM" != "y" ]]; then
            echo -e "   ${YELLOW}- 已取消操作${NC}"
            exit 0
        fi
    fi

    if [ -x "$SHIM_PATH" ]; then
        "$SHIM_PATH" service uninstall >/dev/null 2>&1 || true
    elif systemctl --user is-active "$SERVICE_NAME" &>/dev/null; then
        systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
        systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
        rm -f "$SERVICE_FILE"
        systemctl --user daemon-reload 2>/dev/null || true
    fi
    echo -e "   ${GREEN}✓ 已移除 $SERVICE_NAME${NC}"

    if [ -f "$ENV_D_FILE" ]; then
        rm -f "$ENV_D_FILE"
        echo -e "   ${GREEN}✓ 已移除 $ENV_D_FILE${NC}"
    fi

    echo -e "\n${GREEN}移除完成！${NC}"
    exit 0
fi

# =============================================================================
# === 安裝操作 (install) ===
# =============================================================================
if [ "$ACTION" = "install" ]; then
    echo -e "\n${CYAN}=== 開始設置 Paperclip 受管 CLI、修補與背景服務 ===${NC}"

    # 步驟 1: 檢查前置環境
    echo -e "\n${YELLOW}1. 檢查前置條件...${NC}"
    if ! command -v node &>/dev/null; then
        echo -e "   ${RED}- 未找到 Node.js (需 Node.js >= 20.19.0)${NC}"
        exit 1
    fi
    echo -e "   ${GREEN}- Node.js $(node --version) ($(command -v node))${NC}"

    if ! command -v npm &>/dev/null; then
        echo -e "   ${RED}- 未找到 npm${NC}"
        exit 1
    fi
    echo -e "   ${GREEN}- npm $(npm --version)${NC}"

    if ! command -v python3 &>/dev/null || ! python3 -c "import pty" &>/dev/null; then
        echo -e "   ${RED}- 未找到支援 pty 模組的 python3 (Claude/Codex 訂閱登入需要 POSIX python3 pty)${NC}"
        exit 1
    fi
    echo -e "   ${GREEN}- python3 (含 POSIX pty 模組) 可用${NC}"

    if ! command -v systemctl &>/dev/null || ! systemctl --user show-environment &>/dev/null; then
        echo -e "   ${RED}- systemd --user 未啟用。若在 WSL2，請確認 /etc/wsl.conf 內含 [boot] systemd=true${NC}"
        exit 1
    fi
    echo -e "   ${GREEN}- systemd --user 可用${NC}"

    # 步驟 2: 安裝受管 CLI (若尚未執行 npx paperclipai@latest install --yes)
    echo -e "\n${YELLOW}2. 檢查 Paperclip 受管 CLI 安裝...${NC}"
    if [ ! -x "$SHIM_PATH" ] || [ ! -d "$CLI_CURRENT_DIR/node_modules" ]; then
        echo -e "   ${GRAY}- 尚未安裝受管 CLI，正在執行 npx paperclipai@latest install --yes...${NC}"
        npx --yes paperclipai@latest install --yes
    else
        echo -e "   ${GREEN}- 已安裝受管 CLI ($("$SHIM_PATH" --version 2>/dev/null || echo "installed"))${NC}"
    fi

    # 步驟 3: 立即套用修補 (必須在 onboard 與啟動服務前完成，否則 initdb 與 codex 登入會失敗)
    apply_all_patches

    # 步驟 4: 若尚未建立實例配置 (新機器首次安裝)，使用修補後的 CLI 執行 onboard
    echo -e "\n${YELLOW}3. 檢查 Paperclip 實例配置 ($DEFAULT_CONFIG_PATH)...${NC}"
    if [ ! -f "$DEFAULT_CONFIG_PATH" ]; then
        echo -e "   ${YELLOW}- 尚未偵測到 $DEFAULT_CONFIG_PATH，即將啟動互動式初始化 (onboard)...${NC}"
        echo -e "   ${GRAY}  (因為套件已先行修補完畢，Embedded PostgreSQL 與 Claude/Codex 訂閱登入可直接正常執行)${NC}"
        "$SHIM_PATH" onboard --no-service
    else
        echo -e "   ${GREEN}- 已存在實例配置：$DEFAULT_CONFIG_PATH${NC}"
    fi

    # 步驟 5: 安裝並啟動 systemd user service
    echo -e "\n${YELLOW}4. 正在安裝並啟動 systemd 背景服務...${NC}"
    "$SHIM_PATH" service install --enable-linger >/dev/null
    "$SHIM_PATH" service restart >/dev/null
    echo -e "   ${GREEN}- 已安裝並重啟 $SERVICE_NAME (linger 已啟用)${NC}"

    # 步驟 6: 等待 HTTP 健康檢查通過
    PORT=$(read_configured_port)
    echo -e "\n${YELLOW}5. 正在等待 Paperclip HTTP 服務就緒 (http://127.0.0.1:$PORT/api/health)...${NC}"
    READY=false
    for _ in $(seq 1 30); do
        HEALTH_JSON=$(curl -fsS --connect-timeout 2 "http://127.0.0.1:$PORT/api/health" 2>/dev/null || echo "")
        if echo "$HEALTH_JSON" | grep -q '"status":"ok"'; then
            READY=true
            break
        fi
        sleep 1
    done

    if [ "$READY" = true ]; then
        echo -e "   ${GREEN}- 服務已就緒：$HEALTH_JSON${NC}"
    else
        echo -e "   ${RED}- 等待服務就緒逾時，請檢查日誌：$SHIM_PATH service logs${NC}"
        exit 1
    fi

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     Paperclip Linux / WSL2 背景服務設置與修補完成！      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}配置資訊：${NC}"
    echo -e "   - 受管 CLI：$SHIM_PATH"
    echo -e "   - 實例配置：$DEFAULT_CONFIG_PATH"
    echo -e "   - systemd 服務：$SERVICE_FILE"
    echo -e "   - 本地網址：http://127.0.0.1:$PORT/"
    echo ""
    echo -e "${CYAN}常用指令：${NC}"
    echo -e "   - 驗證狀態：./scripts/linux/setup-paperclip-service.sh verify"
    echo -e "   - 更新後重補丁：./scripts/linux/setup-paperclip-service.sh patch"
    echo -e "   - 查看服務日誌：$SHIM_PATH service logs"
    exit 0
fi

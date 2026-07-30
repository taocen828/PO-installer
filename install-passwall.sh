#!/bin/sh
#==============================================
# PO-installer - PassWall / PassWall2 / OpenClash 一键安装
# 支持 OPKG (OpenWrt ≤24.10) 和 APK (OpenWrt ≥25.12)
#==============================================
RED='\e[31m'; GREEN='\e[32m'; YELLOW='\e[33m'; BLUE='\e[34m'; NC='\e[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${YELLOW}[→]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
hdr()  { echo -e "${BLUE}━━━ $1 ━━━${NC}"; }
check_url() { curl -sL -o /dev/null -w "%{http_code}" "$1" --max-time 8 2>/dev/null; }

# 管道模式
if [ ! -t 0 ] && [ -z "$0" -o "$0" = "sh" -o "$0" = "-sh" ]; then
  echo "检测到管道模式执行，正在保存脚本..."
  cat > /tmp/install-passwall.sh
  echo "脚本已保存到 /tmp/install-passwall.sh"
  echo "请执行: sh /tmp/install-passwall.sh"
  exit 0
fi

echo ""
echo "============================================"
echo " PO-installer - PassWall/OpenClash 一键安装"
echo "============================================"
echo ""

if [ -z "$HTTP_PROXY" ]; then
  echo -n "需要代理？输入地址 (http://user:pass@host:port) 或直接回车跳过: "
  read -r PROXY_INPUT
  [ -n "$PROXY_INPUT" ] && export HTTP_PROXY="$PROXY_INPUT" && echo "  ✓ 已设置代理"
fi
echo ""

#==============================================
# 1. 系统检测
#==============================================
hdr "系统检测"

# 修复 wget 损坏（apk 内部依赖 wget 下载文件）
WGET_FIXED=0
if [ ! -s /usr/bin/wget ] || ! head -1 /usr/bin/wget 2>/dev/null | grep -q "^#!/"; then
  cp /usr/bin/wget /tmp/wget.bak 2>/dev/null
  cat > /usr/bin/wget << 'WGETEOF'
#!/bin/sh
URL=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -O) shift; OUT="$1";;
    -q|-P|-c|-nc|-nv|-S|-s|--no-check-certificate) ;;
    *) URL="$1";;
  esac
  shift
done
[ -z "$URL" ] && exit 1
[ -n "$OUT" ] && set -- -o "$OUT"
exec curl -sL --max-time 60 "$@" "$URL"
WGETEOF
  chmod +x /usr/bin/wget
  WGET_FIXED=1
  ok "修复 wget（已损坏，替换为 curl 包装器）"
fi
PKG_MGR=""
if command -v apk >/dev/null 2>&1; then
  PKG_MGR="apk"; ok "包管理器: APK (OpenWrt 25.12+)"
elif command -v opkg >/dev/null 2>&1; then
  PKG_MGR="opkg"; ok "包管理器: OPKG (OpenWrt 24.10 及以下)"
else
  err "无法识别包管理器"; exit 1
fi

SYS_ARCH=""
if [ "$PKG_MGR" = "opkg" ]; then
  SYS_ARCH=$(opkg print-architecture 2>/dev/null | grep -oE 'mipsel_24kc|aarch64_cortex-a53|aarch64_cortex-a72|aarch64_generic|x86_64|arm_cortex-a7_neon-vfpv4|mips_24kc|arm_cortex-a9_vfpv3-d16|arm_cortex-a15_neon-vfpv4|i386_pentium4|mipsel_74kc|x86_generic' | head -1)
  [ -z "$SYS_ARCH" ] && SYS_ARCH=$(opkg print-architecture 2>/dev/null | head -2 | tail -1 | awk '{print $2}')
else
  SYS_ARCH=$(apk info --print-arch 2>/dev/null)
  [ -z "$SYS_ARCH" ] && SYS_ARCH=$(cat /etc/apk/arch 2>/dev/null)
  [ -z "$SYS_ARCH" ] && SYS_ARCH=$(uname -m | sed 's/mips/mipsel_24kc/')
fi
[ -z "$SYS_ARCH" ] && { err "无法检测架构"; exit 1; }
ok "CPU 架构: $SYS_ARCH"

. /etc/openwrt_release 2>/dev/null || true
SYS_RELEASE="$DISTRIB_RELEASE"; SYS_DESC="$DISTRIB_DESCRIPTION"
[ -z "$SYS_RELEASE" ] && SYS_RELEASE=$(cat /etc/version 2>/dev/null | head -1)
[ -z "$SYS_RELEASE" ] && SYS_RELEASE="unknown"
ok "系统: $SYS_DESC ($SYS_RELEASE)"

PW_VER=$(echo "$SYS_RELEASE" | sed -n 's/^\([0-9]*\.[0-9]*\).*/\1/p')
[ -z "$PW_VER" ] && PW_VER="23.05"
echo "$SYS_RELEASE" | grep -qiE "istore|immortalwrt|koolshare|lede" && PW_VER="23.05"
echo "$PW_VER" | grep -q "^22" && PW_VER="22.03"
echo "$PW_VER" | grep -q "^23" && PW_VER="23.05"
echo "$PW_VER" | grep -q "^24" && PW_VER="24.10"
echo "$PW_VER" | grep -qE "^2[5-9]|^3" && PW_VER="snapshots"
[ "$PKG_MGR" = "apk" ] && PW_VER="snapshots"
ok "源版本: $PW_VER"

#==============================================
# 2. 源连通性检测
#==============================================
hdr "源连通性检测"
SF_OK=0; OW_OK=0; OW_USE=""
[ "$PKG_MGR" = "opkg" ] && SF_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-$PW_VER/$SYS_ARCH" || SF_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/snapshots/packages/$SYS_ARCH"
SF_TEST="$SF_BASE/passwall_luci/Packages.gz"
[ "$PKG_MGR" != "opkg" ] && SF_TEST="$SF_BASE/passwall_luci/packages.adb"
[ "$(check_url $SF_TEST)" = "200" ] && SF_OK=1 && ok "PassWall 源 ✓" || err "PassWall 源不可用"

if [ "$PKG_MGR" = "opkg" ]; then
  case "$PW_VER" in 22.03) OW_VER="22.03.7" ;; 23.05) OW_VER="23.05.5" ;; 24.10) OW_VER="24.10.0" ;; *) OW_VER="23.05.5" ;; esac
  OW_BASE="https://downloads.openwrt.org/releases/$OW_VER/packages/$SYS_ARCH"
  OW_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/$OW_VER/packages/$SYS_ARCH"
  OW_OK=1
  for feed in base packages luci; do
    [ "$(check_url $OW_BASE/$feed/Packages.gz)" != "200" ] && { OW_OK=0; break; }
  done
  [ "$OW_OK" = "1" ] && OW_USE=$OW_BASE && ok "OpenWrt 官方源 ✓"
  if [ "$OW_OK" != "1" ]; then
    OW_OK=1
    for feed in base packages luci; do
      [ "$(check_url $OW_MIRROR/$feed/Packages.gz)" != "200" ] && { OW_OK=0; break; }
    done
    [ "$OW_OK" = "1" ] && OW_USE=$OW_MIRROR && ok "OpenWrt 清华镜像 ✓"
  fi
  [ "$OW_OK" = "0" ] && err "所有 OpenWrt OPKG 源不可用"
else
  OW_BASE="https://downloads.openwrt.org/snapshots/packages/$SYS_ARCH"
  OW_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/openwrt/snapshots/packages/$SYS_ARCH"
  OW_OK=0
  [ "$(check_url $OW_BASE/base/packages.adb)" = "200" ] && OW_OK=1 && OW_USE=$OW_BASE && ok "OpenWrt 快照源 ✓"
  [ "$OW_OK" != "1" ] && [ "$SYS_RELEASE" != "unknown" ] && [ "$(check_url https://downloads.openwrt.org/releases/$SYS_RELEASE/packages/$SYS_ARCH/base/packages.adb)" = "200" ] && OW_OK=1 && OW_USE="https://downloads.openwrt.org/releases/$SYS_RELEASE/packages/$SYS_ARCH" && ok "OpenWrt 发行版源 ✓"
  [ "$OW_OK" != "1" ] && [ "$(check_url $OW_MIRROR/base/packages.adb)" = "200" ] && OW_OK=1 && OW_USE=$OW_MIRROR && ok "OpenWrt 清华快照源 ✓"
  [ "$OW_OK" = "0" ] && err "所有 OpenWrt APK 源不可用"
fi

#==============================================
# 3. 安装选择
#==============================================
hdr "安装选择"
echo "请选择要安装的软件："
echo ""
echo "  1) PassWall (经典版，推荐)"
echo "  2) PassWall2 (新版，可与 PassWall 共存)"
echo "  3) OpenClash (Clash 内核)"
echo "  4) 全部安装"
echo ""
printf "请输入选项 (1/2/3/4): "
read -r MAIN_CHOICE
case "$MAIN_CHOICE" in
  1) INSTALL_PW=1; INSTALL_PW2=0; INSTALL_OC=0; ok "选择: PassWall" ;;
  2) INSTALL_PW=0; INSTALL_PW2=1; INSTALL_OC=0; ok "选择: PassWall2" ;;
  3) INSTALL_PW=0; INSTALL_PW2=0; INSTALL_OC=1; ok "选择: OpenClash" ;;
  4) INSTALL_PW=1; INSTALL_PW2=1; INSTALL_OC=1; ok "选择: 全部安装" ;;
  *) INSTALL_PW=1; INSTALL_PW2=0; INSTALL_OC=0; ok "默认: PassWall" ;;
esac

#==============================================
# 3.5 空间检测（根据选择项估算）
#==============================================
hdr "空间检测"
REQUIRED_SPACE_MB=30
[ "$INSTALL_PW" = "1" ] && REQUIRED_SPACE_MB=$((REQUIRED_SPACE_MB + 80))
[ "$INSTALL_PW2" = "1" ] && REQUIRED_SPACE_MB=$((REQUIRED_SPACE_MB + 80))
[ "$INSTALL_OC" = "1" ] && REQUIRED_SPACE_MB=$((REQUIRED_SPACE_MB + 30))
OVERLAY_SPACE=$(df -k /overlay 2>/dev/null | tail -1 | awk '{print $4}')
[ -z "$OVERLAY_SPACE" ] && OVERLAY_SPACE=$(df -k / 2>/dev/null | tail -1 | awk '{print $4}')
OVERLAY_SPACE=$((OVERLAY_SPACE / 1024))
ok "Overlay 可用: ${OVERLAY_SPACE}MB"
info "预计需要: ${REQUIRED_SPACE_MB}MB"
[ "$OVERLAY_SPACE" -ge "$REQUIRED_SPACE_MB" ] && ok "空间充足" || err "空间不足"

#==============================================
# 4. 配置源
#==============================================
hdr "软件源配置"
info "检测系统默认源..."
SYS_SOURCE_OK=0
if [ "$PKG_MGR" = "opkg" ]; then
  opkg update 2>&1 | grep -qi "Updated list" && SYS_SOURCE_OK=1
else
  apk update 2>&1 | grep -qi "OK" && SYS_SOURCE_OK=1
fi

if [ "$SYS_SOURCE_OK" = "1" ]; then
  ok "系统源可用"
else
  err "系统源不可用，配置回退源..."
  if [ "$PKG_MGR" = "opkg" ]; then
    [ -f /etc/opkg/distfeeds.conf ] && sed -i 's/^[^#]/#&/' /etc/opkg/distfeeds.conf
    if [ "$OW_OK" = "1" ]; then
      for feed in base packages luci; do echo "src/gz openwrt_$feed $OW_USE/$feed" >> /etc/opkg/customfeeds.conf; done
      ok "已配置 OpenWrt 回退源"
    fi
  else
    [ -f /etc/apk/repositories.d/distfeeds.list ] && sed -i 's/^[^#]/#&/' /etc/apk/repositories.d/distfeeds.list 2>/dev/null
    if [ "$OW_OK" = "1" ]; then
      echo "# OpenWrt 回退源" > /etc/apk/repositories.d/customfeeds.list
      for feed in base packages luci; do echo "$OW_USE/$feed/packages.adb" >> /etc/apk/repositories.d/customfeeds.list; done
      ok "已配置 OpenWrt 回退源"
    fi
  fi
fi

# 添加 PassWall 源（仅安装 PassWall/PassWall2 时需要）
if [ "$INSTALL_PW" = "1" -o "$INSTALL_PW2" = "1" ]; then
  if [ "$SF_OK" = "1" ]; then
    info "添加 PassWall 源..."
    if [ "$PKG_MGR" = "opkg" ]; then
      wget -q --no-check-certificate -O /tmp/ipk.pub https://master.dl.sourceforge.net/project/openwrt-passwall-build/ipk.pub 2>/dev/null || true
      opkg-key add /tmp/ipk.pub 2>/dev/null || true
      for feed in passwall_luci passwall_packages passwall2; do
        echo "src/gz $feed $SF_BASE/$feed" >> /etc/opkg/customfeeds.conf
      done
      opkg update 2>/dev/null && ok "源配置完成" || err "opkg update 失败"
    else
      for feed in passwall_luci passwall_packages passwall2; do
        echo "$SF_BASE/$feed/packages.adb" >> /etc/apk/repositories.d/customfeeds.list
      done
      apk update 2>/dev/null && ok "源配置完成" || err "apk update 失败"
    fi
  fi
fi

#==============================================
# 5. 安装主程序
#==============================================
hdr "安装主程序"

get_version() {
  local pkg="$1"
  if [ "$PKG_MGR" = "opkg" ]; then
    opkg list-installed 2>/dev/null | grep "^$pkg " | awk '{print $3}'
  else
    apk info "$pkg" 2>/dev/null | grep "^$pkg-" | head -1 | awk '{print $1}' | sed "s/^$pkg-//"
  fi
}
check_installed() {
  local pkg="$1"
  if [ "$PKG_MGR" = "opkg" ]; then
    opkg list-installed 2>/dev/null | grep -q "^$pkg " && return 0
  else
    apk info "$pkg" 2>/dev/null | grep -q "^$pkg-" && return 0
  fi
  return 1
}

# 获取源中的最新版本
get_repo_version() {
  local pkg="$1"
  if [ "$PKG_MGR" = "opkg" ]; then
    opkg list "$pkg" 2>/dev/null | grep "^$pkg " | awk '{print $3}' | head -1
  else
    apk list "$pkg" 2>/dev/null | grep -v WARNING | grep "^$pkg-" | head -1 | awk '{print $1}' | sed "s/^$pkg-//"
  fi
}

# 包安装/升级
apk_install() {
  local pkg="$1"
  if [ "$PKG_MGR" != "apk" ]; then
    opkg install "$pkg" --force-overwrite --force-depends >/dev/null 2>&1
    return 0
  fi
  apk add --allow-untrusted --force-broken-world "$pkg" >/dev/null 2>&1
}

# 智能安装：已装则检测更新，未装则安装
pkg_install_or_upgrade() {
  local pkg="$1" desc="$2" ask="$3"
  if check_installed "$pkg"; then
    local ver=$(get_version "$pkg")
    local repo_ver=$(get_repo_version "$pkg")
    if [ -n "$repo_ver" ] && [ "$ver" != "$repo_ver" ]; then
      info "$desc 已安装 ($ver)，源中有新版本 ($repo_ver)"
      if [ "$ask" = "y" ]; then
        echo -n "  更新 $desc？[Y/n]: "
        read -r ANSWER
        case "$ANSWER" in n|N|no|NO) info "跳过 $desc" ;; *)
          apk_install "$pkg"
          local nver=$(get_version "$pkg")
          check_installed "$pkg" && { [ "$ver" != "$nver" ] && ok "$desc: $ver → $nver ✓" || ok "$desc ($nver) ✓"; } || err "$desc 更新失败"
        ;; esac
      else
        ok "$desc ($ver) ✓"
      fi
    else
      ok "$desc ($ver) ✓"
    fi
  else
    if [ "$ask" = "y" ]; then
      echo -n "  安装 $desc？[Y/n]: "
      read -r ANSWER
      case "$ANSWER" in n|N|no|NO) info "跳过 $desc" ;; *)
        info "安装 $desc..."
        apk_install "$pkg"
        check_installed "$pkg" && ok "$desc $(get_version $pkg) ✓" || err "$desc 安装失败"
      ;; esac
    else
      info "安装 $desc..."
      apk_install "$pkg"
      check_installed "$pkg" && ok "$desc $(get_version $pkg) ✓" || err "$desc 安装失败"
    fi
  fi
}

# 简化版（不询问，直接安装）
pkginstall() {
  local pkg="$1" desc="$2"
  pkg_install_or_upgrade "$pkg" "$desc" "n"
}

# 升级函数
pkgupgrade() {
  local pkg="$1" desc="$2"
  if check_installed "$pkg"; then
    local ver=$(get_version "$pkg")
    apk_install "$pkg"
    local nver=$(get_version "$pkg")
    [ "$ver" != "$nver" ] && [ -n "$nver" ] && ok "$desc: $ver → $nver ✓" || ok "$desc ($ver) ✓"
  else
    info "安装 $desc..."
    apk_install "$pkg"
    check_installed "$pkg" && ok "$desc $(get_version $pkg) ✓" || err "$desc 安装失败"
  fi
}

# PassWall
[ "$INSTALL_PW" = "1" ] && pkginstall "luci-app-passwall" "PassWall" && pkginstall "luci-i18n-passwall-zh-cn" "PassWall 中文包" && pkginstall "xray-core" "Xray 内核"

# PassWall2
[ "$INSTALL_PW2" = "1" ] && pkginstall "luci-app-passwall2" "PassWall2" && pkginstall "luci-i18n-passwall2-zh-cn" "PassWall2 中文包" && [ "$INSTALL_PW" != "1" ] && pkginstall "xray-core" "Xray 内核"

# OpenClash
if [ "$INSTALL_OC" = "1" ]; then
  hdr "OpenClash 安装"

  # 1) 主程序
  if check_installed "luci-app-openclash"; then
    OC_VER=$(get_version "luci-app-openclash")
    ok "OpenClash 主程序已安装 ($OC_VER)"
    # 检测 GitHub 最新版本
    OC_LATEST=$(curl -sL "https://api.github.com/repos/vernesong/OpenClash/releases/latest" --max-time 10 | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4 2>/dev/null)
    OC_LATEST_NUM=$(echo "$OC_LATEST" | sed 's/^v//')
    if [ -n "$OC_LATEST_NUM" ] && [ "$OC_VER" != "$OC_LATEST_NUM" ]; then
      info "OpenClash $OC_LATEST 可用"
      echo -n "  升级 OpenClash？[Y/n]: "
      read -r OC_DO
      case "$OC_DO" in n|N|no|NO) info "跳过" ;; *)
        OC_URL=$(curl -sL "https://api.github.com/repos/vernesong/OpenClash/releases/latest" --max-time 10 | grep -oE 'https://[^"]+\.(ipk|apk)' | head -1)
        if [ -n "$OC_URL" ]; then
          info "下载 OpenClash $OC_LATEST..."
          for url in "$OC_URL" "https://gh-proxy.com/$OC_URL" "https://ghfast.top/$OC_URL"; do
            curl -fL -# --max-time 60 -o /tmp/luci-app-openclash.ipk "$url" 2>/dev/null && break
          done
          if [ -f /tmp/luci-app-openclash.ipk ] && [ -s /tmp/luci-app-openclash.ipk ]; then
            [ "$PKG_MGR" = "opkg" ] && opkg install /tmp/luci-app-openclash.ipk --force-overwrite >/dev/null 2>&1 || apk add --allow-untrusted /tmp/luci-app-openclash.ipk >/dev/null 2>&1
            check_installed "luci-app-openclash" && ok "OpenClash $(get_version luci-app-openclash) ✓"
          fi
        fi
      ;; esac
    else
      ok "OpenClash 已是最新版"
    fi
  else
    echo -n "  安装 OpenClash 主程序？[Y/n]: "
    read -r OC_INST
    case "$OC_INST" in n|N|no|NO) info "跳过 OpenClash" ;; *)
      info "安装 OpenClash..."
      OC_VER=$(curl -sL "https://api.github.com/repos/vernesong/OpenClash/releases/latest" --max-time 10 | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4)
      OC_URL=$(curl -sL "https://api.github.com/repos/vernesong/OpenClash/releases/latest" --max-time 10 | grep -oE 'https://[^"]+\.(ipk|apk)' | head -1)
      if [ -n "$OC_URL" ]; then
        info "下载 OpenClash $OC_VER..."
        for url in "$OC_URL" "https://gh-proxy.com/$OC_URL" "https://ghfast.top/$OC_URL"; do
          curl -fL -# --max-time 60 -o /tmp/luci-app-openclash.ipk "$url" 2>/dev/null && break
        done
        if [ -f /tmp/luci-app-openclash.ipk ] && [ -s /tmp/luci-app-openclash.ipk ]; then
          [ "$PKG_MGR" = "opkg" ] && opkg install /tmp/luci-app-openclash.ipk --force-overwrite >/dev/null 2>&1 || apk add --allow-untrusted /tmp/luci-app-openclash.ipk >/dev/null 2>&1
          check_installed "luci-app-openclash" && ok "OpenClash $(get_version luci-app-openclash) ✓"
        fi
      fi
    ;; esac
  fi

  # 2) Clash 内核（检测 clash/clash_meta/clash_tun 三种）
  if [ -f /etc/openclash/core/clash ] || [ -f /etc/openclash/core/clash_meta ] || [ -f /etc/openclash/core/clash_tun ]; then
    ok "Clash 内核已安装"
  else
    echo -n "  下载 Clash 运行内核？[Y/n]: "
    read -r CORE_ANS
    case "$CORE_ANS" in n|N|no|NO) info "跳过 Clash 内核" ;; *)
      info "下载 Clash 内核..."
      OC_CORE_URL=$(curl -sL "https://api.github.com/repos/vernesong/OpenClash/releases/latest" --max-time 10 | grep -oE 'https://[^"]+clash-linux-[^"]+\.tar\.gz' | head -1)
      if [ -n "$OC_CORE_URL" ]; then
        for url in "$OC_CORE_URL" "https://gh-proxy.com/$OC_CORE_URL" "https://ghfast.top/$OC_CORE_URL"; do
          curl -fL -# --max-time 120 -o /tmp/clash-core.tar.gz "$url" 2>/dev/null && break
        done
        if [ -f /tmp/clash-core.tar.gz ] && [ -s /tmp/clash-core.tar.gz ]; then
          cd /tmp && tar xzf clash-core.tar.gz 2>/dev/null
          mkdir -p /etc/openclash/core
          cp /tmp/clash* /etc/openclash/core/clash 2>/dev/null
          chmod +x /etc/openclash/core/clash 2>/dev/null && ok "Clash 内核已安装" || err "Clash 内核安装失败"
        fi
      fi
    ;; esac
  fi
fi

#==============================================
# 6. Geo 数据库（仅 PassWall/PassWall2 需要）
#==============================================
if [ "$INSTALL_PW" = "1" -o "$INSTALL_PW2" = "1" ]; then
  hdr "Geo 数据库"
  for pkg in v2ray-geoip v2ray-geosite; do
    pkgupgrade "$pkg" "$pkg"
  done
fi

#==============================================
# 7. 可选组件（一次性列出，用户输入序号）
#==============================================
if [ "$INSTALL_PW" = "1" -o "$INSTALL_PW2" = "1" ]; then
  hdr "可选组件"
  echo "可选组件列表："
  echo ""
  i=1
  for comp_desc in "sing-box:Sing-Box 代理核心" "hysteria:Hysteria 2 加速协议" "naiveproxy:NaiveProxy 代理协议" "v2ray-plugin:V2Ray WebSocket 插件" "ipt2socks:IPTables 转 SOCKS"; do
    comp="${comp_desc%%:*}"
    desc="${comp_desc##*:}"
    if check_installed "$comp"; then
      echo "  $i) $desc ($(get_version $comp)) ✓"
    else
      echo "  $i) $desc"
    fi
    eval "OPT_COMP_$i=\"$comp\""
    eval "OPT_DESC_$i=\"$desc\""
    i=$((i + 1))
  done
  echo ""
  echo "输入序号安装（多个用空格隔开，回车跳过）: "
  echo -n "> "
  read -r OPT_CHOICES
  for idx in $OPT_CHOICES; do
    eval "comp=\"\$OPT_COMP_$idx\""
    eval "desc=\"\$OPT_DESC_$idx\""
    [ -n "$comp" ] && pkginstall "$comp" "$desc"
  done
fi

#==============================================
# 8. 刷新 LuCI
#==============================================
if command -v luci-reload >/dev/null 2>&1; then
  luci-reload 2>/dev/null || true
  ok "LuCI 已刷新"
fi

#==============================================
# 9. 结果汇总
#==============================================
echo ""
echo "============================================="
echo " [✓] 安装完成！"
echo "============================================="
echo ""
echo "系统: $SYS_DESC | $SYS_RELEASE | $SYS_ARCH | $PKG_MGR"
echo ""

# 自动删除脚本
THIS_SCRIPT=$(readlink -f "$0" 2>/dev/null || echo "$0")
case "$THIS_SCRIPT" in
  /tmp/install-passwall.sh|/tmp/install.sh|/tmp/*.sh)
    rm -f "$THIS_SCRIPT" 2>/dev/null
    echo "本地脚本已自动删除"
    ;;
esac
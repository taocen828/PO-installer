#!/bin/sh
#==============================================
# PassWall / OpenClash 通用一键安装脚本
# 支持 OPKG (OpenWrt ≤24.10) 和 APK (OpenWrt ≥25.12)
#==============================================
RED='\e[31m'; GREEN='\e[32m'; YELLOW='\e[33m'; BLUE='\e[34m'; NC='\e[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${YELLOW}[→]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
hdr()  { echo -e "${BLUE}━━━ $1 ━━━${NC}"; }
check_url() { curl -sL -o /dev/null -w "%{http_code}" "$1" --max-time 8 2>/dev/null; }

#==============================================
# 0. 管道模式检测 + 代理配置
#==============================================
if [ ! -t 0 ] && [ -z "$0" -o "$0" = "sh" -o "$0" = "-sh" ]; then
  echo "检测到管道模式执行，正在保存脚本..."
  SCRIPT_PATH="/tmp/install-passwall.sh"
  cat > "$SCRIPT_PATH"
  echo "脚本已保存到 $SCRIPT_PATH"
  echo "请执行: sh $SCRIPT_PATH"
  echo ""
  exit 0
fi

MY_PROXY="http://mp:mpproxy@cc.828789.xyz:20206"

hdr "系统检测"

if command -v apk >/dev/null 2>&1; then
  PKG_MGR="apk"
  ok "包管理器: APK (OpenWrt 25.12+)"
elif command -v opkg >/dev/null 2>&1; then
  PKG_MGR="opkg"
  ok "包管理器: OPKG (OpenWrt 24.10 及以下)"
else
  err "无法识别包管理器"
  exit 1
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
SYS_RELEASE="$DISTRIB_RELEASE"
SYS_DESC="$DISTRIB_DESCRIPTION"
[ -z "$SYS_RELEASE" ] && SYS_RELEASE=$(cat /etc/version 2>/dev/null | head -1)
[ -z "$SYS_RELEASE" ] && SYS_RELEASE="unknown"
ok "系统: $SYS_DESC ($SYS_RELEASE)"

PW_VER=$(echo "$SYS_RELEASE" | sed -n 's/^\([0-9]*\.[0-9]*\).*/\1/p')
[ -z "$PW_VER" ] && PW_VER="23.05"
echo "$SYS_RELEASE" | grep -qiE "istore|immortalwrt|koolshare|lede" && PW_VER="23.05"
echo "$PW_VER" | grep -q "^22" && PW_VER="22.03"
echo "$PW_VER" | grep -q "^23" && PW_VER="23.05"
echo "$PW_VER" | grep -q "^24" && PW_VER="24.10"
echo "$PW_VER" | grep -qE "^25|^26" && PW_VER="snapshots"
[ "$PKG_MGR" = "apk" ] && PW_VER="snapshots"
ok "源版本: $PW_VER"

#==============================================
# 2. 源检测
#==============================================
hdr "源连通性检测"

SF_OK=0; OW_OK=0; OW_USE=""

if [ "$PKG_MGR" = "opkg" ]; then
  SF_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-$PW_VER/$SYS_ARCH"
  SF_TEST="$SF_BASE/passwall_luci/Packages.gz"
else
  SF_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/snapshots/packages/$SYS_ARCH"
  SF_TEST="$SF_BASE/passwall_luci/packages.adb"
fi

[ "$(check_url $SF_TEST)" = "200" ] && SF_OK=1 && ok "PassWall 源 ✓" || err "PassWall 源不可用"

if [ "$PKG_MGR" = "opkg" ]; then
  case "$PW_VER" in
    22.03) OW_VER="22.03.7" ;;
    23.05) OW_VER="23.05.5" ;;
    24.10) OW_VER="24.10.0" ;;
    *)     OW_VER="23.05.5" ;;
  esac
  OW_BASE="https://downloads.openwrt.org/releases/$OW_VER/packages/$SYS_ARCH"
  OW_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/$OW_VER/packages/$SYS_ARCH"
  for feed in base packages luci; do
    [ "$(check_url $OW_BASE/$feed/Packages.gz)" = "200" ] && OW_OK=1 || { OW_OK=0; break; }
  done
  [ "$OW_OK" = "1" ] && OW_USE=$OW_BASE && ok "OpenWrt 官方源 ✓" || {
    for feed in base packages luci; do
      [ "$(check_url $OW_MIRROR/$feed/Packages.gz)" = "200" ] && OW_OK=1 || { OW_OK=0; break; }
    done
    [ "$OW_OK" = "1" ] && OW_USE=$OW_MIRROR && ok "OpenWrt 清华镜像 ✓"
  }
  [ "$OW_OK" = "0" ] && err "所有 OpenWrt OPKG 源不可用"
else
  OW_BASE="https://downloads.openwrt.org/snapshots/packages/$SYS_ARCH"
  OW_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/openwrt/snapshots/packages/$SYS_ARCH"
  [ "$(check_url $OW_BASE/base/Packages.adb)" = "200" ] && OW_OK=1 && OW_USE=$OW_BASE && ok "OpenWrt 快照源 ✓" || {
    [ "$(check_url $OW_MIRROR/base/Packages.adb)" = "200" ] && OW_OK=1 && OW_USE=$OW_MIRROR && ok "OpenWrt 清华快照源 ✓"
  }
  [ "$OW_OK" = "0" ] && err "所有 OpenWrt APK 源不可用"
fi

#==============================================
# 3. 主菜单
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
# 3.5 空间检测
#==============================================
hdr "空间检测"

# 估算所需空间（MB）
REQUIRED_SPACE_MB=20
[ "$INSTALL_PW" = "1" -o "$INSTALL_PW2" = "1" ] && REQUIRED_SPACE_MB=$((REQUIRED_SPACE_MB + 280))
[ "$INSTALL_OC" = "1" ] && REQUIRED_SPACE_MB=$((REQUIRED_SPACE_MB + 30))

check_space() {
  local path="$1"
  local avail=$(df -k "$path" 2>/dev/null | tail -1 | awk '{print $4}')
  [ -z "$avail" ] && avail=$(df -k "$path" 2>/dev/null | tail -1 | awk '{print $3}')
  [ -z "$avail" ] && return 1
  echo "$((avail / 1024))"
}

OVERLAY_SPACE=$(check_space /overlay)
[ -z "$OVERLAY_SPACE" ] && OVERLAY_SPACE=$(check_space /)

ok "Overlay 可用: ${OVERLAY_SPACE}MB"
info "预计需要: ${REQUIRED_SPACE_MB}MB"

if [ "$OVERLAY_SPACE" -ge "$REQUIRED_SPACE_MB" ]; then
  ok "空间充足"
else
  err "空间不足！可用 ${OVERLAY_SPACE}MB，需要 ${REQUIRED_SPACE_MB}MB"
  echo ""
  echo "是否需要自动清理空间？(清理项: 旧日志、opkg缓存、/tmp临时文件、旧内核)"
  echo -n "清理空间？[Y/n]: "
  read -r CLEAN_CHOICE
  case "$CLEAN_CHOICE" in
    n|N|no|NO) info "跳过清理，空间不足可能安装失败" ;;
    *)
      info "开始安全清理..."
      CLEANED=0

      info "清理 opkg 缓存..."
      if [ "$PKG_MGR" = "opkg" ]; then
        rm -rf /var/opkg-lists/* /var/cache/opkg/* /tmp/opkg-cache/* 2>/dev/null
      else
        rm -rf /var/cache/apk/* 2>/dev/null
      fi
      CLEANED=$((CLEANED + 1))

      info "清理 /tmp 临时文件..."
      rm -rf /tmp/*.ipk /tmp/*.apk /tmp/*.tar.gz /tmp/pw_* /tmp/install-passwall*.sh 2>/dev/null
      CLEANED=$((CLEANED + 1))

      info "清理系统日志..."
      logrotate -f /etc/logrotate.conf 2>/dev/null || true
      rm -f /var/log/*.gz /var/log/*.1 /var/log/*.old 2>/dev/null
      CLEANED=$((CLEANED + 1))

      info "清理旧内核..."
      CURRENT_KERNEL=$(uname -r)
      [ -d /boot ] && for k in /boot/vmlinuz-*; do
        [ "$k" = "/boot/vmlinuz-$CURRENT_KERNEL" ] && continue
        [ -f "$k" ] && rm -f "$k" 2>/dev/null
      done
      CLEANED=$((CLEANED + 1))

      if command -v docker >/dev/null 2>&1; then
        info "清理 Docker 无用数据..."
        docker system prune -f 2>/dev/null || true
        CLEANED=$((CLEANED + 1))
      fi

      OVERLAY_SPACE=$(check_space /overlay)
      [ -z "$OVERLAY_SPACE" ] && OVERLAY_SPACE=$(check_space /)

      echo ""
      ok "清理完成（共执行 $CLEANED 项清理）"
      ok "当前 Overlay 可用: ${OVERLAY_SPACE}MB"

      if [ "$OVERLAY_SPACE" -lt "$REQUIRED_SPACE_MB" ]; then
        err "清理后空间仍不足（${OVERLAY_SPACE}MB < ${REQUIRED_SPACE_MB}MB）"
        echo -n "是否继续安装？（可能因空间不足失败）[y/N]: "
        read -r FORCE_CONTINUE
        case "$FORCE_CONTINUE" in
          y|Y|yes|YES) info "继续安装..." ;;
          *) err "退出安装"; exit 1 ;;
        esac
      fi
      ;;
  esac
fi

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
  err "系统源不可用，配置替代源..."

  if [ "$PKG_MGR" = "opkg" ]; then
    cp /etc/opkg/customfeeds.conf /etc/opkg/customfeeds.conf.bak 2>/dev/null
    cp /etc/opkg/distfeeds.conf /etc/opkg/distfeeds.conf.bak 2>/dev/null
    sed -i 's/^[^#]/#&/' /etc/opkg/distfeeds.conf 2>/dev/null

    if [ "$SF_OK" = "1" ]; then
      wget -q --no-check-certificate -O /tmp/ipk.pub \
        https://master.dl.sourceforge.net/project/openwrt-passwall-build/ipk.pub 2>/dev/null || true
      opkg-key add /tmp/ipk.pub 2>/dev/null || true
      echo "src/gz passwall_luci $SF_BASE/passwall_luci" >> /etc/opkg/customfeeds.conf
      echo "src/gz passwall_packages $SF_BASE/passwall_packages" >> /etc/opkg/customfeeds.conf
      echo "src/gz passwall2 $SF_BASE/passwall2" >> /etc/opkg/customfeeds.conf
    fi
    if [ "$OW_OK" = "1" ]; then
      for feed in base packages luci; do
        echo "src/gz openwrt_$feed $OW_USE/$feed" >> /etc/opkg/customfeeds.conf
      done
    fi
    opkg update || { err "opkg update 失败"; exit 1; }
  else
    cp /etc/apk/repositories.d/customfeeds.list /etc/apk/repositories.d/customfeeds.list.bak 2>/dev/null
    rm -f /etc/apk/repositories.d/customfeeds.list

    if [ "$SF_OK" = "1" ]; then
      wget -q --no-check-certificate -O /etc/apk/keys/openwrt-passwall-build.pem \
        https://master.dl.sourceforge.net/project/openwrt-passwall-build/apk.pub 2>/dev/null || true
      for feed in passwall_luci passwall_packages passwall2; do
        echo "$SF_BASE/$feed/packages.adb" >> /etc/apk/repositories.d/customfeeds.list
      done
    fi
    if [ "$OW_OK" = "1" ]; then
      for feed in base packages luci; do
        echo "$OW_USE/$feed/packages.adb" >> /etc/apk/repositories.d/customfeeds.list
      done
    fi
    apk update || { err "apk update 失败"; exit 1; }
  fi
  ok "替代源配置完成"
fi

#==============================================
# 5. 安装主程序 + 依赖（含 Xray 内核）
#==============================================
hdr "安装主程序"

if [ "$PKG_MGR" = "opkg" ]; then
  if [ "$SYS_SOURCE_OK" != "1" ] && [ "$OW_OK" = "1" ]; then
    info "补装依赖..."
    opkg install coreutils-timeout lyaml coreutils-base64 coreutils-nohup --force-overwrite 2>/dev/null || true
  fi

  if [ "$INSTALL_PW" = "1" ]; then
    info "安装 PassWall (含 Xray 内核)..."
    if opkg install luci-app-passwall luci-i18n-passwall-zh-cn xray-core --force-overwrite 2>/dev/null; then
      ok "PassWall + Xray 安装成功"
    else
      err "标准安装失败，尝试强制安装..."
      opkg install luci-app-passwall luci-i18n-passwall-zh-cn xray-core --force-overwrite --force-depends 2>/dev/null && ok "强制安装成功" || {
        err "安装失败，尝试手动下载 IPK..."
        mkdir -p /tmp/pw_ipk && cd /tmp/pw_ipk
        for feed_dir in passwall_luci passwall_packages; do
          curl -sL "$SF_BASE/$feed_dir/Packages.gz" --max-time 10 | gunzip -c 2>/dev/null | \
            awk '/^Package:/{p=$2} /^Filename:/{f=$2} /^$/{if(p&&f){print p"|"f; p=""; f=""}}' >> /tmp/pw_list.txt
        done
        for pkg in luci-app-passwall luci-i18n-passwall-zh-cn chinadns-ng dns2socks geoview tcping xray-core v2ray-geoip v2ray-geosite; do
          fname=$(grep "^$pkg|" /tmp/pw_list.txt | head -1 | cut -d'|' -f2)
          [ -n "$fname" ] && wget -q --no-check-certificate "$SF_BASE/passwall_luci/$fname" 2>/dev/null || \
            wget -q --no-check-certificate "$SF_BASE/passwall_packages/$fname" 2>/dev/null || true
        done
        ls *.ipk 2>/dev/null | while read f; do opkg install "$f" --force-overwrite --force-depends 2>/dev/null; done
        cd /tmp && rm -rf /tmp/pw_ipk /tmp/pw_list.txt
      }
    fi
  fi

  if [ "$INSTALL_PW2" = "1" ]; then
    info "安装 PassWall2 (含 Xray 内核)..."
    if opkg install luci-app-passwall2 luci-i18n-passwall2-zh-cn xray-core --force-overwrite 2>/dev/null; then
      ok "PassWall2 + Xray 安装成功"
    else
      opkg install luci-app-passwall2 luci-i18n-passwall2-zh-cn xray-core --force-overwrite --force-depends 2>/dev/null && ok "强制安装成功" || err "PassWall2 安装失败"
    fi
  fi

  if [ "$INSTALL_OC" = "1" ]; then
    info "安装 OpenClash..."
    OC_IPK_URL=$(curl -sL "https://api.github.com/repos/vernesong/OpenClash/releases/latest" --max-time 10 | grep -oE 'https://[^"]+_all\.ipk' | head -1)
    OC_LATEST=$(curl -sL "https://api.github.com/repos/vernesong/OpenClash/releases/latest" --max-time 10 | grep -oE '"tag_name":[^,]+' | cut -d'"' -f4)

    if [ -n "$OC_IPK_URL" ]; then
      info "下载 OpenClash $OC_LATEST..."
      # 直连 → 代理 → gh-proxy → 用户自定义代理 → 内置代理
      OC_DOWNLOAD_OK=0
      
      curl -fsSL -o /tmp/luci-app-openclash.ipk "$OC_IPK_URL" --max-time 60 2>/dev/null && OC_DOWNLOAD_OK=1 || \
      curl -fsSL -o /tmp/luci-app-openclash.ipk -x "$HTTP_PROXY" "$OC_IPK_URL" --max-time 60 2>/dev/null && OC_DOWNLOAD_OK=1 || \
      curl -fsSL -o /tmp/luci-app-openclash.ipk "https://gh-proxy.com/$OC_IPK_URL" --max-time 60 2>/dev/null && OC_DOWNLOAD_OK=1 || \
      curl -fsSL -o /tmp/luci-app-openclash.ipk "https://ghfast.top/$OC_IPK_URL" --max-time 60 2>/dev/null && OC_DOWNLOAD_OK=1 || \
      curl -fsSL -o /tmp/luci-app-openclash.ipk -x "$MY_PROXY" "$OC_IPK_URL" --max-time 60 2>/dev/null && OC_DOWNLOAD_OK=1

      if [ "$OC_DOWNLOAD_OK" = "1" ]; then
        opkg install /tmp/luci-app-openclash.ipk --force-overwrite 2>/dev/null && ok "OpenClash 安装成功" || err "OpenClash IPK 安装失败"
      else
        err "OpenClash 下载失败，跳过"
      fi

      OC_CORE_URL=$(curl -sL "https://api.github.com/repos/vernesong/OpenClash/releases/latest" --max-time 10 | grep -oE 'https://[^"]+clash-linux-[^"]+\.tar\.gz' | head -1)
      if [ -n "$OC_CORE_URL" ]; then
        info "下载 Clash 核心..."
        for url in "$OC_CORE_URL" \
          "$(echo "$OC_CORE_URL" | sed "s|https://|$HTTP_PROXY|")" \
          "https://gh-proxy.com/$OC_CORE_URL" \
          "https://ghfast.top/$OC_CORE_URL"; do
          [ -z "$url" ] && continue
          curl -fsSL -o /tmp/clash-core.tar.gz "$url" --max-time 120 2>/dev/null && break
        done
        if [ -f /tmp/clash-core.tar.gz ] && [ -s /tmp/clash-core.tar.gz ]; then
          cd /tmp && tar xzf clash-core.tar.gz 2>/dev/null
          mkdir -p /etc/openclash/core
          cp /tmp/clash* /etc/openclash/core/clash 2>/dev/null
          chmod +x /etc/openclash/core/clash 2>/dev/null
          ok "Clash 核心已安装"
        fi
      fi
    else
      err "无法获取 OpenClash 下载地址"
    fi
  fi
else
  # APK 模式
  if [ "$INSTALL_PW" = "1" ]; then
    info "安装 PassWall..."
    apk add luci-app-passwall luci-i18n-passwall-zh-cn 2>/dev/null && ok "PassWall 安装成功" || err "PassWall 安装失败"
  fi
  if [ "$INSTALL_PW2" = "1" ]; then
    info "安装 PassWall2..."
    apk add luci-app-passwall2 luci-i18n-passwall2-zh-cn 2>/dev/null && ok "PassWall2 安装成功" || err "PassWall2 安装失败"
  fi
  if [ "$INSTALL_OC" = "1" ]; then
    info "安装 OpenClash..."
    OC_APK_URL=$(curl -sL "https://api.github.com/repos/vernesong/OpenClash/releases/latest" --max-time 10 | grep -oE 'https://[^"]+\.apk' | head -1)
    OC_LATEST=$(curl -sL "https://api.github.com/repos/vernesong/OpenClash/releases/latest" --max-time 10 | grep -oE '"tag_name":[^,]+' | cut -d'"' -f4)

    if [ -n "$OC_APK_URL" ]; then
      info "下载 OpenClash $OC_LATEST..."
      # 尝试多个下载方式：直连 → GitHub 代理 → 用户自定义代理
      OC_DOWNLOAD_OK=0
      
      curl -fsSL -o /tmp/luci-app-openclash.apk "$OC_APK_URL" --max-time 60 2>/dev/null && OC_DOWNLOAD_OK=1 || \
      curl -fsSL -o /tmp/luci-app-openclash.apk -x "$HTTP_PROXY" "$OC_APK_URL" --max-time 60 2>/dev/null && OC_DOWNLOAD_OK=1 || \
      curl -fsSL -o /tmp/luci-app-openclash.apk "https://gh-proxy.com/$OC_APK_URL" --max-time 60 2>/dev/null && OC_DOWNLOAD_OK=1 || \
      curl -fsSL -o /tmp/luci-app-openclash.apk "https://ghfast.top/$OC_APK_URL" --max-time 60 2>/dev/null && OC_DOWNLOAD_OK=1 || \
      curl -fsSL -o /tmp/luci-app-openclash.apk -x "$MY_PROXY" "$OC_APK_URL" --max-time 60 2>/dev/null && OC_DOWNLOAD_OK=1
      
      if [ "$OC_DOWNLOAD_OK" = "1" ]; then
        apk add /tmp/luci-app-openclash.apk 2>/dev/null && ok "OpenClash 安装成功" || err "OpenClash APK 安装失败"
      else
        err "OpenClash 下载失败（直连和代理均不可用）"
        info "提示: 如需使用代理，请设置环境变量:"
        info "  export HTTP_PROXY=http://user:pass@host:port"
        info "  然后重新执行脚本"
      fi

      # 下载 Clash 核心（同样多方式）
      OC_CORE_URL=$(curl -sL "https://api.github.com/repos/vernesong/OpenClash/releases/latest" --max-time 10 | grep -oE 'https://[^"]+clash-linux-[^"]+\.tar\.gz' | head -1)
      if [ -n "$OC_CORE_URL" ] && [ "$OC_DOWNLOAD_OK" = "1" ]; then
        info "下载 Clash 核心..."
        for url in "$OC_CORE_URL" \
          "https://gh-proxy.com/$OC_CORE_URL" \
          "https://ghfast.top/$OC_CORE_URL"; do
          curl -fsSL -o /tmp/clash-core.tar.gz "$url" --max-time 120 2>/dev/null && {
            cd /tmp && tar xzf clash-core.tar.gz 2>/dev/null
            mkdir -p /etc/openclash/core
            cp /tmp/clash* /etc/openclash/core/clash 2>/dev/null
            chmod +x /etc/openclash/core/clash 2>/dev/null
            ok "Clash 核心已安装"; break
          }
        done
      fi
    else
      err "无法获取 OpenClash 下载地址"
    fi
  fi

  # 安装后清理
  rm -f /tmp/luci-app-openclash.apk /tmp/clash-core.tar.gz 2>/dev/null
fi

#==============================================
# 6. Geo 数据库
#==============================================
hdr "Geo 数据库"

[ "$PKG_MGR" = "opkg" ] && opkg install geoview v2ray-geoip v2ray-geosite --force-overwrite 2>/dev/null || \
  apk add geoview v2ray-geoip v2ray-geosite 2>/dev/null || true
ok "Geo 数据库已安装"

GEO_DIR=""
[ -d /usr/share/v2ray ] && GEO_DIR="/usr/share/v2ray"
[ -d /usr/share/xray ] && GEO_DIR="/usr/share/xray"
[ -z "$GEO_DIR" ] && { GEO_DIR="/usr/share/v2ray"; mkdir -p "$GEO_DIR"; }

if [ ! -f "$GEO_DIR/geosite.dat" ]; then
  info "手动下载 geosite.dat..."
  for url in \
    "https://testingcf.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat" \
    "https://gcore.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat" \
    "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/geosite.dat"; do
    [ "$(check_url $url)" = "200" ] && {
      curl -sL "$url" -o "$GEO_DIR/geosite.dat" --max-time 120 2>/dev/null
      [ -d /usr/share/xray ] && cp "$GEO_DIR/geosite.dat" /usr/share/xray/geosite.dat 2>/dev/null
      ok "geosite.dat ✓"; break
    }
  done
fi
if [ ! -f "$GEO_DIR/geoip.dat" ]; then
  info "手动下载 geoip.dat..."
  for url in \
    "https://testingcf.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat" \
    "https://gcore.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat" \
    "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/geoip.dat"; do
    [ "$(check_url $url)" = "200" ] && {
      curl -sL "$url" -o "$GEO_DIR/geoip.dat" --max-time 120 2>/dev/null
      [ -d /usr/share/xray ] && cp "$GEO_DIR/geoip.dat" /usr/share/xray/geoip.dat 2>/dev/null
      ok "geoip.dat ✓"; break
    }
  done
fi

#==============================================
# 7. 可选组件（交互）
#==============================================
hdr "可选组件"
echo "是否安装以下可选组件？（输入 y/n）"
echo ""

ask_install() {
  local pkg="$1" desc="$2"
  printf "  %-25s %s [Y/n]: " "$pkg" "$desc"
  read -r ans
  case "$ans" in n|N|no|NO) return 1 ;; *) return 0 ;; esac
}

for comp in "sing-box:Sing-Box 代理核心" \
            "hysteria:Hysteria 2 加速协议" \
            "naiveproxy:NaiveProxy 代理协议" \
            "v2ray-plugin:V2Ray WebSocket 插件" \
            "ipt2socks:IPTables 转 SOCKS"; do
  pkg="${comp%%:*}"
  desc="${comp#*:}"
  if ask_install "$pkg" "$desc"; then
    [ "$PKG_MGR" = "opkg" ] && opkg install "$pkg" --force-overwrite 2>/dev/null && ok "$pkg ✓" || \
      apk add "$pkg" 2>/dev/null && ok "$pkg ✓" || \
      err "$pkg 安装失败"
  else
    info "跳过 $pkg"
  fi
done

#==============================================
# 8. Xray 内核升级
#==============================================
hdr "Xray 内核升级"

CURRENT_XRAY=""
if [ "$PKG_MGR" = "opkg" ]; then
  CURRENT_XRAY=$(opkg status xray-core 2>/dev/null | grep "^Version:" | awk '{print $2}')
else
  # APK: 用 list 获取已安装包的版本
  CURRENT_XRAY=$(apk list --installed xray-core 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
fi

[ -n "$CURRENT_XRAY" ] && ok "当前 Xray: $CURRENT_XRAY" || info "Xray 未安装"

# 获取 PassWall 源里的 Xray 版本
PW_XRAY_VERSION=""
if [ "$SF_OK" = "1" ] && [ "$PKG_MGR" = "opkg" ]; then
  PW_XRAY_VERSION=$(curl -sL "$SF_BASE/passwall_packages/Packages.gz" --max-time 10 | gunzip -c 2>/dev/null | awk '/^Package: xray-core/{found=1} found && /^Version:/{print $2; exit}')
fi

LATEST_XRAY_TAG=$(curl -sL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" --max-time 10 | grep -oE '"tag_name":[^,]+' | cut -d'"' -f4)
LATEST_XRAY_NUM=$(echo "$LATEST_XRAY_TAG" | sed 's/^v//')

[ -n "$PW_XRAY_VERSION" ] && ok "PassWall 源 Xray: $PW_XRAY_VERSION"
[ -n "$LATEST_XRAY_TAG" ] && ok "GitHub 最新: $LATEST_XRAY_TAG"

# 比较版本决定是否需要升级
NEED_UPGRADE=0
if [ -n "$CURRENT_XRAY" ] && [ -n "$PW_XRAY_VERSION" ]; then
  CUR_NUM=$(echo "$CURRENT_XRAY" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  PW_NUM=$(echo "$PW_XRAY_VERSION" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [ "$CUR_NUM" != "$PW_NUM" ] && NEED_UPGRADE=1
fi

if [ "$NEED_UPGRADE" = "0" ] && [ -n "$CURRENT_XRAY" ]; then
  ok "已是最新版"
else
  [ -n "$CURRENT_XRAY" ] && info "升级 Xray ($CURRENT_XRAY → $PW_XRAY_VERSION)..." || info "安装 Xray ($PW_XRAY_VERSION)..."
  
  if [ "$PKG_MGR" = "opkg" ] && [ "$SF_OK" = "1" ]; then
    # OPKG: 从 PassWall 源下载最新 IPK
    XRAY_IPK=$(curl -sL "$SF_BASE/passwall_packages/Packages.gz" --max-time 10 | gunzip -c 2>/dev/null | awk '/^Package: xray-core/{found=1} found && /^Filename:/{print $2; exit}')
    [ -n "$XRAY_IPK" ] && wget -q --no-check-certificate "$SF_BASE/passwall_packages/$XRAY_IPK" -O /tmp/xray-core.ipk 2>/dev/null && {
      opkg install /tmp/xray-core.ipk --force-overwrite 2>/dev/null && ok "Xray 升级成功" || err "Xray 安装失败"
    } || err "Xray 下载失败"
  else
    # APK 模式：直接用 apk add 从 PassWall 源安装最新版
    # APK 源的顺序决定版本，PassWall 源在 customfeeds.list 中优先
    apk add xray-core 2>/dev/null && ok "Xray 升级成功" || err "Xray 升级失败"
  fi
fi

#==============================================
# 9. 升级核心组件
#==============================================
hdr "升级核心组件"
for pkg in chinadns-ng xray-core geoview v2ray-geoip v2ray-geosite; do
  [ "$PKG_MGR" = "opkg" ] && opkg upgrade "$pkg" --force-overwrite 2>/dev/null || \
    apk upgrade "$pkg" 2>/dev/null || true
done

#==============================================
# 10. 结果汇总
#==============================================
echo ""
echo "======================================================"
ok "安装完成！"
echo "======================================================"
echo ""

for comp in "luci-app-passwall" "luci-app-passwall2" "luci-app-openclash" "geoview" "chinadns-ng" "xray-core" "v2ray-geosite" "v2ray-geoip"; do
  if [ "$PKG_MGR" = "opkg" ]; then
    ver=$(opkg status "$comp" 2>/dev/null | grep "^Version:" | awk '{print $2}')
  else
    ver=$(apk info "$comp" 2>/dev/null | grep -i version | head -1 | awk '{print $NF}')
  fi
  [ -n "$ver" ] && ok "$comp: $ver"
done

echo ""
echo "系统: $SYS_DESC | $SYS_RELEASE | $SYS_ARCH | $PKG_MGR"
echo ""
echo "规则更新地址:"
echo "  GFW:  https://testingcf.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/gfw.txt"
echo "  CHN:  https://ispip.clang.cn/all_cn.txt"
echo "  CHN6: https://ispip.clang.cn/all_cn_ipv6.txt"
echo ""

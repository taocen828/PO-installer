#!/bin/sh
#==============================================
# PassWall 通用一键安装脚本
# 支持 OPKG (OpenWrt ≤24.10) 和 APK (OpenWrt ≥25.12)
# 自动检测架构、系统版本、源连通性
#==============================================
RED='\e[31m'; GREEN='\e[32m'; YELLOW='\e[33m'; BLUE='\e[34m'; NC='\e[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${YELLOW}[→]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
hdr()  { echo -e "${BLUE}━━━ $1 ━━━${NC}"; }
check_url() { curl -sL -o /dev/null -w "%{http_code}" "$1" --max-time 8 2>/dev/null; }

#==============================================
# 1. 系统检测
#==============================================
hdr "系统检测"

# 检测包管理器
if command -v apk >/dev/null 2>&1; then
  PKG_MGR="apk"
  ok "包管理器: APK (OpenWrt 25.12+ / 快照版)"
elif command -v opkg >/dev/null 2>&1; then
  PKG_MGR="opkg"
  ok "包管理器: OPKG (OpenWrt 24.10 及以下)"
else
  err "无法识别包管理器 (既不是 apk 也不是 opkg)"
  exit 1
fi

# 检测架构
SYS_ARCH=""
if [ "$PKG_MGR" = "opkg" ]; then
  SYS_ARCH=$(opkg print-architecture 2>/dev/null | grep -oE 'mipsel_24kc|aarch64_cortex-a53|aarch64_cortex-a72|aarch64_generic|x86_64|arm_cortex-a7_neon-vfpv4|mips_24kc|arm_cortex-a9_vfpv3-d16|arm_cortex-a15_neon-vfpv4|i386_pentium4|mipsel_74kc|x86_generic' | head -1)
  [ -z "$SYS_ARCH" ] && SYS_ARCH=$(opkg print-architecture 2>/dev/null | head -2 | tail -1 | awk '{print $2}')
elif [ "$PKG_MGR" = "apk" ]; then
  SYS_ARCH=$(apk info --print-arch 2>/dev/null)
  [ -z "$SYS_ARCH" ] && SYS_ARCH=$(cat /etc/apk/arch 2>/dev/null)
  [ -z "$SYS_ARCH" ] && SYS_ARCH=$(uname -m 2>/dev/null | sed 's/mips/mipsel_24kc/')  # 保底
fi
[ -z "$SYS_ARCH" ] && { err "无法检测架构"; exit 1; }
ok "CPU 架构: $SYS_ARCH"

# 读取系统版本
. /etc/openwrt_release 2>/dev/null || true
SYS_RELEASE="$DISTRIB_RELEASE"
SYS_DESC="$DISTRIB_DESCRIPTION"
[ -z "$SYS_RELEASE" ] && SYS_RELEASE=$(cat /etc/version 2>/dev/null | head -1)
[ -z "$SYS_RELEASE" ] && SYS_RELEASE="unknown"
ok "系统: $SYS_DESC ($SYS_RELEASE)"

# 映射版本号
PW_VER=$(echo "$SYS_RELEASE" | sed -n 's/^\([0-9]*\.[0-9]*\).*/\1/p')
[ -z "$PW_VER" ] && PW_VER="23.05"
echo "$SYS_RELEASE" | grep -qiE "istore|immortalwrt|koolshare|lede" && PW_VER="23.05"
echo "$PW_VER" | grep -q "^22" && PW_VER="22.03"
echo "$PW_VER" | grep -q "^23" && PW_VER="23.05"
echo "$PW_VER" | grep -q "^24" && PW_VER="24.10"
echo "$PW_VER" | grep -qE "^25|^26" && PW_VER="snapshots"  # 25.x+ 用快照版

# APK 模式特殊处理：25.x 稳定版可能还没发布，fallback 到 snapshots
[ "$PKG_MGR" = "apk" ] && PW_VER="snapshots"

ok "PassWall 源版本: $PW_VER"

#==============================================
# 2. 源检测
#==============================================
hdr "源连通性检测"

SF_OK=0; OW_OK=0; OW_USE=""

# PassWall 源 (SourceForge)
if [ "$PKG_MGR" = "opkg" ]; then
  SF_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-$PW_VER/$SYS_ARCH"
  SF_TEST="$SF_BASE/passwall_luci/Packages.gz"
  SF_SUFFIX="/Packages.gz"
else
  # APK 模式
  if [ "$PW_VER" = "snapshots" ]; then
    SF_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/snapshots/packages/$SYS_ARCH"
  else
    SF_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-$PW_VER/$SYS_ARCH"
  fi
  SF_TEST="$SF_BASE/passwall_luci/packages.adb"
  SF_SUFFIX="/packages.adb"
fi

[ "$(check_url $SF_TEST)" = "200" ] && SF_OK=1 && ok "PassWall 源 ✓" || err "PassWall 源不可用"

# OpenWrt 依赖源 — 根据包管理器选版本
if [ "$PKG_MGR" = "opkg" ]; then
  case "$PW_VER" in
    22.03) OW_VER="22.03.7" ;;
    23.05) OW_VER="23.05.5" ;;
    24.10) OW_VER="24.10.0" ;;
    snapshots) OW_VER="snapshots" ;;
    *)     OW_VER="23.05.5" ;;
  esac

  if [ "$OW_VER" = "snapshots" ]; then
    OW_BASE="https://downloads.openwrt.org/snapshots/packages/$SYS_ARCH"
    OW_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/openwrt/snapshots/packages/$SYS_ARCH"
  else
    OW_BASE="https://downloads.openwrt.org/releases/$OW_VER/packages/$SYS_ARCH"
    OW_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/$OW_VER/packages/$SYS_ARCH"
  fi

  for feed in base packages luci; do
    [ "$(check_url $OW_BASE/$feed/Packages.gz)" = "200" ] && OW_OK=1 || { OW_OK=0; break; }
  done
  [ "$OW_OK" = "1" ] && OW_USE=$OW_BASE && ok "OpenWrt 官方源 ✓" || {
    for feed in base packages luci; do
      [ "$(check_url $OW_MIRROR/$feed/Packages.gz)" = "200" ] && OW_OK=1 || { OW_OK=0; break; }
    done
    [ "$OW_OK" = "1" ] && OW_USE=$OW_MIRROR && ok "OpenWrt 清华镜像 ✓"
  }
  # 其他版本保底
  if [ "$OW_OK" = "0" ]; then
    for try_ver in "23.05.5" "22.03.7" "24.10.0"; do
      try_url="https://downloads.openwrt.org/releases/$try_ver/packages/$SYS_ARCH"
      for feed in base packages luci; do
        [ "$(check_url $try_url/$feed/Packages.gz)" = "200" ] && OW_OK=1 || { OW_OK=0; break; }
      done
      [ "$OW_OK" = "1" ] && { OW_USE=$try_url; OW_VER=$try_ver; ok "OpenWrt $try_ver 源 ✓"; break; }
    done
  fi
  [ "$OW_OK" = "0" ] && err "所有 OpenWrt OPKG 源不可用"
else
  # APK 模式的 OpenWrt 源 — 快照版
  OW_BASE="https://downloads.openwrt.org/snapshots/packages/$SYS_ARCH"
  OW_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/openwrt/snapshots/packages/$SYS_ARCH"
  [ "$(check_url $OW_BASE/base/Packages.adb)" = "200" ] && OW_OK=1 && OW_USE=$OW_BASE && ok "OpenWrt 快照源 ✓" || {
    [ "$(check_url $OW_MIRROR/base/Packages.adb)" = "200" ] && OW_OK=1 && OW_USE=$OW_MIRROR && ok "OpenWrt 清华快照源 ✓"
  }
  [ "$OW_OK" = "0" ] && err "所有 OpenWrt APK 源不可用"
fi

#==============================================
# 3. 配置源
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
  ok "系统源可用，跳过额外配置"
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
    fi
    if [ "$OW_OK" = "1" ]; then
      for feed in base packages luci; do
        echo "src/gz openwrt_$feed $OW_USE/$feed" >> /etc/opkg/customfeeds.conf
      done
    fi
    opkg update || { err "opkg update 失败"; exit 1; }
  else
    # APK 模式
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
# 4. 安装 PassWall
#==============================================
hdr "安装 PassWall"

if [ "$PKG_MGR" = "opkg" ]; then
  if [ "$SYS_SOURCE_OK" != "1" ] && [ "$OW_OK" = "1" ]; then
    info "补装依赖..."
    opkg install coreutils-timeout lyaml coreutils-base64 coreutils-nohup --force-overwrite 2>/dev/null || true
  fi
  if opkg install luci-app-passwall luci-i18n-passwall-zh-cn --force-overwrite 2>/dev/null; then
    ok "PassWall 安装成功"
  else
    err "标准安装失败，尝试强制安装..."
    opkg install luci-app-passwall luci-i18n-passwall-zh-cn --force-overwrite --force-depends 2>/dev/null && ok "强制安装成功" || {
      err "强制安装也失败，尝试手动下载 IPK..."
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
else
  # APK 模式
  apk add luci-app-passwall luci-i18n-passwall-zh-cn 2>/dev/null && ok "PassWall 安装成功" || {
    err "APK 安装失败，尝试强制..."
    apk add --force luci-app-passwall luci-i18n-passwall-zh-cn 2>/dev/null && ok "强制安装成功"
  }
fi

#==============================================
# 5. Geo 数据库
#==============================================
hdr "Geo 数据库"

if [ "$PKG_MGR" = "opkg" ]; then
  opkg install geoview v2ray-geoip v2ray-geosite --force-overwrite 2>/dev/null && ok "Geo 数据库已安装" || true
else
  apk add geoview v2ray-geoip v2ray-geosite 2>/dev/null && ok "Geo 数据库已安装" || true
fi

# 如果 geo 文件缺失，手动下载
GEO_DIR=""
[ -d /usr/share/v2ray ] && GEO_DIR="/usr/share/v2ray"
[ -d /usr/share/xray ] && GEO_DIR="/usr/share/xray"
[ -z "$GEO_DIR" ] && GEO_DIR="/usr/share/v2ray" && mkdir -p "$GEO_DIR"

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
# 6. 可选组件
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
# 7. 升级核心组件
#==============================================
hdr "升级到最新版"
for pkg in chinadns-ng xray-core geoview v2ray-geoip v2ray-geosite; do
  [ "$PKG_MGR" = "opkg" ] && opkg upgrade "$pkg" --force-overwrite 2>/dev/null || \
    apk upgrade "$pkg" 2>/dev/null || true
done

#==============================================
# 8. 结果汇总
#==============================================
echo ""
echo "======================================================"
ok "PassWall 安装完成！"
echo "======================================================"
echo ""

for comp in "luci-app-passwall" "geoview" "chinadns-ng" "xray-core" "v2ray-geosite" "v2ray-geoip"; do
  if [ "$PKG_MGR" = "opkg" ]; then
    ver=$(opkg status "$comp" 2>/dev/null | grep "^Version:" | awk '{print $2}')
  else
    ver=$(apk info "$comp" 2>/dev/null | grep -i version | head -1 | awk '{print $NF}')
  fi
  [ -n "$ver" ] && ok "$comp: $ver" || {
    # 再检查一次文件是否存在
    [ -f "/usr/share/$comp" ] && ok "$comp: 已安装" || err "$comp: 未安装"
  }
done

echo ""
echo "系统: $SYS_DESC | $SYS_RELEASE | $SYS_ARCH | $PKG_MGR"
echo ""
echo "规则更新地址（PassWall → 规则管理中设置）:"
echo "  GFW列表:   https://testingcf.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/gfw.txt"
echo "  CHNRoute:  https://ispip.clang.cn/all_cn.txt"
echo "  CHNRoute6: https://ispip.clang.cn/all_cn_ipv6.txt"
echo ""
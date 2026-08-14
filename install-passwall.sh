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
# 用"能否运行"判断而非文件头检测（ELF 二进制/symlink 会误判）
WGET_FIXED=0
if ! command -v wget >/dev/null 2>&1 || ! wget --version >/dev/null 2>&1; then
  if [ -w /usr/bin ]; then
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
    ok "修复 wget（不可用，替换为 curl 包装器）"
  else
    info "wget 不可用且 /usr/bin 只读，跳过（后续使用 curl）"
  fi
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
  # 通用提取：任意架构（不限于白名单），取第一个非 all/noarch/any 的架构
  SYS_ARCH=$(opkg print-architecture 2>/dev/null | awk '{print $2}' | grep -vE '^(all|noarch|any)$' | head -1)
else
  SYS_ARCH=$(apk info --print-arch 2>/dev/null)
  [ -z "$SYS_ARCH" ] && SYS_ARCH=$(cat /etc/apk/arch 2>/dev/null)
  [ -z "$SYS_ARCH" ] && SYS_ARCH=$(uname -m | sed 's/mips/mipsel_24kc/')
fi
[ -z "$SYS_ARCH" ] && { err "无法检测架构"; exit 1; }
ok "CPU 架构: $SYS_ARCH"

if [ -r /etc/openwrt_release ]; then . /etc/openwrt_release; fi
SYS_RELEASE="$DISTRIB_RELEASE"; SYS_DESC="$DISTRIB_DESCRIPTION"
[ -z "$SYS_RELEASE" ] && SYS_RELEASE=$(cat /etc/version 2>/dev/null | head -1)
[ -z "$SYS_RELEASE" ] && SYS_RELEASE="unknown"
ok "系统: $SYS_DESC ($SYS_RELEASE)"

PW_VER=$(echo "$SYS_RELEASE" | sed -n 's/^\(2[0-9]\.[0-9]*\).*/\1/p')
[ -z "$PW_VER" ] && PW_VER="23.05"
echo "$SYS_RELEASE" | grep -qiE "istore|immortalwrt|koolshare|lede" && PW_VER="23.05"
echo "$PW_VER" | grep -q "^22" && PW_VER="22.03"
echo "$PW_VER" | grep -q "^23" && PW_VER="23.05"
echo "$PW_VER" | grep -q "^24" && PW_VER="24.10"
echo "$PW_VER" | grep -qE "^2[5-9]|^3" && PW_VER="snapshots"
[ "$PKG_MGR" = "apk" ] && PW_VER="snapshots"
ok "源版本: $PW_VER"

# 架构 → 目标平台候选映射（完整 31 架构，数据来自官方 22.03.7 targets/Packages 索引）
arch_to_targets() {
  case "$1" in
    aarch64_cortex-a53)   echo "armvirt/64 bcm27xx/bcm2710 bcm4908/generic mediatek/mt7622 mvebu/cortexa53 sunxi/cortexa53" ;;
    aarch64_cortex-a72)   echo "bcm27xx/bcm2711 mvebu/cortexa72" ;;
    aarch64_generic)      echo "octeontx/generic rockchip/armv8" ;;
    arc_archs)            echo "archs38/generic" ;;
    arm_arm1176jzf-s_vfp) echo "bcm27xx/bcm2708" ;;
    arm_arm926ej-s)       echo "at91/sam9x mxs/generic" ;;
    arm_cortex-a15_neon-vfpv4) echo "armvirt/32 ipq806x/generic" ;;
    arm_cortex-a5_vfpv4)  echo "at91/sama5" ;;
    arm_cortex-a7)        echo "mediatek/mt7629" ;;
    arm_cortex-a7_neon-vfpv4) echo "bcm27xx/bcm2709 imx/cortexa7 ipq40xx/generic ipq40xx/mikrotik layerscape/armv7 mediatek/mt7623 sunxi/cortexa7" ;;
    arm_cortex-a7_vfpv4)  echo "at91/sama7" ;;
    arm_cortex-a8_vfpv3)  echo "omap/generic sunxi/cortexa8" ;;
    arm_cortex-a9)        echo "bcm53xx/generic" ;;
    arm_cortex-a9_neon)   echo "imx/cortexa9 zynq/generic" ;;
    arm_cortex-a9_vfpv3-d16) echo "mvebu/cortexa9 tegra/generic" ;;
    arm_fa526)            echo "gemini/generic" ;;
    arm_mpcore)           echo "oxnas/ox820" ;;
    arm_xscale)           echo "kirkwood/generic" ;;
    i386_pentium-mmx)     echo "x86/geode x86/legacy" ;;
    i386_pentium4)        echo "x86/generic" ;;
    mips64_octeonplus)    echo "octeon/generic" ;;
    mips_24kc)            echo "ath79/generic ath79/mikrotik ath79/nand ath79/tiny lantiq/xrx200 lantiq/xway malta/be realtek/rtl839x realtek/rtl930x realtek/rtl931x" ;;
    mips_4kec)            echo "realtek/rtl838x" ;;
    mips_mips32)          echo "ath25/generic bcm63xx/generic bcm63xx/smp lantiq/ase" ;;
    mipsel_24kc)          echo "ramips/mt7620 ramips/mt7621 ramips/mt76x8 ramips/rt288x ramips/rt305x" ;;
    mipsel_24kc_24kf)     echo "pistachio/generic" ;;
    mipsel_74kc)          echo "bcm47xx/mips74k ramips/rt3883" ;;
    mipsel_mips32)        echo "bcm47xx/generic bcm47xx/legacy" ;;
    powerpc_464fp)        echo "apm821xx/nand apm821xx/sata" ;;
    powerpc_8540)         echo "mpc85xx/p1010 mpc85xx/p1020 mpc85xx/p2020" ;;
    x86_64)               echo "x86/64" ;;
    *)                    echo "" ;;
  esac
}

# 本地目标平台检测（不联网）：DISTRIB_TARGET → distfeeds URL → 架构映射
SYS_TARGET="$DISTRIB_TARGET"
[ -z "$SYS_TARGET" ] && SYS_TARGET=$(grep -hoE 'targets/[a-z0-9]+/[a-z0-9]+' /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf 2>/dev/null | head -1 | cut -d/ -f2-)
[ -z "$SYS_TARGET" ] && SYS_TARGET=$(arch_to_targets "$SYS_ARCH" | awk '{print $1}')
ARCH_TARGETS=$(arch_to_targets "$SYS_ARCH")
[ -n "$SYS_TARGET" ] && ok "目标平台: $SYS_TARGET" || info "目标平台: 未知（仅能检测 packages 源）"

# 内核版本
KERNEL_VER=$(uname -r 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
[ -n "$KERNEL_VER" ] && ok "内核版本: $KERNEL_VER"

# 版本系列链（按内核主线；4.14→19.07, 5.4→21.02, 6.x 兜底 24.10/snapshots）
case "$KERNEL_VER" in
  4.14.*) SERIES_CHAIN="19.07" ;;
  5.4.*)  SERIES_CHAIN="21.02" ;;
  5.10.*) SERIES_CHAIN="22.03" ;;
  5.15.*) SERIES_CHAIN="23.05" ;;
  6.1.*|6.6.*|6.12.*) SERIES_CHAIN="24.10" ;;
  6.*)    SERIES_CHAIN="24.10 snapshots" ;;
  *)      SERIES_CHAIN="snapshots" ;;
esac

#==============================================
# 2. 源连通性检测
#==============================================
hdr "源连通性检测"
SF_OK=0; OW_OK=0; OW_USE=""

# 列出镜像上某系列的所有小版本（从新到旧）
list_series_vers() {
  curl -sL --max-time 10 "$1/releases/" 2>/dev/null | grep -oE "$2\.[0-9]+/" | tr -d '/' | sort -uVr
}

# 动态探测精确源版本 + 目标平台：用内核版本精确匹配官方 manifest
# 返回: OW_VER 精确版本号, SYS_TARGET 精确 target/subtarget
probe_ow_ver() {
  local MIR="$1" v t mf kv
  OW_VER=""
  # 1) DISTRIB_RELEASE 直接给出（最准）
  OW_VER=$(echo "$SYS_RELEASE" | grep -oE '^(19\.07|21\.02|22\.03|23\.05|24\.10)\.[0-9]+' | head -1)
  [ -n "$OW_VER" ] && return 0
  # 2) 遍历候选平台 × 系列链，manifest 内核精确匹配（覆盖所有内核所有硬件）
  #    候选平台: 本地检测 target 优先，然后架构映射全列表
  local cands="$SYS_TARGET $ARCH_TARGETS"
  for t in $cands; do
    [ -z "$t" ] && continue
    for s in $SERIES_CHAIN; do
      for v in $(list_series_vers "$MIR" "$s"); do
        mf="$MIR/releases/$v/targets/${t%/*}/${t#*/}/openwrt-$v-${t%/*}-${t#*/}.manifest"
        kv=$(curl -sL --max-time 5 "$mf" 2>/dev/null | sed -n 's/^kernel - \([0-9.]*\)-.*/\1/p' | head -1)
        [ "$kv" = "$KERNEL_VER" ] && { OW_VER="$v"; SYS_TARGET="$t"; return 0; }
      done
    done
  done
  # 3) 兜底：系列链最新版本
  for s in $SERIES_CHAIN; do
    OW_VER=$(list_series_vers "$MIR" "$s" | head -1)
    [ -n "$OW_VER" ] && break
  done
  [ -n "$OW_VER" ] && return 0
  return 1
}

# 候选 OpenWrt 镜像（阿里云 → 清华 → 官方），先确定可用主镜像
MIR_BASES="https://mirrors.aliyun.com/openwrt https://mirrors.tuna.tsinghua.edu.cn/openwrt https://downloads.openwrt.org"
MIR_USE=""
for m in $MIR_BASES; do
  [ "$(check_url $m/releases/)" = "200" ] && { MIR_USE=$m; break; }
done
if [ -n "$MIR_USE" ]; then
  ok "OpenWrt 镜像 ✓ ($MIR_USE)"
  probe_ow_ver "$MIR_USE"
  [ -n "$OW_VER" ] && ok "匹配源版本: $OW_VER (内核 $KERNEL_VER)" || err "无法确定源版本"
else
  err "所有 OpenWrt 镜像不可用"
fi

# PassWall 源版本：跟随探测到的精确版本（22.03/23.05/24.10），快照用 snapshots
SF_PW_VER="$PW_VER"
[ -n "$OW_VER" ] && SF_PW_VER=$(echo "$OW_VER" | cut -d. -f1-2)
[ "$PKG_MGR" = "opkg" ] && SF_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-$SF_PW_VER/$SYS_ARCH" || SF_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/snapshots/packages/$SYS_ARCH"
SF_TEST="$SF_BASE/passwall_luci/Packages.gz"
[ "$PKG_MGR" != "opkg" ] && SF_TEST="$SF_BASE/passwall_luci/packages.adb"
[ "$(check_url $SF_TEST)" = "200" ] && SF_OK=1 && ok "PassWall 源 ✓ (SourceForge)" || err "PassWall 源不可用（SourceForge 国外直连失败）"

# 国内 PassWall 备用源：immortalwrt 官方源自带 passwall 全家桶（luci-app-passwall/xray-core/sing-box 等），
# 且国内有完整镜像（上海交大/VSean）。外网不通时自动降级使用。
IW_OK=0; IW_USE=""; IW_VER=""
if [ "$SF_OK" != "1" ] && [ "$PKG_MGR" = "opkg" ]; then
  info "SourceForge 不通，探测国内 immortalwrt 镜像（自带 PassWall 包）..."
  for iw in "https://mirror.sjtu.edu.cn/immortalwrt" "https://mirrors.vsean.net/immortalwrt" "https://downloads.immortalwrt.org"; do
    [ "$(check_url $iw/releases/23.05.4/packages/$SYS_ARCH/luci/Packages.gz)" != "200" ] && continue
    IW_USE=$iw; IW_VER="23.05.4"
    # 确认 luci feed 有 passwall（.gz 解压后 grep 包名）
    if curl -sL --max-time 8 "$iw/releases/$IW_VER/packages/$SYS_ARCH/luci/Packages.gz" 2>/dev/null | gzip -dc 2>/dev/null | grep -q "luci-app-passwall"; then
      IW_OK=1
      ok "国内 PassWall 源 ✓ (immortalwrt 镜像: $IW_USE)"
      break
    fi
  done
  [ "$IW_OK" = "0" ] && err "国内 immortalwrt 镜像也不可用"
fi

# OpenWrt 源验证：基于探测到的 OW_VER + 主镜像，验证 base/luci + targets(kmod)
# 24.10+ 官方已切换 APK，源索引文件为 packages.adb；其余为 Packages.gz
PKG_FILE="Packages.gz"
[ "$PW_VER" = "24.10" -o "$PW_VER" = "snapshots" ] && PKG_FILE="packages.adb"
OW_OK=0
if [ -n "$MIR_USE" ] && [ -n "$OW_VER" ]; then
  if [ "$PW_VER" = "snapshots" ]; then
    OW_BASE="$MIR_USE/snapshots"
  else
    OW_BASE="$MIR_USE/releases/$OW_VER"
  fi
  OW_OK=1
  for feed in base luci; do
    [ "$(check_url $OW_BASE/packages/$SYS_ARCH/$feed/$PKG_FILE)" != "200" ] && { OW_OK=0; break; }
  done
  # targets 源（kmod 所在目录）也需可用
  if [ "$OW_OK" = "1" ] && [ -n "$SYS_TARGET" ]; then
    [ "$(check_url $OW_BASE/targets/$SYS_TARGET/packages/$PKG_FILE)" != "200" ] && OW_OK=0
  fi
  [ "$OW_OK" = "1" ] && OW_USE=$OW_BASE && ok "OpenWrt 源 ✓ ($OW_BASE)"
fi
[ "$OW_OK" = "0" ] && err "OpenWrt 源不可用（镜像或版本探测失败）"

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
  opkg update >/dev/null 2>&1 && SYS_SOURCE_OK=1
else
  apk update >/dev/null 2>&1 && SYS_SOURCE_OK=1
fi

if [ "$SYS_SOURCE_OK" = "1" ]; then
  ok "系统源可用"
else
  err "系统源不可用，配置 OpenWrt 镜像源..."
  if [ "$PKG_MGR" = "opkg" ]; then
    [ -f /etc/opkg/distfeeds.conf ] && sed -i 's/^/#/' /etc/opkg/distfeeds.conf
    if [ -n "$OW_USE" ]; then
      { echo "# PO-installer 自动配置 (OpenWrt $OW_VER / $SYS_ARCH / $SYS_TARGET)"
        if [ -n "$SYS_TARGET" ]; then
          echo "src/gz openwrt_core $OW_USE/targets/$SYS_TARGET/packages"
        fi
        echo "src/gz openwrt_base $OW_USE/packages/$SYS_ARCH/base"
        echo "src/gz openwrt_luci $OW_USE/packages/$SYS_ARCH/luci"
        echo "src/gz openwrt_packages $OW_USE/packages/$SYS_ARCH/packages"
        echo "src/gz openwrt_routing $OW_USE/packages/$SYS_ARCH/routing"
        echo "src/gz openwrt_telephony $OW_USE/packages/$SYS_ARCH/telephony"
      } > /etc/opkg/customfeeds.conf
      ok "已配置 OpenWrt 镜像源 ($OW_USE)"
    fi
  else
    [ -f /etc/apk/repositories.d/distfeeds.list ] && sed -i 's/^/#/' /etc/apk/repositories.d/distfeeds.list 2>/dev/null
    if [ -n "$OW_USE" ]; then
      { echo "$OW_USE/packages/$SYS_ARCH/base/packages.adb"
        echo "$OW_USE/packages/$SYS_ARCH/luci/packages.adb"
        echo "$OW_USE/packages/$SYS_ARCH/packages/packages.adb"
        echo "$OW_USE/packages/$SYS_ARCH/routing/packages.adb"
        echo "$OW_USE/packages/$SYS_ARCH/telephony/packages.adb"
        if [ -n "$SYS_TARGET" ]; then
          echo "$OW_USE/targets/$SYS_TARGET/packages/packages.adb"
        fi
      } > /etc/apk/repositories.d/customfeeds.list
      ok "已配置 OpenWrt 镜像源 ($OW_USE)"
    fi
  fi
  # 重新验证源
  if [ "$PKG_MGR" = "opkg" ]; then
    opkg update >/dev/null 2>&1 && ok "源更新成功" || err "源更新失败，请检查网络"
  else
    apk update >/dev/null 2>&1 && ok "源更新成功" || err "源更新失败，请检查网络"
  fi
fi

# 自编译固件提示（Kiddin'/immortalwrt 等：kmod 内核模块可能不匹配官方源）
echo "$SYS_DESC" | grep -qiE "kiddin|immortalwrt|koolshare|lede|self" && \
  info "提示: 自编译固件 ($SYS_DESC) 的 kmod 内核模块可能不匹配官方源，普通软件包不受影响"

# 添加 PassWall 源（仅安装 PassWall/PassWall2 时需要）
# 降级链: SourceForge 官方 → immortalwrt 国内镜像（外网不通时）
if [ "$INSTALL_PW" = "1" -o "$INSTALL_PW2" = "1" ]; then
  if [ "$SF_OK" = "1" ]; then
    info "添加 PassWall 源 (SourceForge)..."
    if [ "$PKG_MGR" = "opkg" ]; then
      wget -q --no-check-certificate -O /tmp/ipk.pub https://master.dl.sourceforge.net/project/openwrt-passwall-build/ipk.pub 2>/dev/null || true
      opkg-key add /tmp/ipk.pub 2>/dev/null || true
      for feed in passwall_luci passwall_packages passwall2; do
        echo "src/gz $feed $SF_BASE/$feed" >> /etc/opkg/customfeeds.conf
      done
      opkg update >/dev/null 2>&1 || true
      ok "源配置完成 (SourceForge)"
    else
      for feed in passwall_luci passwall_packages passwall2; do
        echo "$SF_BASE/$feed/packages.adb" >> /etc/apk/repositories.d/customfeeds.list
      done
      apk update >/dev/null 2>&1 || true
      ok "源配置完成 (SourceForge)"
    fi
  elif [ "$IW_OK" = "1" ]; then
    info "使用国内 immortalwrt 镜像作为 PassWall 源..."
    info "说明: PassWall 包从 immortalwrt 官方源获取，kmod 依赖仍走 OpenWrt 官方源，外网不通也能装"
    if [ "$PKG_MGR" = "opkg" ]; then
      { echo "src/gz passwall_luci $IW_USE/releases/$IW_VER/packages/$SYS_ARCH/luci"
        echo "src/gz passwall_packages $IW_USE/releases/$IW_VER/packages/$SYS_ARCH/packages"
      } >> /etc/opkg/customfeeds.conf
      opkg update >/dev/null 2>&1 || true
      ok "源配置完成 (immortalwrt $IW_VER)"
    fi
  else
    err "PassWall 源不可用：SourceForge 与国内镜像均无法连接，PassWall 无法安装（OpenClash 不受影响）"
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
    opkg install "$pkg" --force-downgrade --force-overwrite --force-depends 2>&1 | grep -v "^Configuring\|^\.\.\.$" || true
    return 0
  fi
  apk add --allow-untrusted --force-broken-world "$pkg" 2>&1 | grep -v "^WARNING.*opening" || true
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
  if check_installed "$pkg"; then
    local ver=$(get_version "$pkg")
    local repo_ver=$(get_repo_version "$pkg")
    if [ -n "$repo_ver" ] && [ "$ver" != "$repo_ver" ]; then
      info "$desc 已安装 ($ver)，源中有新版本 ($repo_ver)..."
      apk_install "$pkg"
      local nver=$(get_version "$pkg")
      [ "$ver" != "$nver" ] && ok "$desc: $ver → $nver ✓" || ok "$desc ($nver) ✓"
    else
      ok "$desc ($ver) ✓"
    fi
  else
    info "安装 $desc..."
    apk_install "$pkg"
    check_installed "$pkg" && ok "$desc $(get_version $pkg) ✓" || err "$desc 安装失败"
  fi
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
# PassWall2（注意: 国内 immortalwrt 源不含 PassWall2，仅 SourceForge 有）
if [ "$INSTALL_PW2" = "1" ]; then
  if [ "$SF_OK" = "1" ]; then
    pkginstall "luci-app-passwall2" "PassWall2" && pkginstall "luci-i18n-passwall2-zh-cn" "PassWall2 中文包" && [ "$INSTALL_PW" != "1" ] && pkginstall "xray-core" "Xray 内核"
  else
    info "跳过 PassWall2: 当前 PassWall 源为国内 immortalwrt 镜像，不含 PassWall2 包（PassWall 经典版不受影响）"
    [ "$INSTALL_PW" != "1" ] && pkginstall "xray-core" "Xray 内核"
  fi
fi

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
                      if [ "$PKG_MGR" = "opkg" ]; then
                        opkg install /tmp/luci-app-openclash.ipk --force-downgrade --force-overwrite --force-depends 2>&1 | grep -v "^Configuring\|^\.\.\.$" || true
                      else
                        apk add --allow-untrusted /tmp/luci-app-openclash.ipk 2>&1 | grep -v "^WARNING.*opening" || true
                      fi
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
                    if [ "$PKG_MGR" = "opkg" ]; then
                      opkg install /tmp/luci-app-openclash.ipk --force-downgrade --force-overwrite --force-depends 2>&1 | grep -v "^Configuring\|^\.\.\.$" || true
                    else
                      apk add --allow-untrusted /tmp/luci-app-openclash.ipk 2>&1 | grep -v "^WARNING.*opening" || true
                    fi
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
  for pkg in geoview v2ray-geoip v2ray-geosite; do
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

# 自动清理
THIS_SCRIPT=$(readlink -f "$0" 2>/dev/null || echo "$0")
case "$THIS_SCRIPT" in
  /tmp/install-passwall.sh|/tmp/install.sh|/tmp/*.sh)
    rm -f "$THIS_SCRIPT" 2>/dev/null
    ;;
esac
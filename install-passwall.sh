#!/bin/sh
#==============================================
# PO-installer - PassWall / PassWall2 / OpenClash 一键安装
# 支持 OPKG (OpenWrt ≤24.10) 和 APK (OpenWrt ≥25.12)
# VERSION: 20260903.1 (版本号改为日期+当日次数，每次推送同步更新)
#==============================================
VERSION="20260903.1"
RED='\e[31m'; GREEN='\e[32m'; YELLOW='\e[33m'; BLUE='\e[34m'; NC='\e[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${YELLOW}[→]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
hdr()  { echo -e "${BLUE}━━━ $1 ━━━${NC}"; }
# 检查 URL 可达性: 优先 curl(Range 只取1KB省流量), curl 不可用回退 wget
# 206(Partial Content)=成功归一化为200; 000/空=DNS失败/超时/无curl, 输出诊断
check_url() {
  local code url="$1"
  if command -v curl >/dev/null 2>&1; then
    code=$(curl -sL -o /dev/null -r 0-1024 -w "%{http_code}" "$url" --max-time 8 2>/dev/null)
  elif command -v wget >/dev/null 2>&1; then
    code=$(wget -q --spider --timeout=8 -O /dev/null "$url" 2>/dev/null; echo $?)
    [ "$code" = "0" ] && code="200" || code="000"
  else
    echo "  [探测] 无 curl/wget 可用!" >&2
    echo "000"; return
  fi
  # 206=Range 成功；SourceForge 常返回 301/302/303/307/308 跳转，也算可达
  case "$code" in
    206|301|302|303|307|308) code="200" ;;
  esac
  if [ "$code" != "200" ]; then
    if [ -z "$code" ]; then
      echo "  [探测] $url → 无响应(可能无curl或超时)" >&2
    elif [ "$code" = "000" ]; then
      echo "  [探测] $url → 连接失败(DNS/超时/被墙)" >&2
    else
      echo "  [探测] $url → HTTP $code" >&2
    fi
  fi
  echo "$code"
}

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
echo " PO-installer - PassWall/OpenClash 一键安装 (v$VERSION)"
echo "============================================"
echo ""
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
# 优先 OPKG：部分第三方固件/环境同时存在 apk-tools 2.x (Alpine 风格) 和 opkg，
# Alpine apk 不支持 OpenWrt packages.adb，会把 packages.adb 当目录拼 APKINDEX.tar.gz。
# 因此只要 opkg 存在就优先用 opkg；只有无 opkg 时才走 OpenWrt APK。
if command -v opkg >/dev/null 2>&1; then
  PKG_MGR="opkg"; ok "包管理器: OPKG"
elif command -v apk >/dev/null 2>&1; then
  APK_VER_LINE=$(apk --version 2>/dev/null | head -1)
  # OpenWrt 新版 apk 支持 packages.adb；Alpine/旧 apk-tools 2.x 不支持，直接拦截
  if echo "$APK_VER_LINE" | grep -qE 'apk-tools 2\.'; then
    err "检测到 Alpine/旧版 apk-tools ($APK_VER_LINE)，不支持 OpenWrt packages.adb 源"
    err "该系统未发现 opkg，无法安全安装 PassWall/OpenClash"
    exit 1
  fi
  PKG_MGR="apk"; ok "包管理器: APK (OpenWrt packages.adb)"
else
  err "无法识别包管理器"; exit 1
fi

# APK 源文件路径兼容：部分 OpenWrt APK 系统没有 /etc/apk/repositories.d
APK_REPO_FILE="/etc/apk/repositories"
if [ "$PKG_MGR" = "apk" ]; then
  if [ -d /etc/apk/repositories.d ] || mkdir -p /etc/apk/repositories.d 2>/dev/null; then
    APK_REPO_FILE="/etc/apk/repositories.d/customfeeds.list"
  else
    APK_REPO_FILE="/etc/apk/repositories"
    touch "$APK_REPO_FILE" 2>/dev/null || true
  fi
fi
# APK 兼容性：不使用 --force-reinstall
# 不同 OpenWrt/apk-tools 版本对该参数支持不一致，普通 add/upgrade 已足够。
APK_FORCE_REINSTALL_OPT=""

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
CPU_ARCH="$SYS_ARCH"
ok "CPU 架构: $CPU_ARCH"

if [ -r /etc/openwrt_release ]; then . /etc/openwrt_release; fi
SYS_RELEASE="$DISTRIB_RELEASE"; SYS_DESC="$DISTRIB_DESCRIPTION"
[ -z "$SYS_RELEASE" ] && SYS_RELEASE=$(cat /etc/version 2>/dev/null | head -1)
[ -z "$SYS_RELEASE" ] && SYS_RELEASE="unknown"
ok "系统: $SYS_DESC ($SYS_RELEASE)"

PW_VER=$(echo "$SYS_RELEASE" | sed -n 's/^\(2[0-9]\.[0-9]*\).*/\1/p')
[ -z "$PW_VER" ] && PW_VER="23.05"
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

# APK 报告的是运行时 CPU 架构(aarch64)，但 OpenWrt 25.12 源目录使用 arch_packages
# (如 mediatek/filogic → aarch64_cortex-a53)。源 URL 必须用包架构，否则 packages.adb 404。
apk_pkg_arch_from_target() {
  case "$1" in
    mediatek/filogic|mediatek/mt7622|bcm27xx/bcm2710|bcm4908/generic|mvebu/cortexa53|sunxi/cortexa53|armvirt/64) echo "aarch64_cortex-a53" ;;
    bcm27xx/bcm2711|mvebu/cortexa72) echo "aarch64_cortex-a72" ;;
    rockchip/armv8|octeontx/generic) echo "aarch64_generic" ;;
    *) echo "" ;;
  esac
}

# 本地目标平台检测（不联网）：DISTRIB_TARGET → distfeeds URL → 架构映射
SYS_TARGET="$DISTRIB_TARGET"
[ -z "$SYS_TARGET" ] && SYS_TARGET=$(grep -hoE 'targets/[a-z0-9]+/[a-z0-9]+' /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf /etc/apk/repositories.d/*.list 2>/dev/null | head -1 | cut -d/ -f2-)
if [ "$PKG_MGR" = "apk" ]; then
  PKG_ARCH=$(apk_pkg_arch_from_target "$SYS_TARGET")
  if [ -n "$PKG_ARCH" ]; then
    SYS_ARCH="$PKG_ARCH"
    ok "软件源架构: $SYS_ARCH"
  fi
fi
[ -z "$SYS_TARGET" ] && SYS_TARGET=$(arch_to_targets "$SYS_ARCH" | awk '{print $1}')
ARCH_TARGETS=$(arch_to_targets "$SYS_ARCH")
[ -n "$SYS_TARGET" ] && ok "目标平台: $SYS_TARGET" || info "目标平台: 未知（仅能检测 packages 源）"

# 内核版本
KERNEL_VER=$(uname -r 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
[ -n "$KERNEL_VER" ] && ok "内核版本: $KERNEL_VER"

# 版本系列链（按内核主线；4.14→19.07, 5.4→21.02, 6.12→25.12 优先(24.10.5 也用过 6.12), 6.x 兜底 24.10/snapshots）
case "$KERNEL_VER" in
  4.14.*) SERIES_CHAIN="19.07" ;;
  5.4.*)  SERIES_CHAIN="21.02" ;;
  5.10.*) SERIES_CHAIN="22.03" ;;
  5.15.*) SERIES_CHAIN="23.05" ;;
  6.12.*) SERIES_CHAIN="25.12 24.10" ;;
  6.1.*|6.6.*) SERIES_CHAIN="24.10" ;;
  6.*)    SERIES_CHAIN="24.10 snapshots" ;;
  *)      SERIES_CHAIN="snapshots" ;;
esac
# opkg 系统: 官方 25.12/snapshots 已切 APK 索引(packages.adb), 无 Packages.gz
# 第三方 25.12-SNAPSHOT 仍带 opkg 的固件只能用 24.10 opkg 源作 best-effort 普通包源
if [ "$PKG_MGR" = "opkg" ]; then
  SERIES_CHAIN=$(echo "$SERIES_CHAIN" | tr ' ' '\n' | grep -v -E '^(25\.12|snapshots)$' | tr '\n' ' ')
  [ -z "$SERIES_CHAIN" ] && SERIES_CHAIN="24.10"
  # 去尾随空格 (tr 换行→空格会产生)
  SERIES_CHAIN=${SERIES_CHAIN% }
  info "opkg 系统: 官方 25.12/snapshots 为 apk 格式，源链过滤为 opkg 可用系列 → $SERIES_CHAIN"
fi

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
  local MIR="$1" v t mf kv V mfname
  OW_VER=""
  # manifest 文件名前缀: immortalwrt 镜像用 immortalwrt-, openwrt 镜像用 openwrt-
  mfname="openwrt"
  echo "$MIR" | grep -q "immortalwrt" && mfname="immortalwrt"
  # 1) DISTRIB_RELEASE 直接给出（最准，但需验证镜像上确实存在该版本——镜像可能滞后）
  V=$(echo "$SYS_RELEASE" | grep -oE '^(19\.07|21\.02|22\.03|23\.05|24\.10|25\.12)\.[0-9]+' | head -1)
  if [ -n "$V" ] && [ "$(check_url $MIR/releases/$V/packages/$SYS_ARCH/base/$PKG_FILE)" = "200" ]; then
    OW_VER="$V"; return 0
  fi
  # 2) SNAPSHOT 固件 (SYS_RELEASE=SNAPSHOT/r0-xxx): 直接探测 snapshots 目录
  #    (opkg 系统跳过: 官方 snapshots 已切 apk, 无 Packages.gz)
  if [ "$PKG_MGR" != "opkg" ] && [ "$(check_url $MIR/snapshots/packages/$SYS_ARCH/base/$PKG_FILE)" = "200" ]; then
    OW_VER="snapshots"; return 0
  fi
  # 3) 遍历候选平台 × 系列链，manifest 内核精确匹配（覆盖所有内核所有硬件）
  #    候选平台: 本地检测 target 优先，然后架构映射全列表
  local cands="$SYS_TARGET $ARCH_TARGETS"
  for t in $cands; do
    [ -z "$t" ] && continue
    for s in $SERIES_CHAIN; do
      for v in $(list_series_vers "$MIR" "$s"); do
        mf="$MIR/releases/$v/targets/${t%/*}/${t#*/}/$mfname-$v-${t%/*}-${t#*/}.manifest"
        kv=$(curl -sL --max-time 5 "$mf" 2>/dev/null | sed -n 's/^kernel - \([0-9.]*\)[~-].*/\1/p' | head -1)
        [ "$kv" = "$KERNEL_VER" ] && { OW_VER="$v"; SYS_TARGET="$t"; return 0; }
      done
    done
  done
  # 无精确匹配：不在此处兜底，让主循环尝试下一个镜像
  return 1
}

# 候选 OpenWrt 镜像（阿里云 → 清华 → 官方），依次探测直到找到匹配的镜像+版本
# 注意: 阿里云可能滞后（如 25.12 系列未同步完整），自动切到有完整版本的镜像
# 索引文件类型按包管理器判断：opkg→Packages.gz（24.10及以下），apk→packages.adb（25.12/snapshots）
PKG_FILE="Packages.gz"
[ "$PKG_MGR" = "apk" ] && PKG_FILE="packages.adb"
MIR_BASES="https://mirrors.aliyun.com/openwrt https://mirrors.tuna.tsinghua.edu.cn/openwrt https://downloads.openwrt.org https://downloads.immortalwrt.org"
# ImmortalWrt 固件: immortalwrt 镜像排最前 (自编译/官方 iStoreOS 等)
if echo "$SYS_DESC $DISTRIB_ID" | grep -qi immortalwrt; then
  MIR_BASES="https://downloads.immortalwrt.org https://mirror.sjtu.edu.cn/immortalwrt https://mirrors.vsean.net/immortalwrt $MIR_BASES"
  info "检测到 ImmortalWrt 固件，优先使用 immortalwrt 镜像"
fi
MIR_USE=""; OW_VER=""
for m in $MIR_BASES; do
  [ "$(check_url $m/releases/)" = "200" ] || continue
  # 优先: DISTRIB_RELEASE 精确匹配（最准，如 25.12.4）
  V=$(echo "$SYS_RELEASE" | grep -oE '^(19\.07|21\.02|22\.03|23\.05|24\.10|25\.12)\.[0-9]+' | head -1)
  if [ -n "$V" ] && [ "$(check_url $m/releases/$V/packages/$SYS_ARCH/base/$PKG_FILE)" = "200" ]; then
    MIR_USE=$m; OW_VER=$V
    ok "OpenWrt 镜像 ✓ ($MIR_USE, 版本 $OW_VER)"
    break
  fi
  # 次选: 内核版本精确匹配（覆盖自编译固件/无 RELEASE）
  probe_ow_ver "$m"
  if [ -n "$OW_VER" ]; then
    MIR_USE=$m
    ok "OpenWrt 镜像 ✓ ($MIR_USE, 内核匹配 $OW_VER)"
    break
  fi
done
if [ -n "$MIR_USE" ] && [ -n "$OW_VER" ]; then
  # OW_VER 用途: PassWall 源版本选择 + 系统源不可用时的 fallback 源
  # 说明: opkg 系统官方 snapshots 已切 apk, 但 25.12 release 仍有 opkg 索引, 可正常匹配
  ok "PassWall 源版本: $OW_VER (官方镜像)"
  [ "$PKG_MGR" = "opkg" ] && info "  └ opkg 系统: 官方 snapshots 为 apk, release 源正常 (系统源不受影响)"
else
  # 全局兜底：所有镜像都无精确匹配时，取系列链最新版本（best effort）
  err "无精确匹配版本，尝试系列最新版本..."
  for m in $MIR_BASES; do
    [ "$(check_url $m/releases/)" = "200" ] || continue
    for s in $SERIES_CHAIN; do
      OW_VER=$(list_series_vers "$m" "$s" | head -1)
      if [ -n "$OW_VER" ] && [ "$(check_url $m/releases/$OW_VER/packages/$SYS_ARCH/base/$PKG_FILE)" = "200" ]; then
        MIR_USE=$m
        info "使用镜像 $m 的系列最新版本 $OW_VER (PassWall 源用)"
        break 2
      fi
      OW_VER=""
    done
  done
  if [ -n "$MIR_USE" ] && [ -n "$OW_VER" ]; then
    ok "PassWall 源版本: $OW_VER (best effort)"
  else
    err "所有 OpenWrt 镜像均无法匹配源版本"
  fi
fi

# PassWall 源版本：跟随探测到的精确版本（22.03/23.05/24.10/25.12）
# 注意: SourceForge 打包只到 24.10，25.12 用 snapshots(apk)；opkg 系统降级到最近可用系列
SF_PW_VER="$PW_VER"
[ -n "$OW_VER" ] && SF_PW_VER=$(echo "$OW_VER" | cut -d. -f1-2)
if [ "$PKG_MGR" = "opkg" ]; then
  case "$SF_PW_VER" in
    25.12) SF_PW_VER="24.10" ;;  # SF 无 packages-25.12
  esac
  SF_PATH="releases/packages-$SF_PW_VER/$SYS_ARCH"
else
  SF_PATH="snapshots/packages/$SYS_ARCH"
fi

# SF 多节点测速: 选最快下载节点 (哪里快从哪里下)
# 支持手动指定: SF_MIRROR=downloads/master/jaist/nchc/netix/netcologne/pilotfiber/phoenixnap/versaweb/ixpeering/astuteinternet
# 说明: SourceForge 镜像参数必须放在完整文件路径后: .../file.ipk?use_mirror=jaist
sf_pick_node() {
  local spath="$1" best="" best_spd=0 prefix spd url mirror
  if [ -n "$SF_MIRROR" ]; then
    case "$SF_MIRROR" in
      downloads) echo "https://downloads.sourceforge.net/project/openwrt-passwall-build||downloads"; return ;;
      master)    echo "https://master.dl.sourceforge.net/project/openwrt-passwall-build||master"; return ;;
      *)         echo "https://downloads.sourceforge.net/project/openwrt-passwall-build|?use_mirror=$SF_MIRROR|$SF_MIRROR"; return ;;
    esac
  fi
  for mirror in downloads master jaist nchc netix netcologne pilotfiber phoenixnap versaweb ixpeering astuteinternet ghfast; do
    case "$mirror" in
      downloads) prefix="https://downloads.sourceforge.net/project/openwrt-passwall-build"; url="$prefix/$spath" ;;
      master)    prefix="https://master.dl.sourceforge.net/project/openwrt-passwall-build"; url="$prefix/$spath" ;;
      ghfast)    prefix="https://ghfast.top/https://master.dl.sourceforge.net/project/openwrt-passwall-build"; url="$prefix/$spath" ;;
      *)         prefix="https://downloads.sourceforge.net/project/openwrt-passwall-build"; url="$prefix/$spath?use_mirror=$mirror" ;;
    esac
    spd=$(curl -sL --max-time 6 -r 0-262143 -o /dev/null -w "%{speed_download}" "$url" 2>/dev/null)
    [ -z "$spd" ] && continue
    if awk "BEGIN{exit !($spd > $best_spd)}" 2>/dev/null; then
      best_spd=$spd; best="$mirror"
    fi
  done
  case "$best" in
    ""|downloads) echo "https://downloads.sourceforge.net/project/openwrt-passwall-build||downloads" ;;
    master)       echo "https://master.dl.sourceforge.net/project/openwrt-passwall-build||master" ;;
    ghfast)       echo "https://ghfast.top/https://master.dl.sourceforge.net/project/openwrt-passwall-build||ghfast" ;;
    *)            echo "https://downloads.sourceforge.net/project/openwrt-passwall-build|?use_mirror=$best|$best" ;;
  esac
}

SF_PREFIX="https://master.dl.sourceforge.net/project/openwrt-passwall-build"
SF_TEST="$SF_PREFIX/$SF_PATH/passwall_luci/Packages.gz"
[ "$PKG_MGR" != "opkg" ] && SF_TEST="$SF_PREFIX/$SF_PATH/passwall_luci/packages.adb"
SF_MIRROR_QUERY=""; SF_MIRROR_LABEL="default"
if [ "$(check_url $SF_TEST)" = "200" ]; then
  SF_OK=1
  ok "PassWall 源 ✓ (SourceForge)"
  info "SF 多节点测速，选最快下载节点..."
  SF_PICK=$(sf_pick_node "$SF_PATH/passwall_luci/Packages.gz")
  SF_PREFIX=$(echo "$SF_PICK" | cut -d'|' -f1)
  SF_MIRROR_QUERY=$(echo "$SF_PICK" | cut -d'|' -f2)
  SF_MIRROR_LABEL=$(echo "$SF_PICK" | cut -d'|' -f3)
  [ -z "$SF_PREFIX" ] && SF_PREFIX="https://downloads.sourceforge.net/project/openwrt-passwall-build"
  ok "PassWall 下载节点: $SF_MIRROR_LABEL ($SF_PREFIX)"
else
  SF_OK=0
  err "PassWall 源不可用（SourceForge 国外直连失败）"
fi
SF_BASE="$SF_PREFIX/$SF_PATH"

# 国内 PassWall 备用源：immortalwrt 官方源自带 passwall 全家桶（luci-app-passwall/xray-core/sing-box 等），
# 且国内有完整镜像（上海交大/VSean）。
# 注意: 始终探测(不只在 SF 失败时)——SF 某些版本/架构构建残缺(如 21.02 aarch64 缺 passwall2/geoview),
#       immortalwrt 作为补充源可兜底。版本优先匹配当前系列, 无则用 23.05.4 兜底。
IW_OK=0; IW_USE=""; IW_VER=""
if [ "$PKG_MGR" = "opkg" ]; then
  info "探测国内 immortalwrt 镜像（PassWall 补充源）..."
  # 按当前版本系列选 immortalwrt 版本 (21.02→21.02.7, 22.03→23.05.4, 23.05→23.05.4, 24.10→24.10.6)
  case "$PW_VER" in
    21.02) IW_CAND="21.02.7" ;;
    22.03|23.05) IW_CAND="23.05.4" ;;
    24.10) IW_CAND="24.10.6" ;;
    *) IW_CAND="23.05.4" ;;
  esac
  for iw in "https://mirror.sjtu.edu.cn/immortalwrt" "https://mirrors.vsean.net/immortalwrt" "https://downloads.immortalwrt.org"; do
    [ "$(check_url $iw/releases/$IW_CAND/packages/$SYS_ARCH/luci/Packages.gz)" != "200" ] && continue
    IW_USE=$iw; IW_VER="$IW_CAND"
    # 确认 luci feed 有 passwall（.gz 解压后 grep 包名）
    if curl -sL --max-time 8 "$iw/releases/$IW_VER/packages/$SYS_ARCH/luci/Packages.gz" 2>/dev/null | gzip -dc 2>/dev/null | grep -q "luci-app-passwall"; then
      IW_OK=1
      ok "国内 PassWall 源 ✓ (immortalwrt $IW_VER 镜像: $IW_USE)"
      break
    fi
  done
  [ "$IW_OK" = "0" ] && info "immortalwrt 镜像不可用（仅 SF 源）"
fi

# OpenWrt 源验证：基于探测到的 OW_VER + 主镜像，验证 base/luci + targets(kmod)
OW_OK=0; TARGET_OK=0
if [ -n "$MIR_USE" ] && [ -n "$OW_VER" ]; then
  # OW_VER 为数字版本号 → releases；否则（snapshots）→ snapshots 目录
  case "$OW_VER" in
    [0-9]*.[0-9]*.[0-9]*) OW_BASE="$MIR_USE/releases/$OW_VER" ;;
    *) OW_BASE="$MIR_USE/snapshots" ;;
  esac
  OW_OK=1
  for feed in base luci; do
    [ "$(check_url $OW_BASE/packages/$SYS_ARCH/$feed/$PKG_FILE)" != "200" ] && { OW_OK=0; break; }
  done
  # targets 源（kmod 所在目录）: 厂商定制 target (如 mt7987) 官方可能没有,
  # 此时降级为"仅 packages 源"——普通包可装, 仅 kmod 不可用
  TARGET_OK=1
  if [ "$OW_OK" = "1" ] && [ -n "$SYS_TARGET" ]; then
    if [ "$(check_url $OW_BASE/targets/$SYS_TARGET/packages/$PKG_FILE)" != "200" ]; then
      TARGET_OK=0
      info "目标平台 $SYS_TARGET 在官方源无 kmod 源（厂商定制平台?），降级为仅 packages 源"
      info "提示: 普通包(PassWall/核心)可正常安装, kmod 内核模块需用固件厂商源"
    fi
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
while :; do
  if ! read -r MAIN_CHOICE; then
    echo ""
    info "输入流已关闭，默认安装 PassWall"
    MAIN_CHOICE="1"
    break
  fi
  case "$MAIN_CHOICE" in
    1|2|3|4) break ;;
    *) printf "  无效输入，请重新选择 (1/2/3/4): " ;;
  esac
done
case "$MAIN_CHOICE" in
  1) INSTALL_PW=1; INSTALL_PW2=0; INSTALL_OC=0; ok "选择: PassWall" ;;
  2) INSTALL_PW=0; INSTALL_PW2=1; INSTALL_OC=0; ok "选择: PassWall2" ;;
  3) INSTALL_PW=0; INSTALL_PW2=0; INSTALL_OC=1; ok "选择: OpenClash" ;;
  4) INSTALL_PW=1; INSTALL_PW2=1; INSTALL_OC=1; ok "选择: 全部安装" ;;
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
info "快速检测系统默认源..."
SYS_SOURCE_OK=0
if [ "$PKG_MGR" = "opkg" ]; then
  # 不跑完整 opkg update 做“检测”：24.10 上会下载/验签所有源，慢则几分钟。
  # 只抽样检测 distfeeds/customfeeds 里的 base/luci Packages.gz URL，真正 update 后面添加 PassWall 源后只跑一次。
  for src in $(awk '/^src\/gz / {print $3}' /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf 2>/dev/null | grep -E '/(base|luci)$' | head -2); do
    [ "$(check_url "$src/Packages.gz")" = "200" ] && SYS_SOURCE_OK=1 && break
  done
  # 如果本机源文件格式特殊但前面已探测到官方镜像可用，也视为系统源可用，避免阻塞。
  [ "$SYS_SOURCE_OK" = "0" ] && [ "$OW_OK" = "1" ] && SYS_SOURCE_OK=1
else
  # APK update 相对较快；保留真实验证。
  apk update >/dev/null 2>&1 && SYS_SOURCE_OK=1
fi

if [ "$SYS_SOURCE_OK" = "1" ]; then
  ok "系统源可用"
else
  err "系统源不可用，配置 OpenWrt 镜像源..."
  if [ "$PKG_MGR" = "opkg" ]; then
    if [ -n "$OW_USE" ]; then
      # 备份后注释系统源（可恢复）
      cp /etc/opkg/distfeeds.conf /tmp/distfeeds.conf.bak 2>/dev/null
      [ -f /etc/opkg/distfeeds.conf ] && sed -i 's/^/#/' /etc/opkg/distfeeds.conf
      { echo "# PO-installer 自动配置 (OpenWrt $OW_VER / $SYS_ARCH / $SYS_TARGET)"
        if [ -n "$SYS_TARGET" ] && [ "$TARGET_OK" = "1" ]; then
          echo "src/gz openwrt_core $OW_USE/targets/$SYS_TARGET/packages"
        fi
        echo "src/gz openwrt_base $OW_USE/packages/$SYS_ARCH/base"
        echo "src/gz openwrt_luci $OW_USE/packages/$SYS_ARCH/luci"
        echo "src/gz openwrt_packages $OW_USE/packages/$SYS_ARCH/packages"
        echo "src/gz openwrt_routing $OW_USE/packages/$SYS_ARCH/routing"
        echo "src/gz openwrt_telephony $OW_USE/packages/$SYS_ARCH/telephony"
      } > /etc/opkg/customfeeds.conf
      ok "已配置 OpenWrt 镜像源 ($OW_USE)"
    else
      err "无可用镜像源，系统源保持不动（未修改）"
    fi
  else
    if [ -n "$OW_USE" ]; then
      [ -f /etc/apk/repositories.d/distfeeds.list ] && cp /etc/apk/repositories.d/distfeeds.list /tmp/distfeeds.list.bak 2>/dev/null
      [ -f /etc/apk/repositories.d/distfeeds.list ] && sed -i 's/^/#/' /etc/apk/repositories.d/distfeeds.list 2>/dev/null
      [ -f /etc/apk/repositories ] && cp /etc/apk/repositories /tmp/apk.repositories.bak 2>/dev/null
      { echo "$OW_USE/packages/$SYS_ARCH/base/packages.adb"
        echo "$OW_USE/packages/$SYS_ARCH/luci/packages.adb"
        echo "$OW_USE/packages/$SYS_ARCH/packages/packages.adb"
        echo "$OW_USE/packages/$SYS_ARCH/routing/packages.adb"
        echo "$OW_USE/packages/$SYS_ARCH/telephony/packages.adb"
        if [ -n "$SYS_TARGET" ] && [ "$TARGET_OK" = "1" ]; then
          echo "$OW_USE/targets/$SYS_TARGET/packages/packages.adb"
        fi
      } > "$APK_REPO_FILE"
      ok "已配置 OpenWrt 镜像源 ($OW_USE)"
    else
      err "无可用镜像源，系统源保持不动（未修改）"
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

# 添加 PassWall 源（装 PassWall/PassWall2/OpenClash 时都需要）
# OpenClash 也需要 immortalwrt 源作为 GitHub 不可达时的降级通道
# 源组合（速度优先）: 国内 immortalwrt 可用 → 优先加在前面；SF 仅作最新版/缺包兜底
if [ "$INSTALL_PW" = "1" -o "$INSTALL_PW2" = "1" -o "$INSTALL_OC" = "1" ]; then
  if [ "$PKG_MGR" = "opkg" ]; then
    # 清旧声明（幂等）: 过滤 passwall/iw_ 行后重建文件 (避免 busybox sed -i 符号链接坑)
    if [ -f /etc/opkg/customfeeds.conf ]; then
      grep -v -e "passwall" -e "^src/gz iw_" /etc/opkg/customfeeds.conf > /tmp/customfeeds.tmp 2>/dev/null || true
      cat /tmp/customfeeds.tmp > /etc/opkg/customfeeds.conf 2>/dev/null
      rm -f /tmp/customfeeds.tmp
    fi
    # 1) 国内 immortalwrt 源（探测到即可用，优先写入，opkg/下载 URL 均先走国内）
    if [ "$IW_OK" = "1" ]; then
      echo "src/gz iw_luci $IW_USE/releases/$IW_VER/packages/$SYS_ARCH/luci" >> /etc/opkg/customfeeds.conf
      echo "src/gz iw_packages $IW_USE/releases/$IW_VER/packages/$SYS_ARCH/packages" >> /etc/opkg/customfeeds.conf
    fi
    # 2) SF 源（可用时保留作缺包/最新版兜底，尤其 passwall2）
    if [ "$SF_OK" = "1" ]; then
      # SourceForge key 也按当前最快节点下载；固定 master 在部分网络下会失败，导致 opkg update 签名失败。
      curl -fsL --max-time 20 -o /tmp/ipk.pub "$SF_PREFIX/ipk.pub$SF_MIRROR_QUERY" 2>/dev/null || \
        wget -q --no-check-certificate -O /tmp/ipk.pub "$SF_PREFIX/ipk.pub$SF_MIRROR_QUERY" 2>/dev/null || \
        curl -fsL --max-time 20 -o /tmp/ipk.pub https://master.dl.sourceforge.net/project/openwrt-passwall-build/ipk.pub 2>/dev/null || true
      [ -s /tmp/ipk.pub ] && opkg-key add /tmp/ipk.pub 2>/dev/null || true
      for feed in passwall_luci passwall_packages passwall2; do
        echo "src/gz $feed $SF_BASE/$feed" >> /etc/opkg/customfeeds.conf
      done
    fi
    # 强制刷新 PassWall 相关索引；否则 24.10/opkg 可能继续使用旧 /var/opkg-lists 缓存，导致检测不到 SF 新版本。
    rm -f /var/opkg-lists/passwall* /var/opkg-lists/iw_* 2>/dev/null || true
    opkg update > /tmp/po_opkg_update.log 2>&1 || true
    # 不再只凭 URL 探测报“源配置完成”，还要确认索引里真的有 PassWall 包。
    PW_INDEX_OK=0
    for idx in /var/opkg-lists/passwall_luci /var/opkg-lists/iw_luci; do
      [ -f "$idx" ] && grep -q "^Package: luci-app-passwall$" "$idx" 2>/dev/null && PW_INDEX_OK=1
    done
    if [ "$PW_INDEX_OK" != "1" ] && [ "$SF_OK" = "1" ]; then
      # 某些 24.10/opkg 固件会因第三方源签名失败导致索引未落盘；SF 已探测可用时，手动拉取索引兜底。
      for feed in passwall_luci passwall_packages passwall2; do
        curl -fsL --max-time 20 "$SF_BASE/$feed/Packages.gz$SF_MIRROR_QUERY" 2>/dev/null | gzip -dc > "/var/opkg-lists/$feed" 2>/dev/null || rm -f "/var/opkg-lists/$feed"
      done
      for idx in /var/opkg-lists/passwall_luci /var/opkg-lists/iw_luci; do
        [ -f "$idx" ] && grep -q "^Package: luci-app-passwall$" "$idx" 2>/dev/null && PW_INDEX_OK=1
      done
      [ "$PW_INDEX_OK" = "1" ] && info "opkg 签名/部分源刷新失败已忽略，已用 SourceForge 索引兜底"
    fi
    if [ "$PW_INDEX_OK" != "1" ]; then
      err "PassWall 源索引刷新失败（可能仍在使用旧缓存/源下载失败）"
      grep -E "Failed|Signature check failed|wget|curl|not found|Permission|ERROR" /tmp/po_opkg_update.log 2>/dev/null || true
    elif grep -qE "Signature check failed|Failed to download|wget returned|curl.*error|Permission denied" /tmp/po_opkg_update.log 2>/dev/null; then
      info "部分系统源刷新失败已忽略，PassWall 源索引正常"
    elif [ "$IW_OK" = "1" ] && [ "$SF_OK" = "1" ]; then
      ok "源配置完成 (速度优先: immortalwrt 国内源 + SourceForge 兜底)"
    elif [ "$IW_OK" = "1" ]; then
      ok "源配置完成 (immortalwrt $IW_VER)"
    elif [ "$SF_OK" = "1" ]; then
      ok "源配置完成 (SourceForge)"
    else
      err "PassWall 源不可用：SourceForge 与国内镜像均无法连接，PassWall 无法安装（OpenClash 不受影响）"
    fi
    rm -f /tmp/po_opkg_update.log 2>/dev/null || true
  else
    # APK 系统: 仅 SF (immortalwrt 是 opkg 体系)
    if [ "$SF_OK" = "1" ]; then
      sed -i '/passwall_luci/d; /passwall_packages/d; /passwall2/d' "$APK_REPO_FILE" 2>/dev/null || true
      for feed in passwall_luci passwall_packages passwall2; do
        echo "$SF_BASE/$feed/packages.adb" >> "$APK_REPO_FILE"
      done
      apk update >/dev/null 2>&1 || true
      ok "源配置完成 (SourceForge)"
    else
      err "PassWall 源不可用：SourceForge 无法连接"
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
    # APK: apk info 会按包名前缀列出多个匹配项，head -1 可能读到旧 ABI/残留项。
    # apk list --installed 才是当前已安装版本；取最高版本避免同名/ABI 过渡残留误判。
    apk list --installed "$pkg" 2>/dev/null | grep -v WARNING | grep "^$pkg-" | awk '{print $1}' | sed "s/^$pkg-//" | sort | tail -1
  fi
}
check_installed() {
  local pkg="$1"
  if [ "$PKG_MGR" = "opkg" ]; then
    opkg list-installed 2>/dev/null | grep -q "^$pkg " && return 0
  else
    # APK: 只能用已安装列表判断。apk info 在 OpenWrt APK 上可能匹配仓库/旧元数据，导致未安装包被当成已安装。
    apk list --installed "$pkg" 2>/dev/null | grep -v WARNING | grep -q "^$pkg-" && return 0
  fi
  return 1
}

# 从 opkg 索引找包元数据
# version/url: 扫所有源取最高版本，避免国内 immortalwrt 低版本遮住 SourceForge 新版本
# 下载 URL 返回最高版本对应源；SourceForge mirror query 只追加到具体文件 URL 末尾
find_pkg_meta() {
  local pkg="$1" want="$2" idx="" feed="" fn="" ver="" url="" best_ver="" best_feed="" best_fn="" best_url=""
  for idx in /var/opkg-lists/iw_* /var/opkg-lists/*; do
    [ -f "$idx" ] || continue
    fn=$(awk -v p="$pkg" '
      $1=="Package:" && $2==p {f=1; next}
      f && $1=="Filename:" {print $2; exit}
      f && $1=="Package:" {f=0}
    ' "$idx" 2>/dev/null)
    [ -z "$fn" ] && continue
    ver=$(awk -v p="$pkg" '
      $1=="Package:" && $2==p {f=1; next}
      f && $1=="Version:" {print $2; exit}
      f && $1=="Package:" {f=0}
    ' "$idx" 2>/dev/null)
    [ -z "$ver" ] && continue
    feed=$(basename "$idx"); feed=${feed%.gz}
    url=$(grep -h "^src/gz $feed \|^src $feed " /etc/opkg/customfeeds.conf /etc/opkg/distfeeds.conf 2>/dev/null | head -1 | awk '{print $3}')
    [ -n "$url" ] || continue
    if [ -z "$best_ver" ] || [ "$(printf '%s\n%s\n' "$best_ver" "$ver" | sort -V | tail -1)" = "$ver" ]; then
      best_ver="$ver"; best_feed="$feed"; best_fn="$fn"; best_url="$url"
    fi
  done
  # 24.10/opkg 有时 opkg update 未刷新 SF 索引但本地旧索引仍存在；直接读 SF Packages.gz 参与比较。
  if [ -n "$SF_BASE" ]; then
    local sf_feed sf_meta sf_ver sf_fn
    for sf_feed in passwall_luci passwall_packages passwall2; do
      sf_meta=$(curl -sL --max-time 10 "$SF_BASE/$sf_feed/Packages.gz$SF_MIRROR_QUERY" 2>/dev/null | gzip -dc 2>/dev/null | awk -v p="$pkg" '
        $1=="Package:" && $2==p {f=1; next}
        f && $1=="Version:" {ver=$2}
        f && $1=="Filename:" {fn=$2}
        f && ver && fn {print ver "|" fn; exit}
        f && $1=="Package:" {f=0}
      ')
      [ -z "$sf_meta" ] && continue
      sf_ver=${sf_meta%%|*}; sf_fn=${sf_meta#*|}
      if [ -n "$sf_ver" ] && { [ -z "$best_ver" ] || [ "$(printf '%s\n%s\n' "$best_ver" "$sf_ver" | sort -V | tail -1)" = "$sf_ver" ]; }; then
        best_ver="$sf_ver"; best_feed="$sf_feed"; best_fn="$sf_fn"; best_url="$SF_BASE/$sf_feed"
      fi
    done
  fi
  [ -z "$best_ver" ] && { echo ""; return; }
  case "$want" in
    version) echo "$best_ver" ;;
    feed) echo "$best_feed" ;;
    url|*)
      case "$best_url" in
        *sourceforge.net*/openwrt-passwall-build*) echo "$best_url/$best_fn$SF_MIRROR_QUERY" ;;
        *) echo "$best_url/$best_fn" ;;
      esac
      ;;
  esac
}

# 获取所有源中的最高版本（国内源低版本不会遮住 SourceForge 新版本）
get_repo_version() {
  local pkg="$1"
  if [ "$PKG_MGR" = "opkg" ]; then
    find_pkg_meta "$pkg" version
  else
    # APK: apk list 可能先输出已装旧版，再输出 [upgradable] 新版；不能 head -1
    # 例: luci-app-passwall-26.7.24-r1 [installed] / luci-app-passwall-26.8.26-r1 [upgradable]
    apk list "$pkg" 2>/dev/null | grep -v WARNING | grep "^$pkg-" | awk '{print $1}' | sed "s/^$pkg-//" | sort | tail -1
  fi
}

# 版本比较：仅当 $1 明确大于 $2 时返回 0。
# 避免把本机 sing-box 1.14.0 误判成可“升级”到源里的 1.13.21-r1。
version_newer() {
  local a="$1" b="$2" top
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 1
  if printf '%s\n%s\n' "$a" "$b" | sort -V >/dev/null 2>&1; then
    top=$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)
    [ "$top" = "$a" ] && return 0 || return 1
  fi
  return 0
}

# 从 opkg 索引找包下载 URL（用于带进度下载）
find_pkg_url() {
  find_pkg_meta "$1" url
}

# APK 主包也走 curl 预下载，这样和 IPK 一样能显示 100% 进度条。
# SourceForge APK 文件名格式: 包名-版本.apk，例如 sing-box-1.13.21-r1.apk
find_apk_url() {
  local pkg="$1" ver="$2" feed url
  [ -n "$SF_BASE" ] || return
  [ -n "$ver" ] || ver=$(get_repo_version "$pkg")
  [ -n "$ver" ] || return
  for feed in passwall_luci passwall_packages passwall2; do
    url="$SF_BASE/$feed/$pkg-$ver.apk$SF_MIRROR_QUERY"
    [ "$(check_url "$url")" = "200" ] && { echo "$url"; return; }
  done
}

# 包安装/升级
# 主包走 curl 带进度下载（百分比），依赖包逐个显示 [N/总数] 包名级进度
# 过滤已知无害的 opkg 噪音: Configuring 进度、remove_obsolesced_files(旧文件已删)、opkg.lock 警告
apk_install() {
  local pkg="$1" rc=0
  if [ "$PKG_MGR" != "apk" ]; then
    # 预解析依赖清单 (模拟安装), 用于显示包名级进度; 排除主包自身(后面单独处理)
    local total=0 cur=0 dep deps
    deps=$(opkg install --noaction "$pkg" --force-downgrade --force-overwrite --force-depends 2>/dev/null | grep "^Installing " | sed 's/Installing \(.*\) (.*/\1/' | grep -v "^$pkg$")
    for dep in $deps; do total=$((total + 1)); done
    [ "$total" = "0" ] && total=1
    cur=0
    # 逐个安装显示进度 (opkg 会跳过已装依赖, 只装缺的)
    # 先尝试按速度优先索引下载本地 ipk，避免依赖包被 opkg 默认挑到 SourceForge。
    for dep in $deps; do
      cur=$((cur + 1))
      printf "\r  [%s/%s] 安装 %s...  " "$cur" "$total" "$dep"
      dep_url=$(find_pkg_url "$dep")
      if [ -n "$dep_url" ]; then
        if curl -fL -sS -o "/tmp/pkg_$dep.ipk" "$dep_url" 2>/tmp/opkg_dep.log; then
          opkg install "/tmp/pkg_$dep.ipk" --force-downgrade --force-overwrite --force-depends > /tmp/opkg_dep.log 2>&1 || true
          rm -f "/tmp/pkg_$dep.ipk"
        else
          opkg install "$dep" --force-downgrade --force-overwrite --force-depends > /tmp/opkg_dep.log 2>&1 || true
        fi
      else
        opkg install "$dep" --force-downgrade --force-overwrite --force-depends > /tmp/opkg_dep.log 2>&1 || true
      fi
      rm -f /tmp/opkg_dep.log
    done
    printf "\r  [%s/%s] 完成             \n" "$total" "$total"
    # 主包: 优先 find_pkg_url 拿 URL 走 curl 带进度; 找不到则 opkg download(也带进度到 stderr)
    local url prog log=/tmp/opkg_install.log repo_ver
    url=$(find_pkg_url "$pkg")
    repo_ver=$(get_repo_version "$pkg")
    if [ -n "$url" ]; then
      # 验证 URL 文件名版本 = 目标版本 (多源时 find_pkg_url 可能拿到旧源 URL, 下载旧版无意义)
      if [ -n "$repo_ver" ] && ! echo "$url" | grep -Fq "$repo_ver"; then
        info "索引版本不匹配 (期望 $repo_ver)，使用速度优先源安装..."
        # 保底仍调用 opkg，但前面的源顺序已是国内优先；正常路径不会走到这里。
        opkg install "$pkg" --force-downgrade --force-overwrite --force-depends > "$log" 2>&1
        rc=$?
        grep -q "pkg_hash_check_unresolved" "$log" 2>/dev/null && rc=2
        grep -v -e "^Configuring" -e "^\.\.\.$" -e "^Collected errors:$" -e "^Removing obsolete file " -e "remove_obsolesced_files" -e "opkg\.lock" "$log" || true
        rm -f "$log"
      else
        prog="-sS"; [ -t 1 ] && prog="--progress-bar"
        info "下载 $pkg (带进度)..."
        if curl -fL $prog -o "/tmp/pkg_$pkg.ipk" "$url"; then
          opkg install "/tmp/pkg_$pkg.ipk" --force-downgrade --force-overwrite --force-depends > "$log" 2>&1
          rc=$?
          # 新版依赖缺失 (pkg_hash_check_unresolved) → 返回2, 上层保留旧版
          grep -q "pkg_hash_check_unresolved" "$log" 2>/dev/null && rc=2
          grep -v -e "^Configuring" -e "^\.\.\.$" -e "^Collected errors:$" -e "^Removing obsolete file " -e "remove_obsolesced_files" -e "opkg\.lock" "$log" || true
          rm -f "/tmp/pkg_$pkg.ipk" "$log"
        else
          err "下载 $pkg 失败，回退 opkg 直接安装..."
          opkg install "$pkg" --force-downgrade --force-overwrite --force-depends > "$log" 2>&1
          rc=$?
          grep -q "pkg_hash_check_unresolved" "$log" 2>/dev/null && rc=2
          grep -v -e "^Configuring" -e "^\.\.\.$" -e "^Collected errors:$" -e "^Removing obsolete file " -e "remove_obsolesced_files" -e "opkg\.lock" "$log" || true
          rm -f "$log"
        fi
      fi
    else
      # find_pkg_url 找不到 URL → 再试 opkg download 预下载 (输出到 TTY 可见；仅作为兜底)
      info "未在速度优先索引找到 $pkg，下载 $pkg (opkg download 兜底)..."
      if (cd /tmp && opkg download "$pkg") 2>&1; then
        # 找到下载的 ipk 并本地安装; 验证文件名版本 = 目标版本, 否则弃用直装
        local dl_ipk
        dl_ipk=$(ls -t /tmp/*.ipk 2>/dev/null | head -1)
        if [ -n "$dl_ipk" ] && { [ -z "$repo_ver" ] || echo "$dl_ipk" | grep -Fq "$repo_ver"; }; then
          opkg install "$dl_ipk" --force-downgrade --force-overwrite --force-depends > "$log" 2>&1
          rc=$?
          rm -f "$dl_ipk"
        else
          [ -n "$dl_ipk" ] && rm -f "$dl_ipk"
          info "下载版本不匹配 (期望 $repo_ver)，直接 opkg install..."
          opkg install "$pkg" --force-downgrade --force-overwrite --force-depends > "$log" 2>&1
          rc=$?
        fi
      else
        # opkg download 失败, 直接 opkg install
        opkg install "$pkg" --force-downgrade --force-overwrite --force-depends > "$log" 2>&1
        rc=$?
      fi
      grep -q "pkg_hash_check_unresolved" "$log" 2>/dev/null && rc=2
      grep -v -e "^Configuring" -e "^\.\.\.$" -e "^Collected errors:$" -e "^Removing obsolete file " -e "remove_obsolesced_files" -e "opkg\.lock" "$log" || true
      rm -f "$log"
    fi
    return $rc
  fi
  local log=/tmp/apk_add.log url prog repo_ver
  # --force-reinstall: 修复假安装(数据库有元数据但文件缺失)时 apk add 跳过解压的问题
  # 之前的 SourceForge 重定向失败可能留下只注册元数据无文件的"假安装", apk add 认为已装直接 OK
  # --upgrade 是关键：apk add 默认不会替换已安装旧版，即使仓库已有新版本
  repo_ver=$(get_repo_version "$pkg")
  url=$(find_apk_url "$pkg" "$repo_ver")
  if [ -n "$url" ]; then
    prog="-sS"; [ -t 1 ] && prog="--progress-bar"
    info "下载 $pkg (带进度)..."
    if curl -fL $prog -o "/tmp/pkg_$pkg.apk" "$url"; then
      apk add --upgrade --allow-untrusted --force-broken-world $APK_FORCE_REINSTALL_OPT "/tmp/pkg_$pkg.apk" > "$log" 2>&1
      rc=$?
      rm -f "/tmp/pkg_$pkg.apk"
    else
      err "下载 $pkg 失败，回退 apk 直接安装..."
      apk add --upgrade --allow-untrusted --force-broken-world $APK_FORCE_REINSTALL_OPT "$pkg" > "$log" 2>&1
      rc=$?
    fi
  else
    apk add --upgrade --allow-untrusted --force-broken-world $APK_FORCE_REINSTALL_OPT "$pkg" > "$log" 2>&1
    rc=$?
  fi
  grep -v "^WARNING.*opening" "$log" || true
  rm -f "$log"
  return $rc
}

# 已安装包升级：APK 必须指定精确版本；只写包名时部分 OpenWrt apk-tools 只输出 OK 但不替换旧版
pkg_update() {
  local pkg="$1"
  local want_ver="$2"
  if [ "$PKG_MGR" = "apk" ]; then
    local log=/tmp/apk_upgrade.log rc=0 url prog
    if [ -n "$want_ver" ]; then
      # 先指定精确版本升级。若 apk 只改 world 约束但没替换，再用 --available 重选。
      url=$(find_apk_url "$pkg" "$want_ver")
      if [ -n "$url" ]; then
        prog="-sS"; [ -t 1 ] && prog="--progress-bar"
        info "下载 $pkg (带进度)..."
        if curl -fL $prog -o "/tmp/pkg_$pkg.apk" "$url"; then
          apk add --upgrade --latest --allow-untrusted --force-broken-world "/tmp/pkg_$pkg.apk" > "$log" 2>&1
          rc=$?
          rm -f "/tmp/pkg_$pkg.apk"
        else
          err "下载 $pkg 失败，回退 apk 直接升级..."
          apk add --upgrade --latest --allow-untrusted --force-broken-world "$pkg=$want_ver" > "$log" 2>&1
          rc=$?
        fi
      else
        apk add --upgrade --latest --allow-untrusted --force-broken-world "$pkg=$want_ver" > "$log" 2>&1
        rc=$?
      fi
      if ! apk list --installed "$pkg" 2>/dev/null | grep -v WARNING | grep -q "^$pkg-$want_ver"; then
        apk upgrade --available --latest --allow-untrusted --force-broken-world "$pkg" >> "$log" 2>&1
        rc=$?
      fi
    else
      apk add --upgrade --latest --allow-untrusted --force-broken-world "$pkg" > "$log" 2>&1
      rc=$?
    fi
    # apk upgrade --available 可能为满足 world 约束安装/卸载无关包；如果目标包没实际变更，避免刷出误导性 Purging/Installing 噪音。
    if [ -n "$want_ver" ] && ! apk list --installed "$pkg" 2>/dev/null | grep -v WARNING | grep -q "^$pkg-$want_ver"; then
      grep -E "ERROR|WARNING|conflict|breaks|unable|failed|permission|No such|not found" "$log" || true
    else
      grep -v "^WARNING.*opening" "$log" || true
    fi
    rm -f "$log"
    return $rc
  fi
  apk_install "$pkg"
}

# 简化版（不询问，直接安装）
pkginstall() {
  local pkg="$1" desc="$2"
  if check_installed "$pkg"; then
    local ver=$(get_version "$pkg")
    local repo_ver=$(get_repo_version "$pkg")
    if version_newer "$repo_ver" "$ver"; then
      info "$desc 已安装 ($ver)，源中有新版本 ($repo_ver)..."
      pkg_update "$pkg" "$repo_ver"
      local rc=$?
      if [ "$rc" = "2" ]; then
        err "$desc 升级失败: 新版缺少依赖 (coreutils-timeout/lyaml 等), 保留旧版 $ver"
        return 1
      elif [ "$rc" != "0" ]; then
        err "$desc 升级失败: opkg/apk 返回错误码 $rc，保留旧版 $ver"
        return 1
      fi
      local nver=$(get_version "$pkg")
      if [ "$nver" = "$repo_ver" ]; then
        ok "$desc: $ver → $nver ✓"
      elif [ "$nver" != "$ver" ] && [ -n "$nver" ]; then
        ok "$desc: $ver → $nver ✓ (源版本 $repo_ver 未完全匹配)"
      else
        err "$desc 未升级: 当前仍为 $ver，源中版本 $repo_ver"
        return 1
      fi
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
# 先比较版本: 已是最新则跳过下载 (避免每次跑脚本都重新下载 geo 包)
pkgupgrade() {
  local pkg="$1" desc="$2"
  if check_installed "$pkg"; then
    local ver=$(get_version "$pkg")
    local repo_ver=$(get_repo_version "$pkg")
    if version_newer "$repo_ver" "$ver"; then
      info "$desc 已安装 ($ver)，源中有新版本 ($repo_ver)..."
      pkg_update "$pkg" "$repo_ver"
      local rc=$?
      if [ "$rc" = "2" ]; then
        err "$desc 升级失败: 新版缺少依赖, 保留旧版 $ver"
        return 1
      elif [ "$rc" != "0" ]; then
        err "$desc 升级失败: opkg/apk 返回错误码 $rc，保留旧版 $ver"
        return 1
      fi
      local nver=$(get_version "$pkg")
      if [ "$nver" = "$repo_ver" ]; then
        ok "$desc: $ver → $nver ✓"
      elif [ "$nver" != "$ver" ] && [ -n "$nver" ]; then
        ok "$desc: $ver → $nver ✓ (源版本 $repo_ver 未完全匹配)"
      else
        err "$desc 未升级: 当前仍为 $ver，源中版本 $repo_ver"
        return 1
      fi
    else
      ok "$desc ($ver) ✓"
    fi
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
# SF 某些版本/架构构建残缺(架构不兼容)时, 明确提示改用 PassWall 经典版
if [ "$INSTALL_PW2" = "1" ]; then
  if [ "$SF_OK" = "1" ]; then
    pkginstall "luci-app-passwall2" "PassWall2"; pkginstall "luci-i18n-passwall2-zh-cn" "PassWall2 中文包"; [ "$INSTALL_PW" != "1" ] && pkginstall "xray-core" "Xray 内核"
  else
    info "跳过 PassWall2: 当前 PassWall 源为国内 immortalwrt 镜像，不含 PassWall2 包（PassWall 经典版不受影响）"
    [ "$INSTALL_PW" != "1" ] && pkginstall "xray-core" "Xray 内核"
  fi
fi

# OpenClash
# 下载函数: 直连 → ghfast.top → ghproxy.net (gh-proxy.com 已挂 403, 移除)
# 返回 0=成功 1=全部失败
# 验证下载内容: ipk 为 gzip/ar, apk 为 APK v3 adb(ADBd), gz 为 gzip
# (代理可能返回 404/错误页但 HTTP 200, 仅 -s 非空检查不够)
# 注意: OpenWrt 无 od/xxd; 用 dd 提取头部字节比较 (busybox 核心命令必有)
#       gz magic 2字节(\x1f\x8b) 用 count=2 避免 NUL 截断; ar/adb magic 4字节纯 ASCII 无 NUL
dl_with_mirror() {
  local url="$1" out="$2" u magic
  # 多通道: 直连 + 多个国内 GitHub 代理 (gh-proxy.com 已挂 403 移除)
  for u in "$url" \
           "https://ghfast.top/$url" \
           "https://ghproxy.net/$url" \
           "https://ghproxy.cc/$url" \
           "https://gh.ddlc.top/$url"; do
    curl -fL -# --max-time 60 -o "$out" "$u" 2>/dev/null
    if [ -s "$out" ]; then
      case "$out" in
        *.gz)   magic=$(dd if="$out" bs=1 count=2 2>/dev/null)
                [ "$magic" = "$(printf '\037\213')" ] && return 0 ;;
        *.apk)  magic=$(dd if="$out" bs=1 count=4 2>/dev/null)
                [ "$magic" = "ADBd" ] && return 0 ;;
        *)      magic=$(dd if="$out" bs=1 count=4 2>/dev/null)
                [ "$magic" = "!<ar" ] && return 0
                magic=$(dd if="$out" bs=1 count=2 2>/dev/null)
                [ "$magic" = "$(printf '\037\213')" ] && return 0 ;;
      esac
    fi
    rm -f "$out"
  done
  return 1
}


# 获取 Mihomo 最新版本和匹配当前架构的下载地址
# 不再手拼文件名：MetaCubeX 会为 amd64 提供多种 v1/v2/v3/goXXX 变体，
# mips/mipsel 也区分 hardfloat/softfloat；手拼容易拿错或拿不到最新版资产。
mihomo_arch_pattern() {
  case "$SYS_ARCH" in
    x86_64|amd64) echo 'mihomo-linux-amd64-v[0-9.]+\.gz' ;;
    aarch64*|arm64) echo 'mihomo-linux-arm64-v[0-9.]+\.gz' ;;
    arm_cortex-a7*|armv7*) echo 'mihomo-linux-armv7-v[0-9.]+\.gz' ;;
    arm_cortex-a5*|arm_cortex-a8*|arm_cortex-a9*|arm*) echo 'mihomo-linux-armv7-v[0-9.]+\.gz' ;;
    i386*|386) echo 'mihomo-linux-386-v[0-9.]+\.gz' ;;
    mipsel*) echo 'mihomo-linux-mipsle-softfloat-v[0-9.]+\.gz' ;;
    mips*) echo 'mihomo-linux-mips-softfloat-v[0-9.]+\.gz' ;;
    *) echo '' ;;
  esac
}
get_mihomo_latest_json() {
  local api="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" u
  for u in "$api" \
           "https://ghfast.top/$api" \
           "https://ghproxy.net/$api"; do
    curl -sL --max-time 10 "$u" 2>/dev/null | grep -q '"tag_name"' || continue
    curl -sL --max-time 20 "$u" 2>/dev/null
    return 0
  done
  return 1
}
get_mihomo_latest_ver() {
  get_mihomo_latest_json | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4 | head -1
}
get_mihomo_asset_url() {
  local pat json
  pat=$(mihomo_arch_pattern)
  [ -n "$pat" ] || return 1
  json=$(get_mihomo_latest_json) || return 1
  MIHOMO_VER=$(printf '%s\n' "$json" | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4 | head -1)
  printf '%s\n' "$json" | grep -oE 'https://[^" ]+' | grep -E "$pat" | head -1
}
install_mihomo_core() {
  local dest="$1" url
  url=$(get_mihomo_asset_url)
  # get_mihomo_asset_url 通过命令替换调用，函数内变量赋值在子 shell 中不会保留；从下载 URL 反解析版本。
  [ -z "$MIHOMO_VER" ] && MIHOMO_VER=$(echo "$url" | sed -n 's#.*/download/\([^/]*\)/.*#\1#p')
  if [ -z "$MIHOMO_VER" ] || [ -z "$url" ]; then
    err "无法获取 Clash Meta 内核下载地址 (GitHub 不可达或架构 $SYS_ARCH 无匹配资产)"
    return 1
  fi
  info "下载 Clash Meta 内核 $MIHOMO_VER ($SYS_ARCH)..."
  if dl_with_mirror "$url" /tmp/mihomo-core.gz; then
    mkdir -p /etc/openclash/core
    gzip -dc /tmp/mihomo-core.gz > "$dest" 2>/dev/null
    rm -f /tmp/mihomo-core.gz
    chmod +x "$dest" 2>/dev/null || { err "Clash 内核安装失败"; return 1; }
    ncore=$("$dest" -v 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -z "$ncore" ] && ncore=$("$dest" --version 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -n "$ncore" ] && [ "$ncore" = "$MIHOMO_VER" ]; then
      ok "Clash Meta 内核已安装最新版 ($ncore)"
    elif [ -n "$ncore" ]; then
      err "Clash 内核版本校验异常: 已安装 $ncore，期望 $MIHOMO_VER"
      return 1
    else
      ok "Clash Meta 内核已安装 ($MIHOMO_VER，版本输出不可解析)"
    fi
  else
    err "Clash Meta 内核下载失败（GitHub 通道不可达或资产无效）"
    return 1
  fi
}

# 获取 OpenClash 最新版本 (GitHub API → 代理重试)
get_oc_latest() {
  local api="https://api.github.com/repos/vernesong/OpenClash/releases/latest" u r
  for u in "$api" \
           "https://ghfast.top/$api" \
           "https://ghproxy.net/$api" \
           "https://ghproxy.cc/$api" \
           "https://gh.ddlc.top/$api"; do
    r=$(curl -sL --max-time 10 "$u" 2>/dev/null | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4)
    [ -n "$r" ] && { echo "$r"; return 0; }
  done
  return 1
}
if [ "$INSTALL_OC" = "1" ]; then
  hdr "OpenClash 安装"

  # 1) 主程序: 已装则自动升级到最新, 未装则直接安装 (无确认)
  OC_VER=$(get_version "luci-app-openclash")
  if check_installed "luci-app-openclash"; then
    ok "OpenClash 主程序已安装 ($OC_VER)"
  fi
  OC_LATEST=$(get_oc_latest)
  OC_LATEST_NUM=$(echo "$OC_LATEST" | sed 's/^v//')
  if [ -z "$OC_LATEST_NUM" ]; then
    info "GitHub API 不可达（直连+代理均失败），尝试 immortalwrt 源安装/升级..."
    if [ "$IW_OK" = "1" ] && [ "$PKG_MGR" = "opkg" ]; then
      opkg install luci-app-openclash --force-downgrade --force-overwrite --force-depends 2>&1 | grep -v -e "^Configuring" -e "^\.\.\.$" -e "^Collected errors:$" -e "^Removing obsolete file " -e "remove_obsolesced_files" -e "opkg\.lock" || true
      nver=$(get_version "luci-app-openclash")
      if [ -n "$nver" ] && [ "$nver" != "$OC_VER" ]; then
        ok "OpenClash $nver ✓ (immortalwrt 源升级)"
      elif check_installed "luci-app-openclash"; then
        ok "OpenClash $nver ✓ (immortalwrt 源)"
      else
        err "OpenClash 安装/升级失败"
      fi
    else
      err "无可用降级源 (immortalwrt 源不可用或 APK 系统)"
    fi
  elif [ "$OC_VER" != "$OC_LATEST_NUM" ]; then
    info "OpenClash 更新: $OC_VER → $OC_LATEST..."
    OC_EXT="ipk"; [ "$PKG_MGR" = "apk" ] && OC_EXT="apk"
    OC_URL=$(curl -sL "https://api.github.com/repos/vernesong/OpenClash/releases/latest" --max-time 10 | grep -oE 'https://[^"]+\.(ipk|apk)' | grep "\.$OC_EXT" | head -1)
    if [ -z "$OC_URL" ]; then
      OC_URL=$(curl -sL --max-time 10 "https://ghfast.top/https://api.github.com/repos/vernesong/OpenClash/releases/latest" 2>/dev/null | grep -oE 'https://[^"]+\.(ipk|apk)' | grep "\.$OC_EXT" | head -1)
    fi
    if [ -n "$OC_URL" ]; then
      info "下载 OpenClash $OC_LATEST ($OC_EXT)..."
      OC_PKG="/tmp/luci-app-openclash.$OC_EXT"
      if dl_with_mirror "$OC_URL" "$OC_PKG"; then
        if [ "$PKG_MGR" = "opkg" ]; then
          opkg install "$OC_PKG" --force-downgrade --force-overwrite --force-depends 2>&1 | grep -v -e "^Configuring" -e "^\.\.\.$" -e "^Collected errors:$" -e "^Removing obsolete file " -e "remove_obsolesced_files" -e "opkg\.lock" || true
        else
          apk add --upgrade --allow-untrusted $APK_FORCE_REINSTALL_OPT "$OC_PKG" 2>&1 | grep -v "^WARNING.*opening" || true
        fi
        rm -f "$OC_PKG"
        # 验证版本真正更新到目标 (旧版还在不算成功)
        nver=$(get_version "luci-app-openclash")
        if [ -n "$nver" ] && [ "$nver" = "$OC_LATEST_NUM" ]; then
          ok "OpenClash 已升级到 $nver ✓"
        elif [ -n "$nver" ] && [ "$OC_VER" != "$nver" ]; then
          ok "OpenClash $nver ✓ (源版本与 GitHub 标记不一致)"
        elif check_installed "luci-app-openclash"; then
          err "OpenClash 安装包无效，版本未更新 (仍为 $nver)"
        else
          err "OpenClash 安装失败"
        fi
      else
        err "GitHub 全部通道失败或下载内容无效，降级尝试 immortalwrt 源..."
        if [ "$IW_OK" = "1" ] && [ "$PKG_MGR" = "opkg" ]; then
          opkg install luci-app-openclash --force-downgrade --force-overwrite --force-depends 2>&1 | grep -v -e "^Configuring" -e "^\.\.\.$" -e "^Collected errors:$" -e "^Removing obsolete file " -e "remove_obsolesced_files" -e "opkg\.lock" || true
          # 验证降级源是否真的提供了新版本 (immortalwrt 源可能滞后, 只有旧版 → 不算成功)
          nver=$(get_version "luci-app-openclash")
          if [ -n "$nver" ] && [ "$nver" != "$OC_VER" ]; then
            ok "OpenClash $nver ✓ (immortalwrt 源升级)"
          elif [ -n "$nver" ] && [ "$nver" = "$OC_LATEST_NUM" ]; then
            ok "OpenClash $nver ✓ (immortalwrt 源)"
          else
            err "immortalwrt 源无新版 (仍为 $nver)，OpenClash 保持当前版本"
          fi
        else
          err "无可用降级源 (immortalwrt 源不可用或 APK 系统)，OpenClash 未安装"
        fi
      fi
    else
      err "无法获取 OpenClash 下载地址 (GitHub 不可达)"
    fi
  else
    ok "OpenClash 已是最新版 ($OC_VER)"
  fi

  # 2) Clash 内核: 文件存在且非空 = 已装, 不反复下载
  # 注意: OpenClash 的 GitHub release 只有 ipk/apk 主程序, 没有内核资产!
  #       内核需从 mihomo (Clash Meta) 官方 release 下载, 命名 mihomo-linux-<arch>-v<ver>.gz
  info "Clash 内核检查..."
  # 检测已装内核文件 (clash_meta / clash / clash_tun, 非空才算)
  CORE_FILE=""
  INSTALLED_MIHOMO=""
  for c in /etc/openclash/core/clash_meta /etc/openclash/core/clash /etc/openclash/core/clash_tun; do
    if [ -f "$c" ] && [ -s "$c" ]; then
      CORE_FILE="$c"
      break
    fi
  done
  if [ -n "$CORE_FILE" ]; then
    # 尝试解析版本 (mihomo -v 输出到 stderr, 需 2>&1; 解析失败也视为已装)
    INSTALLED_MIHOMO=$("$CORE_FILE" -v 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -z "$INSTALLED_MIHOMO" ] && INSTALLED_MIHOMO=$("$CORE_FILE" --version 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -n "$INSTALLED_MIHOMO" ]; then
      ok "Clash 内核已安装 ($INSTALLED_MIHOMO)"
    else
      ok "Clash 内核已安装 (跳过下载)"
    fi
    # 获取最新版本用于对比 (直连 → ghfast → ghproxy)
    MIHOMO_VER=$(get_mihomo_latest_ver)
    # 版本可解析且落后于最新 → 询问升级
    if [ -n "$INSTALLED_MIHOMO" ] && [ -n "$MIHOMO_VER" ] && [ "$INSTALLED_MIHOMO" != "$MIHOMO_VER" ]; then
      echo -n "  升级 Clash 内核 ($INSTALLED_MIHOMO → $MIHOMO_VER)？[Y/n]: "
      read -r CORE_UP
      case "$CORE_UP" in n|N|no|NO) info "跳过升级" ;; *)
        install_mihomo_core "$CORE_FILE"
      ;; esac
    elif [ -n "$INSTALLED_MIHOMO" ] && [ -n "$MIHOMO_VER" ]; then
      ok "Clash 内核已是最新 ($MIHOMO_VER)"
    fi
  else
    # 无内核 → 询问下载
    echo -n "  下载 Clash 运行内核？[Y/n]: "
    read -r CORE_ANS
    case "$CORE_ANS" in n|N|no|NO) info "跳过 Clash 内核" ;; *)
      install_mihomo_core /etc/openclash/core/clash_meta
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

# 可选组件检测：opkg/apk 元数据 + 二进制兜底。
# 有些固件把 sing-box/naiveproxy 作为内置或不同包名提供，包管理器查不到但命令实际存在。
opt_bin() {
  case "$1" in
    sing-box) echo "sing-box" ;;
    naiveproxy) echo "naive" ;;
    v2ray-plugin) echo "v2ray-plugin" ;;
    ipt2socks) echo "ipt2socks" ;;
    hysteria) echo "hysteria" ;;
    *) echo "$1" ;;
  esac
}
opt_bin_path() {
  local bin="$1" p
  p=$(command -v "$bin" 2>/dev/null) && [ -n "$p" ] && { echo "$p"; return; }
  for p in /usr/bin/$bin /usr/sbin/$bin /bin/$bin /sbin/$bin; do
    [ -x "$p" ] && { echo "$p"; return; }
  done
}
opt_installed() {
  local pkg="$1" bin
  check_installed "$pkg" && return 0
  bin=$(opt_bin "$pkg")
  [ -n "$(opt_bin_path "$bin")" ] && return 0
  return 1
}
opt_version() {
  local pkg="$1" bin path ver
  ver=$(get_version "$pkg")
  [ -n "$ver" ] && { echo "$ver"; return; }
  bin=$(opt_bin "$pkg")
  path=$(opt_bin_path "$bin")
  [ -n "$path" ] || { echo ""; return; }
  case "$pkg" in
    sing-box) "$path" version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?' | head -1 ;;
    naiveproxy) "$path" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?|[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?' | head -1 ;;
    *) "$path" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?' | head -1 ;;
  esac
}
opt_pkginstall() {
  local pkg="$1" desc="$2"
  if opt_installed "$pkg" && ! check_installed "$pkg"; then
    local ver repo_ver
    ver=$(opt_version "$pkg")
    repo_ver=$(get_repo_version "$pkg")
    if [ -n "$repo_ver" ] && [ -n "$ver" ] && version_newer "$repo_ver" "$ver"; then
      info "$desc 已安装二进制 ($ver)，源中有新版本 ($repo_ver)，尝试安装包管理器版本..."
      pkginstall "$pkg" "$desc"
    else
      ok "$desc 已存在二进制 ($ver)，跳过安装"
    fi
    return
  fi
  pkginstall "$pkg" "$desc"
}

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
    if opt_installed "$comp"; then
      ver=$(opt_version "$comp")
      repo_ver=$(get_repo_version "$comp")
      if [ -n "$repo_ver" ] && [ -n "$ver" ] && version_newer "$repo_ver" "$ver"; then
        echo "  $i) $desc ($ver → 可升级 $repo_ver) ⬆"
      elif [ -n "$repo_ver" ] && [ -z "$ver" ]; then
        echo "  $i) $desc (已安装，版本未知 → 源版本 $repo_ver) ✓"
      else
        echo "  $i) $desc ($ver) ✓"
      fi
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
    # 过滤非数字字符(退格^H等控制字符会混入序号)
    idx=$(printf '%s' "$idx" | tr -cd '0-9')
    [ -z "$idx" ] && continue
    eval "comp=\"\$OPT_COMP_$idx\""
    eval "desc=\"\$OPT_DESC_$idx\""
    [ -n "$comp" ] && opt_pkginstall "$comp" "$desc"
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
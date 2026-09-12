#!/bin/sh
#==============================================
# OpenWrt 工具箱
# 支持 OPKG (OpenWrt ≤24.10) 和 APK (OpenWrt ≥25.12)
# VERSION: 20260912.31 (修复 APK OpenClash 依赖假失败)
#==============================================
VERSION="20260912.31"
RED='\e[31m'; GREEN='\e[32m'; YELLOW='\e[33m'; BLUE='\e[34m'; NC='\e[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${YELLOW}[→]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
hdr()  { echo -e "${BLUE}━━━ $1 ━━━${NC}"; }
# 检查 URL 可达性: 优先 curl(Range 只取1KB省流量), curl 不可用回退 wget
# 206(Partial Content)=成功归一化为200; 000/空=DNS失败/超时/无curl, 输出诊断
check_url() {
  local code url="$1"
  # command -v 只代表文件存在；损坏的动态链接 curl 仍会通过 command -v。
  # 必须先实际执行 --version，失败时改用可运行的 wget。
  if command -v curl >/dev/null 2>&1 && curl --version >/dev/null 2>&1; then
    code=$(curl -sL -o /dev/null -r 0-1024 -w "%{http_code}" "$url" --max-time 8 2>/dev/null)
  elif command -v wget >/dev/null 2>&1 && wget --version >/dev/null 2>&1; then
    code=$(wget -q --spider --timeout=8 -O /dev/null "$url" 2>/dev/null; echo $?)
    [ "$code" = "0" ] && code="200" || code="000"
  else
    echo "  [探测] curl/wget 均不可运行!" >&2
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

# GitHub 下载候选：有用户代理时只走官方地址；无代理时再走公开代理兜底。
gh_candidates() {
  local url="$1"
  printf '%s\n' "$url"
  [ -n "$http_proxy$https_proxy$HTTP_PROXY$HTTPS_PROXY" ] && return 0
  printf '%s\n' "https://ghfast.top/$url" "https://ghproxy.net/$url" "https://ghproxy.cc/$url" "https://gh.ddlc.top/$url"
}

# 修复“电脑可上网，但 SSH 到路由器后路由器自身 ping 不通”的常见问题。
# 只处理路由器自身出网：默认路由缺失/网络服务卡住/DNS 文件异常，不改 LAN/DHCP/代理规则。
repair_router_self_network() {
  local ip_ok=0 dns_ok=0 gw="" wan_if="" wan_dev="" changed=0
  hdr "路由器自身联网检测"

  ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 || ping -c 1 -W 2 119.29.29.29 >/dev/null 2>&1 || ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1
  [ "$?" = "0" ] && ip_ok=1
  ping -c 1 -W 3 baidu.com >/dev/null 2>&1 || ping -c 1 -W 3 openwrt.org >/dev/null 2>&1
  [ "$?" = "0" ] && dns_ok=1

  [ "$ip_ok" = "1" ] && [ "$dns_ok" = "1" ] && { ok "路由器自身联网正常"; return 0; }

  if [ "$ip_ok" != "1" ]; then
    err "路由器自身无法 ping 通公网 IP，尝试修复默认路由/重启网络服务"
    gw=$(ip route 2>/dev/null | awk '/^default / {print $3; exit}')
    wan_dev=$(ip route 2>/dev/null | awk '/^default / {print $5; exit}')
    if [ -z "$gw" ]; then
      wan_if=$(uci -q get network.wan.ifname 2>/dev/null)
      [ -z "$wan_if" ] && wan_if=$(uci -q get network.wan.device 2>/dev/null)
      gw=$(ubus call network.interface.wan status 2>/dev/null | sed -n 's/.*"nexthop"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
      [ -z "$wan_dev" ] && wan_dev="$wan_if"
      if [ -n "$gw" ] && [ -n "$wan_dev" ]; then
        ip route replace default via "$gw" dev "$wan_dev" 2>/dev/null && changed=1 && ok "已临时修复默认路由: $gw dev $wan_dev"
      fi
    fi
    if [ "$changed" != "1" ]; then
      /etc/init.d/network reload >/dev/null 2>&1 || /etc/init.d/network restart >/dev/null 2>&1 || true
      /etc/init.d/firewall reload >/dev/null 2>&1 || true
      sleep 3
      ok "已重载 network/firewall"
    fi
  fi

  ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 || ping -c 1 -W 2 119.29.29.29 >/dev/null 2>&1 || ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1
  [ "$?" = "0" ] && ip_ok=1 || ip_ok=0

  if [ "$dns_ok" != "1" ] && [ "$ip_ok" = "1" ]; then
    if [ "$ip_ok" = "1" ]; then
      info "公网 IP 可达但域名不通，修复路由器自身 DNS"
      mkdir -p /tmp/resolv.conf.d 2>/dev/null || true
      {
        echo "nameserver 223.5.5.5"
        echo "nameserver 119.29.29.29"
        echo "nameserver 1.1.1.1"
      } > /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null || true
      [ -L /tmp/resolv.conf ] || {
        cp /tmp/resolv.conf /tmp/resolv.conf.po-bak 2>/dev/null || true
        rm -f /tmp/resolv.conf 2>/dev/null || true
        ln -s /tmp/resolv.conf.d/resolv.conf.auto /tmp/resolv.conf 2>/dev/null || true
      }
      /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
      changed=1
    fi
  fi

  ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 || ping -c 1 -W 2 119.29.29.29 >/dev/null 2>&1 || ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1
  [ "$?" = "0" ] && ip_ok=1 || ip_ok=0
  ping -c 1 -W 3 baidu.com >/dev/null 2>&1 || ping -c 1 -W 3 openwrt.org >/dev/null 2>&1
  [ "$?" = "0" ] && dns_ok=1 || dns_ok=0

  if [ "$ip_ok" = "1" ] && [ "$dns_ok" = "1" ]; then
    ok "路由器自身联网已修复"
    return 0
  fi
  [ "$ip_ok" = "1" ] && err "仍有 DNS 问题：公网 IP 可达，域名解析失败" || err "仍无法 ping 通公网 IP：请检查 WAN 网关/上级光猫/策略路由"
  return 1
}

# 管道模式: stdin 不是 TTY, 且 $0 为 sh/ash/bash/dash/-sh/"" 时说明被管道/heredoc 传入，
# 此时交互式 read 不可用, 先保存到 /tmp 提示手动执行。
if [ ! -t 0 ]; then
  case "$0" in
    sh|ash|bash|dash|-sh|"")
      echo "检测到管道模式执行，正在保存脚本..."
      cat > /tmp/install-passwall.sh
      echo "脚本已保存到 /tmp/install-passwall.sh"
      echo "请执行: sh /tmp/install-passwall.sh"
      exit 0
      ;;
  esac
fi

echo ""
echo "============================================"
echo " OpenWrt 工具箱 (v$VERSION)"
echo "============================================"
echo ""
echo ""

#==============================================
# 1. 系统检测
#==============================================
hdr "系统检测"

# 记录真实网络工具路径；后续即使创建兼容包装器，也不递归调用包装器。
CURL_REAL=$(command -v curl 2>/dev/null || true)
WGET_REAL=$(command -v wget 2>/dev/null || true)
curl_works() { [ -n "$CURL_REAL" ] && "$CURL_REAL" --version >/dev/null 2>&1; }
wget_works() { [ -n "$WGET_REAL" ] && "$WGET_REAL" --version >/dev/null 2>&1; }

# curl 动态库损坏时，使用 wget 兼容常见 curl 下载/管道调用。
# 这样不会因 /usr/bin/curl 文件存在但无法启动而中断整个安装流程。
if ! curl_works && wget_works; then
  curl() {
    local out="" url="" quiet=0 opt write_out="" range="" fail=0
    while [ "$#" -gt 0 ]; do
      opt="$1"; shift
      case "$opt" in
        -o|--output) [ "$#" -gt 0 ] && { out="$1"; shift; } ;;
        -O|--remote-name) out="__REMOTE_NAME__" ;;
        -r|--range) [ "$#" -gt 0 ] && { range="$1"; shift; } ;;
        -w|--write-out) [ "$#" -gt 0 ] && { write_out="$1"; shift; } ;;
        -s|-S|-L|-k|-I|-#|-N|-nc|-c|-q) [ "$opt" = "-s" ] && quiet=1; [ "$opt" = "-I" ] && write_out="%{http_code}" ;;
        -f) fail=1 ;;
        -sS|-fsL|-fL|-sfL|--silent|--show-error|--fail|--location|--compressed|--no-check-certificate) quiet=1; case "$opt" in *f*) fail=1;; esac ;;
        --max-time|--connect-timeout|--retry|--retry-delay|-H|--header|--user-agent|--retry-all-errors) [ "$#" -gt 0 ] && shift ;;
        --max-time=*|--connect-timeout=*|--retry=*|--retry-delay=*|--retry-all-errors) ;;
        http://*|https://*) url="$opt" ;;
        *) case "$opt" in -*) ;; *) url="$opt" ;; esac ;;
      esac
    done
    [ -n "$url" ] || return 2
    local tmp="/tmp/curl-wget.$$" rc=0
    if [ "$write_out" = "%{http_code}" ] || [ "$write_out" = "%{url_effective}" ]; then
      "$WGET_REAL" -q --spider "$url" >/dev/null 2>&1; rc=$?
      [ "$rc" = "0" ] || return "$rc"
      [ "$write_out" = "%{url_effective}" ] && printf '%s' "$url" || printf '200'
      return 0
    fi
    if [ "$out" = "__REMOTE_NAME__" ]; then
      "$WGET_REAL" $([ "$quiet" = "1" ] && printf '%s' '-q') "$url"
    elif [ -n "$out" ]; then
      "$WGET_REAL" $([ "$quiet" = "1" ] && printf '%s' '-q') -O "$out" "$url"
    else
      "$WGET_REAL" $([ "$quiet" = "1" ] && printf '%s' '-q') -O - "$url"
    fi
    rc=$?
    rm -f "$tmp"
    return "$rc"
  }
  info "检测到 curl 动态库/符号损坏，临时使用可用 wget 兼容下载"
elif ! curl_works && ! wget_works; then
  info "curl 和 wget 均不可运行，网络下载将无法进行"
fi

# 修复 wget 损坏（apk 内部依赖 wget 下载文件）
# 用"能否运行"判断而非文件头检测（ELF 二进制/symlink 会误判）
WGET_FIXED=0
if ! wget_works; then
  if [ -w /usr/bin ]; then
    cp /usr/bin/wget /tmp/wget.bak 2>/dev/null
    cat > /usr/bin/wget << 'WGETEOF'
#!/bin/sh
URL=""; OUT=""; OUT_DIR=""; TIMEOUT="60"
while [ $# -gt 0 ]; do
  case "$1" in
    -O) shift; OUT="$1" ;;
    -P) shift; OUT_DIR="$1" ;;
    -T|--timeout) shift; [ "$1" != "" ] && TIMEOUT="$1" ;;
    --timeout=*) TIMEOUT="${1#--timeout=}" ;;
    -t|--tries) shift ;;
    --tries=*) ;;
    -q|-c|-nc|-nv|-S|-s|--spider|--no-check-certificate) ;;
    *) URL="$1";;
  esac
  shift
done
[ -z "$URL" ] && exit 1
if [ -z "$OUT" ] && [ -n "$OUT_DIR" ]; then
  mkdir -p "$OUT_DIR" 2>/dev/null || true
  OUT="$OUT_DIR/${URL##*/}"
fi
[ -n "$OUT" ] && set -- -o "$OUT"
exec curl -sL --max-time "$TIMEOUT" "$@" "$URL"
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

# 早期清理上次运行追加的代理插件源。
# 必须放在第一次 opkg print-architecture 之前，否则历史 customfeeds 与 distfeeds 重复时，opkg 自身会先刷 Duplicate src declaration。
# 注意：openwrt_ 是脚本探测/修复后的正确系统依赖源，不能清理；否则下一次运行又退回坏源。
if [ "$PKG_MGR" = "opkg" ] && [ -f /etc/opkg/customfeeds.conf ]; then
  grep -v -e "passwall" -e "ssr" -e "helloworld" -e "kiddin9" -e "^src/gz iw_" /etc/opkg/customfeeds.conf > /tmp/customfeeds.po-clean 2>/dev/null || true
  cat /tmp/customfeeds.po-clean > /etc/opkg/customfeeds.conf 2>/dev/null
  rm -f /tmp/customfeeds.po-clean
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
  # 优先读取 opkg 的架构表；部分厂商固件的 opkg print-architecture
  # 输出为空/格式异常，不能因此直接终止脚本。
  SYS_ARCH=$(opkg print-architecture 2>/dev/null | awk '$1=="arch" {print $2}' | grep -vE '^(all|noarch|any)$' | head -1)
  # 备用：从 distfeeds 的 packages/<arch>/路径提取架构。
  [ -z "$SYS_ARCH" ] && SYS_ARCH=$(grep -hoE 'packages/[A-Za-z0-9_.-]+/(base|luci|packages|routing|telephony)' /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf 2>/dev/null | sed -n 's#packages/\([^/]*\)/.*#\1#p' | grep -vE '^(all|noarch|any)$' | head -1)
  # 最后按运行时架构兜底；aarch64 厂商固件通常使用 cortex-a53 用户态架构。
  [ -z "$SYS_ARCH" ] && case "$(uname -m 2>/dev/null)" in
    aarch64) SYS_ARCH="aarch64_cortex-a53" ;;
    armv7*) SYS_ARCH="arm_cortex-a7_neon-vfpv4" ;;
    mipsel*) SYS_ARCH="mipsel_24kc" ;;
    mips*) SYS_ARCH="mips_24kc" ;;
    x86_64) SYS_ARCH="x86_64" ;;
  esac
else
  SYS_ARCH=$(apk info --print-arch 2>/dev/null)
  [ -z "$SYS_ARCH" ] && SYS_ARCH=$(cat /etc/apk/arch 2>/dev/null)
  [ -z "$SYS_ARCH" ] && SYS_ARCH=$(uname -m | sed 's/mips/mipsel_24kc/')
fi
[ -z "$SYS_ARCH" ] && { err "无法检测架构"; exit 1; }
CPU_ARCH="$SYS_ARCH"
ok "CPU 架构: $CPU_ARCH"

# OPKG 必须启用 all/noarch 架构；某些精简/第三方固件缺失后，
# luci-app-passwall 这类 Architecture: all 的包会被误判为 incompatible。
ensure_opkg_common_arches() {
  [ "$PKG_MGR" = "opkg" ] || return 0
  local changed=0
  if ! opkg print-architecture 2>/dev/null | awk '{print $2}' | grep -qx 'all'; then
    echo "arch all 1" >> /etc/opkg.conf
    changed=1
  fi
  if ! opkg print-architecture 2>/dev/null | awk '{print $2}' | grep -qx 'noarch'; then
    echo "arch noarch 1" >> /etc/opkg.conf
    changed=1
  fi
  # SourceForge/ImmortalWrt 的 21.02 aarch64 包通常标记为
  # aarch64_generic，而厂商固件只注册 aarch64_cortex-a53；
  # 两者 ABI 兼容，需要让 opkg 接受 generic 用户态包。
  if [ "$SYS_ARCH" = "aarch64_cortex-a53" ] && ! opkg print-architecture 2>/dev/null | awk '{print $2}' | grep -qx 'aarch64_generic'; then
    echo "arch aarch64_generic 5" >> /etc/opkg.conf
    changed=1
  fi
  [ "$changed" = "1" ] && info "已补齐 OPKG 通用架构: all/noarch${SYS_ARCH:+/$SYS_ARCH兼容架构}"
}
ensure_opkg_common_arches

if [ -r /etc/openwrt_release ]; then . /etc/openwrt_release; fi
SYS_RELEASE="$DISTRIB_RELEASE"; SYS_DESC="$DISTRIB_DESCRIPTION"
[ -z "$SYS_RELEASE" ] && SYS_RELEASE=$(cat /etc/version 2>/dev/null | head -1)
[ -z "$SYS_RELEASE" ] && SYS_RELEASE="unknown"
# 官方 OpenWrt 标准固件：使用官方 target/packages 源，不混入 ImmortalWrt
# 或第三方完整 userspace 源。GL-MT6000/filogic 24.10.4 属于此类。
OFFICIAL_STANDARD=0
if echo "$SYS_DESC" | grep -qi '^OpenWrt ' && [ "$SYS_RELEASE" = "24.10.4" ] && { [ "$DISTRIB_TARGET" = "mediatek/filogic" ] || [ "$SYS_TARGET" = "mediatek/filogic" ]; }; then
  OFFICIAL_STANDARD=1
  info "检测到官方 OpenWrt 24.10.4 mediatek/filogic，锁定官方 userspace/kmod 源"
fi
ok "系统: $SYS_DESC ($SYS_RELEASE)"

PW_VER=$(echo "$SYS_RELEASE" | sed -n 's/^\(2[0-9]\.[0-9]*\).*/\1/p')
[ -z "$PW_VER" ] && PW_VER="23.05"
echo "$PW_VER" | grep -q "^22" && PW_VER="22.03"
echo "$PW_VER" | grep -q "^23" && PW_VER="23.05"
echo "$PW_VER" | grep -q "^24" && PW_VER="24.10"
echo "$PW_VER" | grep -qE "^2[5-9]|^3" && PW_VER="snapshots"
[ "$PKG_MGR" = "apk" ] && PW_VER="snapshots"
ok "源版本: $PW_VER"

# 架构 → 目标平台映射（完整 31 架构，数据来自官方 22.03.7 targets/Packages 索引）
arch_to_targets() {
  case "$1" in
    aarch64_cortex-a53)   echo "armvirt/64 bcm27xx/bcm2710 bcm4908/generic mediatek/mt7622 mvebu/cortexa53 sunxi/cortexa53" ;;
    aarch64_cortex-a72)   echo "bcm27xx/bcm2711 mvebu/cortexa72" ;;
    aarch64_cortex-a76)   echo "bcm27xx/bcm2712" ;;
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
    bcm27xx/bcm2712) echo "aarch64_cortex-a76" ;;
    sifiveu/generic|star64/generic) echo "riscv64" ;;
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

# 旧版内核不等于旧版用户态：厂商固件可能是 24.10 用户态 + 5.4 内核。
# 用户态 PassWall 源优先跟随 DISTRIB_RELEASE；只有 target/kmod 检查使用内核版本。
LEGACY_OPKG=0
if [ "$PKG_MGR" = "opkg" ]; then
  case "$KERNEL_VER" in
    5.4.*|5.10.*) LEGACY_OPKG=1 ;;
  esac
  # 旧内核只限制 kmod；用户态 PassWall 版本跟随 SYS_RELEASE。
  [ "$LEGACY_OPKG" = "1" ] && info "旧内核 $KERNEL_VER 仅限制 kmod，不切换用户态包线"
fi

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
# opkg 固件的用户态包线优先以固件声明版本为准；内核版本只用于 kmod 兼容性判断。
if [ "$PKG_MGR" = "opkg" ]; then
  case "$PW_VER" in
    19.07|21.02|22.03|23.05|24.10) SERIES_CHAIN="$PW_VER" ;;
    *) SERIES_CHAIN="24.10" ;;
  esac
  info "opkg 系统: 按固件用户态版本选择可用包线 → $SERIES_CHAIN"
fi

# 源探测/下载安装依赖路由器自身出网；如果客户端电脑能上网但路由器 SSH 内 ping 不通，先自动修复一次。
# 如确需跳过，可执行: PO_SKIP_NET_REPAIR=1 sh install-passwall.sh
if [ "$PO_SKIP_NET_REPAIR" != "1" ]; then
  ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 || ping -c 1 -W 2 119.29.29.29 >/dev/null 2>&1 || ping -c 1 -W 3 baidu.com >/dev/null 2>&1 || repair_router_self_network || true
fi

#==============================================
# 2. 源连通性检测
#==============================================
# SourceForge/ImmortalWrt 等代理插件源必须等用户选择后再探测；
# 这里保留系统源/固件镜像的基础探测，避免 OpenClash/iStore 单独安装访问 SF。
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
  # 3) SNAPSHOT/第三方固件常没有可用的精确 release 信息。先只探测每个系列的最新
  #    userspace Packages.gz，避免在低性能 MIPS 上按多个 target 逐个下载 manifest 而卡数分钟。
  #    这一步只用于普通用户态包；kmod 源仍在后面按目标平台单独严格验证。
  for s in $SERIES_CHAIN; do
    for v in $(list_series_vers "$MIR" "$s" | head -1); do
      if [ "$(check_url "$MIR/releases/$v/packages/$SYS_ARCH/base/$PKG_FILE")" = "200" ]; then
        OW_VER="$v"; return 0
      fi
    done
  done
  # 4) 仍无可用 userspace 源时，才遍历候选平台 × 系列链，以内核 manifest 精确匹配。
  #    候选平台: 本地检测 target 优先，然后架构映射全列表。
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

# 候选 OpenWrt 镜像：官方源作为版本/内容基准，国内镜像作为连通性兜底。
# 官方源最权威，不保证中国大陆直连稳定；阿里云通常更快，但可能存在同步延迟。
# 因此先探测官方，官方不可达/缺版本时再切阿里云、清华。
# 索引文件类型按包管理器判断：opkg→Packages.gz（24.10及以下），apk→packages.adb（25.12/snapshots）
PKG_FILE="Packages.gz"
[ "$PKG_MGR" = "apk" ] && PKG_FILE="packages.adb"
MIR_BASES="https://downloads.openwrt.org https://mirrors.aliyun.com/openwrt https://mirrors.tuna.tsinghua.edu.cn/openwrt https://downloads.immortalwrt.org"
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

probe_proxy_sources() {
# PassWall 源版本：跟随探测到的精确版本（22.03/23.05/24.10/25.12）
# 注意: SourceForge 打包只到 24.10，25.12 用 snapshots(apk)；opkg 系统降级到最近可用系列
SF_PW_VER="$PW_VER"
[ -n "$OW_VER" ] && SF_PW_VER=$(echo "$OW_VER" | cut -d. -f1-2)
# SourceForge 的包架构目录与 OpenWrt 运行时架构不总是一致：
# 21.02/22.03 的 aarch64_cortex-a53 包通常发布在 aarch64_generic 目录。
SF_ARCH="$SYS_ARCH"
case "$SYS_ARCH" in
  aarch64_cortex-a53|aarch64_cortex-a72|aarch64_cortex-a76) SF_ARCH="aarch64_generic" ;;
esac
# 厂商固件如果明确声明为 24.10-SNAPSHOT，优先使用对应 24.10 userspace 包线；
# 不因 5.4 内核把整个用户态错误切到 21.02。
[ -n "$OW_VER" ] && SF_PW_VER=$(echo "$OW_VER" | cut -d. -f1-2)
[ -z "$SF_PW_VER" ] && SF_PW_VER="${SYS_RELEASE%.*}"
[ "$SF_PW_VER" = "unknown" ] && SF_PW_VER="24.10"
# SourceForge 的 21/22 旧目录兼容 aarch64 generic，但不能覆盖明确的 24.10。
if [ "$PKG_MGR" = "opkg" ]; then
  case "$SF_PW_VER" in
    25.12|snapshots) SF_PW_VER="24.10" ;;  # SF 无 packages-25.12/snapshots
  esac
  SF_PATH="releases/packages-$SF_PW_VER/$SF_ARCH"
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
      netix|jaist|nchc|netcologne|pilotfiber|phoenixnap|versaweb|ixpeering|astuteinternet) echo "https://$SF_MIRROR.dl.sourceforge.net/project/openwrt-passwall-build||$SF_MIRROR"; return ;;
      *)         echo "https://downloads.sourceforge.net/project/openwrt-passwall-build|?use_mirror=$SF_MIRROR|$SF_MIRROR"; return ;;
    esac
  fi
  for mirror in downloads master jaist nchc netix netcologne pilotfiber phoenixnap versaweb ixpeering astuteinternet; do
    case "$mirror" in
      downloads) prefix="https://downloads.sourceforge.net/project/openwrt-passwall-build"; url="$prefix/$spath" ;;
      master)    prefix="https://master.dl.sourceforge.net/project/openwrt-passwall-build"; url="$prefix/$spath" ;;
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
    *)            echo "https://downloads.sourceforge.net/project/openwrt-passwall-build|?use_mirror=$best|$best" ;;
  esac
}

# 实际下载索引并校验格式；不以 check_url/HTTP 状态码决定 SF_OK。
sf_probe_index() {
  local path="$1" u q tmp
  tmp="/tmp/po_sf_index.$$"
  for u in \
    "https://downloads.sourceforge.net/project/openwrt-passwall-build/$path?use_mirror=$SF_MIRROR" \
    "https://downloads.sourceforge.net/project/openwrt-passwall-build/$path" \
    "https://master.dl.sourceforge.net/project/openwrt-passwall-build/$path" \
    "https://downloads.sourceforge.net/project/openwrt-passwall-build/$path?use_mirror=jaist" \
    "https://downloads.sourceforge.net/project/openwrt-passwall-build/$path?use_mirror=nchc" \
    "https://downloads.sourceforge.net/project/openwrt-passwall-build/$path?use_mirror=netix"; do
    rm -f "$tmp"
    curl -fsL --retry 1 --connect-timeout 10 --max-time 25 -o "$tmp" "$u" 2>/dev/null || true
    if [ "$PKG_MGR" = "opkg" ]; then
      gzip -t "$tmp" 2>/dev/null && { rm -f "$tmp"; echo "$u"; return 0; }
    else
      # APK 索引 packages.adb 是 ADB 格式，前 4 字节魔数 ADBd；404 HTML 错误页不能算成功。
      [ "$(dd if="$tmp" bs=1 count=4 2>/dev/null)" = "ADBd" ] && { rm -f "$tmp"; echo "$u"; return 0; }
    fi
  done
  rm -f "$tmp"
  return 1
}

SF_MIRROR_QUERY=""; SF_MIRROR_LABEL="default"
SF_PROBE_URL=""
if [ "$PKG_MGR" = "opkg" ]; then
  SF_PROBE_URL=$(sf_probe_index "$SF_PATH/passwall_luci/Packages.gz")
  # SourceForge 历史目录并不统一：aarch64 可能使用 generic，也可能使用具体 cortex 目录。
  # 首选 generic，探测不到时自动回退运行时架构，不能把架构目录写死。
  if [ -z "$SF_PROBE_URL" ] && [ "$SF_ARCH" != "$SYS_ARCH" ]; then
    SF_ARCH="$SYS_ARCH"
    SF_PATH="releases/packages-$SF_PW_VER/$SF_ARCH"
    SF_PROBE_URL=$(sf_probe_index "$SF_PATH/passwall_luci/Packages.gz")
  fi
else
  SF_PROBE_URL=$(sf_probe_index "$SF_PATH/passwall_luci/packages.adb")
fi
if [ -n "$SF_PROBE_URL" ]; then
  SF_PREFIX="${SF_PROBE_URL%%/$SF_PATH/*}"
  SF_MIRROR_QUERY=""
  case "$SF_PROBE_URL" in *\?*) SF_MIRROR_QUERY="?${SF_PROBE_URL#*\?}";; esac
  SF_OK=1
  ok "PassWall 源 ✓ (SourceForge 实际索引校验通过)"
  if [ -n "$SF_MIRROR" ]; then
    info "使用手动指定 SourceForge 节点: $SF_MIRROR"
    SF_PICK=$(sf_pick_node "$SF_PATH/passwall_luci/Packages.gz")
    SF_PREFIX=$(echo "$SF_PICK" | cut -d'|' -f1)
    SF_MIRROR_QUERY=$(echo "$SF_PICK" | cut -d'|' -f2)
    SF_MIRROR_LABEL=$(echo "$SF_PICK" | cut -d'|' -f3)
    ok "PassWall 下载节点: $SF_MIRROR_LABEL ($SF_PREFIX)"
  elif [ -n "$http_proxy$https_proxy$HTTP_PROXY$HTTPS_PROXY" ]; then
    info "检测到代理环境，跳过 SF 多节点测速，直接使用默认下载节点"
    SF_PREFIX="https://downloads.sourceforge.net/project/openwrt-passwall-build"
    SF_MIRROR_QUERY=""
    SF_MIRROR_LABEL="downloads"
    ok "PassWall 下载节点: downloads ($SF_PREFIX)"
  else
    info "SF 多节点测速，选最快下载节点..."
    SF_PICK=$(sf_pick_node "$SF_PATH/passwall_luci/Packages.gz")
    SF_PREFIX=$(echo "$SF_PICK" | cut -d'|' -f1)
    SF_MIRROR_QUERY=$(echo "$SF_PICK" | cut -d'|' -f2)
    SF_MIRROR_LABEL=$(echo "$SF_PICK" | cut -d'|' -f3)
    [ -z "$SF_PREFIX" ] && SF_PREFIX="https://downloads.sourceforge.net/project/openwrt-passwall-build"
    ok "PassWall 下载节点: $SF_MIRROR_LABEL ($SF_PREFIX)"
  fi
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
# SourceForge 官方 PassWall 源可用时，不再额外探测 ImmortalWrt，避免
# 24.10.6 等补充源被误认为 PassWall 安装候选，也避免混入第三方依赖。
if [ "$PKG_MGR" = "opkg" ] && [ "$SF_OK" != "1" ]; then
  info "探测国内 immortalwrt 镜像（PassWall 补充源）..."
  # 按内核系列选择同系列 ImmortalWrt 用户态源；旧版不能用 23.05 依赖混装。
  case "$SF_PW_VER" in
    21.02) IW_CAND="21.02.7" ;;
    22.03) IW_CAND="23.05.4" ;;
    23.05) IW_CAND="23.05.4" ;;
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


}

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
echo "  4) SSR Plus (ShadowSocksR Plus+)"
echo "  5) AdGuardHome (DNS 广告过滤)"
echo "  6) iStore 商店"
echo "  7) 全部安装"
echo "  8) 卸载插件"
echo "  9) 修复路由器自身联网（SSH 进路由器后 ping 不通）"
echo ""
printf "请输入选项 (1/2/3/4/5/6/7/8/9): "
while :; do
  if ! read -r MAIN_CHOICE; then
    echo ""
    info "输入流已关闭，默认安装 PassWall"
    MAIN_CHOICE="1"
    break
  fi
  # 某些 SSH/串口终端会把回车作为 CRLF，去掉 CR 和首尾空白，避免输入 1 被判无效。
  MAIN_CHOICE=$(printf '%s' "$MAIN_CHOICE" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  case "$MAIN_CHOICE" in
    1|2|3|4|5|6|7|8|9) break ;;
    *) printf "  无效输入，请重新选择 (1/2/3/4/5/6/7/8/9): " ;;
  esac
done
case "$MAIN_CHOICE" in
  1) INSTALL_PW=1; INSTALL_PW2=0; INSTALL_OC=0; INSTALL_SSR=0; INSTALL_AGH=0; INSTALL_ISTORE=0; ok "选择: PassWall" ;;
  2) INSTALL_PW=0; INSTALL_PW2=1; INSTALL_OC=0; INSTALL_SSR=0; INSTALL_AGH=0; INSTALL_ISTORE=0; ok "选择: PassWall2" ;;
  3) INSTALL_PW=0; INSTALL_PW2=0; INSTALL_OC=1; INSTALL_SSR=0; INSTALL_AGH=0; INSTALL_ISTORE=0; ok "选择: OpenClash" ;;
  4) INSTALL_PW=0; INSTALL_PW2=0; INSTALL_OC=0; INSTALL_SSR=1; INSTALL_AGH=0; INSTALL_ISTORE=0; ok "选择: SSR Plus" ;;
  5) INSTALL_PW=0; INSTALL_PW2=0; INSTALL_OC=0; INSTALL_SSR=0; INSTALL_AGH=1; INSTALL_ISTORE=0; ok "选择: AdGuardHome" ;;
  6) INSTALL_PW=0; INSTALL_PW2=0; INSTALL_OC=0; INSTALL_SSR=0; INSTALL_AGH=0; INSTALL_ISTORE=1; ok "选择: iStore 商店" ;;
  7) INSTALL_PW=1; INSTALL_PW2=1; INSTALL_OC=1; INSTALL_SSR=1; INSTALL_AGH=1; INSTALL_ISTORE=1; ok "选择: 全部安装" ;;
  8)
    echo ""
    echo "请选择要卸载的软件："
    echo ""
    echo "  1) PassWall"
    echo "  2) PassWall2"
    echo "  3) OpenClash"
    echo "  4) SSR Plus"
    echo "  5) AdGuardHome"
    echo "  6) iStore 商店"
    echo "  7) 全部卸载"
    echo ""
    printf "请输入选项 (1/2/3/4/5/6/7): "
    while :; do
      if ! read -r UNINSTALL_CHOICE; then
        echo ""
        info "输入流已关闭，默认不执行卸载"
        exit 0
      fi
      case "$UNINSTALL_CHOICE" in
        1|2|3|4|5|6|7) break ;;
        *) printf "  无效输入，请重新选择 (1/2/3/4/5/6/7): " ;;
      esac
    done
    case "$UNINSTALL_CHOICE" in
      1) INSTALL_PW=1; INSTALL_PW2=0; INSTALL_OC=0; INSTALL_SSR=0; INSTALL_AGH=0; INSTALL_ISTORE=0; ok "卸载: PassWall" ;;
      2) INSTALL_PW=0; INSTALL_PW2=1; INSTALL_OC=0; INSTALL_SSR=0; INSTALL_AGH=0; INSTALL_ISTORE=0; ok "卸载: PassWall2" ;;
      3) INSTALL_PW=0; INSTALL_PW2=0; INSTALL_OC=1; INSTALL_SSR=0; INSTALL_AGH=0; INSTALL_ISTORE=0; ok "卸载: OpenClash" ;;
      4) INSTALL_PW=0; INSTALL_PW2=0; INSTALL_OC=0; INSTALL_SSR=1; INSTALL_AGH=0; INSTALL_ISTORE=0; ok "卸载: SSR Plus" ;;
      5) INSTALL_PW=0; INSTALL_PW2=0; INSTALL_OC=0; INSTALL_SSR=0; INSTALL_AGH=1; INSTALL_ISTORE=0; ok "卸载: AdGuardHome" ;;
      6) INSTALL_PW=0; INSTALL_PW2=0; INSTALL_OC=0; INSTALL_SSR=0; INSTALL_AGH=0; INSTALL_ISTORE=1; ok "卸载: iStore 商店" ;;
      7) INSTALL_PW=1; INSTALL_PW2=1; INSTALL_OC=1; INSTALL_SSR=1; INSTALL_AGH=1; INSTALL_ISTORE=1; ok "卸载: 全部插件" ;;
    esac
    FORCE_REINSTALL=0; UNINSTALL_ONLY=1
    ;;
  9)
    ok "选择: 修复路由器自身联网"
    repair_router_self_network
    exit $?
    ;;
esac

# 用户选择完成后先进入安装模式；软件源检测/PassWall官方源配置必须按顺序执行。
# PassWall2 OPKG 主包优先走 GitHub Release；源仅用于依赖和失败兜底。
if [ "$UNINSTALL_ONLY" = "1" ]; then
  echo ""
  echo "卸载配置："
  echo "  1) 保留配置（默认）"
  echo "  2) 删除配置"
  echo ""
  printf "请选择 (1/2，回车默认1): "
  if ! read -r UNINSTALL_CFG_CHOICE; then
    echo ""
    UNINSTALL_CFG_CHOICE="1"
  fi
  case "$UNINSTALL_CFG_CHOICE" in
    2) UNINSTALL_KEEP_CONFIG=0; ok "卸载配置: 删除配置" ;;
    *) UNINSTALL_KEEP_CONFIG=1; ok "卸载配置: 保留配置" ;;
  esac
fi

if [ "$UNINSTALL_ONLY" != "1" ]; then
  echo ""
  echo "安装模式："
  echo "  1) 直接安装/升级（默认）"
  echo "  2) 先卸载已选插件主程序，再重新安装（保留配置）"
  echo "  3) 仅卸载已选插件"
  echo ""
  printf "请选择安装模式 (1/2/3，回车默认1): "
  if ! read -r INSTALL_MODE; then
    echo ""
    INSTALL_MODE="1"
  fi
  case "$INSTALL_MODE" in
    2) FORCE_REINSTALL=1; UNINSTALL_ONLY=0; ok "模式: 卸载后重装（保留配置）" ;;
    3) FORCE_REINSTALL=0; UNINSTALL_ONLY=1; ok "模式: 仅卸载" ;;
    *) FORCE_REINSTALL=0; UNINSTALL_ONLY=0; ok "模式: 直接安装/升级" ;;
  esac
  if [ "$UNINSTALL_ONLY" = "1" ]; then
    echo ""
    echo "卸载配置："
    echo "  1) 保留配置（默认）"
    echo "  2) 删除配置"
    echo ""
    printf "请选择 (1/2，回车默认1): "
    if ! read -r UNINSTALL_CFG_CHOICE; then
      echo ""
      UNINSTALL_CFG_CHOICE="1"
    fi
    case "$UNINSTALL_CFG_CHOICE" in
      2) UNINSTALL_KEEP_CONFIG=0; ok "卸载配置: 删除配置" ;;
      *) UNINSTALL_KEEP_CONFIG=1; ok "卸载配置: 保留配置" ;;
    esac
  fi
fi

#==============================================
# 3.5 空间检测（仅提示，不用固定估算值拦截安装）
#==============================================
if [ "$UNINSTALL_ONLY" != "1" ]; then
  hdr "空间检测"
  REQUIRED_SPACE_MB=30
  [ "$INSTALL_PW" = "1" ] && REQUIRED_SPACE_MB=$((REQUIRED_SPACE_MB + 80))
  [ "$INSTALL_PW2" = "1" ] && REQUIRED_SPACE_MB=$((REQUIRED_SPACE_MB + 80))
  [ "$INSTALL_OC" = "1" ] && REQUIRED_SPACE_MB=$((REQUIRED_SPACE_MB + 30))
  [ "$INSTALL_SSR" = "1" ] && REQUIRED_SPACE_MB=$((REQUIRED_SPACE_MB + 60))
  [ "$INSTALL_AGH" = "1" ] && REQUIRED_SPACE_MB=$((REQUIRED_SPACE_MB + 40))
  [ "$INSTALL_ISTORE" = "1" ] && REQUIRED_SPACE_MB=$((REQUIRED_SPACE_MB + 20))
  OVERLAY_SPACE=$(df -k /overlay 2>/dev/null | tail -1 | awk '{print $4}')
  [ -z "$OVERLAY_SPACE" ] && OVERLAY_SPACE=$(df -k / 2>/dev/null | tail -1 | awk '{print $4}')
  OVERLAY_SPACE=$((OVERLAY_SPACE / 1024))
  ok "Overlay 可用: ${OVERLAY_SPACE}MB"
  info "插件完整安装预估: ${REQUIRED_SPACE_MB}MB（仅供参考）"
fi

#==============================================
# 4. 配置源
#==============================================
if [ "$UNINSTALL_ONLY" != "1" ]; then
hdr "软件源配置"
info "快速检测系统默认源..."
validate_source_path_compatibility() {
  local file="$1" url series arch bad=0
  series=$(echo "$SYS_RELEASE" | sed -n 's/^\(19\.07\|21\.02\|22\.03\|23\.05\|24\.10\|25\.12\)\..*/\1/p')
  [ -n "$series" ] || series=$(echo "$SYS_RELEASE" | sed -n 's/^\(19\.07\|21\.02\|22\.03\|23\.05\|24\.10\|25\.12\).*/\1/p')
  while read -r url; do
    [ -n "$url" ] || continue
    # 明确写了 releases/packages-X.Y 的源必须与当前固件系列一致。
    case "$url" in
      */releases/packages-[0-9]*.[0-9]*/*)
        src_series=$(printf '%s\n' "$url" | sed -n 's#.*releases/packages-\([0-9]*\.[0-9]*\)/.*#\1#p')
        if [ -n "$series" ] && [ "$src_series" != "$series" ]; then
          err "检测到版本不匹配的软件源: $url (固件系列 $series)"
          bad=1
        fi
        ;;
    esac
    # OpenWrt 官方包源路径中的架构必须等于当前系统架构；all/noarch 例外。
    arch=$(printf '%s\n' "$url" | sed -n 's#.*/packages/\([^/]*\)/\(base\|luci\|packages\|routing\|telephony\).*#\1#p')
    if [ -n "$arch" ] && [ "$arch" != "$SYS_ARCH" ] && ! echo "$arch" | grep -qE '^(all|noarch|any)$'; then
      err "检测到架构不匹配的软件源: $url (当前架构 $SYS_ARCH)"
      bad=1
    fi
  done < "$file"
  return "$bad"
}
validate_opkg_system_source() {
  local log=/tmp/po_system_opkg_update.log
  opkg update > "$log" 2>&1
  local rc=$?
  if [ "$rc" != "0" ] || grep -qE 'Failed to download|Signature check failed|Collected errors|incompatible|404|wget returned' "$log" 2>/dev/null; then
    err "OPKG 系统源更新失败或存在错误"
    grep -E 'Failed|Signature|Collected errors|incompatible|404|wget returned|ERROR' "$log" 2>/dev/null || true
    rm -f "$log"
    return 1
  fi
  awk '!/^#/ && /^src(\/gz)?[[:space:]]/ {print $3}' /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf /etc/opkg/compatfeeds.conf 2>/dev/null | sort -u > /tmp/po_opkg_source_urls
  validate_source_path_compatibility /tmp/po_opkg_source_urls || { rm -f "$log" /tmp/po_opkg_source_urls; return 1; }
  # 索引必须至少能提供当前系统的基础用户态包，不能只凭 URL/HTTP 200 判定可用。
  for pkg in base-files libc luci-base; do
    opkg list "$pkg" 2>/dev/null | grep -q "^$pkg " || {
      err "OPKG 索引缺少基础包: $pkg"
      rm -f "$log" /tmp/po_opkg_source_urls
      return 1
    }
  done
  rm -f "$log" /tmp/po_opkg_source_urls
  return 0
}
validate_apk_system_source() {
  local log=/tmp/po_system_apk_update.log
  apk update > "$log" 2>&1
  local rc=$?
  if [ "$rc" != "0" ] || grep -qE 'ERROR|WARNING.*(architecture|not found|failed)|UNTRUST|No such' "$log" 2>/dev/null; then
    err "APK 系统源更新失败或存在错误"
    grep -E 'ERROR|WARNING|UNTRUST|failed|not found|No such' "$log" 2>/dev/null || true
    rm -f "$log"
    return 1
  fi
  cat /etc/apk/repositories /etc/apk/repositories.d/*.list 2>/dev/null | awk '!/^#/ && NF {print $1}' | sort -u > /tmp/po_apk_source_urls
  validate_source_path_compatibility /tmp/po_apk_source_urls || { rm -f "$log" /tmp/po_apk_source_urls; return 1; }
  for pkg in base-files libc luci-base; do
    apk search --exact "$pkg" 2>/dev/null | grep -q "$pkg" || {
      err "APK 索引缺少基础包: $pkg"
      rm -f "$log" /tmp/po_apk_source_urls
      return 1
    }
  done
  rm -f "$log" /tmp/po_apk_source_urls
  return 0
}

SYS_SOURCE_OK=0
if [ "$PKG_MGR" = "opkg" ]; then
  # 早期版本可能注释过系统源；先恢复，避免 iStoreOS 商店被旧状态卡住。
  if echo "$SYS_DESC" | grep -qiE "iStoreOS|istoreos"; then
    sed -i 's/^#\(src\/gz \)/\1/' /etc/opkg/distfeeds.conf 2>/dev/null || true
    mkdir -p /etc/opkg
    if [ -f /etc/opkg/compatfeeds.conf ]; then
      last_char=$(tail -c 1 /etc/opkg/compatfeeds.conf 2>/dev/null | tr -d '\n' 2>/dev/null)
      [ -n "$last_char" ] && printf '\n' >> /etc/opkg/compatfeeds.conf
    else
      : > /etc/opkg/compatfeeds.conf
    fi
    grep -qE '^src/gz istore_compat ' /etc/opkg/compatfeeds.conf 2>/dev/null || printf '%s\n' 'src/gz istore_compat https://istore.istoreos.com/repo/all/compat' >> /etc/opkg/compatfeeds.conf
  fi
  validate_opkg_system_source && SYS_SOURCE_OK=1
else
  validate_apk_system_source && SYS_SOURCE_OK=1
fi

if [ "$SYS_SOURCE_OK" = "1" ]; then
  ok "系统源可用"
  # iStoreOS 的 iStore 商店依赖独立的 compat 源；系统源正常不代表商店源正常。
  if echo "$SYS_DESC" | grep -qiE "iStoreOS|istoreos" && [ "$PKG_MGR" = "opkg" ]; then
    mkdir -p /etc/opkg
    istore_feed_changed=0
    if [ -f /etc/opkg/compatfeeds.conf ]; then
      last_char=$(tail -c 1 /etc/opkg/compatfeeds.conf 2>/dev/null | tr -d '\n' 2>/dev/null)
      [ -n "$last_char" ] && printf '\n' >> /etc/opkg/compatfeeds.conf && istore_feed_changed=1
    else
      : > /etc/opkg/compatfeeds.conf
      istore_feed_changed=1
    fi
    if ! grep -qE '^src/gz istore_compat ' /etc/opkg/compatfeeds.conf 2>/dev/null; then
      printf '%s\n' 'src/gz istore_compat https://istore.istoreos.com/repo/all/compat' >> /etc/opkg/compatfeeds.conf
      istore_feed_changed=1
    fi
    if [ "$istore_feed_changed" = "1" ]; then
      ok "iStoreOS 软件源配置已修复"
    else
      ok "iStoreOS 软件源配置正常"
    fi
  fi
else
  err "系统源不可用，保留原系统源，仅追加 OpenWrt 镜像源..."
  if [ "$PKG_MGR" = "opkg" ]; then
    if [ -n "$OW_USE" ]; then
      # 保留用户已有 customfeeds，只替换本脚本管理的 openwrt_* 源，避免覆盖其它插件源。
      cp /etc/opkg/customfeeds.conf /tmp/customfeeds.po-bak 2>/dev/null || true
      : > /tmp/customfeeds.po-new
      if [ -f /etc/opkg/customfeeds.conf ]; then
        grep -vE '^[[:space:]]*src(/gz)?[[:space:]]+openwrt_(core|base|luci|packages|routing|telephony)[[:space:]]' \
          /etc/opkg/customfeeds.conf > /tmp/customfeeds.po-new 2>/dev/null || true
      fi
      {
        echo "# PO-installer 自动配置 (OpenWrt $OW_VER / $SYS_ARCH / $SYS_TARGET)"
        if [ -n "$SYS_TARGET" ] && [ "$TARGET_OK" = "1" ]; then
          echo "src/gz openwrt_core $OW_USE/targets/$SYS_TARGET/packages"
        fi
        echo "src/gz openwrt_base $OW_USE/packages/$SYS_ARCH/base"
        echo "src/gz openwrt_luci $OW_USE/packages/$SYS_ARCH/luci"
        echo "src/gz openwrt_packages $OW_USE/packages/$SYS_ARCH/packages"
        echo "src/gz openwrt_routing $OW_USE/packages/$SYS_ARCH/routing"
        echo "src/gz openwrt_telephony $OW_USE/packages/$SYS_ARCH/telephony"
      } >> /tmp/customfeeds.po-new
      cat /tmp/customfeeds.po-new > /etc/opkg/customfeeds.conf
      rm -f /tmp/customfeeds.po-new
      ok "已配置 OpenWrt 镜像源，保留现有 customfeeds ($OW_USE)"
    else
      err "无可用镜像源，系统源保持不动（未修改）"
    fi
  else
    if [ -n "$OW_USE" ]; then
      # 绝不注释原 APK 系统源；只追加兜底源，避免 iStore/系统源状态被破坏。
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

# 系统源正常时按官方教程直接配置 PassWall 源，不做镜像测速、索引手工兜底或 ImmortalWrt 探测。
# 系统源异常时才进入完整兼容探测流程。
OFFICIAL_PASSWALL_MODE=0
if [ "$UNINSTALL_ONLY" != "1" ] && [ "$SYS_SOURCE_OK" = "1" ] &&
   [ "$INSTALL_OC" = "0" ] && [ "$INSTALL_SSR" = "0" ] &&
   [ "$INSTALL_PW$INSTALL_PW2" != "00" ]; then
  OFFICIAL_PASSWALL_MODE=1
  SF_PW_VER="${SYS_RELEASE%.*}"
  # 24.10-SNAPSHOT 仍是 24.10 用户态包线，不再因 5.4 内核退回 21.02。
  echo "$SYS_RELEASE" | grep -q '^24\.10' && SF_PW_VER="24.10"
  SF_ARCH="$SYS_ARCH"
  SF_PREFIX="https://master.dl.sourceforge.net/project/openwrt-passwall-build"
  SF_MIRROR_QUERY=""
  if [ "$PKG_MGR" = "apk" ]; then
    if echo "$SYS_RELEASE" | grep -qiE 'snapshot|snapshots|SNAPSHOT'; then
      SF_PATH="snapshots/packages/$SYS_ARCH"
    else
      SF_PATH="releases/packages-$SF_PW_VER/$SYS_ARCH"
    fi
  else
    SF_PATH="releases/packages-$SF_PW_VER/$SYS_ARCH"
  fi
  SF_BASE="$SF_PREFIX/$SF_PATH"
  SF_OK=1
  IW_OK=0
  ok "按官方教程配置 PassWall 源 ($SF_PATH)"
else
  if [ "$UNINSTALL_ONLY" != "1" ] && { [ "$INSTALL_PW" = "1" ] || [ "$INSTALL_PW2" = "1" ]; }; then
    probe_proxy_sources
  fi
fi

# 添加代理插件源（PassWall/PassWall2/SSR Plus/OpenClash 均有需要；OpenClash 用 GitHub 下载，
# 但 GitHub 不可达时降级走 immortalwrt 源 opkg 安装，所以 OpenClash-only 也必须写入 iw 源）
# 源组合（速度优先）: 国内 immortalwrt 可用 → 优先加在前面；SF 仅作最新版/缺包兜底
if [ "$INSTALL_PW" = "1" -o "$INSTALL_PW2" = "1" -o "$INSTALL_OC" = "1" -o "$INSTALL_SSR" = "1" ]; then
  if [ "$PKG_MGR" = "opkg" ]; then
    # 清旧声明（幂等）: 仅过滤代理插件源；保留已修复的 openwrt_ 系统依赖源 (避免 busybox sed -i 符号链接坑)
    if [ -f /etc/opkg/customfeeds.conf ]; then
      grep -v -e "passwall" -e "ssr" -e "helloworld" -e "kiddin9" -e "^src/gz iw_" /etc/opkg/customfeeds.conf > /tmp/customfeeds.tmp 2>/dev/null || true
      cat /tmp/customfeeds.tmp > /etc/opkg/customfeeds.conf 2>/dev/null
      rm -f /tmp/customfeeds.tmp
    fi
    add_opkg_feed_once() {
      local name="$1" url="$2" tmp
      [ -n "$name" ] && [ -n "$url" ] || return 0
      # 同名 custom feed 可能是上一次运行留下的旧架构/旧版本地址；
      # 不能直接 return，否则脚本看似追加成功，实际仍使用错误源。
      if [ -f /etc/opkg/customfeeds.conf ]; then
        tmp="/tmp/customfeeds.$$.tmp"
        grep -vE "^src/gz[[:space:]]+$name[[:space:]]|^src[[:space:]]+$name[[:space:]]" /etc/opkg/customfeeds.conf > "$tmp" 2>/dev/null || true
        cat "$tmp" > /etc/opkg/customfeeds.conf 2>/dev/null || true
        rm -f "$tmp"
      fi
      # distfeeds 中的系统源不修改；若 URL 已存在于任一配置，不重复追加。
      awk '/^src\/gz |^src / {print $3}' /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf 2>/dev/null | grep -Fxq "$url" && return 0
      echo "src/gz $name $url" >> /etc/opkg/customfeeds.conf
    }
    # 0) OpenWrt 官方/镜像 packages 源：系统源异常时追加完整依赖源。
    #    对第三方 SNAPSHOT：即使系统源能更新，也可能缺 PassWall 必需的 coreutils-timeout/lyaml；
    #    此时只补当前系列的 userspace packages feed，不写 kmod/target 源。
    NEED_PW_USERSPACE_DEPS=0
    NEED_PW2_USERSPACE_DEPS=0
    NEED_OC_USERSPACE_DEPS=0
    MISSING_PW_DEPS=""
    MISSING_PW2_DEPS=""
    MISSING_OC_DEPS=""
    # 检查“索引中是否存在”而不是只检查 Packages.gz 是否能访问。
    if [ "$INSTALL_PW" = "1" ]; then
      for dep in coreutils coreutils-base64 coreutils-nohup coreutils-timeout curl chinadns-ng dns2socks dns2tcp dnsmasq-full ip-full libuci-lua lua luci-compat luci-lib-jsonc microsocks resolveip tcping lyaml; do
        opkg list "$dep" 2>/dev/null | grep -q "^$dep " || MISSING_PW_DEPS="$MISSING_PW_DEPS $dep"
      done
      [ -n "$MISSING_PW_DEPS" ] && NEED_PW_USERSPACE_DEPS=1
      [ "$NEED_PW_USERSPACE_DEPS" = "1" ] && info "PassWall 依赖索引不完整，缺少:$MISSING_PW_DEPS"
    fi
    # PassWall2 与 PassWall 依赖不同：它额外需要 geoview/geo 数据包，通常不需要 chinadns/dns2socks。
    if [ "$INSTALL_PW2" = "1" ]; then
      for dep in coreutils coreutils-base64 coreutils-nohup coreutils-timeout curl ip-full libuci-lua lua luci-compat luci-lib-jsonc lyaml resolveip tcping geoview v2ray-geoip v2ray-geosite unzip; do
        opkg list "$dep" 2>/dev/null | grep -q "^$dep " || MISSING_PW2_DEPS="$MISSING_PW2_DEPS $dep"
      done
      # 23.05/24.10 的 PassWall2 才声明 luci-lua-runtime；21/22.03 不把它当硬依赖。
      case "$SF_PW_VER" in
        23.05|24.10) opkg list luci-lua-runtime 2>/dev/null | grep -q '^luci-lua-runtime ' || MISSING_PW2_DEPS="$MISSING_PW2_DEPS luci-lua-runtime" ;;
      esac
      [ -n "$MISSING_PW2_DEPS" ] && NEED_PW2_USERSPACE_DEPS=1
      [ "$NEED_PW2_USERSPACE_DEPS" = "1" ] && info "PassWall2 依赖索引不完整，缺少:$MISSING_PW2_DEPS"
    fi
    # OpenClash 主包的系统用户态依赖（0.47.x）：dnsmasq-full/bash/curl/ca-bundle/ip-full/ruby/ruby-yaml/unzip。
    # kmod-tun 单独检测，不能从官方其它版本源补装，必须匹配当前内核 hash。
    if [ "$INSTALL_OC" = "1" ]; then
      for dep in dnsmasq-full bash curl ca-bundle ip-full ruby ruby-yaml unzip; do
        opkg list "$dep" 2>/dev/null | grep -q "^$dep " || MISSING_OC_DEPS="$MISSING_OC_DEPS $dep"
      done
      [ -n "$MISSING_OC_DEPS" ] && NEED_OC_USERSPACE_DEPS=1
      [ "$NEED_OC_USERSPACE_DEPS" = "1" ] && info "OpenClash 用户态依赖索引不完整，缺少:$MISSING_OC_DEPS"
      if ! opkg list kmod-tun 2>/dev/null | grep -q '^kmod-tun '; then
        info "OpenClash 需要 kmod-tun，但当前源未提供；不会从不匹配的官方内核源强装"
      fi
    fi
    if [ "$INSTALL_PW$INSTALL_PW2" != "00" ] || [ "$NEED_OC_USERSPACE_DEPS" = "1" ]; then
    if [ "$OFFICIAL_STANDARD" = "1" ]; then
      # 官方固件已有完整匹配源：不因 PassWall 专用包缺少若干依赖而
      # 追加另一套完整 userspace 源，避免 libc/架构/版本混用。
      info "官方系统源正常，保留官方 userspace/kmod 源；不追加第三方依赖源"
    elif { [ "$NEED_PW_USERSPACE_DEPS" = "1" ] || [ "$NEED_PW2_USERSPACE_DEPS" = "1" ] || [ "$NEED_OC_USERSPACE_DEPS" = "1" ]; } && [ "$OW_OK" = "1" ] && [ -n "$OW_USE" ]; then
      # 系统源能访问不等于依赖完整：iStoreOS/厂商源可能缺 coreutils-timeout、libyaml、lyaml。
      # 只要 PassWall 依赖探测缺包，就必须追加匹配系列 userspace 源。
      add_opkg_feed_once "openwrt_base" "$OW_USE/packages/$SYS_ARCH/base"
      add_opkg_feed_once "openwrt_luci" "$OW_USE/packages/$SYS_ARCH/luci"
      add_opkg_feed_once "openwrt_packages" "$OW_USE/packages/$SYS_ARCH/packages"
      add_opkg_feed_once "openwrt_routing" "$OW_USE/packages/$SYS_ARCH/routing"
      add_opkg_feed_once "openwrt_telephony" "$OW_USE/packages/$SYS_ARCH/telephony"
      info "系统源可用但依赖不完整，已补充 OpenWrt userspace 依赖源 ($OW_USE / $SYS_ARCH)"
    elif [ "$SYS_SOURCE_OK" != "1" ] && [ "$OW_OK" = "1" ] && [ -n "$OW_USE" ]; then
      [ -n "$SYS_TARGET" ] && [ "$TARGET_OK" = "1" ] && add_opkg_feed_once "openwrt_core" "$OW_USE/targets/$SYS_TARGET/packages"
      add_opkg_feed_once "openwrt_base" "$OW_USE/packages/$SYS_ARCH/base"
      add_opkg_feed_once "openwrt_luci" "$OW_USE/packages/$SYS_ARCH/luci"
      add_opkg_feed_once "openwrt_packages" "$OW_USE/packages/$SYS_ARCH/packages"
      add_opkg_feed_once "openwrt_routing" "$OW_USE/packages/$SYS_ARCH/routing"
      add_opkg_feed_once "openwrt_telephony" "$OW_USE/packages/$SYS_ARCH/telephony"
      info "已追加匹配的 OpenWrt 依赖源 ($OW_USE / $SYS_ARCH)"
    elif [ "$SYS_SOURCE_OK" = "1" ]; then
      # 系统源完整时清理旧版残留；不碰 distfeeds.conf 中的系统源。
      if [ -f /etc/opkg/customfeeds.conf ]; then
        grep -v -e '^src/gz openwrt_' -e '^src/gz iw_' /etc/opkg/customfeeds.conf > /tmp/customfeeds.clean 2>/dev/null || true
        cat /tmp/customfeeds.clean > /etc/opkg/customfeeds.conf 2>/dev/null || true
        rm -f /tmp/customfeeds.clean
      fi
      info "系统源正常，不追加 OpenWrt 镜像依赖源（减少 opkg 刷新时间）"
    else
      info "未追加 OpenWrt 依赖源：未探测到匹配版本；将仅使用系统默认源"
    fi
    # 1) PassWall 备用源：系统源健康时只补 PassWall 专用源；
    # 不把 ImmortalWrt userspace 源混入基础依赖解析。只有 SourceForge 不可用时，
    # 才使用 ImmortalWrt 的 PassWall/LuCI 源兜底。
    if [ "$IW_OK" = "1" ] && [ "$SF_OK" != "1" ]; then
      echo "src/gz iw_luci $IW_USE/releases/$IW_VER/packages/$SYS_ARCH/luci" >> /etc/opkg/customfeeds.conf
      echo "src/gz iw_packages $IW_USE/releases/$IW_VER/packages/$SYS_ARCH/packages" >> /etc/opkg/customfeeds.conf
    fi
    # 2) SF 源（仅 PassWall/PassWall2 需要；SSR Plus 走 fw876/helloworld Release，OpenClash 走 GitHub）
    if [ "$SF_OK" = "1" ] && [ "$LEGACY_OPKG" = "1" ]; then
      info "旧版 OPKG：仅使用 $SF_PW_VER/$SF_ARCH PassWall 源，避免跨版本依赖混装"
    fi
    if [ "$SF_OK" = "1" ] && [ "$INSTALL_PW$INSTALL_PW2" != "00" ]; then
      # SourceForge key 也按当前最快节点下载；固定 master 在部分网络下会失败，导致 opkg update 签名失败。
      curl -fsL --max-time 20 -o /tmp/ipk.pub "$SF_PREFIX/ipk.pub$SF_MIRROR_QUERY" 2>/dev/null || \
        wget -q --no-check-certificate -O /tmp/ipk.pub "$SF_PREFIX/ipk.pub$SF_MIRROR_QUERY" 2>/dev/null || \
        curl -fsL --max-time 20 -o /tmp/ipk.pub https://master.dl.sourceforge.net/project/openwrt-passwall-build/ipk.pub 2>/dev/null || true
      [ -s /tmp/ipk.pub ] && opkg-key add /tmp/ipk.pub 2>/dev/null || true
      for feed in passwall_luci passwall_packages passwall2; do
        echo "src/gz $feed $SF_BASE/$feed" >> /etc/opkg/customfeeds.conf
      done
    fi
    # 3) SSR Plus 源：使用 openwrt.ai/kiddin9 预编译源（R3S aarch64_generic/24.10 等有现成包）
    SSR_OK=0; SSR_BASE=""
    if [ "$INSTALL_SSR" = "1" ] && [ "$PKG_MGR" = "opkg" ]; then
      SSR_VER="$SF_PW_VER"
      [ -z "$SSR_VER" ] && SSR_VER="$PW_VER"
      SSR_BASE="https://dl.openwrt.ai/packages-$SSR_VER/$SYS_ARCH/kiddin9"
      if [ "$(check_url "$SSR_BASE/Packages.gz")" = "200" ] && curl -sL --max-time 12 "$SSR_BASE/Packages.gz" 2>/dev/null | gzip -dc 2>/dev/null | grep -q "^Package: luci-app-ssr-plus$"; then
        add_opkg_feed_once "openwrt_ai_kiddin9" "$SSR_BASE"
        SSR_OK=1
        ok "SSR Plus 源 ✓ (openwrt.ai packages-$SSR_VER / $SYS_ARCH)"
      else
        err "SSR Plus 源不可用或无 luci-app-ssr-plus ($SSR_BASE)"
      fi
    fi
    ensure_opkg_feed_arches() {
      [ "$PKG_MGR" = "opkg" ] || return 0
      local arch changed=0
      for arch in $(grep -hoE 'packages/[A-Za-z0-9_.-]+/(base|luci|packages|routing|telephony)' /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf 2>/dev/null | sed -n 's#packages/\([^/]*\)/.*#\1#p' | sort -u); do
        echo "$arch" | grep -qE '^(all|noarch|any)$' && continue
        if ! opkg print-architecture 2>/dev/null | awk '$1=="arch" {print $2}' | grep -qx "$arch"; then
          echo "arch $arch 5" >> /etc/opkg.conf
          changed=1
        fi
      done
      [ "$changed" = "1" ] && info "已注册软件源架构，避免 OPKG 忽略索引包"
    }
    # 源已写入后再注册源路径里的架构；不能只依赖 uname/opkg 的本机架构名。
    ensure_opkg_feed_arches
    # 清理上一次运行留下的索引：旧索引可能来自 25.12/6.6 或错误架构，
    # 即使 customfeeds 已改正，opkg 仍会继续读取 /var/opkg-lists 中的旧包。
    # 先全部清空，随后用当前固件对应的源重新刷新，避免“no valid architecture”。
    rm -f /var/opkg-lists/* 2>/dev/null || true
    info "已清理旧 OPKG 索引，按当前固件源重新刷新..."
    opkg update > /tmp/po_opkg_update.log 2>&1 || true
    # 第三方 SNAPSHOT 的 opkg 有时不会将新 customfeed 的索引落盘。若补了完整 userspace packages 源，
    # 直接缓存 Packages.gz，使 OPKG 能解析所有递归依赖（而不是按 coreutils-timeout/libyaml 逐个特判）。
    if [ "$NEED_PW_USERSPACE_DEPS" = "1" ] || [ "$NEED_PW2_USERSPACE_DEPS" = "1" ] || [ "$NEED_OC_USERSPACE_DEPS" = "1" ]; then
      info "缓存完整 userspace 依赖索引，交由 OPKG 自动解析递归依赖..."
      if curl -fsL --connect-timeout 10 --max-time 60 "$OW_USE/packages/$SYS_ARCH/packages/Packages.gz" 2>/dev/null | gzip -dc > /tmp/openwrt_packages.po 2>/dev/null && [ -s /tmp/openwrt_packages.po ]; then
        mkdir -p /var/opkg-lists 2>/dev/null || true
        cat /tmp/openwrt_packages.po > /var/opkg-lists/openwrt_packages
        rm -f /tmp/openwrt_packages.po
        ok "完整 userspace 依赖索引已就绪"
      else
        rm -f /tmp/openwrt_packages.po
        err "userspace 依赖索引缓存失败"
      fi
    fi
    # 不再只凭 URL 探测报“源配置完成”，还要确认索引里真的有 PassWall 包。
    PW_INDEX_OK=0; PW_INDEX_FALLBACK=0
    for idx in /var/opkg-lists/passwall_luci /var/opkg-lists/iw_luci; do
      [ -f "$idx" ] && grep -q "^Package: luci-app-passwall$" "$idx" 2>/dev/null && PW_INDEX_OK=1
    done
    if [ "$PW_INDEX_OK" != "1" ] && [ "$SF_OK" = "1" ]; then
      # 某些 24.10/opkg 固件会因第三方源签名失败导致索引未落盘；SF 已探测可用时，手动拉取索引兜底。
      for feed in passwall_luci passwall_packages passwall2; do
        curl -fsL --max-time 20 "$SF_BASE/$feed/Packages.gz$SF_MIRROR_QUERY" 2>/dev/null | gzip -dc > "/var/opkg-lists/$feed" 2>/dev/null || rm -f "/var/opkg-lists/$feed"
      done
      for idx in /var/opkg-lists/passwall_luci /var/opkg-lists/iw_luci; do
        [ -f "$idx" ] && grep -q "^Package: luci-app-passwall$" "$idx" 2>/dev/null && PW_INDEX_OK=1 && PW_INDEX_FALLBACK=1
      done
    fi
    if [ "$PW_INDEX_OK" != "1" ] && [ "$INSTALL_PW$INSTALL_PW2" != "00" ]; then
      err "PassWall 源索引刷新失败（可能仍在使用旧缓存/源下载失败）"
      grep -E "Failed|Signature check failed|wget|curl|not found|Permission|ERROR" /tmp/po_opkg_update.log 2>/dev/null || true
    elif [ "$PW_INDEX_FALLBACK" = "1" ]; then
      ok "PassWall 源索引正常（已自动兜底处理 opkg 刷新警告）"
    elif [ "$INSTALL_PW$INSTALL_PW2" = "00" ] && [ "$INSTALL_SSR" = "1" ] && [ "$SSR_OK" = "1" ]; then
      ok "源配置完成 (SSR Plus openwrt.ai/kiddin9)"
    elif grep -qE "Signature check failed|Failed to download|wget returned|curl.*error|Permission denied" /tmp/po_opkg_update.log 2>/dev/null; then
      ok "源索引正常（已忽略无关系统源刷新警告）"
    elif [ "$IW_OK" = "1" ] && [ "$SF_OK" = "1" ]; then
      ok "源配置完成 (速度优先: immortalwrt 国内源 + SourceForge 兜底)"
    elif [ "$IW_OK" = "1" ]; then
      ok "源配置完成 (immortalwrt $IW_VER)"
    elif [ "$SF_OK" = "1" ] && [ "$INSTALL_PW$INSTALL_PW2" != "00" ]; then
      ok "源配置完成 (SourceForge)"
    elif [ "$INSTALL_PW$INSTALL_PW2$INSTALL_OC" = "000" ] && [ "$INSTALL_SSR" = "1" ]; then
      ok "源配置完成 (SSR Plus 使用 fw876/helloworld Release；OPKG 依赖走系统/openwrt.ai 源)"
    elif [ "$SSR_OK" = "1" ]; then
      ok "源配置完成 (SSR Plus openwrt.ai/kiddin9)"
    else
      err "代理插件源不可用：PassWall/SSR Plus 源均未成功配置（OpenClash 不受影响）"
    fi
    rm -f /tmp/po_opkg_update.log 2>/dev/null || true
    fi
  else
    # APK 系统: PassWall/PassWall2 才需要 SF；SSR Plus 走 fw876/helloworld Release、OpenClash 走 GitHub，
    # 两者都不写 SF 源，避免多余 apk update/404 探测。
    if [ "$INSTALL_PW$INSTALL_PW2" = "00" ] && [ "$INSTALL_OC" = "0" ] && [ "$INSTALL_SSR" = "1" ]; then
      ok "源配置完成 (SSR Plus 使用 fw876/helloworld GitHub Release 直装)"
    elif [ "$INSTALL_PW$INSTALL_PW2" = "00" ] && [ "$INSTALL_OC" = "1" ]; then
      ok "源配置完成 (OpenClash 使用 GitHub Release 直装，不写代理源)"
    elif [ "$SF_OK" = "1" ] && [ "$INSTALL_PW$INSTALL_PW2" != "00" ]; then
      sed -i '/passwall_luci/d; /passwall_packages/d; /passwall2/d' "$APK_REPO_FILE" 2>/dev/null || true
      for feed in passwall_luci passwall_packages passwall2; do
        echo "$SF_BASE/$feed/packages.adb" >> "$APK_REPO_FILE"
      done
      apk update >/dev/null 2>&1 || true
      APK_PW_INDEX_OK=1
      if [ "$INSTALL_PW" = "1" ] && ! apk list luci-app-passwall 2>/dev/null | grep -v WARNING | grep -q '^luci-app-passwall-'; then
        APK_PW_INDEX_OK=0
        err "SourceForge APK 源缺少 luci-app-passwall"
      fi
      if [ "$INSTALL_PW2" = "1" ] && ! apk list luci-app-passwall2 2>/dev/null | grep -v WARNING | grep -q '^luci-app-passwall2-'; then
        APK_PW_INDEX_OK=0
        err "SourceForge APK 源缺少 luci-app-passwall2"
      fi
      [ "$APK_PW_INDEX_OK" = "1" ] && ok "源配置完成 (SourceForge)" || err "PassWall APK 源索引刷新失败或构建残缺"
    else
      err "PassWall 源不可用：SourceForge 无法连接"
    fi
  fi
fi
fi

#==============================================
# 5. 安装主程序 / 卸载
#==============================================
hdr "安装主程序"

get_version_from_status() {
  local pkg="$1" file="$2"
  [ -f "$file" ] || return 1
  awk -v p="$pkg" '
    $1=="Package:" && $2==p {f=1; next}
    f && $1=="Version:" {print $2; exit}
    f && $1=="Package:" {f=0}
  ' "$file" 2>/dev/null
}
get_version_from_apk_db() {
  local pkg="$1" file v
  for file in /lib/apk/db/installed /usr/lib/apk/db/installed; do
    [ -f "$file" ] || continue
    # OpenWrt APK installed db uses compact fields like P:luci-app-xxx / V:1.2.3.
    # Some apk-tools variants may print P: <pkg>; handle both forms.
    v=$(awk -v p="$pkg" '
      /^P:/ {
        name=substr($0,3); sub(/^ /,"",name);
        f=(name==p); next
      }
      f && /^V:/ {
        ver=substr($0,3); sub(/^ /,"",ver); print ver; exit
      }
    ' "$file" 2>/dev/null)
    [ -n "$v" ] && { echo "$v"; return 0; }
  done
  return 1
}
get_version() {
  local pkg="$1" v=""
  if [ "$PKG_MGR" = "opkg" ]; then
    v=$(opkg list-installed 2>/dev/null | grep "^$pkg " | awk '{print $3}' | sort -V | tail -1)
    [ -n "$v" ] || v=$(get_version_from_status "$pkg" /usr/lib/opkg/status)
    [ -n "$v" ] || v=$(get_version_from_status "$pkg" /var/lib/opkg/status)
    echo "$v"
  else
    # APK: apk list --installed 是主路径；本地 Release 安装后某些 OpenWrt apk 不刷新 list 输出，兜底读 apk db。
    v=$(apk list --installed "$pkg" 2>/dev/null | grep -v WARNING | grep "^$pkg-" | awk '{print $1}' | sed "s/^$pkg-//" | sort -V | tail -1)
    [ -n "$v" ] || v=$(get_version_from_apk_db "$pkg")
    echo "$v"
  fi
}
check_installed() {
  local pkg="$1"
  [ -n "$(get_version "$pkg")" ] && return 0
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
    if [ -z "$best_ver" ] || version_newer "$ver" "$best_ver"; then
      best_ver="$ver"; best_feed="$feed"; best_fn="$fn"; best_url="$url"
    fi
  done
  # 24.10/opkg 有时 opkg update 未刷新 SF 索引但本地旧索引仍存在；直接读 SF Packages.gz 参与比较。
  if [ "$SF_OK" = "1" ] && [ -n "$SF_BASE" ]; then
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
      if [ -n "$sf_ver" ] && { [ -z "$best_ver" ] || version_newer "$sf_ver" "$best_ver"; }; then
        best_ver="$sf_ver"; best_feed="$sf_feed"; best_fn="$sf_fn"; best_url="$SF_BASE/$sf_feed"
      fi
    done
  fi
  # SSR Plus: openwrt.ai/kiddin9 源可能未签名，opkg update 不一定把索引落盘；
  # 直接读取远端 Packages.gz 参与 version/url 解析，确保 dns2tcp/lua-neturl/ssr-plus 等能走 curl 预下载安装。
  if [ -n "$SSR_BASE" ]; then
    local ssr_meta ssr_ver ssr_fn
    ssr_meta=$(curl -sL --max-time 10 "$SSR_BASE/Packages.gz" 2>/dev/null | gzip -dc 2>/dev/null | awk -v p="$pkg" '
      $1=="Package:" && $2==p {f=1; next}
      f && $1=="Version:" {ver=$2}
      f && $1=="Filename:" {fn=$2}
      f && ver && fn {print ver "|" fn; exit}
      f && $1=="Package:" {f=0}
    ')
    if [ -n "$ssr_meta" ]; then
      ssr_ver=${ssr_meta%%|*}; ssr_fn=${ssr_meta#*|}
      if [ -n "$ssr_ver" ] && { [ -z "$best_ver" ] || version_newer "$ssr_ver" "$best_ver"; }; then
        best_ver="$ssr_ver"; best_feed="openwrt_ai_kiddin9"; best_fn="$ssr_fn"; best_url="$SSR_BASE"
      fi
    fi
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
    apk list "$pkg" 2>/dev/null | grep -v WARNING | grep "^$pkg-" | awk '{print $1}' | sed "s/^$pkg-//" | sort -V | tail -1
  fi
}

# 版本比较：仅当 $1 明确大于 $2 时返回 0。
# 避免把本机 sing-box 1.14.0 误判成可“升级”到源里的 1.13.21-r1。
version_newer() {
  local a="$1" b="$2" an bn top
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 1
  an=$(echo "$a" | sed 's/^v//; s/-r[0-9][0-9]*$//')
  bn=$(echo "$b" | sed 's/^v//; s/-r[0-9][0-9]*$//')
  # PassWall 旧包常用 git-YY.MMDD.build 格式；不能直接和 26.9.9
  # 用 sort -V 比较，否则 sort 会把 git-25... 错排在 26.9.9 后面。
  case "$an" in
    git-[0-9][0-9].*) an=$(echo "$an" | sed -n 's/^git-\([0-9][0-9]\.[0-9][0-9]*\).*/\1/p') ;;
  esac
  case "$bn" in
    git-[0-9][0-9].*) bn=$(echo "$bn" | sed -n 's/^git-\([0-9][0-9]\.[0-9][0-9]*\).*/\1/p') ;;
  esac
  # ChinaDNS-NG 旧版会显示 v1.0-beta.25，而新源是 2025.08.09-r1。
  # sort -V 会把带 v/beta 的旧版本排到日期版本后面，需先把日期版判为新上游格式。
  case "$an|$bn" in
    20[0-9][0-9].*'|'*beta*) return 0 ;;
    *beta*'|'20[0-9][0-9].*) return 1 ;;
  esac
  if printf '%s\n%s\n' "$an" "$bn" | sort -V >/dev/null 2>&1; then
    top=$(printf '%s\n%s\n' "$an" "$bn" | sort -V | tail -1)
    [ "$top" = "$an" ] && return 0 || return 1
  fi
  # sort -V 不可用时保守处理: 不判定为可升级
  return 1
}

# 从 opkg 索引找包下载 URL（用于带进度下载）
find_pkg_url() {
  find_pkg_meta "$1" url
}

# 从 opkg 索引/远端 SF 索引读取 Depends 字段，供直链安装路径先装依赖。
find_pkg_depends() {
  local pkg="$1" idx deps sf_feed meta
  for idx in /var/opkg-lists/iw_* /var/opkg-lists/*; do
    [ -f "$idx" ] || continue
    deps=$(awk -v p="$pkg" '
      $1=="Package:" && $2==p {f=1; next}
      f && $1=="Depends:" {sub(/^Depends:[[:space:]]*/, ""); print; exit}
      f && $1=="Package:" {f=0}
    ' "$idx" 2>/dev/null)
    [ -n "$deps" ] && { echo "$deps"; return 0; }
  done
  if [ "$SF_OK" = "1" ] && [ -n "$SF_BASE" ]; then
    for sf_feed in passwall_luci passwall_packages passwall2; do
      meta=$(curl -sL --max-time 10 "$SF_BASE/$sf_feed/Packages.gz$SF_MIRROR_QUERY" 2>/dev/null | gzip -dc 2>/dev/null | awk -v p="$pkg" '
        $1=="Package:" && $2==p {f=1; next}
        f && $1=="Depends:" {sub(/^Depends:[[:space:]]*/, ""); print; exit}
        f && $1=="Package:" {f=0}
      ')
      [ -n "$meta" ] && { echo "$meta"; return 0; }
    done
  fi
}
normalize_dep_names() {
  tr ',' '\n' | sed 's/(.*)//g; s/^[[:space:]]*//; s/[[:space:]]*$//' | awk 'NF && $1 !~ /^kernel$/ {print $1}' | sort -u
}

# APK 主包也走 curl 预下载，这样和 IPK 一样能显示 100% 进度条。
# SourceForge APK 文件名格式: 包名-版本.apk，例如 sing-box-1.13.21-r1.apk
find_apk_url() {
  local pkg="$1" ver="$2" feed url
  [ "$SF_OK" = "1" ] && [ -n "$SF_BASE" ] || return
  [ -n "$ver" ] || ver=$(get_repo_version "$pkg")
  [ -n "$ver" ] || return
  for feed in passwall_luci passwall_packages passwall2; do
    url="$SF_BASE/$feed/$pkg-$ver.apk$SF_MIRROR_QUERY"
    [ "$(check_url "$url")" = "200" ] && { echo "$url"; return; }
  done
}

apk_installed_exact() {
  local pkg="$1" ver="$2"
  [ -n "$pkg" ] && [ -n "$ver" ] || return 1
  apk list --installed "$pkg" 2>/dev/null | grep -v WARNING | grep -q "^$pkg-$ver"
}

# 预先解析重定向后的最终地址，再显示一次下载进度。
# SourceForge 的 -L 会对原地址和镜像地址各打印一条进度，造成“两个进度条”。
curl_download_progress() {
  local url="$1" out="$2" final
  final=$(curl -fsSL --max-time 30 -o /dev/null -w '%{url_effective}' "$url" 2>/dev/null)
  [ -n "$final" ] || final="$url"
  curl -fL --progress-bar -o "$out" "$final"
}

# 预下载的 .apk 可能因 SourceForge 跳转/镜像不同步变成 HTML/错误页。
# apk add 返回码不能直接代表目标包已升级；必须安装后读回精确版本，失败再走仓库精确版本兜底。
apk_add_repo_exact() {
  local pkg="$1" want_ver="$2" log="$3" rc=0
  if [ -n "$want_ver" ]; then
    apk add --upgrade --latest --allow-untrusted --force-broken-world "$pkg=$want_ver" >> "$log" 2>&1
    rc=$?
    apk_installed_exact "$pkg" "$want_ver" && return 0
    # 不再回退 apk upgrade --available：OpenWrt APK 会为满足 world 约束顺手升级大量 LuCI/系统包，
    # 用户只想装一个可选组件时不应触发全系统事务。
    return $rc
  fi
  apk add --upgrade --latest --allow-untrusted --force-broken-world "$pkg" >> "$log" 2>&1
}

# 包安装/升级
# 主包走 curl 带进度下载（百分比），依赖包逐个显示 [N/总数] 包名级进度
# 过滤已知无害的 opkg 噪音: Configuring 进度、remove_obsolesced_files(旧文件已删)、opkg.lock 警告
opkg_preflight_installable() {
  # 先用 --noaction 做依赖预检，避免 --force-depends 把 LuCI 主包半升级后才发现 kmod/nftables 依赖不匹配。
  # 第三方/厂商固件常见: 普通 packages 源可用，但 targets/kmod 源不匹配，出现 kmod-nft-core / nftables-json incompatible。
  local target="$1" log="/tmp/opkg_preflight.log" target_name
  [ "$PKG_MGR" = "opkg" ] || return 0
  target_name=$(basename "$target")
  # 中文包只依赖已经安装的主包；用统一的已安装检测兼容不同 opkg
  # 的 Status 写法，不能硬编码为 install ok installed。
  case "$target_name" in
    pkg_luci-i18n-passwall-zh-cn*.ipk|luci-i18n-passwall-zh-cn*.ipk)
      check_installed luci-app-passwall && return 0
      ;;
    pkg_luci-i18n-passwall2-zh-cn*.ipk|luci-i18n-passwall2-zh-cn*.ipk)
      check_installed luci-app-passwall2 && return 0
      ;;
    pkg_xray-core*.ipk|xray-core*.ipk|pkg_chinadns-ng*.ipk|chinadns-ng*.ipk|pkg_v2ray-geoip*.ipk|v2ray-geoip*.ipk|pkg_v2ray-geosite*.ipk|v2ray-geosite*.ipk|pkg_geoview*.ipk|geoview*.ipk)
      # 这些是用户态程序/Geo 数据包，不应被其它包的 kmod 索引错误阻断；
      # 最终仍由真实 opkg install 检查它们自己的依赖。
      return 0
      ;;
  esac
  opkg install --noaction "$target" --force-downgrade --force-overwrite > "$log" 2>&1
  local preflight_rc=$?
  if [ "$preflight_rc" != "0" ] || grep -qE "pkg_hash_check_unresolved|cannot find dependency|incompatible with the architectures configured|Unknown package|No space left on device|kmod-|nftables-|Collected errors:" "$log" 2>/dev/null; then
    err "依赖预检失败，跳过安装/升级，避免半升级破坏现有版本"
    grep -E "pkg_hash_check_unresolved|cannot find dependency|incompatible with the architectures configured|Unknown package|No space left on device|kmod-|nftables-|Collected errors:|ERROR" "$log" 2>/dev/null || cat "$log"
    cp "$log" /tmp/po-last-opkg-preflight.log 2>/dev/null || true
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
  return 0
}
apk_install() {
  local pkg="$1" rc=0
  if [ "$PKG_MGR" != "apk" ]; then
    local url prog log="/tmp/opkg_install.log" repo_ver
    url=$(find_pkg_url "$pkg")
    repo_ver=$(get_repo_version "$pkg")
    # 预解析依赖清单 (模拟安装), 用于显示包名级进度; 排除主包自身(后面单独处理)
    local total=0 cur=0 dep deps
    # 如果 PassWall/SF 索引已被脚本手动兜底到 /var/opkg-lists，但 opkg 自身没有接收该 feed，
    # `opkg install --noaction luci-app-passwall` 会误报 Unknown package。
    # 此时只要 find_pkg_url 已经从索引/远端 Packages.gz 找到直链，就跳过包名预检，下载本地 ipk 后再对本地文件做真实依赖预检。
    if [ -z "$url" ] && ! opkg_preflight_installable "$pkg"; then
      return 2
    fi
    deps=$(find_pkg_depends "$pkg" | normalize_dep_names | grep -v "^$pkg$" || true)
    if [ -z "$deps" ] && [ -z "$url" ]; then
      deps=$(opkg install --noaction "$pkg" --force-downgrade --force-overwrite 2>/dev/null | grep "^Installing " | sed 's/Installing \(.*\) (.*/\1/' | grep -v "^$pkg$")
    fi
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
    if [ -n "$url" ]; then
      # 验证 URL 文件名版本 = 目标版本 (多源时 find_pkg_url 可能拿到旧源 URL, 下载旧版无意义)
      if [ -n "$repo_ver" ] && ! echo "$url" | grep -Fq "$repo_ver"; then
        info "索引版本不匹配 (期望 $repo_ver)，使用速度优先源安装..."
        # 保底仍调用 opkg，但前面的源顺序已是国内优先；正常路径不会走到这里。
        if ! opkg_preflight_installable "$pkg"; then rc=2; else
          opkg install "$pkg" --force-downgrade --force-overwrite > "$log" 2>&1
          rc=$?
        fi
        if [ -f "$log" ]; then
          grep -q "pkg_hash_check_unresolved" "$log" 2>/dev/null && rc=2
          grep -v -e "^Configuring" -e "^\.\.\.$" -e "^Collected errors:$" -e "^Removing obsolete file " -e "remove_obsolesced_files" -e "opkg\.lock" "$log" || true
        fi
        rm -f "$log"
      else
        prog="-sS"; [ -t 1 ] && prog="--progress-bar"
        info "下载 $pkg (带进度)..."
        if curl_download_progress "$url" "/tmp/pkg_$pkg.ipk"; then
          if ! opkg_preflight_installable "/tmp/pkg_$pkg.ipk"; then
            rc=2
          else
            # Geo/用户态包的索引可能被旧 kmod/混源依赖污染；本地 IPK 已由
            # 直链校验下载，安装时允许 opkg 忽略无关的未满足依赖，不能让
            # kmod-nft-* 阻断 chinadns-ng/v2ray-geo*。
            local local_force_depends=""
            case "$pkg" in
              chinadns-ng|v2ray-geoip|v2ray-geosite|geoview|xray-core) local_force_depends="--force-depends" ;;
            esac
            opkg install "/tmp/pkg_$pkg.ipk" --force-downgrade --force-overwrite $local_force_depends > "$log" 2>&1
            rc=$?
            cp "$log" /tmp/po-last-opkg-install.log 2>/dev/null || true
            grep -q "pkg_hash_check_unresolved" "$log" 2>/dev/null && [ -z "$local_force_depends" ] && rc=2
            grep -v -e "^Configuring" -e "^\.\.\.$" -e "^Collected errors:$" -e "^Removing obsolete file " -e "remove_obsolesced_files" -e "opkg\.lock" "$log" || true
          fi
          rm -f "/tmp/pkg_$pkg.ipk" "$log"
        else
          err "下载 $pkg 失败，回退 opkg 直接安装..."
          if ! opkg_preflight_installable "$pkg"; then rc=2; else
            opkg install "$pkg" --force-downgrade --force-overwrite > "$log" 2>&1
            rc=$?
          fi
          if [ -f "$log" ]; then
            grep -q "pkg_hash_check_unresolved" "$log" 2>/dev/null && rc=2
            grep -v -e "^Configuring" -e "^\.\.\.$" -e "^Collected errors:$" -e "^Removing obsolete file " -e "remove_obsolesced_files" -e "opkg\.lock" "$log" || true
          fi
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
          if ! opkg_preflight_installable "$dl_ipk"; then rc=2; else
            opkg install "$dl_ipk" --force-downgrade --force-overwrite > "$log" 2>&1
            rc=$?
          fi
          rm -f "$dl_ipk"
        else
          [ -n "$dl_ipk" ] && rm -f "$dl_ipk"
          info "下载版本不匹配 (期望 $repo_ver)，直接 opkg install..."
          if ! opkg_preflight_installable "$pkg"; then rc=2; else
            opkg install "$pkg" --force-downgrade --force-overwrite > "$log" 2>&1
            rc=$?
          fi
        fi
      else
        # opkg download 失败, 直接 opkg install
        if ! opkg_preflight_installable "$pkg"; then rc=2; else
          opkg install "$pkg" --force-downgrade --force-overwrite > "$log" 2>&1
          rc=$?
        fi
      fi
      if [ -f "$log" ]; then
        grep -q "pkg_hash_check_unresolved" "$log" 2>/dev/null && rc=2
        grep -v -e "^Configuring" -e "^\.\.\.$" -e "^Collected errors:$" -e "^Removing obsolete file " -e "remove_obsolesced_files" -e "opkg\.lock" "$log" || true
      fi
      rm -f "$log"
    fi
    if [ "$rc" != "0" ]; then
    case "$pkg" in
      luci-app-passwall|luci-app-passwall2|luci-app-ssr-plus)
        info "安装日志已保留: /tmp/po-last-opkg-install.log"
        ;;
    esac
  fi
  return $rc
  fi
  local log=/tmp/apk_add.log url prog repo_ver
  : > "$log"
  # --upgrade 是关键：apk add 默认不会替换已安装旧版，即使仓库已有新版本。
  # 先尝试 SourceForge 直链带进度；若本地包无效/未达到目标版本，必须回退仓库精确版本。
  repo_ver=$(get_repo_version "$pkg")
  url=$(find_apk_url "$pkg" "$repo_ver")
  if [ -n "$url" ]; then
    prog="-sS"; [ -t 1 ] && prog="--progress-bar"
    info "下载 $pkg (带进度)..."
    if curl -fL $prog -o "/tmp/pkg_$pkg.apk" "$url"; then
      apk add --upgrade --allow-untrusted --force-broken-world $APK_FORCE_REINSTALL_OPT "/tmp/pkg_$pkg.apk" >> "$log" 2>&1
      rc=$?
      rm -f "/tmp/pkg_$pkg.apk"
      if [ -n "$repo_ver" ] && ! apk_installed_exact "$pkg" "$repo_ver"; then
        info "$pkg 直链包未达到源版本，回退 apk 仓库安装..."
        apk_add_repo_exact "$pkg" "$repo_ver" "$log"
        rc=$?
      fi
    else
      err "下载 $pkg 失败，回退 apk 仓库安装..."
      apk_add_repo_exact "$pkg" "$repo_ver" "$log"
      rc=$?
    fi
  else
    apk_add_repo_exact "$pkg" "$repo_ver" "$log"
    rc=$?
  fi
  grep -v "^WARNING.*opening" "$log" || true
  rm -f "$log"
  if [ "$rc" != "0" ]; then
    case "$pkg" in
      luci-app-passwall|luci-app-passwall2|luci-app-ssr-plus)
        info "提示: 该架构 $SYS_ARCH 上游可能无预编译包，请改用 xray-core 纯内核方案/换固件"
        ;;
    esac
  fi
  return $rc
}

# 已安装包升级：APK 必须指定精确版本；只写包名时部分 OpenWrt apk-tools 只输出 OK 但不替换旧版
pkg_update() {
  local pkg="$1"
  local want_ver="$2"
  if [ "$PKG_MGR" = "apk" ]; then
    local log=/tmp/apk_upgrade.log rc=0 url prog
    if [ -n "$want_ver" ]; then
      # 先尝试直链包以显示进度；安装后若未读回精确版本，再回退 apk 仓库精确版本。
      : > "$log"
      url=$(find_apk_url "$pkg" "$want_ver")
      if [ -n "$url" ]; then
        prog="-sS"; [ -t 1 ] && prog="--progress-bar"
        info "下载 $pkg (带进度)..."
        if curl -fL $prog -o "/tmp/pkg_$pkg.apk" "$url"; then
          apk add --upgrade --latest --allow-untrusted --force-broken-world "/tmp/pkg_$pkg.apk" >> "$log" 2>&1
          rc=$?
          rm -f "/tmp/pkg_$pkg.apk"
        else
          err "下载 $pkg 失败，回退 apk 仓库升级..."
          rc=1
        fi
      else
        rc=1
      fi
      if ! apk_installed_exact "$pkg" "$want_ver"; then
        info "$pkg 未达到目标版本，回退 apk 仓库升级..."
        apk_add_repo_exact "$pkg" "$want_ver" "$log"
        rc=$?
      fi
    else
      apk add --upgrade --latest --allow-untrusted --force-broken-world "$pkg" > "$log" 2>&1
      rc=$?
    fi
    # apk upgrade --available 可能为满足 world 约束安装/卸载无关包；如果目标包没实际变更，避免刷出误导性 Purging/Installing 噪音。
    if [ -n "$want_ver" ] && ! apk_installed_exact "$pkg" "$want_ver"; then
      grep -E "ERROR|WARNING|conflict|breaks|unable|failed|permission|No such|not found" "$log" || true
    else
      grep -v "^WARNING.*opening" "$log" || true
    fi
    rm -f "$log"
    return $rc
  fi
  apk_install "$pkg"
}

clean_luci_cache() {
  rm -rf /tmp/luci-indexcache.* /tmp/luci-modulecache/ 2>/dev/null || true
  /etc/init.d/rpcd reload >/dev/null 2>&1 || true
}
clean_apk_broken_world() {
  [ "$PKG_MGR" = "apk" ] || return 0
  [ -f /etc/apk/world ] || return 0
  cp /etc/apk/world /tmp/apk.world.po-bak 2>/dev/null || true
  # OpenWrt apk world 可带约束/校验后缀，如 luci-app-ssr-plus><Qxxx；按前缀清理。
  # naiveprox4 是错误包名；naiveproxy 在 25.12/APK 上可能依赖不存在的 libatomic1，留在 world 会让 iStore 内安装任何插件都失败。
  awk '
    $0 ~ /^(dns2tcp|lua-neturl|luci-app-ssr-plus|mosdns|naiveprox4|naiveproxy|libatomic1|nping|sing-box)([<>=~].*)?$/ {next}
    $0 ~ /^naiveprox/ {next}
    $0 ~ /^libatomic/ {next}
    {print}
  ' /etc/apk/world > /tmp/apk.world.po-clean 2>/dev/null || cp /etc/apk/world /tmp/apk.world.po-clean 2>/dev/null
  if ! cmp -s /etc/apk/world /tmp/apk.world.po-clean 2>/dev/null; then
    cat /tmp/apk.world.po-clean > /etc/apk/world 2>/dev/null || true
    ok "已清理 APK world 残留约束: naiveprox*/libatomic*"
  fi
  rm -f /tmp/apk.world.po-clean 2>/dev/null || true
}


clean_apk_broken_installed() {
  [ "$PKG_MGR" = "apk" ] || return 0
  clean_apk_broken_world
  # 如果已安装 naiveproxy 但系统没有 libatomic1，APK 求解器会继续报 libatomic1 missing；先移除这个已破损包。
  if apk list --installed 'naiveproxy' 2>/dev/null | grep -q '^naiveproxy-'; then
    if ! apk info 'libatomic1' >/dev/null 2>&1 && ! apk list --installed 'libatomic1' 2>/dev/null | grep -q '^libatomic1-'; then
      info "检测到已安装 naiveproxy 依赖缺失 libatomic1，先移除破损 naiveproxy"
      apk del --force-broken-world naiveproxy >/tmp/apk_clean_naiveproxy.log 2>&1 || true
      grep -E "ERROR|WARNING|failed|not found|unable|cannot|conflict|breaks" /tmp/apk_clean_naiveproxy.log 2>/dev/null || true
      rm -f /tmp/apk_clean_naiveproxy.log 2>/dev/null || true
    fi
  fi
}

remove_pkg_keep_config() {
  local pkg="$1" desc="$2" log="/tmp/po_remove.log" rc=0
  if ! check_installed "$pkg"; then
    info "$desc 未登记安装，跳过包管理器卸载（继续清理程序文件）"
    return 0
  fi
  info "卸载 $desc（$(config_action_text)）..."
  if [ "$PKG_MGR" = "opkg" ]; then
    opkg remove "$pkg" > "$log" 2>&1
    rc=$?
    grep -v -e "^Removing package" -e "^Configuring" -e "^Collected errors:$" -e "opkg\.lock" "$log" || true
  else
    # APK 的 world 里如果残留不存在的约束，apk del 任何包都会先解依赖失败；先清理已知 PO/SSR 残留再删。
    clean_apk_broken_world
    apk del --force-broken-world "$pkg" > "$log" 2>&1
    rc=$?
    if [ "$rc" != "0" ] && grep -q "unable to select packages\|no such package\|required by: world" "$log" 2>/dev/null; then
      info "APK world/依赖存在残留约束，清理后强制重试..."
      clean_apk_broken_world
      apk del --force-broken-world "$pkg" > "$log" 2>&1
      rc=$?
    fi
    grep -v "^WARNING.*opening" "$log" || true
  fi
  rm -f "$log"
  if [ "$rc" = "0" ] || ! check_installed "$pkg"; then
    ok "$desc 已卸载"
    return 0
  fi
  err "$desc 卸载失败: 包管理器返回 $rc，继续尝试安装覆盖"
  return 1
}
remove_ssr_manual_files_keep_config() {
  # 只清 SSR Plus 程序文件，保留 /etc/config/shadowsocksr 用户配置。
  rm -f /usr/lib/lua/luci/controller/shadowsocksr.lua \
        /usr/bin/ssr-monitor /usr/bin/ssr-rules /usr/bin/ssr-switch \
        /etc/init.d/shadowsocksr /etc/hotplug.d/iface/99-ssrplus-pppoe \
        /usr/share/rpcd/acl.d/luci-app-ssr-plus.json \
        /usr/share/ucitrack/luci-app-ssr-plus.json \
        /lib/upgrade/keep.d/luci-app-ssr-plus 2>/dev/null || true
  rm -rf /usr/lib/lua/luci/model/cbi/shadowsocksr \
         /usr/lib/lua/luci/view/shadowsocksr \
         /usr/share/shadowsocksr 2>/dev/null || true
}

remove_adguardhome_keep_config() {
  # 卸载 AdGuardHome 程序和服务；是否保留 /opt/AdGuardHome/AdGuardHome.yaml 与 data 由 UNINSTALL_KEEP_CONFIG 控制。
  local tmp="/tmp/AdGuardHome.keep"
  if [ -x /opt/AdGuardHome/AdGuardHome ]; then
    /opt/AdGuardHome/AdGuardHome -s stop >/dev/null 2>&1 || true
    /opt/AdGuardHome/AdGuardHome -s uninstall >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
  if [ "$UNINSTALL_KEEP_CONFIG" != "0" ]; then
    mkdir -p "$tmp" 2>/dev/null || true
    [ -f /opt/AdGuardHome/AdGuardHome.yaml ] && cp /opt/AdGuardHome/AdGuardHome.yaml "$tmp/AdGuardHome.yaml" 2>/dev/null || true
    [ -d /opt/AdGuardHome/data ] && cp -a /opt/AdGuardHome/data "$tmp/data" 2>/dev/null || true
  fi
  rm -f /usr/bin/AdGuardHome /etc/init.d/AdGuardHome 2>/dev/null || true
  rm -rf /opt/AdGuardHome 2>/dev/null || true
  if [ "$UNINSTALL_KEEP_CONFIG" != "0" ]; then
    mkdir -p /opt/AdGuardHome 2>/dev/null || true
    [ -f "$tmp/AdGuardHome.yaml" ] && mv "$tmp/AdGuardHome.yaml" /opt/AdGuardHome/AdGuardHome.yaml 2>/dev/null || true
    [ -d "$tmp/data" ] && mv "$tmp/data" /opt/AdGuardHome/data 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
remove_istore_manual_files_keep_config() {
  # APK/手动解包安装的 iStore 不一定登记在包管理器中，仍需清理实际文件。
  /etc/init.d/istore stop >/dev/null 2>&1 || true
  /etc/init.d/tasks stop >/dev/null 2>&1 || true
  rm -f /bin/is-opkg /usr/libexec/taskd /etc/init.d/istore /etc/init.d/tasks \
        /etc/uci-defaults/luci-app-store \
        /usr/share/rpcd/acl.d/luci-app-store.json \
        /usr/share/ucitrack/luci-app-store.json 2>/dev/null || true
  rm -rf /www/luci-static/istore /usr/lib/lua/luci/controller/store.lua \
         /usr/lib/lua/luci/model/cbi/store /usr/lib/lua/luci/view/store \
         /usr/lib/lua/luci/controller/taskd.lua /usr/lib/lua/luci/model/cbi/taskd \
         /usr/lib/lua/luci/view/taskd /usr/lib/lua/luci/model/cbi/xterm \
         /usr/lib/lua/luci/view/xterm /usr/share/istore /usr/share/taskd \
         /usr/share/xterm /usr/libexec/luci-taskd 2>/dev/null || true
}
remove_plugin_config() {
  local plugin="$1"
  [ "$UNINSTALL_KEEP_CONFIG" = "0" ] || return 0
  case "$plugin" in
    passwall)
      rm -f /etc/config/passwall 2>/dev/null || true
      ;;
    passwall2)
      rm -f /etc/config/passwall2 2>/dev/null || true
      ;;
    openclash)
      rm -f /etc/config/openclash 2>/dev/null || true
      rm -rf /etc/openclash /etc/openclash_backup 2>/dev/null || true
      ;;
    ssr)
      rm -f /etc/config/shadowsocksr 2>/dev/null || true
      ;;
    istore)
      rm -f /etc/config/store /etc/config/istore /etc/config/tasks 2>/dev/null || true
      rm -rf /usr/share/istore /tmp/istore 2>/dev/null || true
      ;;
  esac
}
config_action_text() {
  [ "$UNINSTALL_KEEP_CONFIG" = "0" ] && echo "删除配置" || echo "保留配置"
}
force_reinstall_selected() {
  [ "$FORCE_REINSTALL" = "1" ] || return 0
  hdr "卸载旧版主程序"
  clean_apk_broken_world
  if [ "$INSTALL_PW" = "1" ]; then
    remove_pkg_keep_config "luci-i18n-passwall-zh-cn" "PassWall 中文包" || true
    remove_pkg_keep_config "luci-app-passwall" "PassWall" || true
    remove_plugin_config "passwall"
  fi
  if [ "$INSTALL_PW2" = "1" ]; then
    remove_pkg_keep_config "luci-i18n-passwall2-zh-cn" "PassWall2 中文包" || true
    remove_pkg_keep_config "luci-app-passwall2" "PassWall2" || true
    remove_plugin_config "passwall2"
  fi
  if [ "$INSTALL_OC" = "1" ]; then
    remove_pkg_keep_config "luci-app-openclash" "OpenClash" || true
    remove_plugin_config "openclash"
  fi
  if [ "$INSTALL_SSR" = "1" ]; then
    remove_pkg_keep_config "luci-app-ssr-plus" "SSR Plus" || true
    remove_ssr_manual_files_keep_config
    remove_plugin_config "ssr"
    ok "SSR Plus 程序文件已清理（$(config_action_text)）"
  fi
  if [ "$INSTALL_AGH" = "1" ]; then
    remove_adguardhome_keep_config
    ok "AdGuardHome 程序文件已清理（$(config_action_text)）"
  fi
  if [ "$INSTALL_ISTORE" = "1" ]; then
    remove_pkg_keep_config "luci-app-store" "iStore 商店" || true
    remove_pkg_keep_config "luci-lib-taskd" "iStore taskd 库" || true
    remove_pkg_keep_config "luci-lib-xterm" "iStore xterm 库" || true
    remove_pkg_keep_config "taskd" "iStore taskd" || true
    remove_istore_manual_files_keep_config
    remove_plugin_config "istore"
    ok "iStore 商店已清理（$(config_action_text)）"
  fi
  clean_luci_cache
}
uninstall_selected_only() {
  [ "$UNINSTALL_ONLY" = "1" ] || return 0
  hdr "卸载已选插件"
  clean_apk_broken_world
  if [ "$INSTALL_PW" = "1" ]; then
    remove_pkg_keep_config "luci-i18n-passwall-zh-cn" "PassWall 中文包" || true
    remove_pkg_keep_config "luci-app-passwall" "PassWall" || true
    remove_plugin_config "passwall"
  fi
  if [ "$INSTALL_PW2" = "1" ]; then
    remove_pkg_keep_config "luci-i18n-passwall2-zh-cn" "PassWall2 中文包" || true
    remove_pkg_keep_config "luci-app-passwall2" "PassWall2" || true
    remove_plugin_config "passwall2"
  fi
  if [ "$INSTALL_OC" = "1" ]; then
    remove_pkg_keep_config "luci-app-openclash" "OpenClash" || true
    remove_plugin_config "openclash"
  fi
  if [ "$INSTALL_SSR" = "1" ]; then
    remove_pkg_keep_config "luci-app-ssr-plus" "SSR Plus" || true
    remove_ssr_manual_files_keep_config
    remove_plugin_config "ssr"
    ok "SSR Plus 程序文件已清理（$(config_action_text)）"
  fi
  if [ "$INSTALL_AGH" = "1" ]; then
    remove_adguardhome_keep_config
    ok "AdGuardHome 程序文件已清理（$(config_action_text)）"
  fi
  if [ "$INSTALL_ISTORE" = "1" ]; then
    remove_pkg_keep_config "luci-app-store" "iStore 商店" || true
    remove_pkg_keep_config "luci-lib-taskd" "iStore taskd 库" || true
    remove_pkg_keep_config "luci-lib-xterm" "iStore xterm 库" || true
    remove_pkg_keep_config "taskd" "iStore taskd" || true
    remove_istore_manual_files_keep_config
    remove_plugin_config "istore"
    ok "iStore 商店已清理（$(config_action_text)）"
  fi
  clean_luci_cache
  echo ""
  echo "============================================="
  echo " [✓] 卸载完成！"
  echo "============================================="
  echo ""
  echo "系统: $SYS_DESC | $SYS_RELEASE | $SYS_ARCH | $PKG_MGR"
  exit 0
}

verify_package_installed() {
  local pkg="$1" path files
  check_installed "$pkg" || return 1
  # OPKG 可能只更新了 status 数据库，但实际 IPK 解包失败；
  # 中文语言包必须确认至少一个实际的普通文件已经落盘。
  if [ "$PKG_MGR" = "opkg" ]; then
    case "$pkg" in
      luci-i18n-passwall-zh-cn|luci-i18n-passwall2-zh-cn)
        files=$(opkg files "$pkg" 2>/dev/null | awk '/^\// {print; exit}')
        [ -n "$files" ] || return 1
        path="$files"
        [ -f "$path" ] || return 1
        ;;
    esac
  fi
  return 0
}

# 简化版（不询问，直接安装）
pkginstall() {
  local pkg="$1" desc="$2"
  # Xray 官方/手动更新可能已经放置 /usr/bin/xray，但 opkg 数据库没有
  # xray-core 记录；不要因此重复走错误的仓库安装路径。
  if [ "$pkg" = "xray-core" ] && command -v xray >/dev/null 2>&1; then
    ok "$desc 已存在 ($(xray version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo 未知) ✓"
    return 0
  fi
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
    if verify_package_installed "$pkg"; then
      ok "$desc $(get_version "$pkg") ✓"
    else
      err "$desc 安装失败（包已登记但文件未落盘）"
      return 1
    fi
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
    if verify_package_installed "$pkg"; then
      ok "$desc $(get_version "$pkg") ✓"
    else
      err "$desc 安装失败（包已登记但文件未落盘）"
      return 1
    fi
  fi
}

uninstall_selected_only
force_reinstall_selected

# 旧版 MIPS OPKG 源的 xray-core 常长期停留在 1.x；官方 Release 仍提供 mips32le 二进制。
# 只替换独立 /usr/bin/xray，不改 LuCI、配置、内核模块；下载/解压/执行校验都成功才覆盖旧文件。
update_xray_official_mips() {
  [ "$PKG_MGR" = "opkg" ] || return 0
  case "$SYS_ARCH" in mipsel_*|mipsel) ;; *) return 0;; esac
  command -v curl >/dev/null 2>&1 || { info "跳过 Xray 官方更新：缺少 curl"; return 0; }
  if ! command -v unzip >/dev/null 2>&1; then
    info "Xray 官方更新需要 unzip，尝试安装..."
    opkg install unzip >/tmp/po_unzip_install.log 2>&1
    if ! command -v unzip >/dev/null 2>&1; then
      err "unzip 安装失败，跳过 Xray 官方更新"
      grep -E "ERROR|Collected errors|cannot find|No space|failed" /tmp/po_unzip_install.log 2>/dev/null || true
      rm -f /tmp/po_unzip_install.log
      return 0
    fi
    ok "unzip 已安装"
    rm -f /tmp/po_unzip_install.log
  fi
  local api json tag url u cur new bin=/usr/bin/xray tmp=/tmp/xray-mips.zip newbin=/tmp/xray-new
  cur=$($bin version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  api="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
  for u in $(gh_candidates "$api"); do
    json=$(curl -sL --connect-timeout 10 --max-time 25 "$u" 2>/dev/null) || continue
    tag=$(printf '%s' "$json" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4)
    url=$(printf '%s' "$json" | grep -oE 'https://[^" ]*/Xray-linux-mips32le\.zip' | head -1)
    [ -n "$tag" ] && [ -n "$url" ] && break
  done
  [ -n "$url" ] || { info "跳过 Xray 官方更新：无法获取 mips32le Release"; return 0; }
  new=${tag#v}
  if [ -n "$cur" ] && ! version_newer "$new" "$cur"; then
    ok "Xray 官方版 ($cur) 已是最新版"
    return 0
  fi
  info "更新 Xray 官方 mips32le: ${cur:-未知} → $new"
  rm -f "$tmp" "$newbin"
  for u in $(gh_candidates "$url"); do
    curl -fL --connect-timeout 10 --max-time 180 -o "$tmp" "$u" 2>/dev/null || { rm -f "$tmp"; continue; }
    # MT7621 等 mipsel_24kc 通常没有可用硬件 FPU；官方压缩包同时提供 xray_softfloat，
    # 普通 xray 会因 FPU/ABI 不兼容无法运行，必须优先取 softfloat 版本。
    unzip -p "$tmp" xray_softfloat > "$newbin" 2>/dev/null || unzip -p "$tmp" xray > "$newbin" 2>/dev/null || { rm -f "$tmp" "$newbin"; continue; }
    [ -s "$newbin" ] && break
  done
  if [ ! -s "$newbin" ]; then
    err "Xray 官方 mips32le 下载或解压失败，保留当前版本 ${cur:-未知}"
    rm -f "$tmp" "$newbin"
    return 0
  fi
  chmod 755 "$newbin"
  if ! "$newbin" version >/tmp/xray_version.log 2>&1; then
    err "Xray 官方二进制无法运行，保留当前版本 ${cur:-未知}"
    rm -f "$tmp" "$newbin" /tmp/xray_version.log
    return 0
  fi
  mv "$bin" "$bin.po-bak" 2>/dev/null || true
  mv "$newbin" "$bin" 2>/dev/null || { [ -f "$bin.po-bak" ] && mv "$bin.po-bak" "$bin"; err "Xray 替换失败，已恢复旧版本"; rm -f "$tmp" /tmp/xray_version.log; return 0; }
  new=$($bin version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [ -n "$new" ] && ok "Xray 官方内核已更新 ($new)" || err "Xray 更新后版本读取失败"
  rm -f "$tmp" /tmp/xray_version.log
}

install_passwall_iptables_compat() {
  [ "$PKG_MGR" = "opkg" ] || return 0
  # 24.10 正常使用 fw4/nftables 时不需要旧版 iptables 透明代理扩展。
  # 只有检测到 fw4 缺失、PassWall 会回退 iptables 时才补装，避免在
  # 正常 nft 环境中额外引入旧版兼容依赖和不必要的 kmod 冲突。
  if command -v fw4 >/dev/null 2>&1 || [ -x /sbin/fw4 ] || [ -x /usr/sbin/fw4 ]; then
    info "检测到 fw4/nftables 环境，跳过旧版 iptables 兼容依赖"
    return 0
  fi
  info "未检测到 fw4，PassWall 将回退 iptables，检查兼容依赖..."
  # Kiddin' 旧版固件可能没有完整 fw4/nft 环境，PassWall 会回退 iptables。
  # 这些是用户态 iptables 扩展包；逐个交给 opkg 安装，不绕过真实依赖检查。
  local pkg rc
  for pkg in iptables-mod-tproxy iptables-mod-socket iptables-mod-iprange iptables-mod-conntrack-extra; do
    if check_installed "$pkg"; then
      ok "$pkg 已安装"
      continue
    fi
    info "安装 PassWall 兼容依赖: $pkg..."
    opkg install "$pkg" >/tmp/po_iptables_compat.log 2>&1
    rc=$?
    if [ "$rc" = "0" ] && check_installed "$pkg"; then
      ok "$pkg 安装成功"
    else
      err "$pkg 安装失败（需要匹配当前固件的 kmod/iptables 源）"
      grep -E "cannot find dependency|incompatible|Unknown package|Collected errors|No space|ERROR" /tmp/po_iptables_compat.log 2>/dev/null || true
    fi
  done
  rm -f /tmp/po_iptables_compat.log
}

# PassWall2 官方 Release 安装：主包按官方 README 从 GitHub 获取；
# 依赖仍由包管理器解析，缺失时使用前面配置的 PassWall 源兜底。
get_passwall2_release_asset() {
  local ext="$1" api json u pattern
  api="https://api.github.com/repos/Openwrt-Passwall/openwrt-passwall2/releases/latest"
  for u in $(gh_candidates "$api"); do
    json=$(curl -fsSL --connect-timeout 10 --max-time 30 "$u" 2>/dev/null) || continue
    if [ "$ext" = "ipk" ]; then
      pattern='https://[^" ]*/luci-app-passwall2_[^" ]*_all\.ipk'
    else
      pattern='https://[^" ]*/luci-app-passwall2-[^" ]*\.apk'
    fi
    printf '%s\n' "$json" | grep -oE "$pattern" | head -1 && return 0
  done
  return 1
}
install_passwall2_release() {
  local ext="$1" url u pkgfile rc=1 oldver newver magic
  pkgfile="/tmp/luci-app-passwall2.$ext"
  url=$(get_passwall2_release_asset "$ext") || { err "无法获取 PassWall2 官方 Release ($ext)"; return 1; }
  oldver=$(get_version "luci-app-passwall2")
  info "下载 PassWall2 官方 Release ($ext)..."
  rm -f "$pkgfile"
  for u in $(gh_candidates "$url"); do
    curl -fL --connect-timeout 10 --max-time 120 -o "$pkgfile" "$u" 2>/dev/null || { rm -f "$pkgfile"; continue; }
    [ -s "$pkgfile" ] || { rm -f "$pkgfile"; continue; }
    if [ "$ext" = "apk" ]; then
      magic=$(dd if="$pkgfile" bs=1 count=4 2>/dev/null); [ "$magic" = "ADBd" ] || { rm -f "$pkgfile"; continue; }
    else
      magic=$(dd if="$pkgfile" bs=1 count=4 2>/dev/null)
      [ "$magic" = "!<ar" ] || { magic=$(dd if="$pkgfile" bs=1 count=2 2>/dev/null); [ "$magic" = "$(printf '\037\213')" ] || { rm -f "$pkgfile"; continue; }; }
    fi
    break
  done
  [ -s "$pkgfile" ] || { err "PassWall2 官方 Release 下载失败"; return 1; }
  if [ "$ext" = "apk" ]; then
    apk add --upgrade --allow-untrusted --force-broken-world "$pkgfile" >/tmp/passwall2-release.log 2>&1
    rc=$?
  else
    opkg install "$pkgfile" >/tmp/passwall2-release.log 2>&1
    rc=$?
  fi
  grep -E "ERROR|warning|cannot find|Unknown package|incompatible|No space|Collected errors" /tmp/passwall2-release.log 2>/dev/null || true
  rm -f "$pkgfile" /tmp/passwall2-release.log
  newver=$(get_version "luci-app-passwall2")
  if [ "$rc" = "0" ] && [ -n "$newver" ]; then
    if [ -n "$oldver" ] && [ "$newver" = "$oldver" ]; then
      ok "PassWall2 $newver ✓ (官方 Release，已是当前版本)"
    else
      ok "PassWall2: ${oldver:-未安装} → $newver ✓ (官方 Release)"
    fi
    return 0
  fi
  err "PassWall2 官方 Release 安装失败（当前版本: ${newver:-未安装}）"
  return 1
}

# PassWall
if [ "$INSTALL_PW" = "1" ]; then
  pkginstall "luci-app-passwall" "PassWall" && pkginstall "luci-i18n-passwall-zh-cn" "PassWall 中文包"
  update_xray_official_mips
  install_passwall_iptables_compat
fi

# PassWall2
# 按 PassWall2 官方 README：OPKG 先安装 GitHub Release 主包；
# APK 优先使用官方推荐的 SourceForge APK 仓库。依赖由包管理器自动解析，
# 只有主包安装失败时才回退到另一条官方路径。
if [ "$INSTALL_PW2" = "1" ]; then
  if [ "$PKG_MGR" = "opkg" ]; then
    if ! install_passwall2_release "ipk"; then
      info "PassWall2 官方 IPK 安装失败，使用已配置的 PassWall 源回退安装..."
      pkginstall "luci-app-passwall2" "PassWall2" || true
    fi
  else
    if ! pkginstall "luci-app-passwall2" "PassWall2"; then
      info "PassWall2 APK 仓库安装失败，回退 GitHub 官方 APK..."
      install_passwall2_release "apk" || true
    fi
  fi
  # 中文包是可选语言包，不应阻断 PassWall2 主程序安装。
  pkginstall "luci-i18n-passwall2-zh-cn" "PassWall2 中文包" || true
  # PassWall/PassWall2 默认核心统一在后面的“默认核心组件”阶段安装，避免重复安装。
  if [ "$INSTALL_PW$INSTALL_PW2" = "10" ]; then
    update_xray_official_mips
  fi
fi

# SSR Plus: fw876/helloworld 官方 release 直装。release 同时提供：
#   luci-app-ssr-plus_196-r7_all.ipk (OPKG)
#   luci-app-ssr-plus-196-r7.apk (APK)
# opkg 下仍保留 openwrt.ai/kiddin9 作为依赖源；APK 下直接安装 release apk。
get_ssr_latest_json() {
  local api="https://api.github.com/repos/fw876/helloworld/releases/latest" u json
  for u in $(gh_candidates "$api"); do
    json=$(curl -sL --max-time 20 "$u" 2>/dev/null) || continue
    echo "$json" | grep -q '"tag_name"' || continue
    echo "$json"
    return 0
  done
  return 1
}
get_ssr_asset_url() {
  local ext="$1" json pat
  json=$(get_ssr_latest_json) || return 1
  if [ "$ext" = "apk" ]; then
    pat='https://[^" ]*/luci-app-ssr-plus-[^" ]*\.apk'
  else
    pat='https://[^" ]*/luci-app-ssr-plus_[^" ]*_all\.ipk'
  fi
  printf '%s\n' "$json" | grep -oE "$pat" | head -1
}
ssr_ver_from_url() {
  local url="$1" ext="$2"
  if [ "$ext" = "apk" ]; then
    basename "$url" | sed -n 's/^luci-app-ssr-plus-\(.*\)\.apk$/\1/p'
  else
    basename "$url" | sed -n 's/^luci-app-ssr-plus_\(.*\)_all\.ipk$/\1/p'
  fi
}
download_ssr_release_pkg() {
  local ext="$1" out="$2" url u magic
  url=$(get_ssr_asset_url "$ext") || return 1
  [ -n "$url" ] || return 1
  SSR_RELEASE_URL="$url"
  SSR_RELEASE_VER=$(ssr_ver_from_url "$url" "$ext")
  for u in $(gh_candidates "$url"); do
    curl -fL -# --max-time 90 -o "$out" "$u" 2>/dev/null
    if [ -s "$out" ]; then
      case "$ext" in
        apk) magic=$(dd if="$out" bs=1 count=4 2>/dev/null); [ "$magic" = "ADBd" ] && return 0 ;;
        ipk) magic=$(dd if="$out" bs=1 count=4 2>/dev/null); [ "$magic" = "!<ar" ] && return 0
             magic=$(dd if="$out" bs=1 count=2 2>/dev/null); [ "$magic" = "$(printf '\037\213')" ] && return 0 ;;
      esac
    fi
    rm -f "$out"
  done
  return 1
}
ensure_lua_neturl_file() {
  # SSR Plus client.lua uses `require "url"`; lua-neturl installs exactly /usr/lib/lua/url.lua.
  # On APK 25.12, apk may print OK but not register/extract lua-neturl, so repair the single Lua module directly.
  local dst="/usr/lib/lua/url.lua" url
  [ -s "$dst" ] && return 0
  mkdir -p /usr/lib/lua 2>/dev/null || true
  url="https://raw.githubusercontent.com/golgote/neturl/master/lib/net/url.lua"
  for u in $(gh_candidates "$url"); do
    curl -fsL --max-time 20 -o "$dst.tmp" "$u" 2>/dev/null || { rm -f "$dst.tmp"; continue; }
    if grep -q 'return M' "$dst.tmp" 2>/dev/null && grep -q 'function M.parse' "$dst.tmp" 2>/dev/null; then
      mv "$dst.tmp" "$dst"
      chmod 644 "$dst" 2>/dev/null || true
      ok "lua-neturl 模块已修复 (/usr/lib/lua/url.lua)"
      return 0
    fi
    rm -f "$dst.tmp"
  done
  err "lua-neturl 模块修复失败：无法下载 url.lua"
  return 1
}

ssr_dep_bin() {
  case "$1" in
    nping) echo "nping" ;;
    mosdns) echo "mosdns" ;;
    microsocks) echo "microsocks" ;;
    ipt2socks) echo "ipt2socks" ;;
    dns2socks) echo "dns2socks" ;;
    xray-core) echo "xray" ;;
    *) echo "" ;;
  esac
}
ssr_dep_present() {
  local pkg="$1" bin
  check_installed "$pkg" && return 0
  bin=$(ssr_dep_bin "$pkg")
  [ -n "$bin" ] && command -v "$bin" >/dev/null 2>&1 && return 0
  return 1
}
ssr_depinstall() {
  local pkg="$1" desc="$2" required="$3" rc=0 ver=""
  if ssr_dep_present "$pkg"; then
    ver=$(get_version "$pkg")
    [ -n "$ver" ] && ok "$desc ($ver) ✓" || ok "$desc 已存在 ✓"
    return 0
  fi
  # 可选依赖只在源里明确存在时才尝试，避免 APK 25.12 的空 OK/404 噪音。
  if [ "$required" != "1" ] && [ -z "$(get_repo_version "$pkg")" ]; then
    info "$desc: 可选组件源中未找到，跳过"
    return 0
  fi
  info "安装 $desc..."
  apk_install "$pkg"
  rc=$?
  if ssr_dep_present "$pkg"; then
    ver=$(get_version "$pkg")
    [ -n "$ver" ] && ok "$desc ($ver) ✓" || ok "$desc 已存在 ✓"
    return 0
  fi
  # OpenWrt APK 25.12 对本地/部分仓库包可能返回 OK 但不登记；SSR Plus 已有主程序兜底，依赖不在这里刷红。
  if [ "$rc" = "0" ]; then
    info "$desc: 包管理器返回 OK 但未登记，继续安装 SSR Plus"
  elif [ "$required" = "1" ]; then
    info "$desc: 未确认安装，继续；若 SSR Plus 页面异常再补装此依赖"
  else
    info "$desc: 可选组件未安装，继续"
  fi
  return 0
}
install_ssr_dependencies() {
  ssr_depinstall "coreutils" "Coreutils" 1
  ssr_depinstall "coreutils-base64" "Coreutils Base64" 1
  ssr_depinstall "dnsmasq-full" "dnsmasq-full" 1
  ssr_depinstall "jq" "jq" 1
  ssr_depinstall "ip-full" "ip-full" 1
  ssr_depinstall "lua" "Lua" 1
  ssr_depinstall "lua-neturl" "lua-neturl" 1
  ensure_lua_neturl_file
  ssr_depinstall "libuci-lua" "libuci-lua" 1
  ssr_depinstall "luci-compat" "LuCI Compat" 1
  ssr_depinstall "resolveip" "ResolveIP" 1
  ssr_depinstall "unzip" "Unzip" 1
  ssr_depinstall "xz" "XZ" 1
  ssr_depinstall "xz-utils" "XZ Utils" 1
  ssr_depinstall "microsocks" "Microsocks" 1
  ssr_depinstall "ipt2socks" "IPT2SOCKS" 1
  ssr_depinstall "xray-core" "Xray 内核" 1
  # 以下为 SSR Plus 的协议/加速/规则更新可选组件；源中没有就跳过，不影响主程序页面安装。
  ssr_depinstall "dns2tcp" "DNS2TCP" 0
  ssr_depinstall "tcping" "TCPing" 0
  ssr_depinstall "nping" "Nping" 0
  ssr_depinstall "lyaml" "lyaml" 0
  ssr_depinstall "dns2socks" "DNS2SOCKS" 0
  ssr_depinstall "mosdns" "MosDNS" 0
  ssr_depinstall "shadowsocksr-libev-ssr-check" "SSR Check" 0
  ssr_depinstall "shadowsocksr-libev-ssr-local" "SSR Local" 0
  ssr_depinstall "shadowsocksr-libev-ssr-redir" "SSR Redir" 0
  ssr_depinstall "shadowsocksr-libev-ssr-server" "SSR Server" 0
  ssr_depinstall "shadowsocks-rust-sslocal" "Shadowsocks Rust Local" 0
  ssr_depinstall "shadowsocks-rust-ssserver" "Shadowsocks Rust Server" 0
  ssr_depinstall "simple-obfs-client" "Simple-Obfs Client" 0
  ssr_depinstall "v2ray-geoip" "v2ray-geoip" 0
  ssr_depinstall "v2ray-geosite" "v2ray-geosite" 0
}

ssr_files_installed() {
  [ -s /usr/lib/lua/luci/controller/shadowsocksr.lua ] && [ -x /etc/init.d/shadowsocksr ] && return 0
  [ -s /usr/share/rpcd/acl.d/luci-app-ssr-plus.json ] && [ -s /etc/config/shadowsocksr ] && return 0
  return 1
}

install_ssr_manual_from_ipk() {
  local ipk="/tmp/luci-app-ssr-plus.manual.ipk" work="/tmp/ssrplus-ipk" log="/tmp/ssr_manual_install.log" rc=0
  info "包管理器未登记 SSR Plus，回退解包安装官方 IPK..."
  rm -rf "$work" "$ipk" "$log"
  mkdir -p "$work" || return 1
  if ! download_ssr_release_pkg "ipk" "$ipk"; then
    err "SSR Plus IPK 兜底下载失败"
    rm -rf "$work" "$ipk"
    return 1
  fi
  if ! tar -xzf "$ipk" -C "$work" > "$log" 2>&1; then
    err "SSR Plus IPK 解包失败"
    grep -E "ERROR|failed|invalid|not found|No such" "$log" || true
    rm -rf "$work" "$ipk" "$log"
    return 1
  fi
  if [ ! -s "$work/data.tar.gz" ]; then
    err "SSR Plus IPK 缺少 data.tar.gz，无法兜底安装"
    rm -rf "$work" "$ipk" "$log"
    return 1
  fi
  tar -xzf "$work/data.tar.gz" -C / >> "$log" 2>&1
  rc=$?
  chmod +x /etc/init.d/shadowsocksr /usr/bin/ssr-* 2>/dev/null || true
  [ -x /etc/uci-defaults/luci-ssr-plus ] && /etc/uci-defaults/luci-ssr-plus >> "$log" 2>&1 || true
  /etc/init.d/rpcd reload >/dev/null 2>&1 || true
  rm -rf /tmp/luci-indexcache.* /tmp/luci-modulecache/ 2>/dev/null || true
  ensure_lua_neturl_file
  if [ "$rc" = "0" ] && ssr_files_installed && [ -s /usr/lib/lua/url.lua ]; then
    ok "SSR Plus 文件已安装 ✓ (fw876/helloworld IPK 解包兜底，版本 $SSR_RELEASE_VER)"
    rm -rf "$work" "$ipk" "$log"
    return 0
  fi
  err "SSR Plus 解包兜底失败"
  grep -E "ERROR|failed|invalid|not found|No such|Permission" "$log" || true
  rm -rf "$work" "$ipk" "$log"
  return 1
}

install_ssr_release() {
  # ash/dash 在同一个 local 命令里不会让后续赋值看到前面的 ext，必须拆开；否则 pkgfile 会变成 /tmp/luci-app-ssr-plus.
  local ext pkgfile oldver newver rc log
  ext="$1"
  pkgfile="/tmp/luci-app-ssr-plus.$ext"
  log="/tmp/ssr_release_install.log"
  oldver=$(get_version "luci-app-ssr-plus")
  info "获取 SSR Plus 官方 Release (fw876/helloworld)..."
  if ! download_ssr_release_pkg "$ext" "$pkgfile"; then
    err "SSR Plus Release 下载失败 (GitHub 直连+代理均失败)"
    info "提示: 该架构 $SYS_ARCH 上游可能无预编译包，请改用 xray-core 纯内核方案/换固件"
    return 1
  fi
  info "安装 SSR Plus $SSR_RELEASE_VER ($ext)..."
  : > "$log"
  if [ "$ext" = "apk" ]; then
    apk add --upgrade --allow-untrusted --force-broken-world --force-overwrite "$pkgfile" >> "$log" 2>&1
    rc=$?
  else
    opkg install "$pkgfile" --force-downgrade --force-overwrite --force-depends >> "$log" 2>&1
    rc=$?
    grep -q "pkg_hash_check_unresolved" "$log" 2>/dev/null && rc=2
  fi
  rm -f "$pkgfile"
  if [ "$rc" = "0" ]; then
    grep -v -e "^Configuring" -e "^WARNING.*opening" -e "^\.\.\.$" -e "^Collected errors:$" -e "remove_obsolesced_files" -e "opkg\.lock" "$log" || true
  else
    grep -E "ERROR|WARNING|conflict|breaks|unable|failed|permission|No such|not found|pkg_hash_check_unresolved|cannot find dependency|incompatible|Unknown package|not a valid|Failed" "$log" || true
  fi
  rm -f "$log"
  newver=$(get_version "luci-app-ssr-plus")
  if [ -n "$SSR_RELEASE_VER" ] && [ "$newver" = "$SSR_RELEASE_VER" ]; then
    if [ -n "$oldver" ] && [ "$oldver" != "$newver" ]; then
      ok "SSR Plus: $oldver → $newver ✓ (fw876/helloworld)"
    else
      ok "SSR Plus $newver ✓ (fw876/helloworld)"
    fi
    return 0
  elif [ "$rc" = "0" ] && [ -n "$newver" ] && [ "$newver" != "$oldver" ]; then
    ok "SSR Plus: $oldver → $newver ✓ (Release 版本 $SSR_RELEASE_VER)"
    return 0
  fi
  if ssr_files_installed; then
    ensure_lua_neturl_file
    if [ -s /usr/lib/lua/url.lua ]; then
      ok "SSR Plus 文件已存在 ✓ (包管理器未返回版本，版本 $SSR_RELEASE_VER)"
      return 0
    fi
  fi
  if install_ssr_manual_from_ipk; then
    return 0
  fi
  if [ "$rc" = "2" ]; then
    err "SSR Plus 安装失败: 缺少依赖；OPKG 系统请确认 OpenWrt/openwrt.ai 依赖源可用"
    info "提示: 该架构 $SYS_ARCH 上游可能无预编译包，请改用 xray-core 纯内核方案/换固件"
  else
    err "SSR Plus 安装失败: 当前版本 ${newver:-未安装}，Release 版本 ${SSR_RELEASE_VER:-未知}"
    info "提示: 该架构 $SYS_ARCH 上游可能无预编译包，请改用 xray-core 纯内核方案/换固件"
    if [ "$PKG_MGR" = "apk" ]; then
      info "诊断: apk 已安装记录"
      apk list --installed '*ssr*' 2>/dev/null | grep -v WARNING || true
      grep -n '^P:luci-app-ssr-plus$\|^V:' /lib/apk/db/installed /usr/lib/apk/db/installed 2>/dev/null | head -20 || true
      info "诊断: SSR Plus 文件"
      ls -l /usr/lib/lua/luci/controller/shadowsocksr.lua /etc/init.d/shadowsocksr /usr/share/rpcd/acl.d/luci-app-ssr-plus.json 2>/dev/null || true
    else
      info "诊断: opkg 已安装记录"
      opkg list-installed 2>/dev/null | grep 'ssr-plus\|shadowsocksr' || true
      grep -n '^Package: luci-app-ssr-plus$\|^Version:' /usr/lib/opkg/status /var/lib/opkg/status 2>/dev/null | head -20 || true
      info "诊断: SSR Plus 文件"
      ls -l /usr/lib/lua/luci/controller/shadowsocksr.lua /etc/init.d/shadowsocksr /usr/share/rpcd/acl.d/luci-app-ssr-plus.json 2>/dev/null || true
    fi
  fi
  return 1
}

# SSR Plus
# 主程序来自 fw876/helloworld 官方 Release；OPKG 依赖源保留 openwrt.ai/kiddin9。
if [ "$INSTALL_SSR" = "1" ]; then
  if [ "$PKG_MGR" = "opkg" ]; then
    hdr "SSR Plus 安装"
    # 先装依赖/协议组件，最后装 LuCI 主程序，避免主程序先因依赖未解开而失败。
    install_ssr_dependencies
    install_ssr_release "ipk"
  else
    hdr "SSR Plus 安装"
    install_ssr_dependencies
    install_ssr_release "apk"
  fi
fi

install_openclash_dependencies() {
  local log=/tmp/openclash-deps.log user_deps kernel_deps deps rc missing="" user_missing="" kernel_missing="" dep_total=0 dep_done=0 installed
  [ "$INSTALL_OC" = "1" ] || return 0
  user_deps="bash dnsmasq-full curl ca-bundle ip-full ruby ruby-yaml unzip luci-compat luci luci-base"
  kernel_deps="kmod-tun kmod-inet-diag"
  if command -v fw4 >/dev/null 2>&1 || [ -x /sbin/fw4 ] || [ -x /usr/sbin/fw4 ]; then
    kernel_deps="$kernel_deps kmod-nft-tproxy"
  elif [ "$PKG_MGR" = "opkg" ]; then
    kernel_deps="$kernel_deps iptables ipset iptables-mod-tproxy iptables-mod-extra"
  fi
  deps="$user_deps $kernel_deps"
  info "按 OpenClash 官方指引安装依赖..."
  info "用户态依赖: $user_deps"
  info "内核/防火墙依赖: $kernel_deps"
  for pkg in $deps; do dep_total=$((dep_total + 1)); done
  : > "$log"
  if [ "$PKG_MGR" = "opkg" ]; then
    opkg install $user_deps >> "$log" 2>&1
    rc=$?
  else
    apk add --upgrade --latest --force-overwrite --clean-protected $user_deps >> "$log" 2>&1
    rc=$?
  fi
  # 内核模块必须由当前固件匹配源提供；不使用 --force-depends 掩盖 hash/依赖错误。
  if [ "$PKG_MGR" = "opkg" ]; then
    opkg install $kernel_deps >> "$log" 2>&1
    kernel_rc=$?
  else
    apk add --upgrade --latest --force-overwrite --clean-protected $kernel_deps >> "$log" 2>&1
    kernel_rc=$?
  fi
  for pkg in $deps; do
    if [ "$PKG_MGR" = "opkg" ]; then
      opkg list-installed 2>/dev/null | grep -q "^$pkg " && installed=1 || installed=0
    else
      apk list --installed "$pkg" 2>/dev/null | grep -v WARNING | grep -q "^$pkg-" && installed=1 || installed=0
    fi
    if [ "$installed" = "1" ]; then
      dep_done=$((dep_done + 1))
      printf "  [%s/%s] ✓ %s\n" "$dep_done" "$dep_total" "$pkg"
    else
      missing="$missing $pkg"
      echo "$kernel_deps" | grep -qw "$pkg" && kernel_missing="$kernel_missing $pkg" || user_missing="$user_missing $pkg"
      printf "  [%s/%s] ✗ %s\n" "$((dep_done + 1))" "$dep_total" "$pkg"
    fi
  done
  if [ -n "$user_missing" ]; then
    grep -E "Unknown package|cannot find dependency|incompatible|No space|Collected errors|ERROR|WARNING|unable|conflict|breaks" "$log" 2>/dev/null || true
    rm -f "$log"
    err "OpenClash 用户态依赖未完全就绪:$user_missing"
    return 1
  fi
  if [ "$rc" != "0" ]; then
    # APK 可能因 world 中无关的残留约束返回非零，但目标依赖已实际落盘；
    # 不能把这种事务噪音误报成 OpenClash 用户态依赖失败。
    info "APK 依赖事务返回 $rc，但 OpenClash 用户态依赖已全部落盘，继续安装"
    grep -E "ERROR|WARNING|unable|conflict|breaks" "$log" 2>/dev/null || true
  fi
  if [ "$kernel_rc" != "0" ] || [ -n "$kernel_missing" ]; then
    info "OpenClash 内核/防火墙依赖安装失败；通常是厂商内核源或 kernel hash 不匹配"
    grep -E "kmod-|incompatible|kernel|hash|Unknown package|ERROR|WARNING|unable" "$log" 2>/dev/null || true
  fi
  rm -f "$log"
  ok "OpenClash 用户态依赖已就绪"
  return 0
}

opkg_prepare_local_package_arches() {
  [ "$PKG_MGR" = "opkg" ] || return 0
  local changed=0
  if ! opkg print-architecture 2>/dev/null | awk '$1=="arch" {print $2}' | grep -qx 'all'; then
    echo "arch all 1" >> /etc/opkg.conf
    changed=1
  fi
  if ! opkg print-architecture 2>/dev/null | awk '$1=="arch" {print $2}' | grep -qx 'noarch'; then
    echo "arch noarch 1" >> /etc/opkg.conf
    changed=1
  fi
  if [ -n "$SYS_ARCH" ] && ! opkg print-architecture 2>/dev/null | awk '$1=="arch" {print $2}' | grep -qx "$SYS_ARCH"; then
    echo "arch $SYS_ARCH 1" >> /etc/opkg.conf
    changed=1
  fi
  [ "$changed" = "1" ] && info "已补齐本地 IPK 架构: all/noarch/$SYS_ARCH"
}
openclash_ipk_architecture() {
  local ipk="$1" arch=""
  if command -v ar >/dev/null 2>&1; then
    arch=$(ar p "$ipk" control.tar.gz 2>/dev/null | gzip -dc 2>/dev/null | tar -xO ./control 2>/dev/null | sed -n 's/^Architecture:[[:space:]]*//p' | head -1)
  fi
  printf '%s\n' "$arch"
}

if [ "$INSTALL_OC" = "1" ]; then
  hdr "OpenClash 依赖"
  install_openclash_dependencies || info "OpenClash 依赖未完全就绪，继续尝试主程序安装以输出详细诊断"
fi

# OpenClash 安装
# 再预检依赖；不能让用户自定义 feeds 的架构表误伤官方 all 架构主包。

# 返回 0=成功 1=全部失败
# 验证下载内容: ipk 为 gzip/ar, apk 为 APK v3 adb(ADBd), gz 为 gzip
# (代理可能返回 404/错误页但 HTTP 200, 仅 -s 非空检查不够)
# 注意: OpenWrt 无 od/xxd; 用 dd 提取头部字节比较 (busybox 核心命令必有)
#       gz magic 2字节(\x1f\x8b) 用 count=2 避免 NUL 截断; ar/adb magic 4字节纯 ASCII 无 NUL
dl_with_mirror() {
  local url="$1" out="$2" u magic tmp
  rm -f "$out"
  for u in $(gh_candidates "$url"); do
    tmp="${out}.tmp"
    rm -f "$tmp" "$out"
    curl -fL -# --max-time 60 -o "$tmp" "$u" 2>/dev/null
    if [ -s "$tmp" ]; then
      case "$out" in
        *.gz)   magic=$(dd if="$tmp" bs=1 count=2 2>/dev/null)
                [ "$magic" = "$(printf '\037\213')" ] && { mv "$tmp" "$out"; return 0; } ;;
        *.apk)  magic=$(dd if="$tmp" bs=1 count=4 2>/dev/null)
                [ "$magic" = "ADBd" ] && { mv "$tmp" "$out"; return 0; } ;;
        *)      magic=$(dd if="$tmp" bs=1 count=4 2>/dev/null)
                [ "$magic" = "!<ar" ] && { mv "$tmp" "$out"; return 0; }
                magic=$(dd if="$tmp" bs=1 count=2 2>/dev/null)
                [ "$magic" = "$(printf '\037\213')" ] && { mv "$tmp" "$out"; return 0; } ;;
      esac
    fi
    rm -f "$tmp" "$out"
  done
  return 1
}


# AdGuardHome: 使用 AdGuardTeam/AdGuardHome 官方 Release 二进制安装。
agh_arch_name() {
  case "$SYS_ARCH" in
    x86_64|amd64) echo "amd64" ;;
    i386*|i686|386) echo "386" ;;
    aarch64*|arm64) echo "arm64" ;;
    arm_cortex-a5*|armv5*) echo "armv5" ;;
    arm_cortex-a7*|arm_cortex-a8*|arm_cortex-a9*|armv7*) echo "armv7" ;;
    arm*) echo "armv6" ;;
    mipsel*|mipsle*) echo "mipsle_softfloat" ;;
    mips64el*|mips64le*) echo "mips64le_softfloat" ;;
    mips64*) echo "mips64_softfloat" ;;
    mips*) echo "mips_softfloat" ;;
    powerpc64le|ppc64le) echo "ppc64le" ;;
    riscv64*) echo "riscv64" ;;
    *) echo "" ;;
  esac
}
get_agh_latest_json() {
  local api="https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" u json
  for u in $(gh_candidates "$api"); do
    json=$(curl -sL --max-time 20 "$u" 2>/dev/null) || continue
    echo "$json" | grep -q '"tag_name"' || continue
    echo "$json"
    return 0
  done
  return 1
}
get_agh_latest_ver() {
  get_agh_latest_json | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4 | head -1
}
get_agh_asset_url() {
  local arch json
  arch=$(agh_arch_name)
  [ -n "$arch" ] || return 1
  json=$(get_agh_latest_json) || return 1
  AGH_LATEST_VER=$(printf '%s\n' "$json" | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4 | head -1)
  printf '%s\n' "$json" | grep -oE 'https://[^" ]*/AdGuardHome_linux_[^" ]+\.tar\.gz' | grep "AdGuardHome_linux_${arch}\.tar\.gz" | head -1
}
get_agh_installed_ver() {
  local bin="/opt/AdGuardHome/AdGuardHome" v
  [ -x "$bin" ] || bin=$(command -v AdGuardHome 2>/dev/null)
  [ -x "$bin" ] || { echo ""; return; }
  v=$("$bin" --version 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  echo "$v"
}
install_agh_service_fallback() {
  [ -x /etc/init.d/AdGuardHome ] && return 0
  cat > /etc/init.d/AdGuardHome << 'AGH_INIT_EOF'
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1
PROG=/opt/AdGuardHome/AdGuardHome
start_service() {
  procd_open_instance
  procd_set_param command "$PROG" -w /opt/AdGuardHome --no-check-update
  procd_set_param respawn
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
AGH_INIT_EOF
  chmod +x /etc/init.d/AdGuardHome 2>/dev/null || true
  /etc/init.d/AdGuardHome enable >/dev/null 2>&1 || true
}
install_adguardhome() {
  hdr "AdGuardHome 安装"
  local oldver latest url work tarball newver bin arch
  bin="/opt/AdGuardHome/AdGuardHome"
  oldver=$(get_agh_installed_ver)
  latest=$(get_agh_latest_ver)
  if [ -n "$oldver" ] && [ -n "$latest" ] && [ "$oldver" = "$latest" ]; then
    ok "AdGuardHome 已是最新版 ($oldver)"
    return 0
  fi
  arch=$(agh_arch_name)
  if [ -z "$arch" ]; then
    err "AdGuardHome 不支持或无法匹配当前架构: $SYS_ARCH"
    return 1
  fi
  url=$(get_agh_asset_url)
  [ -z "$latest" ] && latest="$AGH_LATEST_VER"
  if [ -z "$url" ]; then
    err "无法获取 AdGuardHome 下载地址 (GitHub 不可达或架构 $SYS_ARCH/$arch 无匹配资产)"
    return 1
  fi
  info "下载 AdGuardHome ${latest:-latest} ($arch)..."
  work="/tmp/AdGuardHome-install"
  tarball="/tmp/AdGuardHome_linux_${arch}.tar.gz"
  rm -rf "$work" "$tarball"
  mkdir -p "$work" || return 1
  if ! dl_with_mirror "$url" "$tarball"; then
    rm -rf "$work" "$tarball"
    err "AdGuardHome 下载失败（GitHub 通道不可达或资产无效）"
    return 1
  fi
  if ! tar -xzf "$tarball" -C "$work" >/tmp/agh_extract.log 2>&1; then
    err "AdGuardHome 解压失败"
    grep -E "ERROR|failed|invalid|not found|No such" /tmp/agh_extract.log || true
    rm -rf "$work" "$tarball" /tmp/agh_extract.log
    return 1
  fi
  if [ ! -x "$work/AdGuardHome/AdGuardHome" ]; then
    err "AdGuardHome 安装包缺少可执行文件"
    rm -rf "$work" "$tarball" /tmp/agh_extract.log
    return 1
  fi
  mkdir -p /opt
  if [ -x "$bin" ]; then
    "$bin" -s stop >/dev/null 2>&1 || true
  fi
  rm -rf /opt/AdGuardHome.new
  mv "$work/AdGuardHome" /opt/AdGuardHome.new || { err "AdGuardHome 文件写入失败"; rm -rf "$work" "$tarball"; return 1; }
  if [ -d /opt/AdGuardHome ]; then
    [ -f /opt/AdGuardHome/AdGuardHome.yaml ] && cp /opt/AdGuardHome/AdGuardHome.yaml /opt/AdGuardHome.new/AdGuardHome.yaml 2>/dev/null || true
    [ -d /opt/AdGuardHome/data ] && cp -a /opt/AdGuardHome/data /opt/AdGuardHome.new/ 2>/dev/null || true
    rm -rf /opt/AdGuardHome.old
    mv /opt/AdGuardHome /opt/AdGuardHome.old 2>/dev/null || rm -rf /opt/AdGuardHome
  fi
  mv /opt/AdGuardHome.new /opt/AdGuardHome
  chmod +x "$bin" 2>/dev/null || true
  ln -sf "$bin" /usr/bin/AdGuardHome 2>/dev/null || true
  newver=$(get_agh_installed_ver)
  if [ -n "$latest" ] && [ -n "$newver" ] && [ "$newver" != "$latest" ]; then
    err "AdGuardHome 版本校验异常: 已安装 $newver，期望 $latest"
    rm -rf "$work" "$tarball" /tmp/agh_extract.log
    return 1
  fi
  "$bin" -s install >/tmp/agh_service.log 2>&1 || install_agh_service_fallback
  /etc/init.d/AdGuardHome enable >/dev/null 2>&1 || true
  /etc/init.d/AdGuardHome start >/dev/null 2>&1 || "$bin" -s start >/dev/null 2>&1 || true
  if [ -x "$bin" ]; then
    [ -n "$oldver" ] && [ "$oldver" != "$newver" ] && ok "AdGuardHome: $oldver → ${newver:-$latest} ✓" || ok "AdGuardHome ${newver:-$latest} ✓"
    info "默认管理地址: http://路由器IP:3000 （首次初始化；DNS 53 端口如被 dnsmasq/AdGuard 其它服务占用需手动调整）"
  else
    err "AdGuardHome 安装失败"
    rm -rf "$work" "$tarball" /tmp/agh_extract.log /tmp/agh_service.log
    return 1
  fi
  rm -rf "$work" "$tarball" /tmp/agh_extract.log /tmp/agh_service.log /opt/AdGuardHome.old
  return 0
}


# OpenClash 官方内核：按 OpenClash core 分支的 core_version 和 meta 包安装。
# 不能使用 MetaCubeX Releases 的 v1.x；OpenClash 页面显示的是 alpha-ge... 版本。
openclash_core_cpu_model() {
  case "$SYS_ARCH" in
    x86_64|amd64) echo "linux-amd64-v1" ;;
    aarch64*|arm64) echo "linux-arm64" ;;
    arm_cortex-a7*|armv7*) echo "linux-armv7" ;;
    arm_cortex-a5*|arm_cortex-a8*|arm_cortex-a9*|arm*) echo "linux-armv7" ;;
    mipsel*) echo "linux-mipsle-softfloat" ;;
    mips*) echo "linux-mips-softfloat" ;;
    i386*|386) echo "linux-386" ;;
    *) echo "" ;;
  esac
}
openclash_core_branch="master"
openclash_core_version_url() {
  echo "https://raw.githubusercontent.com/vernesong/OpenClash/core/$openclash_core_branch/core_version"
}
get_openclash_core_latest() {
  local u v
  for u in $(gh_candidates "$(openclash_core_version_url)"); do
    v=$(curl -fsSL --max-time 20 "$u" 2>/dev/null | sed -n '1p' | tr -d '\r')
    [ -n "$v" ] && { echo "$v"; return 0; }
  done
  return 1
}
openclash_core_version() {
  "$1" -v 2>&1 | sed -n 's/.*\(alpha-[A-Za-z0-9._-]*\).*/\1/p' | head -1
}
install_openclash_core() {
  local dest="$1" model="$2" url u tarball work nver
  [ -n "$model" ] || { err "当前架构 $SYS_ARCH 没有匹配的 OpenClash 内核"; return 1; }
  url="https://raw.githubusercontent.com/vernesong/OpenClash/core/$openclash_core_branch/meta/clash-$model.tar.gz"
  info "下载 OpenClash 官方内核 $OPENCLASH_CORE_LATEST ($model)..."
  tarball=/tmp/openclash-core.tar.gz
  work=/tmp/openclash-core.$$
  rm -rf "$tarball" "$work"
  mkdir -p "$work" || return 1
  for u in $(gh_candidates "$url"); do
    curl -fsL --connect-timeout 10 --max-time 120 -o "$tarball" "$u" 2>/dev/null || { rm -f "$tarball"; continue; }
    tar -tzf "$tarball" >/dev/null 2>&1 || { rm -f "$tarball"; continue; }
    break
  done
  if [ ! -s "$tarball" ] || ! tar -xzf "$tarball" -C "$work" >/dev/null 2>&1; then
    err "OpenClash 官方内核下载或解压失败"
    rm -rf "$tarball" "$work"
    return 1
  fi
  [ -s "$work/clash" ] || { err "OpenClash 内核包缺少 clash 文件"; rm -rf "$tarball" "$work"; return 1; }
  chmod 755 "$work/clash"
  nver=$(openclash_core_version "$work/clash")
  [ -n "$nver" ] && [ "$nver" = "$OPENCLASH_CORE_LATEST" ] || {
    err "OpenClash 内核版本校验失败: ${nver:-未知}，期望 $OPENCLASH_CORE_LATEST"
    rm -rf "$tarball" "$work"
    return 1
  }
  mkdir -p "$(dirname "$dest")"
  mv "$work/clash" "$dest" || { err "OpenClash 内核写入失败"; rm -rf "$tarball" "$work"; return 1; }
  chmod 755 "$dest"
  ok "OpenClash 官方内核已安装 ($nver)"
  rm -rf "$tarball" "$work"
  return 0
}

# 保留旧函数名仅供其它代码兼容，但实际改为 OpenClash 官方内核流程。
mihomo_version_matches() { [ "$1" = "$2" ] || [ "$(openclash_core_version "$1")" = "$2" ]; }

mihomo_arch_pattern() {
  case "$SYS_ARCH" in
    x86_64|amd64) echo 'mihomo-linux-amd64(-v[123])?(-go[0-9]+)?-v[0-9.]+\.gz' ;;
    aarch64*|arm64) echo 'mihomo-linux-arm64-v[0-9.]+\.gz' ;;
    arm_cortex-a7*|armv7*) echo 'mihomo-linux-armv7-v[0-9.]+\.gz' ;;
    arm_cortex-a5*|arm_cortex-a8*|arm_cortex-a9*|arm*) echo 'mihomo-linux-armv7-v[0-9.]+\.gz' ;;
    i386*|386) echo 'mihomo-linux-386(-softfloat)?(-go[0-9]+)?-v[0-9.]+\.gz' ;;
    mipsel*) echo 'mihomo-linux-mipsle-softfloat-v[0-9.]+\.gz' ;;
    mips*) echo 'mihomo-linux-mips-softfloat-v[0-9.]+\.gz' ;;
    riscv64*) echo 'mihomo-linux-riscv64-v[0-9.]+\.gz' ;;
    *) echo '' ;;
  esac
}
mihomo_arch_prefer_pattern() {
  case "$SYS_ARCH" in
    x86_64|amd64) echo 'mihomo-linux-amd64-v[0-9.]+\.gz' ;;
    i386*|386) echo 'mihomo-linux-386-v[0-9.]+\.gz' ;;
    *) mihomo_arch_pattern ;;
  esac
}
mihomo_ver_num() {
  echo "$1" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | tail -1 | sed 's/^v//'
}
mihomo_ver_tag() {
  local v
  v=$(mihomo_ver_num "$1")
  [ -n "$v" ] && echo "v$v"
}
mihomo_version_matches() {
  [ "$(mihomo_ver_num "$1")" = "$(mihomo_ver_num "$2")" ]
}
get_mihomo_latest_json() {
  local api="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" u json
  for u in $(gh_candidates "$api"); do
    json=$(curl -sL --max-time 20 "$u" 2>/dev/null) || continue
    echo "$json" | grep -q '"tag_name"' || continue
    echo "$json"
    return 0
  done
  return 1
}
get_mihomo_latest_ver() {
  get_mihomo_latest_json | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4 | head -1
}
get_mihomo_asset_url() {
  local pat prefer json url
  pat=$(mihomo_arch_pattern)
  prefer=$(mihomo_arch_prefer_pattern)
  [ -n "$pat" ] || return 1
  json=$(get_mihomo_latest_json) || return 1
  MIHOMO_VER=$(printf '%s\n' "$json" | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4 | head -1)
  url=$(printf '%s\n' "$json" | grep -oE 'https://[^" ]+' | grep -E "$prefer" | head -1)
  [ -n "$url" ] || url=$(printf '%s\n' "$json" | grep -oE 'https://[^" ]+' | grep -E "$pat" | head -1)
  printf '%s\n' "$url"
}
install_mihomo_core() {
  local dest="$1" url
  url=$(get_mihomo_asset_url)
  # get_mihomo_asset_url 通过命令替换调用，函数内变量赋值在子 shell 中不会保留；从下载 URL 反解析版本。
  [ -z "$MIHOMO_VER" ] && MIHOMO_VER=$(echo "$url" | sed -n 's#.*/download/\([^/]*\)/.*#\1#p')
  if [ -z "$MIHOMO_VER" ] || [ -z "$url" ]; then
    err "无法获取 Clash Meta 内核下载地址 (GitHub 不可达或架构 $SYS_ARCH 无匹配资产)"
    info "提示: 该架构 $SYS_ARCH 上游可能无预编译包，请改用 xray-core 纯内核方案/换固件"
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
    if [ -n "$ncore" ] && mihomo_version_matches "$ncore" "$MIHOMO_VER"; then
      ok "Clash Meta 内核已安装最新版 ($(mihomo_ver_tag "$ncore"))"
    elif [ -n "$ncore" ]; then
      err "Clash 内核版本校验异常: 已安装 $ncore，期望 $MIHOMO_VER"
      return 1
    else
      ok "Clash Meta 内核已安装 ($MIHOMO_VER，版本输出不可解析)"
    fi
  else
    err "Clash Meta 内核下载失败（GitHub 通道不可达或资产无效）"
    info "提示: 该架构 $SYS_ARCH 上游可能无预编译包，请改用 xray-core 纯内核方案/换固件"
    return 1
  fi
}

# 获取 OpenClash 最新版本 (GitHub API → 代理重试)
get_oc_latest() {
  local api="https://api.github.com/repos/vernesong/OpenClash/releases/latest" u r
  for u in $(gh_candidates "$api"); do
    r=$(curl -sL --max-time 20 "$u" 2>/dev/null | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4)
    [ -n "$r" ] && { echo "$r"; return 0; }
  done
  return 1
}

# GitHub 不可达时的 OPKG 兜底：先预检，再安装；不强行忽略依赖错误。
install_openclash_immortal_fallback() {
  local old_ver="$1" log=/tmp/po-openclash-immortal.log rc nver
  [ "$PKG_MGR" = "opkg" ] && [ "$IW_OK" = "1" ] || return 1
  opkg install --noaction luci-app-openclash --force-downgrade --force-overwrite > "$log" 2>&1
  rc=$?
  if [ "$rc" != "0" ]; then
    err "immortalwrt OpenClash 依赖预检失败"
    grep -E "cannot find dependency|incompatible|kmod-|No space|Unknown package|Collected errors|ERROR" "$log" || cat "$log"
    info "OpenClash 诊断日志: $log"
    return 1
  fi
  opkg install luci-app-openclash --force-downgrade --force-overwrite > "$log" 2>&1
  rc=$?
  grep -v -e "^Configuring" -e "^\.\.\.$" -e "^Collected errors:$" -e "^Removing obsolete file " -e "remove_obsolesced_files" -e "opkg\.lock" "$log" || true
  nver=$(get_version "luci-app-openclash")
  if [ "$rc" = "0" ] && [ -n "$nver" ] && { [ -z "$old_ver" ] || [ "$nver" != "$old_ver" ]; }; then
    ok "OpenClash $nver ✓ (immortalwrt 源)"
    return 0
  fi
  err "immortalwrt 源未完成 OpenClash 安装/升级 (当前 ${nver:-未安装})"
  info "OpenClash 诊断日志: $log"
  return 1
}
if [ "$INSTALL_AGH" = "1" ]; then
  install_adguardhome
fi

istore_files_installed() {
  [ -s /usr/lib/lua/luci/controller/store.lua ] && [ -d /www/luci-static/istore ] && return 0
  [ -x /bin/is-opkg ] && [ -x /etc/init.d/istore ] && return 0
  return 1
}
istore_runtime_deps_ok() {
  command -v script >/dev/null 2>&1 && command -v stty >/dev/null 2>&1 && return 0
  return 1
}
ensure_istore_runtime_deps() {
  # taskd 运行商店安装任务时会调用 `script` 和 `stty`。
  # 手动解包 iStore 时包管理器不会自动安装 taskd 的依赖，缺 script 会报：/usr/libexec/taskd: exec: line 11: script: not found
  local need="" log="/tmp/istore_deps.log" rc=0
  command -v script >/dev/null 2>&1 || need="$need script-utils"
  command -v stty >/dev/null 2>&1 || need="$need coreutils-stty"
  [ -z "$need" ] && return 0
  info "补装 iStore 运行依赖:$need"
  : > "$log"
  if [ "$PKG_MGR" = "apk" ]; then
    clean_apk_broken_installed
    apk add --upgrade --latest --allow-untrusted --force-broken-world $need > "$log" 2>&1
    rc=$?
  else
    opkg install $need --force-downgrade --force-overwrite --force-depends > "$log" 2>&1
    rc=$?
  fi
  if istore_runtime_deps_ok; then
    grep -E "ERROR|WARNING|failed|not found|unable|cannot|conflict|breaks" "$log" 2>/dev/null || true
    rm -f "$log"
    ok "iStore 运行依赖已就绪"
    return 0
  fi
  grep -E "ERROR|WARNING|failed|not found|unable|cannot|conflict|breaks" "$log" 2>/dev/null || true
  rm -f "$log"
  err "iStore 运行依赖缺失：$(command -v script >/dev/null 2>&1 || echo script) $(command -v stty >/dev/null 2>&1 || echo stty)"
  return $rc
}
patch_istore_is_opkg_world_cleanup() {
  # iStore 的 /bin/is-opkg 在安装商店插件时会直接调用 apk；如果 /etc/apk/world 残留 naiveprox4/naiveproxy 等坏约束，
  # 商店内安装会报 unable to select packages。给 is-opkg 注入一次轻量 world 清理，避免用户手动编辑 world。
  [ "$PKG_MGR" = "apk" ] || return 0
  [ -s /bin/is-opkg ] || return 0
  if grep -q "PO_CLEAN_APK_WORLD" /bin/is-opkg 2>/dev/null; then
    grep -q "naiveprox" /bin/is-opkg 2>/dev/null && grep -q "libatomic" /bin/is-opkg 2>/dev/null && return 0
    cp /tmp/is-opkg.po-bak /bin/is-opkg 2>/dev/null || true
  fi
  cp /bin/is-opkg /tmp/is-opkg.po-bak 2>/dev/null || true
  awk '
    NR==2 {
      print "PO_CLEAN_APK_WORLD=1"
      print "if [ -f /etc/apk/world ]; then"
      print "  awk '\''$0 ~ /^(dns2tcp|lua-neturl|luci-app-ssr-plus|mosdns|naiveprox4|naiveproxy|libatomic1|nping|sing-box)([<>=~].*)?$/ {next} $0 ~ /^naiveprox/ {next} $0 ~ /^libatomic/ {next} {print}'\'' /etc/apk/world > /tmp/apk.world.istore-clean 2>/dev/null && cat /tmp/apk.world.istore-clean > /etc/apk/world"
      print "  rm -f /tmp/apk.world.istore-clean 2>/dev/null || true"
      print "fi"
    }
    {print}
  ' /bin/is-opkg > /tmp/is-opkg.po-new 2>/dev/null && cat /tmp/is-opkg.po-new > /bin/is-opkg
  rm -f /tmp/is-opkg.po-new 2>/dev/null || true
  chmod +x /bin/is-opkg 2>/dev/null || true
  grep -q "PO_CLEAN_APK_WORLD" /bin/is-opkg 2>/dev/null && ok "iStore is-opkg 已注入 APK world 清理" || info "iStore is-opkg world 清理注入失败，继续"
}
fetch_istore_ipk() {
  local pkg="$1" out="$2" base idx fn u
  for base in "https://istore.istoreos.com/repo/all/store" "https://repo.istoreos.com/repo/all/store"; do
    idx=$(curl -fsL --max-time 20 "$base/Packages.gz" 2>/dev/null | gzip -dc 2>/dev/null) || continue
    fn=$(printf '%s\n' "$idx" | awk -v p="$pkg" '
      $1=="Package:" && $2==p {f=1; next}
      f && $1=="Filename:" {print $2; exit}
      f && $1=="Package:" {f=0}
    ')
    [ -n "$fn" ] || continue
    u="$base/$fn"
    curl -fL --progress-bar --max-time 90 -o "$out" "$u" 2>/dev/null || curl -fsL --max-time 90 -o "$out" "$u" 2>/dev/null || { rm -f "$out"; continue; }
    [ -s "$out" ] || continue
    # iStore repo 的 .ipk 实际是 gzip tar，含 data.tar.gz/control.tar.gz。
    tar -tzf "$out" 2>/dev/null | grep -q '^\./data\.tar\.gz$' && return 0
    rm -f "$out"
  done
  return 1
}
install_istore_ipk_manual() {
  # 官方 istore-reinstall.run 在 APK 固件上可能被 world 约束卡住，报 unable to select packages。
  # 兜底直接解包 iStore 官方 all/store IPK：这些包都是 all 架构，适合 x86_64/arm64。
  local pkg ipk work rc=0
  info "官方脚本失败，回退直接解包 iStore 官方 IPK..."
  work="/tmp/istore-ipk"
  rm -rf "$work"
  mkdir -p "$work" || return 1
  for pkg in taskd luci-lib-xterm luci-lib-taskd luci-app-store; do
    ipk="$work/$pkg.ipk"
    info "下载 iStore 组件: $pkg"
    if ! fetch_istore_ipk "$pkg" "$ipk"; then
      err "iStore 组件下载失败: $pkg"
      rm -rf "$work"
      return 1
    fi
    mkdir -p "$work/$pkg"
    tar -xzf "$ipk" -C "$work/$pkg" >/tmp/istore_extract.log 2>&1 || rc=1
    if [ "$rc" != "0" ] || [ ! -s "$work/$pkg/data.tar.gz" ]; then
      err "iStore 组件解包失败: $pkg"
      grep -E "ERROR|failed|invalid|not found|No such" /tmp/istore_extract.log 2>/dev/null || true
      rm -rf "$work" /tmp/istore_extract.log
      return 1
    fi
    tar -xzf "$work/$pkg/data.tar.gz" -C / >>/tmp/istore_extract.log 2>&1 || rc=1
    if [ "$rc" != "0" ]; then
      err "iStore 组件写入失败: $pkg"
      grep -E "ERROR|failed|invalid|not found|No such|Permission" /tmp/istore_extract.log 2>/dev/null || true
      rm -rf "$work" /tmp/istore_extract.log
      return 1
    fi
  done
  chmod +x /bin/is-opkg /etc/init.d/istore /etc/init.d/tasks /usr/libexec/taskd 2>/dev/null || true
  ensure_istore_runtime_deps || true
  patch_istore_is_opkg_world_cleanup
  [ -x /etc/uci-defaults/luci-app-store ] && /etc/uci-defaults/luci-app-store >/tmp/istore_uci.log 2>&1 || true
  /etc/init.d/tasks enable >/dev/null 2>&1 || true
  /etc/init.d/tasks start >/dev/null 2>&1 || true
  /etc/init.d/istore enable >/dev/null 2>&1 || true
  /etc/init.d/istore start >/dev/null 2>&1 || true
  clean_luci_cache
  if istore_files_installed; then
    ok "iStore 商店安装完成 ✓ (IPK 解包兜底)"
    rm -rf "$work" /tmp/istore_extract.log /tmp/istore_uci.log
    return 0
  fi
  err "iStore IPK 解包兜底失败：关键文件不存在"
  rm -rf "$work" /tmp/istore_extract.log /tmp/istore_uci.log
  return 1
}
install_istore() {
  hdr "iStore 商店安装"
  clean_apk_broken_installed
  case "$SYS_ARCH" in
    x86_64|amd64|aarch64*|arm64)
      ;;
    *)
      err "iStore 官方安装脚本只支持 x86_64 和 arm64，当前架构: $SYS_ARCH"
      return 1
      ;;
  esac
  if check_installed "luci-app-store" || istore_files_installed; then
    ensure_istore_runtime_deps || true
    patch_istore_is_opkg_world_cleanup
    if istore_runtime_deps_ok; then
      ok "iStore 商店已安装，运行依赖正常"
    else
      err "iStore 商店已安装，但 taskd 运行依赖不完整；商店安装插件可能失败"
    fi
    return 0
  fi
  if [ "$PKG_MGR" = "apk" ]; then
    info "检测到 APK 固件，跳过官方 repo-apk 安装路径，直接使用官方 IPK 解包兜底"
    install_istore_ipk_manual
    return $?
  fi
  local run="/tmp/istore-reinstall.run" url u
  url="https://github.com/linkease/openwrt-app-actions/raw/main/applications/luci-app-systools/root/usr/share/systools/istore-reinstall.run"
  info "下载 iStore 官方安装脚本..."
  rm -f "$run"
  for u in $(gh_candidates "$url"); do
    curl -fsL --max-time 60 -o "$run" "$u" 2>/dev/null || { rm -f "$run"; continue; }
    grep -q "ISTORE_REPO=https://istore.istoreos.com/repo/all/store" "$run" 2>/dev/null && \
      grep -q "luci-app-store" "$run" 2>/dev/null && \
      grep -q "/tmp/is-opkg install" "$run" 2>/dev/null && break
    rm -f "$run"
  done
  if [ -s "$run" ]; then
    chmod 755 "$run"
    info "执行 iStore 官方安装脚本..."
    "$run" > /tmp/istore_install.log 2>&1
    local rc=$?
    if [ "$rc" = "0" ] && { check_installed "luci-app-store" || istore_files_installed; }; then
      grep -E "ERROR|Failed|failed|not found|No such|unable|cannot" /tmp/istore_install.log 2>/dev/null || true
      ok "iStore 商店安装完成 ✓"
      rm -f "$run" /tmp/istore_install.log
      return 0
    fi
    grep -E "ERROR|Failed|failed|not found|No such|unable|cannot|curl|wget|opkg|apk" /tmp/istore_install.log 2>/dev/null || true
  else
    info "iStore 官方安装脚本下载失败或内容校验失败，尝试 IPK 解包兜底"
  fi
  if install_istore_ipk_manual; then
    rm -f "$run" /tmp/istore_install.log
    return 0
  fi
  err "iStore 商店安装失败"
  rm -f "$run" /tmp/istore_install.log
  return 1
}

if [ "$INSTALL_ISTORE" = "1" ]; then
  install_istore
fi

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
      install_openclash_immortal_fallback "$OC_VER" || true
    else
      err "无可用降级源 (immortalwrt 源不可用或 APK 系统)"
    fi
  elif [ "$OC_VER" != "$OC_LATEST_NUM" ]; then
    info "OpenClash 更新: $OC_VER → $OC_LATEST..."
    OC_EXT="ipk"; [ "$PKG_MGR" = "apk" ] && OC_EXT="apk"
    OC_URL=""
    for OC_API_URL in $(gh_candidates "https://api.github.com/repos/vernesong/OpenClash/releases/latest"); do
      OC_URL=$(curl -sL --max-time 20 "$OC_API_URL" | grep -oE 'https://[^"]+\.(ipk|apk)' | grep "\.$OC_EXT" | head -1)
      [ -n "$OC_URL" ] && break
    done
    if [ "$PKG_MGR" = "opkg" ]; then
      OC_URL=$(printf '%s\n' "$OC_URL" | grep -E '\.ipk$')
    else
      OC_URL=$(printf '%s\n' "$OC_URL" | grep -E '\.apk$')
    fi
    if [ -n "$OC_URL" ]; then
      info "下载 OpenClash $OC_LATEST ($OC_EXT)..."
      OC_PKG="/tmp/luci-app-openclash.$OC_EXT"
      if dl_with_mirror "$OC_URL" "$OC_PKG"; then
        if [ "$PKG_MGR" = "opkg" ]; then
          opkg_prepare_local_package_arches
          OC_IPK_ARCH=$(openclash_ipk_architecture "$OC_PKG")
          case "$OC_IPK_ARCH" in
            all|noarch|"$SYS_ARCH") ;;
            *)
              err "OpenClash IPK 架构不匹配: ${OC_IPK_ARCH:-未知}（当前 $SYS_ARCH）"
              rm -f "$OC_PKG"
              continue
              ;;
          esac
          OC_LOG=/tmp/po-openclash-install.log
          opkg install --noaction "$OC_PKG" --force-downgrade --force-overwrite > "$OC_LOG" 2>&1
          OC_PRE_RC=$?
          if [ "$OC_PRE_RC" != "0" ]; then
            err "OpenClash 依赖预检失败，未执行安装"
            grep -E "cannot find dependency|incompatible|kmod-|No space|Unknown package|Collected errors|ERROR" "$OC_LOG" || cat "$OC_LOG"
            info "OpenClash 诊断日志: $OC_LOG"
          else
            opkg install "$OC_PKG" --force-downgrade --force-overwrite > "$OC_LOG" 2>&1
            OC_RC=$?
            grep -v -e "^Configuring" -e "^\.\.\.$" -e "remove_obsolesced_files" -e "opkg\.lock" "$OC_LOG" || true
            [ "$OC_RC" != "0" ] && info "OpenClash 安装日志: $OC_LOG"
          fi
        else
          OC_LOG=/tmp/po-openclash-apk-install.log
          apk add --upgrade --force-non-repository --allow-untrusted --force-broken-world $APK_FORCE_REINSTALL_OPT "$OC_PKG" > "$OC_LOG" 2>&1
          OC_RC=$?
          grep -v "^WARNING.*opening" "$OC_LOG" || true
          [ "$OC_RC" != "0" ] && info "OpenClash 安装日志: $OC_LOG"
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
          install_openclash_immortal_fallback "$OC_VER" || true
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

  # 2) OpenClash 官方 Meta 内核：使用 core_version 中的 alpha-ge... 版本，
  # 不再使用 MetaCubeX Releases 的 v1.x 内核。
  info "OpenClash 官方内核检查..."
  OPENCLASH_CORE_LATEST=$(get_openclash_core_latest)
  OPENCLASH_CORE_MODEL=$(openclash_core_cpu_model)
  CORE_FILE="/etc/openclash/core/clash_meta"
  INSTALLED_OPENCLASH_CORE=""
  if [ -s "$CORE_FILE" ]; then
    INSTALLED_OPENCLASH_CORE=$(openclash_core_version "$CORE_FILE")
  fi
  if [ -n "$OPENCLASH_CORE_LATEST" ] && [ "$INSTALLED_OPENCLASH_CORE" = "$OPENCLASH_CORE_LATEST" ]; then
    ok "OpenClash 官方内核已是最新 ($INSTALLED_OPENCLASH_CORE)"
  elif [ -n "$OPENCLASH_CORE_LATEST" ]; then
    info "OpenClash 官方内核更新: ${INSTALLED_OPENCLASH_CORE:-未安装} → $OPENCLASH_CORE_LATEST"
    install_openclash_core "$CORE_FILE" "$OPENCLASH_CORE_MODEL" || true
  else
    err "无法获取 OpenClash 官方内核版本，保留当前内核"
  fi
fi

#==============================================
# 6. Geo 数据库（仅 PassWall/PassWall2 需要）
#==============================================
# geoview 在 21.02 源缺失时，使用 PassWall 22.03 的同架构完整预编译包。
# kiddin9 latest 的 1KB geoview 包仅含控制信息、不含 /usr/bin/geoview，会导致组件页显示“版本无”。
install_geoview_fallback() {
  [ "$PKG_MGR" = "opkg" ] || return 1
  local base="https://downloads.sourceforge.net/project/openwrt-passwall-build/releases/packages-22.03/$SYS_ARCH/passwall_packages" meta url
  meta=""
  # SourceForge 22.03 的 geoview 对 mipsel_24kc 是完整可运行包（约 3MB），仅依赖 libc。
  meta=$(curl -sL --connect-timeout 10 --max-time 30 "$base/Packages.gz" 2>/dev/null | gzip -dc 2>/dev/null | awk '
    $1=="Package:" && $2=="geoview" {f=1; next}
    f && $1=="Filename:" {print $2; exit}
    f && $1=="Package:" {f=0}
  ')
  [ -n "$meta" ] || { err "PassWall 源没有 geoview ($SYS_ARCH)"; return 1; }
  url="$base/$meta"
  info "安装 geoview（PassWall 同架构完整预编译包）..."
  if curl -fL --connect-timeout 10 --max-time 120 -o /tmp/geoview.ipk "$url"; then
    opkg install /tmp/geoview.ipk --force-downgrade --force-overwrite --force-depends >/tmp/geoview_install.log 2>&1 || true
  else
    err "geoview 下载失败: $url"
  fi
  if ! command -v geoview >/dev/null 2>&1; then
    cat /tmp/geoview_install.log 2>/dev/null || true
  fi
  rm -f /tmp/geoview.ipk /tmp/geoview_install.log
  command -v geoview >/dev/null 2>&1
}

if [ "$INSTALL_PW" = "1" -o "$INSTALL_PW2" = "1" ]; then
  hdr "默认核心组件"
  # PassWall/PassWall2 默认安装 Xray、ChinaDNS-NG、GeoView 和 Geo 数据库。
  pkginstall "xray-core" "Xray 内核" || true
  for pkg in chinadns-ng v2ray-geoip v2ray-geosite; do
    pkgupgrade "$pkg" "$pkg" || true
  done
  if check_installed geoview && command -v geoview >/dev/null 2>&1; then
    pkgupgrade "geoview" "GeoView" || true
  elif [ "$PKG_MGR" = "opkg" ] && install_geoview_fallback; then
    ok "GeoView $(get_version geoview) ✓"
  else
    pkginstall "geoview" "GeoView" || true
  fi
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
    # 只有二进制存在、包管理器未登记时，不强行把 1.14.0 判成低于 1.14.0-r1。
    # sing-box 这类上游二进制版本没有 -r 包修订号；功能版本相同就跳过，避免 apk 拉起系统级升级事务。
    if [ -n "$repo_ver" ] && [ -n "$ver" ] && [ "${repo_ver%%-r*}" = "$ver" ]; then
      ok "$desc 已存在二进制 ($ver)，源版本 $repo_ver 仅包修订号不同，跳过安装"
    elif [ -n "$repo_ver" ] && [ -n "$ver" ] && version_newer "$repo_ver" "$ver"; then
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
      if [ -n "$repo_ver" ] && [ -n "$ver" ] && [ "${repo_ver%%-r*}" = "$ver" ]; then
        echo "  $i) $desc ($ver，本体已是源版本，包修订 $repo_ver) ✓"
      elif [ -n "$repo_ver" ] && [ -n "$ver" ] && version_newer "$repo_ver" "$ver"; then
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
# 8. SourceForge 源收尾（避免 Web 软件源刷新随机超时）
#==============================================
# SourceForge 的 dl 子域仍会被动态重定向到不同 CDN；路由 Web 的 opkg update 可能刚好分到
# 不可达节点而 curl(28)。安装过程已用实际索引校验/下载完成，结束后将 SF feed 设为脚本专用。
# 下次选择 PassWall/PassWall2 时脚本会先清理旧声明、重新探测并临时写入，无需用户手工恢复。
if [ "$PKG_MGR" = "opkg" ] && [ "$INSTALL_PW$INSTALL_PW2" != "00" ] && [ -f /etc/opkg/customfeeds.conf ]; then
  if grep -qE '^src/gz passwall(_|2)' /etc/opkg/customfeeds.conf 2>/dev/null; then
    # 不用 sed -i：busybox sed -i 会破坏符号链接（与开头清理逻辑保持一致），用 sed 输出到临时文件再 cat 回写。
    sed 's/^src\/gz \(passwall[_2][^ ]* \)/#src\/gz \1/' /etc/opkg/customfeeds.conf > /tmp/customfeeds.po-sf 2>/dev/null && cat /tmp/customfeeds.po-sf > /etc/opkg/customfeeds.conf 2>/dev/null
    rm -f /tmp/customfeeds.po-sf
    ok "PassWall 源已设为脚本专用（Web 软件源刷新不会访问 SourceForge）"
  fi
fi

#==============================================
# 9. 刷新 LuCI
#==============================================
if [ "$INSTALL_PW" = "1" ] || [ "$INSTALL_PW2" = "1" ]; then
  /etc/init.d/rpcd restart >/dev/null 2>&1 || /etc/init.d/rpcd reload >/dev/null 2>&1 || true
  ok "PassWall LuCI 后端已刷新"
fi
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

# 安装完成后返回主菜单。
# 直接执行脚本时可以重新进入当前脚本；管道执行没有可重入的脚本文件，只能提示用户重新运行。
THIS_SCRIPT=$(readlink -f "$0" 2>/dev/null || echo "$0")
case "$THIS_SCRIPT" in
  /tmp/install-passwall.sh|/tmp/install.sh|/tmp/*.sh)
    if [ -f "$THIS_SCRIPT" ] && [ -r "$THIS_SCRIPT" ]; then
      echo ""
      info "返回主菜单..."
      exec "$THIS_SCRIPT"
    fi
    ;;
esac
if [ -f "$THIS_SCRIPT" ] && [ -r "$THIS_SCRIPT" ] && [ "$THIS_SCRIPT" != "sh" ] && [ "$THIS_SCRIPT" != "-sh" ]; then
  echo ""
  info "返回主菜单..."
  exec "$THIS_SCRIPT"
fi
info "当前为管道执行模式，安装流程结束；请重新运行 opinstall 进入主菜单。"

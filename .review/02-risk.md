# 02 — 风险审查：安全与供应链 + OpenWrt 兼容性

审查对象：`install-passwall.sh`（5345 行，POSIX sh，v20261029.6，`bash -n` 通过）
审查方式：只读静态审查，逐行核对行号；未修改被审脚本。
结论口径：**P0 = 立即阻断发布**，**P1 = 真实可利用/真实会踩且后果严重**，**P2 = 真实会踩但可绕过或影响可控**，**P3 = 理论风险/工程卫生**。

## 汇总

| 级别 | 条数 | 集中在 |
| --- | --- | --- |
| P0 | 0 | — |
| P1 | 4 | APK 完整性绕过、opkg 公钥无校验、/bin/is-opkg 持久化改写、全链路无哈希 |
| P2 | 10 | 解压无校验、非交互默认安装、源文件改写、架构误注册、版本比较、源校验过严、DNS 覆盖、DAED 空实现 |
| P3 | 9 | 凭据 envp、/tmp 权限、opkg/apk 不对称、架构映射缺口、解析脆弱性、死代码 |
| 合计 | 23 | — |

无 P0：脚本不含反序列化/命令注入类可直接远程触发的洞，所有 P1 均需"下载通道被污染"或"本机 root 误操作"作为前提，但在中国网络环境下（镜像加速、`--no-check-certificate` 兜底）该前提并非理论假设。

---

# A. 安全与供应链

## [P1] APK 完整性重试实际绕过 packages.adb 摘要，只校验 4 字节魔数 — 2650-2700

**触发条件**：`apk add` 事务返回非 0 且日志命中 `ADB integrity error|bad checksum|checksum mismatch`（2656）。此时脚本清空 `/var/cache/apk/*`，用 `grep -oE '[A-Za-z0-9_.+]+-[0-9][A-Za-z0-9._+-]*'`（2668）从错误行抽包名/版本，拼 5 个 SourceForge 镜像直链下载到 `/tmp/apk-retry-<dep>-$$.apk`，用 `apk_file_valid` 校验后 `set -- "$@" $retry_files` 重跑事务（2691-2696）。

**代码事实**：
```sh
# 2614 apk_file_valid —— 全部"校验"
magic=$(dd if="$file" bs=1 count=4 2>/dev/null)
[ "$magic" = "ADBd" ] || return 1
```
```sh
# 2661-2663 注释与实际相反
# 并把依赖 APK 与原主包放进同一次事务；绝不绕过 APK 完整性校验。
```
`--allow-untrusted` 在 2626 处随事务传入，本地文件不经仓库索引摘要，签名链完全跳过。

**影响**：APK 系统（OpenWrt 25.12+ / iStoreOS 25.x），`apk_install` 全程 root。任何能影响下载结果的一方（被墙时启用的镜像、透明代理、SourceForge 镜像站）可投递任意内容为 `ADBd` 开头的包并被执行 `post-install`。这是**注释明确否认、代码实际发生**的校验绕过，属最需要修的一条。

**修复建议**：
```sh
# 1) 删掉本地文件直投分支，改为重新取索引后仅走 apk 自身事务
apk cache clean >/dev/null 2>&1 || true
rm -f /var/cache/apk/* 2>/dev/null || true
apk update >/tmp/po-apk-refresh.log 2>&1 || true
"$@"            # 只重跑，不再 set -- 追加本地 apk
# 2) 若必须重取：让 apk 自己下载并校验摘要，而不是 curl 直取
#    apk fetch 走仓库索引，摘要不符会直接失败，天然不会绕过 packages.adb
(cd /tmp && apk fetch "$dep-$dep_ver" && apk add --allow-untrusted "/tmp/$dep-$dep_ver.apk")
```

## [P1] opkg 签名公钥经 `--no-check-certificate` 下载且无指纹固定 — 1810-1812

**触发条件**：`curl -fsL -o /tmp/ipk.pub` 失败（被墙/镜像抖动，恰是中间人最易介入的时机）→ 回落到 wget 分支。

**代码事实**：
```sh
curl -fsL --max-time 20 -o /tmp/ipk.pub "$SF_PREFIX/ipk.pub$SF_MIRROR_QUERY" 2>/dev/null || \
  wget -q --no-check-certificate -O /tmp/ipk.pub "$SF_PREFIX/ipk.pub$SF_MIRROR_QUERY" 2>/dev/null || \
  curl -fsL --max-time 20 -o /tmp/ipk.pub https://master.dl.sourceforge.net/... 2>/dev/null || true
[ -s /tmp/ipk.pub ] && opkg-key add /tmp/ipk.pub 2>/dev/null || true
```

**影响**：opkg（≤24.10 全部机型）。`opkg-key add` 安装的是**信任根**：攻击者替换 ipk.pub 后，后续 `passwall_luci/passwall_packages/passwall2` 三个 feed 的任意包都能通过 `opkg` 签名验证，而脚本对这些包无任何二次校验（见下一条）。关证书校验 + 无指纹固定 + 直接 `add`，三点叠加等价于"签名机制形同虚设"。

**修复建议**：
```sh
IPK_PUB_SHA256="<发布时写入的固定指纹>"
_fetch_ipk_pub() {   # 三通道都不关 TLS 校验
  for u in "$SF_PREFIX/ipk.pub$SF_MIRROR_QUERY" \
           "https://master.dl.sourceforge.net/project/openwrt-passwall-build/ipk.pub"; do
    curl -fsL --max-time 20 -o /tmp/ipk.pub "$u" 2>/dev/null || continue
    [ "$(sha256sum /tmp/ipk.pub | cut -d' ' -f1)" = "$IPK_PUB_SHA256" ] && return 0
    rm -f /tmp/ipk.pub
  done
  return 1
}
_fetch_ipk_pub && opkg-key add /tmp/ipk.pub || warn "ipk.pub 指纹校验失败，跳过该源"
```

## [P1] `patch_istore_is_opkg_world_cleanup` 永久改写 `/bin/is-opkg` 并从 `/etc/apk/world` 删除 sing-box 等约束 — 4678-4700

**触发条件**：选择菜单 8（iStore）或 11（全部安装）→ 安装完成后调用该函数；此后**每次** iStore 操作都会执行注入块。

**代码事实**：
```sh
awk 'NR==2 { print "PO_CLEAN_APK_WORLD=1"
  print "  awk '\''$0 ~ /^(dns2tcp|lua-neturl|luci-app-ssr-plus|mosdns|naiveprox4|naiveproxy|libatomic1|nping|sing-box)([<>=~].*)?$/ {next} ...'\'' /etc/apk/world > /tmp/apk.world.istore-clean ... && cat /tmp/apk.world.istore-clean > /etc/apk/world" }' /bin/is-opkg > /tmp/is-opkg.po-new \
  && cat /tmp/is-opkg.po-new > /bin/is-opkg
```

**影响**：iStoreOS 25.x（apk）机型。三条独立危害：
1. `sing-box` 正是本脚本 PassWall 的核心依赖，其 world 约束被删后，后续 `apk add/upgrade/fix` 可把它当"非世界包"移除或替换 → **装完 PassWall 再用 iStore 装插件，PassWall 内核可能消失**；
2. 持久化改写第三方系统文件（`/bin/is-opkg`），备份只在 `/tmp`，重启即失；
3. 与 2974 处 `clean_apk_broken_world` 的自述直接矛盾：
```sh
# 2974 注释：APK world 是持久系统状态，只读检查，不自动编辑或删除任何约束。
```

**修复建议**：删除注入逻辑，改为"一次性、显式、可回滚"的清理：
```sh
clean_apk_broken_world_once() {
  [ -f /etc/apk/world ] || return 0
  cp -a /etc/apk/world /etc/apk/world.po-bak.$(date +%s)
  awk '$0 !~ /^(naiveprox4|naiveproxy|libatomic1)([<>=~].*)?$/ {print}' \
    /etc/apk/world > /tmp/world.new && cat /tmp/world.new > /etc/apk/world
  rm -f /tmp/world.new
  warn "已清理坏约束，回滚: cp -a /etc/apk/world.po-bak.* /etc/apk/world"
}
```
**任何情况下不要动 `sing-box`、`luci-app-ssr-plus`、`mosdns` 的 world 行**——它们是本脚本自己要用的包。

## [P1] 全文 0 处 sha256sum/sha512sum：7 条 root 直装路径无任何校验 — 3183-3334 / 3591-3620 / 3660-3700 / 4331-4405 / 4439-4470 / 4532-4564 / 4702-4798

**触发条件**：任意安装动作。`grep -c 'sha256sum\|sha512sum'` = **0**；全文仅 2656 行出现过 `checksum` 字样且只用于匹配错误日志。

**代码事实**（每条都是"下载 → 直接落盘/解包到系统"）：
```sh
# 3290 partexp
curl -fL -sS -o "$work/$archive" "$url"        # 无校验 → tar -xzf -C "$work" → opkg/apk install
# 3591-3620 xray mips
curl ... -o "$tmp" && unzip -p "$tmp" > /usr/bin/xray   # 直接覆盖运行中的二进制
# 3981 SSR 手动 ipk：直接把 data.tar.gz 解到根
tar -xzf "$work/data.tar.gz" -C / >> "$log" 2>&1
# 4362 AGH
tar -xzf "$tarball" -C "$work"                  # 无成员校验 → mv /opt/AdGuardHome.new
# 4439 OpenClash core / 4532 mihomo core
gzip -dc ... > "$dest"                          # 直接覆盖内核
# 4737-4790 iStore ipk 手动安装
cp -a "$work/$pkg/data"/. /                     # 以 root 把远程归档铺到 /
```
`3981` 是比 `cp -a` 更激进的一处：**直接把远程归档的 `data.tar.gz` 解压到 `/`**，连"先解到 /tmp 再搬"这一层都没有，`install_ssr_manual_from_ipk`（3960）的调用路径也没有任何成员校验。
`--allow-untrusted` 共 17 处：1486, 2506, 2527, 2541, 2554, 2626, 2886, 2939, 2955, 3194, 3329, 3331, 3691, 4015, 4661, 4967。

**影响**：全机型全版本，root 代码执行。`install_istore_ipk_manual` 的 `cp -a ... /. /` 是最坏的放大器：即使归档内路径合法，它也会把整棵目录树（含 `etc/init.d/`、`usr/bin/`）以 root 覆盖系统。真正的防线只剩"下载通道可信"这一条假设，而 A2 那条 `--no-check-certificate` 已经把它拆了。

**修复建议**（分两步，先止血再彻底）：
```sh
# 1) 统一入口：所有下载物过一道校验函数
fetch_verified() {  # $1=url $2=out $3=期望sha256（发布时固定）
  curl -fsSL --max-time 120 -o "$2" "$1" || return 1
  got=$(sha256sum "$2" 2>/dev/null | cut -d' ' -f1)
  [ -n "$got" ] && [ "$got" = "$3" ] && return 0
  rm -f "$2"; err "校验失败: $1 (got=$got want=$3)"; return 1
}
# 2) 对 GitHub Release 资产，改用 API 返回的 digest 字段（gh api ... | jq -r '.assets[].digest'）
#    做"同源校验"，避免硬编码版本号导致每次发版都要改脚本
```
短期最低要求：至少给 `xray`、`mihomo`、`openclash core`、`AdGuardHome` 四个**直接覆盖可执行文件**的路径加固定哈希，其余用 Release digest 校验。

---

## [P2] `install_adguardhome` 解压完全无路径校验 — 4362-4367

**触发条件**：安装 AdGuardHome（菜单 7 / 全部安装）。

**代码事实**：
```sh
if ! tar -xzf "$tarball" -C "$work" >/tmp/agh_extract.log 2>&1; then
```
对比 `install_partexp`（3296-3304）有三重校验（内联 awk + `validate_tar_paths` + `-C "$work"`），AGH 一个都没有。

**影响**：含 `../..` 成员或绝对路径成员的归档会以 root 写到 `/tmp/po-*` 之外；含符号链接成员可让后续 `mv "$work/AdGuardHome" /opt/...` 把内容导到任意位置。前提是下载物被污染（P1 第 4 条），一旦成立即"root 任意写"。

**修复建议**：
```sh
validate_tar_paths "$tarball" || { err "AGH 归档路径校验失败"; return 1; }
tar -xzf "$tarball" -C "$work" --no-same-owner --no-same-permissions || return 1
```

## [P2] `validate_tar_paths` 两版并存、语义不一致，且不检查符号链接/设备文件 — 3183-3190 / 4721-4735

**代码事实**（两处定义，后者覆盖前者；仅此一处重复定义以外的语义分叉）：
```sh
# 3183 版：拒绝 "./" 前缀
/*|../*|*/../*|*/..|.|./*|*'\n'*|*'\r'*) exit 1 ;;
# 4721 版：允许 "./" 前缀
case "$member" in /*|..|../*|*/../*|*/..) bad=1 ;; esac
```
两版都只看**成员名字符串**，都不看 `tar -tvzf` 的类型列，因此：
- `ln -s /etc/passwd x` 这类成员能过校验；
- `dev/console` 之类设备文件能过校验；
- 3183 版会把用 `tar -C dir .` 打包的**合法**归档误判为恶意（`./` 前缀）。

**影响**：partexp 走 3183/4721 双检，iStore 走 4721，AGH/OpenClash 完全不检。真实踩点是"合法归档被误杀 → 安装失败"，安全上是"symlink 逃逸未拦"。

**修复建议**：合并为单版，按类型过滤：
```sh
validate_tar_paths() {
  tar -tvzf "$1" 2>/dev/null | awk '
    { type=substr($1,1,1); name=$NF }
    type ~ /[lh]/ { print "symlink/hardlink: " name > "/dev/stderr"; bad=1 }
    type == "b" || type == "c" { print "device: " name > "/dev/stderr"; bad=1 }
    name ~ /^\// || name ~ /(^|\/)\.\.($|\/)/ { print "traversal: " name > "/dev/stderr"; bad=1 }
    END { exit bad }'
}
```

## [P2] stdin 关闭时静默开始安装 PassWall，管道守卫拦不住 `sh file.sh < /dev/null` — 958-963 / 131-143

**代码事实**：
```sh
# 958-963
if ! read -r MAIN_CHOICE; then
  info "输入流已关闭，默认安装 PassWall"
  MAIN_CHOICE="1"
```
```sh
# 131-143 守卫只认 $0
if [ ! -t 0 ]; then
  case "$0" in sh|ash|bash|dash|-sh|"") ... exit 0 ;; esac
fi
```
`sh /tmp/install-passwall.sh < /dev/null`、`ssh root@router 'sh /tmp/x.sh'`、Ansible/CI 调用时 `$0` 是**脚本路径**，守卫不触发 → 直接进入 958 的默认分支 → **无人值守安装 PassWall**（并改源、装包、重启 dnsmasq）。

**影响**：全机型。这是"最容易被误触发且后果最大"的一条：运维批量执行脚本、把脚本挂到 cron、或 `curl -o` 后带 `</dev/null` 调用，都会静默改变路由器状态。

**修复建议**：
```sh
# 961 改为
if ! read -r MAIN_CHOICE; then
  err "非交互环境（stdin 已关闭）：请显式传入选项，例如 PO_CHOICE=1 sh $0"
  err "或加 --yes 确认无人值守安装"
  exit 2
fi
# 并在入口支持显式开关
[ "${1:-}" = "--yes" ] && ASSUME_YES=1
```

## [P2] 子串匹配清理 `customfeeds.conf`，可清掉用户自定义源且失败即整文件清空 — 1700-1702 / 294-313

**代码事实**：
```sh
# 1700-1702
grep -v -e "passwall" -e "ssr" -e "helloworld" -e "kiddin9" -e "^src/gz iw_" \
  /etc/opkg/customfeeds.conf > /tmp/customfeeds.tmp 2>/dev/null || true
cat /tmp/customfeeds.tmp > /etc/opkg/customfeeds.conf 2>/dev/null
```
```sh
# 302-312 cleanup_opkg_duplicate_feeds 同样按名字子串注释，且回写 distfeeds.conf
if ($2 ~ /passwall|ssr|helloworld|kiddin9/ || $2 ~ /^iw_/ || fixed[$2] || seen[$2]++) {
  print "# PO-installer disabled duplicate/obsolete feed: " $0; next
```
三个问题：① 匹配的是 `$2`（feed **名**）的子串，用户自己的 `src/gz myssr_mirror`、`src/gz my_passwall_test` 会被一并注释；② `grep -v` 出错时 `|| true` 让 tmp 为空，`cat` 把**整个文件清空**；③ 无备份、非原子（先截断再写）。

**影响**：opkg 全版本。用户自定义源被静默禁用 → 后续 `opkg install` 找不到包，表现为"脚本跑完了但插件起不来"，极难归因。

**修复建议**：
```sh
feed_clean() {
  f="$1"; tmp="$f.po.$$"
  cp -a "$f" "/etc/opkg/backup.$(basename "$f").$(date +%s)" 2>/dev/null || true
  awk '$1=="src/gz" && $2 ~ /^(passwall_luci|passwall_packages|passwall2|iw_|openwrt_ai_kiddin9)$/ {next} {print}' \
    "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}
```
即：**只删本脚本自己写过的固定 feed 名**，不做子串匹配。

## [P2] `cleanup_apk_passwall_feeds` 备份在 `/tmp` 且 `restore_apk_passwall_feeds` 全文无调用点 — 336-368

**代码事实**：`APK_REPO_BACKUP_DIR="/tmp/po-apk-repos.$$"`（336），`restore_apk_passwall_feeds`（352）定义完整、逻辑正确，但 `grep -n restore_apk_passwall_feeds` 只有定义行本身。

**影响**：apk 全版本。`/etc/apk/repositories` 与 `repositories.d/*.list` 被改写后没有任何自动恢复路径，备份随重启蒸发。若清理把用户唯一可用源也删了（见上条的子串风险在 APK 侧同样存在：正则 `/(passwall_luci|passwall_packages|passwall2)/packages\.adb` 是精确的，风险较低，但备份失效是真问题）。

**修复建议**：
```sh
cleanup_apk_passwall_feeds() {
  ...
  CLEANUP_DONE=1
}
# 安装结束/异常退出统一收尾
trap 'on_exit' EXIT INT TERM
on_exit() { [ "${INSTALL_OK:-0}" = "1" ] || restore_apk_passwall_feeds; }
```

## [P2] `ensure_opkg_feed_arches` 把源里出现的**任意**架构注册进 `/etc/opkg.conf`，与上方注释自相矛盾 — 1831-1846 vs 408-409

**代码事实**：
```sh
# 1836-1841
for arch in $(grep -hoE 'packages/[A-Za-z0-9_.-]+/(base|luci|packages|routing|telephony)' \
    /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf | sed -n 's#packages/\([^/]*\)/.*#\1#p' | sort -u); do
  echo "$arch" | grep -qE '^(all|noarch|any)$' && continue
  if ! opkg print-architecture | awk '$1=="arch" {print $2}' | grep -qx "$arch"; then
    echo "arch $arch 5" >> /etc/opkg.conf
```
```sh
# 408-409 同一文件里的自我否认
# 不擅自追加 aarch64_generic：厂商 opkg 架构表与索引必须由固件/源
# 原生匹配；跨 ABI 注册会导致"no valid architecture"或混源安装。
```

**影响**：opkg 机型。用户若曾添加过异架构 feed（换设备遗留、抄来的配置），该架构被以优先级 5 注册，配合 2705/2735 的 `--force-downgrade --force-overwrite`，可把异 ABI 的 `.ipk` 覆盖到本机 `/usr/lib` → 库不匹配、LuCI 白屏、需重刷固件。这是"配置残留 + 脚本激进"共同作用，真实会踩。

**修复建议**：只注册与 `SYS_ARCH` 同家族（前缀匹配）的架构，其余跳过并提示：
```sh
case "$arch" in
  "$SYS_ARCH"|"$SYS_ARCH"_*|*"${SYS_ARCH%%_*}*") : ;;
  *) warn "跳过异架构 feed: $arch（本机 $SYS_ARCH）"; continue ;;
esac
```

## [P2] `version_newer` 先剥 `-rN` 再比较，revision 回退被误判为"可升级" — 2362-2391

**代码事实**：
```sh
an=$(echo "$a" | sed 's/^v//; s/-r[0-9][0-9]*$//')   # 2366
bn=$(echo "$b" | sed 's/^v//; s/-r[0-9][0-9]*$//')   # 2367
...
top=$(printf '%s\n%s\n' "$an" "$bn" | sort -V | tail -1)
[ "$top" = "$an" ] && return 0 || return 1
```
调用方均为 `version_newer "$repo_ver" "$ver"`（3442、3501、5155、5200），即 a=仓库版本、b=已装版本。已装 `26.9.9-r3`、仓库 `26.9.9-r1` → `an == bn == 26.9.9` → `sort -V` 取尾仍是 `26.9.9` → `top == an` → **return 0（判定可升级）**，随后 2705 带 `--force-downgrade` 真降级。

**实测**（抽出 2362-2388 原函数，在 bash 下跑三组）：
```
orig: 26.9.9-r1 vs 26.9.9-r3 => NEWER
orig: 26.9.9-r3 vs 26.9.9-r1 => NEWER     ← 降级方向也判"可升级"
orig: 1:2.3.4 vs 2.3.4 => not-newer       ← epoch 被丢弃
```
即 **revision 差异一律返回"可升级"**（两个方向都真），比"单向误判"更糟：只要源里 revision 与已装不同，脚本就会重装，方向由 `--force-downgrade` 决定。

**影响**：opkg/apk 均受影响。触发场景真实存在：用户从官方源装过较新 revision，之后脚本切到 SourceForge 快照源（revision 较旧）→ 降级 PassWall 主包 → 与已装 LuCI 版本不匹配，界面报错。

**修复建议**：
```sh
version_newer() {
  local a="$1" b="$2" ab ar bb br
  ab=$(echo "$a" | sed 's/^v//; s/-r[0-9][0-9]*$//')
  ar=$(echo "$a" | sed -n 's/.*-r\([0-9][0-9]*\)$/\1/p'); ar=${ar:-0}
  bb=$(echo "$b" | sed 's/^v//; s/-r[0-9][0-9]*$//')
  br=$(echo "$b" | sed -n 's/.*-r\([0-9][0-9]*\)$/\1/p'); br=${br:-0}
  if [ "$ab" = "$bb" ]; then          # base 相同：只比 revision，严格大于才算新
    [ "$ar" -gt "$br" ] && return 0 || return 1
  fi
  [ "$(printf '%s\n%s\n' "$ab" "$bb" | sort -V | tail -1)" = "$ab" ] && return 0
  return 1
}
```
修复版实测：`r3 vs r1 => not-newer`、`r1 vs r3 => newer`、`26.10.1-r1 vs 26.9.9-r3 => newer`、`26.9.9 vs 26.9.9 => not-newer`（四组全对）。

## [P2] 源校验对**用户自定义源**同样生效，任一条不符即中止整次安装 — 1179-1207 / 1208 / 1434

**代码事实**：`validate_source_path_compatibility`（1179）遍历文件内**所有** feed 行，`*/releases/packages-X.Y/*` 系列不匹配或 `packages/<arch>/` 架构不符即 `bad=1`；`validate_opkg_feed_indexes`（1208）还额外要求 base feed 含 `ip-full`、luci 含 `luci-base`、packages 含 `coreutils`；`validate_unique_opkg_feed_names`（1421）对 distfeeds 与 customfeeds 同名 feed **直接拒绝刷新**。

**影响**：opkg 机型。第三方源（kiddin9、openwrt.ai、自建镜像）几乎必然不满足"releases/packages-X.Y + 三个必需包"的组合，结果不是"跳过该源"而是**安装中止**。用户视角是"脚本一跑就退，什么都没干"。

**修复建议**：校验范围收敛到脚本自己写的 feed 名（`po_*`、`passwall_*`、`iw_*`、`openwrt_*`），其余只 warn：
```sh
case "$name" in
  po_*|passwall_*|iw_*|openwrt_*) : ;;      # 本脚本管理，严格校验
  *) info "跳过非本脚本 feed 校验: $name"; continue ;;
esac
```

## [P2] `repair_router_self_network` 覆盖 DHCP 下发 DNS 且备份从不恢复 — 100-113（调用点 573、1034）

**代码事实**：
```sh
{
  echo "nameserver 223.5.5.5"
  echo "nameserver 119.29.29.29"
  echo "nameserver 1.1.1.1"
} > /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null || true
if [ -e /tmp/resolv.conf ] || [ -L /tmp/resolv.conf ]; then
  cp -a /tmp/resolv.conf /tmp/resolv.conf.po-bak 2>/dev/null || true
fi
rm -f /tmp/resolv.conf; ln -s /tmp/resolv.conf.d/resolv.conf.auto /tmp/resolv.conf
/etc/init.d/dnsmasq restart
```
`grep -n 'resolv.conf.po-bak'` 只有写入行（108），**无任何读取/恢复**。同一函数 81 行还执行 `ip route replace default via "$gw" dev "$wan_dev"`。

**影响**：全机型，且是**自动触发**——573 行在源探测前的联网检测失败时直接调用（`... || repair_router_self_network || true`）。装了 AdGuard Home / 自定义上游 DNS 的路由器，`resolv.conf.auto` 被钉死成三个公共 DNS，AdGuard 的 53 端口劫持与上游配置被绕开，表现为"DNS 分流突然失效"。路由 `replace` 也会覆盖多 WAN/策略路由的默认路由。

**修复建议**：
```sh
DNS_BAK="/tmp/resolv.conf.d/resolv.conf.auto.po-bak"
[ -f "$DNS_BAK" ] || cp -a /tmp/resolv.conf.d/resolv.conf.auto "$DNS_BAK" 2>/dev/null || true
... 修复动作 ...
# 结束后打印回滚提示，不静默
info "如需恢复原 DNS: cp -a $DNS_BAK /tmp/resolv.conf.d/resolv.conf.auto && /etc/init.d/dnsmasq restart"
```
更好：仅在 `uci get dhcp.@dnsmasq[0].noresolv` 为假且未装 AdGuard 时才改写。

## [P2] DAED 选项是空实现：置位后无任何安装动作，仍返回成功 — 991 / 997（全文无消费点）

**代码事实**：
```sh
# 936 初始化
INSTALL_PW=0; ...; INSTALL_DAED=0; ...
# 991 菜单 5
5) ... INSTALL_DAED=1; ... ok "选择: DAED" ;;
# 997 菜单 11
11) INSTALL_PW=1; INSTALL_PW2=1; INSTALL_OC=1; INSTALL_DAED=1; ... ok "选择: 全部安装"
```
`grep -n INSTALL_DAED` 全部命中只有 936/939/991/997，无 `if [ "$INSTALL_DAED" = "1" ]`。

**影响**：全机型。用户选 5 得到"选择: DAED"，然后脚本一路跑完（源探测、清理），最后以 `RESULT_RC=0` 收尾 —— **误报成功**。选 11（全部安装）同样悄悄漏装 DAED。

**修复建议**：要么实现，要么明确拒绝：
```sh
5) err "DAED 暂未支持（本版本无安装实现），请改选 1-4/6-8"; continue ;;
# 997 中移除 INSTALL_DAED=1
```

---

# B. OpenWrt 兼容性

## [P3] 版本探测对非标准发行版偏保守，`list_series_vers` 无 `sort -V` 兜底 — 408-411 / 445 / 586-590 / 595

**代码事实**：
```sh
# 445
PW_VER=$(echo "$SYS_RELEASE" | sed -n 's/^\(21\.02\|22\.03\|23\.05\|24\.10\|25\.12\)\.[0-9][0-9]*$/\1/p')
# 586-590
curl -sL --max-time 10 "$1/releases/" | grep -oE "${2}([.-][0-9]+|[-]SNAPSHOT)/" | tr -d '/' | sort -uVr
```
`DISTRIB_RELEASE` 为 `24.10.4` 可匹配；`iStoreOS 22.03.7`、`SNAPSHOT`、`24.10-SNAPSHOT` 均落空 → `NON_RELEASE_OPKG=1` → 拒绝正式版 fallback（方向正确，属保守）。`list_series_vers` 整条管道依赖 busybox `sort -V`，不支持时输出空且无 `|| true`，调用方拿到空列表后静默跳过镜像探测。595 起的 `check_url $MIR/releases/$V/packages/$SYS_ARCH/base/$PKG_FILE` 多处**未加引号**，`SYS_ARCH` 为空时拼出 `//` 得到 404 而非显式报错。

**影响**：iStoreOS / ImmortalWrt 非标准版本号机型，表现为"探测不到镜像 → 走兜底源 → 安装变慢或失败"，不会损坏系统。

**修复建议**：
```sh
case "$SYS_RELEASE" in
  *[0-9].[0-9][0-9].*) PW_VER=$(echo "$SYS_RELEASE" | grep -oE '[0-9]+\.[0-9]+' | head -1) ;;
esac
list_series_vers() { ... | sort -uVr 2>/dev/null || ... | sort -ur ; }   # 兜底
check_url "$MIR/releases/$V/packages/${SYS_ARCH:?}/base/$PKG_FILE"      # 空值即报错
```

## [P3] opkg 与 apk 两条路径不对称：apk 侧"装成功"判定与回滚都更弱 — 3401-3410 / 2926 / 2545 vs 4015、4967

**不对称点清单**：
- `verify_package_installed`（3401）只对 opkg 的 i18n 包做落盘校验，apk 分支直接 `return 0`；
- `pkg_update`（2926）opkg 分支丢弃 `want_ver` 重新解析；
- 回滚：apk 有 `/etc/apk/world` 备份+回填（2500、2525），opkg 无任何事务回滚；
- 强制参数：opkg 处处 `--force-downgrade --force-overwrite`（2705、2735、2755、2790、2805…），apk 却在 4015、4967 使用 `--force-broken-world`，而 2545 注释明确写着：
```sh
# 不使用 --force-broken-world：它可能为解决 world 冲突清理无关插件
```
- 依赖预检是**对称**的（opkg `--noaction` 2560 / apk `--simulate` 2621，apk 侧还多查 `Purging|Removing|Deleting`）—— 这点做得比 opkg 好。

**影响**：APK 系统（25.12+）。"装完报成功但其实没装上"在 apk 侧更容易发生。

**修复建议**：`verify_package_installed` 补 apk 分支；删除 4015/4967 的 `--force-broken-world`（与 2545 保持一致），world 冲突走 2489/2517 的最小化清理路径。

## [P3] 架构映射缺口：`apk_pkg_arch_from_target` 缺 ipq807x/ipq60xx/x86_64，`arch_to_targets` 缺 riscv64 与 a55/a73/a78 — 468-500 / 508-516

**代码事实**：
```sh
# 508-516 只映射 9 个 target
mediatek/filogic|mediatek/mt7622|bcm27xx/bcm2710|bcm4908/generic|mvebu/cortexa53|sunxi/cortexa53|armvirt/64) echo "aarch64_cortex-a53" ;;
bcm27xx/bcm2711|mvebu/cortexa72) echo "aarch64_cortex-a72" ;;
bcm27xx/bcm2712) echo "aarch64_cortex-a76" ;;
sifiveu/generic|star64/generic) echo "riscv64" ;;
rockchip/armv8|octeontx/generic) echo "aarch64_generic" ;;
*) echo "" ;;
```
未覆盖 `ipq807x/generic`、`ipq60xx/generic`（大量 aarch64 硬路由）、`x86/64`，靠 519-524 从 `/etc/apk/repositories` grep 回落（能救，但依赖已有源路径存在）；`arch_to_targets`（468）对 `arm_cortex-a7` 只给 `mediatek/mt7629`，缺 `riscv64_riscv64`、`aarch64_cortex-a55/a73/a78`。

**影响**：APK 系统上 ipq807x/ipq60xx 机型首次安装时可能拿到空 `SYS_ARCH` → 源 URL 拼成 `//`（见上条）→ 安装失败。opkg 侧 arm_cortex-a7 机型镜像探测偏窄。

**修复建议**：
```sh
ipq807x/generic|ipq60xx/generic|qualcommax/ipq807x) echo "aarch64_cortex-a53" ;;
x86/64|x86/generic) echo "x86_64" ;;
mediatek/mt7981) echo "aarch64_cortex-a53" ;;
mediatek/mt7986) echo "aarch64_cortex-a53" ;;
mediatek/mt7988) echo "aarch64_cortex-a53" ;;
```

## [P3] `version_newer` 不处理 epoch — 2362-2391

`1:2.3.4` 与 `2.3.4` 直接交给 `sort -V`，`:` 不是版本分隔符，epoch 版本被判为更旧（实测 `version_newer 1:2.3.4 2.3.4` → not-newer）。OpenWrt opkg 不用 epoch、apk 也不支持 epoch，故属理论风险；仅当上游改用 `apk` 的 `-r`/epoch 混用时才会暴露。

**修复建议**：比较前显式拆 epoch，缺省为 0，先比 epoch 再比 base。

## [P3] GitHub/HTML 解析脆弱：JSON 靠 `grep -oE` 顺序假设，未加引号的命令替换 — 3162 / 3660 / 4283 / 2333 / 4244

**代码事实**：
```sh
# 3660
grep -oE 'https://[^" ]*/luci-app-passwall2_[^" ]*_all\.ipk'
# 4283 / 4508 / 4566
grep -oE '"tag_name": *"[^"]+"'
# 2333 抓 SourceForge HTML
grep -oE "${pkg}-[^\"/ ]+\.apk"
# 4244 dl_with_mirror：未加引号
for u in $(gh_candidates "$url"); do
```
`partexp_release_asset_url`（3162）用 awk 逐行匹配 `"name"` 再取下一行 `"browser_download_url"` —— GitHub API 一旦调整字段顺序（历史上发生过）即取到错资产或空串。所有解析结果最终以引号形式进入 `curl -o "$out" "$url"`，**未发现命令注入**；但远端版本串直接进 `/tmp/pkg_$pkg.apk`、`retry_path="/tmp/apk-retry-${dep}-$$.apk"` 等路径，无白名单。

**影响**：全机型。真实踩点是"上游改格式 → 装错包或装不上"，不是 RCE。`gh_candidates`（54-57）当前只回显官方 URL（无第三方加速镜像），这点是好的，但 4244 的 `$(...)` 未加引号，若将来加入含空格/通配符的镜像 URL 会出问题。

**修复建议**：有 `jq` 时优先 `jq -r`，否则按 `"name"` 与 `"browser_download_url"` 做同对象内配对而非行序假设；`for u in $(...)` 改为 `while IFS= read -r u`。

## [P3] `/tmp` 下载物默认 644，全文无 `umask` — 全文件

无 `umask` 设置，`curl -o /tmp/...` 落盘为 `0644`（`/tmp/ipk.pub`、`/tmp/apk-retry-*.apk`、`/tmp/po-partexp.$$/*`、`/tmp/AdGuardHome_linux_*.tar.gz`）。OpenWrt 默认单 root 用户，属理论风险；但在 `dropbear` 多用户或 `sftp` 共享场景下，其他本地用户可读、可替换（`/tmp` 是 tmpfs，目录权限 1777 但文件属 root）。

**修复建议**：入口加 `umask 077`，或对下载物显式 `chmod 600`。

## [P3] 凭据经 envp 传递，`ps` 不可见但 `/proc/PID/environ` 可读 — 145-147 / 1943-1944

**代码事实**：
```sh
# 145-147
export http_proxy="$MY_PROXY" https_proxy="$MY_PROXY" HTTP_PROXY="$MY_PROXY" HTTPS_PROXY="$MY_PROXY"
# 1943-1944
https_proxy="$PROXY_URL" http_proxy="$PROXY_URL" apk update >/tmp/po_apk_update.log 2>&1
```
这是**做对了**的实现：赋值前缀进入 `execve` 的 `envp` 而非 `argv`，`ps aux` / `/proc/PID/cmdline` 均不可见；全文也无 `echo "$MY_PROXY"`、无写入日志。剩余风险仅 `/proc/PID/environ`（同 uid 可读，即 root 自己）。

**修复建议**：保持现状；若追求极致，可在下载子 shell 内 `unset` 并在子进程退出后立即清空。

## [P3] 内核二进制覆盖无回滚副本；AdGuardHome 配置备份在 `/tmp` 且 `cp` 失败静默 — 4532-4570 / 3033-3054

**代码事实**：
```sh
# 4532-4560 install_mihomo_core
gzip -dc "$tmp" > "$dest"          # 直接覆盖，无 .po-bak
# 3033-3050 remove_adguardhome_keep_config
cp -a /opt/AdGuardHome "$BAK" 2>/dev/null || true   # 失败静默
rm -rf /opt/AdGuardHome
cp -a "$BAK"/. /opt/AdGuardHome 2>/dev/null || true # 失败即丢数据
```
对比 `update_xray_official_mips`（有 `$bin.po-bak` 回滚，但备份永久留在 `/usr/bin`）。

**影响**：内核升级失败时 PassWall/OpenClash 直接不可用，需手动重装；AGH 卸载"保留配置"在 cp 失败时静默丢配置。

**修复建议**：覆盖前 `cp -a "$dest" "$dest.po-bak"`，成功后删除；AGH 备份改到 `/etc/AdGuardHome.po-bak` 并校验 `[ -d "$BAK" ]` 才执行 `rm -rf`。

## [P3] 死代码与重复定义：`restore_apk_passwall_feeds` 无调用、`validate_tar_paths` 双版、`mihomo_version_matches` 双版、`ncore` 未 `local` — 352 / 3183+4721 / 4475+4505 / 4548

- `restore_apk_passwall_feeds`（352）定义完整但全文无调用（见 P2 条目）；
- `validate_tar_paths` 3183 与 4721 两版语义不同，后者静默覆盖前者；
- `mihomo_version_matches` 4475 与 4505 两版重复定义；
- `install_mihomo_core` 内 `ncore`（4548）未 `local`，污染全局命名空间；
- `apk_add_repo_exact`（2538）内 `apk_installed_exact` 连续调用两次（2543-2544），无害冗余。

**影响**：维护性。双版 `validate_tar_paths` 会让"改了一处没生效"成为后续踩坑点（4721 覆盖 3183，而阅读顺序上 3183 在前）。

**修复建议**：删 3183 版或合并为单版；`restore_apk_passwall_feeds` 接入 `trap`；`mihomo_version_matches` 保留一处；`local ncore`。

---

# 附：已确认做对的部分（避免过度整改）

- **代理凭据不落 argv/日志**（145-147、164-172）：仅环境变量传递，无 echo、无日志输出。
- **卸载默认保留配置**（1044-1057、1076-1090）：`UNINSTALL_KEEP_CONFIG=1` 为默认，删除 `/etc/config/*` 与 `rm -rf /etc/openclash*`（3070）需显式选 2。
- **`disable_failed_opkg_feeds`（1249）**：按 URL 命中 `Failed|404|Signature check failed` 逐行注释并**保留原文**，可回滚，是全文处理源最规范的一处。
- **`apk_retry_without_hash_constraint`（2489）与 `apk_repair_stale_hash_world`（2517）**：只清 `/etc/apk/world` 中 `^sing-box><hash` 与 `/tmp/*.apk` 路径行，前后 `cp -f` 备份+失败回填，日志门禁精确（`grep -q "breaks: world\[sing-box><"`）——**属最小化可回滚处理，不是静默全局绕过**，与 P1 第 1 条的 `apk_retry_integrity_transaction` 性质完全不同，整改时不要一并删掉。
- **`install_partexp`（3275-3304）三重校验**：内联 awk 拒绝对路径与 `..` + `validate_tar_paths` + `-C "$work"`，是全脚本解压防护做得最好的一处（AGH/OpenClash 应照抄）。
- **全文无 `uci set`/`uci commit`、无 `/etc/config/firewall` 写入**：不改防火墙规则、不动 UCI 配置，破坏面收敛在"包管理 + 源文件 + DNS 文件"。
- **`gh_candidates`（54-57）只回显官方 URL**：未硬编码第三方 GitHub 加速镜像，供应链面比预期小（但 `dl_with_mirror` 仍会依次尝试候选，若将来加入镜像需重新评估）。

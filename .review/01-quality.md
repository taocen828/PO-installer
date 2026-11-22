# install-passwall.sh 代码质量审查：结构与健壮性

审查对象：`install-passwall.sh`（5345 行 / 248918 字节 / 141 个函数定义 / busybox ash / v20261029.6）
审查方式：只读静态审查，全部结论附实测行号与代码片段。
基线事实：无 `set -e`、无 `set -u`、无 `set -o pipefail`（`grep '^set '` 无输出）；`/tmp` 引用 212 处，`mktemp` 仅 2 处（1320、1323）；`|| true` 188 处；`2>/dev/null` 318 处；`echo -e` 5 处、`printf` 65 处。

---

## P0

### [P0] 非原子回写 `/etc/opkg/*.conf`，中断即损坏全部系统源 — 309、1600、5255
- **证据**：
  - `install-passwall.sh:309` `awk '...' "$file" > /tmp/opkg-feeds.po-clean 2>/dev/null && cat /tmp/opkg-feeds.po-clean > "$file"`
  - `install-passwall.sh:1600` `cat /tmp/systemfeeds.po-new > "$FEED_FILE"`
  - 对比 `install-passwall.sh:1327` `mv -f "$tmp" "$file" || exit 1`（同一作者在隔离函数里用了原子 mv）
  - `install-passwall.sh:5255` 注释自述"不用 sed -i：busybox sed -i 会破坏符号链接……用 sed 输出到临时文件再 cat 回写"——只解决了符号链接，没解决原子性
- **触发条件/影响**：`cat > file` 先 truncate 再写入。写入过程中 Ctrl-C、SSH 断开、掉电，或 `/overlay` 满（tmpfs 与 flash 双写），`distfeeds.conf`/`customfeeds.conf` 变成空文件或半截文件。opkg 从此无源可用，用户 `opkg update` 全失败，且**没有备份文件可恢复**（294-313 全程未产生 `.bak`）。这是脚本最严重的一类不可逆损坏。
- **修复建议**：统一改 `tmp="$(mktemp "${file}.po.XXXXXX")"` + 写完 `mv -f "$tmp" "$file"`（同目录 mv 是原子 rename，且不破坏符号链接）；首次修改前 `cp -p "$file" "$file.po-bak"`；把该模式抽成 `rewrite_conf_atomic FILE < filter` 一个函数，供 309/1600/1616 三处复用。

### [P0] AdGuardHome 卸载「保留配置」把 data 搬进 tmpfs 且吞掉全部失败，随后无条件 `rm -rf` — 3035-3053
- **证据**：
  ```
  3035 |   local tmp="/tmp/AdGuardHome.keep"
  3042 |     mkdir -p "$tmp" 2>/dev/null || true
  3043 |     [ -f /opt/AdGuardHome/AdGuardHome.yaml ] && cp ... "$tmp/AdGuardHome.yaml" 2>/dev/null || true
  3044 |     [ -d /opt/AdGuardHome/data ] && cp -a /opt/AdGuardHome/data "$tmp/data" 2>/dev/null || true
  3047 |   rm -rf /opt/AdGuardHome 2>/dev/null || true
  3050 |     [ -f "$tmp/AdGuardHome.yaml" ] && mv "$tmp/AdGuardHome.yaml" /opt/AdGuardHome/AdGuardHome.yaml 2>/dev/null || true
  3051 |     [ -d "$tmp/data" ] && mv "$tmp/data" /opt/AdGuardHome/data 2>/dev/null || true
  ```
- **触发条件/影响**：`/tmp` 是 tmpfs（RAM）。AGH 的 `data/` 含查询日志与统计库，正常使用后可达数十 MB；128/256MB 内存的路由器上 `cp -a` 直接 ENOSPC，`|| true` 把失败吞掉，第 3047 行照旧 `rm -rf /opt/AdGuardHome`，第 3050-3051 行再静默失败。**用户明确选了"保留配置"，配置和统计全丢**。同理 3043 失败时连 `AdGuardHome.yaml` 也丢。
- **修复建议**：改为同分区改名保留——`mv /opt/AdGuardHome /opt/AdGuardHome.po-keep-$(date +%s)`，只删二进制与 init 脚本，配置与 data 原地不动；确需清理时再按 `UNINSTALL_KEEP_CONFIG` 处理。复制到 tmpfs 的方案整体废弃，或改用 `/overlay` 下的临时目录并**检查 `cp` 返回码，失败即中止卸载**。

### [P0] `install_adguardhome` 版本切换无回滚：`mv` 失败后旧版被删或滞留 `.old` 且不恢复 — 4377-4385
- **证据**：
  ```
  4382 |     rm -rf /opt/AdGuardHome.old
  4383 |     mv /opt/AdGuardHome /opt/AdGuardHome.old 2>/dev/null || rm -rf /opt/AdGuardHome
  4385 |   mv /opt/AdGuardHome.new /opt/AdGuardHome
  ```
- **触发条件/影响**：4383 的 `mv` 失败时（跨设备、权限、目录被占用），`|| rm -rf` 直接把旧安装删掉；4385 无返回码检查，若 `/overlay` 在 4378 之后被写满，`mv` 失败则 `/opt/AdGuardHome` 不存在、旧版在 `.old`、`.new` 半成品——**AGH 完全不可用且脚本继续往下走**（4388 `newver` 为空 → 4389 的版本校验被 `[ -n "$newver" ]` 短路跳过 → 直到 4397 才 `err`，但从不把 `.old` 恢复回 `/opt/AdGuardHome`）。4405 还会把 `.old` 删掉，彻底断绝恢复可能。
- **修复建议**：4385 改为 `mv /opt/AdGuardHome.new /opt/AdGuardHome || { mv /opt/AdGuardHome.old /opt/AdGuardHome; err ...; return 1; }`；`.old` 的清理推迟到"新版本启动成功且版本号校验通过"之后；版本校验失败分支必须先回滚再 `return 1`。

---

## P1

### [P1] 菜单项 5) DAED 与 11) 全部安装中的 DAED 完全无实现，静默成功 — 936、939、946、991、997、5275-5336
- **证据**：`grep -n DAED` 全文仅 8 处命中，全部在初始化与菜单赋值：
  ```
   936 | INSTALL_PW=0; ... INSTALL_DAED=0; ...
   939 | DAED_INSTALL_OK=0
   946 | echo "  5) DAED (独立代理内核/面板）"
   991 |   5) INSTALL_PW=0; ...; INSTALL_DAED=1; ...; ok "选择: DAED" ;;
   997 |  11) INSTALL_PW=1; ...; INSTALL_DAED=1; ...; ok "选择: 全部安装（不含高风险分区扩容）" ;;
  ```
  `DAED_INSTALL_OK` 定义后**从未被读取**；结果汇总段 5283-5336 无任何 DAED 分支。
- **触发条件/影响**：用户选 5 → 打印"选择: DAED" → 脚本跑完全部流程（源检测、空间检测、Geo、可选组件全部因 `INSTALL_PW/PW2/OC/SSR/AGH/ISTORE/PARTEXP` 全 0 而跳过）→ 汇总无报错 → `exit 0`。用户以为装好了 DAED，实际一个文件都没动。选 11（全部安装）时同样静默跳过 DAED。
- **修复建议**：二选一——(a) 实现 `install_daed()` 并在汇总段加 `[ "$INSTALL_DAED" = "1" ] && { ... RESULT_RC=1; }`；(b) 从菜单 946 与 997 移除 DAED，避免承诺无法兑现的功能。

### [P1] 全脚本无全局 trap：`/tmp` 垃圾与源状态无退出清理，中断后 opkg 源可能永久被注释 — 1317、1331、294-313、5345
- **证据**：`trap` 仅两处，且在**子 shell 函数内部**：
  ```
  1307 | opkg_update_isolated_named_feeds() (
  1317 |   trap 'restore_isolated_feeds' EXIT INT TERM
  1331 |   trap - EXIT INT TERM
  ```
  其余会改系统源文件的路径（294-313 `cleanup_opkg_duplicate_feeds`、1588-1616 写 systemfeeds/apk repositories、1882 写 `/var/opkg-lists/$feed`）**没有任何 trap 保护**。脚本末尾 5345 `exit "$RESULT_RC"` 前也没有 `rm -f /tmp/po-*`。
- **触发条件/影响**：两种后果——(1) 在 1307 的子 shell 内被 `SIGKILL`（或 OOM killer 杀掉，低内存路由器常见）时 `restore_isolated_feeds` 不会执行，`/etc/opkg/*.conf` 里留下 `# PO-installer temporarily isolated: src/gz ...`，**所有源被注释掉，用户下次 `opkg update` 全失败**，且没有任何提示或恢复入口；(2) 其它路径中断后 `/tmp` 留下 `pkg_*.ipk`、`*.apk`、`po_*.log` 等大文件占 RAM。
- **修复建议**：在脚本顶部（约第 60 行后）注册一次性全局清理：`TMP_PO_DIR=$(mktemp -d /tmp/po.XXXXXX)`，所有临时文件落该目录，`trap 'rm -rf "$TMP_PO_DIR"; restore_feeds_if_dirty' EXIT INT TERM HUP`；把源文件改写前的备份记录写进 `$TMP_PO_DIR/feeds.state`，使恢复逻辑不再依赖单个子 shell。

### [P1] 30 处 `curl` 无 `--max-time`，单条挂起连接可让脚本永久卡死 — 2742、2879、2938、3290、2475、4832、4907
- **证据**：`grep 'curl ' | grep -v max-time` 共 30 行（不含注释）。典型：
  ```
  2475 |   curl -fL --progress-bar -o "$out" "$final"
  2742 |         if curl -fL -sS -o "/tmp/pkg_$dep.ipk" "$dep_url"; then
  2879 |     if curl -fL $prog -o "/tmp/pkg_$pkg.apk" "$url" && apk_file_valid "/tmp/pkg_$pkg.apk"; then
  2938 |         if curl -fL $prog -o "/tmp/pkg_$pkg.apk" "$url"; then
  3290 |   if ! command -v tar >/dev/null 2>&1 || ! curl -fL -sS -o "$work/$archive" "$url"; then
  4832 |     curl -fsL --max-time 60 -o "$run" "$u" 2>/dev/null || { rm -f "$run"; continue; }
  ```
  对比：全文件唯一带完整超时/重试的是 803 `curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 15 --max-time 90`。
- **触发条件/影响**：被墙/半开连接（`SYN` 后无响应）时 curl 默认永不超时（无 `--connect-timeout` 时依赖系统 TCP 重传，可达数分钟到永久）。**主包下载路径 2742/2879/2938 恰好全部无超时**，而这三个正是安装失败率最高的环节；用户在 SSH 里看到进度条停住，无任何提示，只能 Ctrl-C（而 Ctrl-C 又触发上一条的源状态残留）。
- **修复建议**：抽 `po_curl() { curl -fL --connect-timeout 10 --max-time "${PO_CURL_MAX:-180}" --retry 2 --retry-delay 2 "$@"; }`，全脚本替换；把超时值集中为常量（见 P3 魔法数字条目）。

### [P1] `VERSION` 注释写死 20261029.6，运行时算出来的是"今天日期.1"，版本号永远对不上 — 5、9-15、151
- **证据**：
  ```
    5 | # VERSION: 20261029.6 (从 OPKG 索引读取依赖架构)
    7 | # 版本号规则：YYYYMMDD.N；N 是"当天"的发布序号，每天从 1 重新开始，不能跨天累计。
    9 | VERSION_SEQ="1"
   10 | VERSION_DATE=$(date +%Y%m%d 2>/dev/null)
   13 |   *) VERSION_DATE="20260913" ;;
   15 | VERSION=$(printf '%s.%s' "$VERSION_DATE" "$VERSION_SEQ")
  151 | echo " OpenWrt 工具箱 (v$VERSION)"
  ```
- **触发条件/影响**：第 5 行注释、仓库 tag 与用户看到的横幅三者互不相等。任何"先 `grep VERSION` 再决定是否推送/是否已装"的流程（团队约定里就有这条）都会误判；排查线上问题时无法从横幅判断用户跑的是哪个版本。第 13 行的兜底日期 `20260913` 也是过期常量。
- **修复建议**：单一事实来源——`VERSION="20261029.6"` 一个常量，`VERSION_SEQ`/`VERSION_DATE` 动态拼接逻辑删除；如需保留日期语义，则注释改为 `# VERSION: 由 VERSION_DATE/VERSION_SEQ 运行时生成`，并删掉 13 行硬编码兜底（`date` 失败时直接 `VERSION="unknown"`）。

### [P1] 无 `set -e` 且关键落盘/服务启动不检查返回码，产生"安装成功但不可用"的假成功 — 4191-4202、4394-4398、4841-4848
- **证据**：
  ```
  4191 |     echo "arch all 1" >> /etc/opkg.conf        # 无返回码检查
  4192 |     changed=1
  4202 |   [ "$changed" = "1" ] && info "已补齐本地 IPK 架构: all/noarch/$SYS_ARCH"
  ```
  ```
  4394 |   "$bin" -s install >/tmp/agh_service.log 2>&1 || install_agh_service_fallback
  4396 |   /etc/init.d/AdGuardHome start >/dev/null 2>&1 || "$bin" -s start >/dev/null 2>&1 || true
  4397 |   if [ -x "$bin" ]; then            # 只校验文件可执行，不校验服务是否真的起来了
  4398 |     ... ok "AdGuardHome ... ✓"
  ```
  ```
  4841 |     "$run" > /tmp/istore_install.log 2>&1
  4843 |     if [ "$rc" = "0" ] && { check_installed "luci-app-store" || istore_files_installed; }; then
  ```
- **触发条件/影响**：`/etc/opkg.conf` 只读（overlay 满或 squashfs 未 overlay）时 `>>` 失败，脚本仍打印"已补齐"；AGH 二进制存在但 init 脚本缺失/端口被占用时，`start` 全失败仍打 ✓，汇总 5315 也因此报成功；iStore 同理只校验文件存在。三类假成功都会让用户以为装好了、实际进 LuCI 无入口或无服务。
- **修复建议**：4191/4195/4199 改为 `echo ... >> /etc/opkg.conf || { err "无法写入 /etc/opkg.conf"; }` 并置 `changed=0`；4397 增加 `pidof AdGuardHome || "$bin" -s status` 检查，未运行则 `err` + `return 1`；4843 增加服务/`taskd` 就绪检查。

---

## P2

### [P2] `apk_install` 222 行单函数，opkg 与 apk 两条完整流程揉在一起，拆分点清晰 — 2702-2923
- **证据**：函数跨度 2702-2923（222 行），内部结构：
  ```
  2705 |   local ... prog ...                      # opkg 分支开始
  2742 |         if curl -fL -sS -o "/tmp/pkg_$dep.ipk" "$dep_url"; then
  2825 |       if (cd /tmp && opkg download "$pkg") 2>&1; then
  2857 |       case "$pkg" in luci-app-passwall|...    # opkg 失败诊断
  2860-2869 |                                        # apk 分支开始（重新声明 prog）
  2879 |     if curl -fL $prog -o "/tmp/pkg_$pkg.apk" "$url" && apk_file_valid ...
  2923 | }
  ```
  两个分支之间**没有共享状态**，只有函数入口的 `local pkg="$1"`。
- **触发条件/影响**：任何一处修改（比如给下载加超时）都要在两条分支各改一遍，且已出现不一致（opkg 分支的 `prog` 变量声明了但从未使用，见 P3 条目）。函数体过长也让"哪条分支在跑"难以判断，历史上 2870 重复声明 `prog` 就是这种耦合的产物。
- **修复建议**：拆为 `apk_install()`（30 行派发）→ `_apk_install_opkg()`（约 110 行）/ `_apk_install_apk()`（约 60 行）+ 共用 `_pkg_download_and_verify pkg url out`、`_pkg_report_failure pkg log rc`。

### [P2] `probe_system_source_candidates` 335 行，且把 3 个函数物理嵌套在函数体内 — 579-913、586、595、715
- **证据**：brace-depth 实测嵌套定义：
  ```
  586 |   list_series_vers() {          # 嵌套于 probe_system_source_candidates 内
  595 |   probe_ow_ver() {               # 同上
  715 |   probe_proxy_sources() {        # 同上（181 行）
  758 |     sf_pick_node() {             # 嵌套于 probe_proxy_sources 内
  788 |     sf_probe_index() {           # 嵌套于 probe_proxy_sources 内
  ```
  注：4319 的 `start_service` 是 heredoc `<< 'AGH_INIT_EOF'` 里的文本，不属此问题。
- **触发条件/影响**：函数在每次调用 `probe_system_source_candidates` 时被**重新定义**（ash 允许，但每次多 fork 开销且污染命名空间）；5 个函数全部不可单测、不可复用，其它函数想用 `probe_ow_ver` 只能重复实现。
- **修复建议**：把 586/595/715/758/788 提升为顶层函数；`probe_system_source_candidates` 只保留编排逻辑，按阶段拆成 `probe_openwrt_series`、`probe_mirror_sources`、`probe_sf_sources` 三个 50 行以内的函数。

### [P2] `pkginstall` 与 `pkgupgrade` 约 95% 重复，唯一实质差异是 geo 空间守卫 — 3428-3480 / 3484-3539
- **证据**：`diff <(sed -n '3428,3480p') <(sed -n '3484,3539p')` 显示除函数头与 3488-3497 的守卫块外，其余逐行相同：
  ```
  3439-3464（pkginstall）≡ 3498-3523（pkgupgrade）：check_installed → get_version → get_repo_version
                                                      → version_newer → pkg_update → rc=2/rc!=0 分支
                                                      → nver 三重比较 → 成功/失败文案
  3465-3479（pkginstall）≡ 3524-3538（pkgupgrade）：apk_install → install_rc → verify_package_installed
  ```
  仅 pkgupgrade 多出：
  ```
  3488 |   if [ "$PKG_MGR" = "opkg" ] && [ "$pkg" = "v2ray-geoip" ] && check_installed "$pkg"; then
  3492 |     geo_need_kb=45000
  ```
- **触发条件/影响**：两份 53/56 行代码必须同步维护；改一处漏一处就是行为分叉（例如给 `pkg_update` 增加新返回码语义时）。当前两份的 `err` 文案已略有差异（3447 "新版缺少依赖 (coreutils-timeout/lyaml 等)" vs 3506 "新版缺少依赖"），说明分叉已经在发生。
- **修复建议**：`pkgupgrade() { _pkg_install_or_upgrade "$1" "$2" --geo-guard; }`，`pkginstall() { _pkg_install_or_upgrade "$1" "$2"; }`；守卫块改成 `_check_geo_space` 前置钩子。

### [P2] `force_reinstall_selected` 与 `uninstall_selected_only` 有 41 行逐字节相同 — 3117-3161 / 3348-3392
- **证据**：`diff <(sed -n '3117,3161p') <(sed -n '3348,3392p')` 仅前 3 行不同（函数名、守卫变量、横幅文案），第 4-44 行完全一致：
  ```
  3119-3121 | remove_pkg_keep_config "luci-i18n-passwall-zh-cn" ...
  3122-3124 | remove_pkg_keep_config "luci-app-passwall" ... / remove_passwall_core_selection / remove_plugin_config
  ...（PW2 / OC / SSR / AGH / PARTEXP / ISTORE 全套 remove 调用）
  3160 | clean_luci_cache
  ```
  差异仅 3161 `}` vs 3393 起的 `echo "" ... exit 0`。
- **触发条件/影响**：新增一个插件（如 DAED 真正实现后）必须同时改两处，漏改就出现"重装能清、纯卸载清不掉"的不一致。这是最容易在后续迭代中退化的重复。
- **修复建议**：抽 `_remove_selected_plugins()`（约 40 行），两个入口只保留守卫与收尾：`force_reinstall_selected() { [ "$FORCE_REINSTALL" = "1" ] || return 0; hdr "卸载旧版主程序"; _remove_selected_plugins; }`。

### [P2] "下载 + magic 校验 + 逐个候选重试"循环被复制 5 份，已有的 `dl_with_mirror` 未被复用 — 4240-4261、3599-3605、3678-3688、4831-4837、3690-3698
- **证据**：`dl_with_mirror`（4240-4261）已经实现了"遍历 `gh_candidates` → curl → `dd` 取 magic → 校验 → `mv`"，但只被 AGH/OpenClash 使用；以下四处各自重写了一遍：
  ```
  3599 |   for u in $(gh_candidates "$url"); do
  3600 |     curl -fL --connect-timeout 10 --max-time 180 -o "$tmp" "$u" ...
  3603 |     unzip -p "$tmp" xray_softfloat > "$newbin" ... || { rm -f "$tmp" "$newbin"; continue; }
  3678 |   for u in $(gh_candidates "$url"); do
  3679 |     curl -fL --connect-timeout 10 --max-time 120 -o "$pkgfile" "$u" ...
  3682 |       magic=$(dd if="$pkgfile" bs=1 count=4 2>/dev/null); [ "$magic" = "ADBd" ] || ...
  4831 |   for u in $(gh_candidates "$url"); do
  4832 |     curl -fsL --max-time 60 -o "$run" "$u" 2>/dev/null || { rm -f "$run"; continue; }
  ```
- **触发条件/影响**：magic 字节集合（`!<ar` / `\037\213` / `ADBd`）在 3682-3685 与 4249-4256 两处各写一遍，格式校验口径已经不完全一致（3679 版本不校验 `!<ar` 之外的非 gzip 情况时直接 break）。超时值也各写一套（120/180/60）。
- **修复建议**：统一为 `dl_verified url out type`（type ∈ ipk/apk/gz/any），内部复用 4240 的实现并接受可选 `--max-time`；3599、3678、4831 三处直接调用。预期净减约 60 行。

### [P2] 4 个函数定义后从未被调用（死代码） — 468、1249、4518、4532
- **证据**：全文 grep 仅 1 次命中（即定义行本身）：
  ```
   468 | arch_to_targets() {
  1249 | disable_failed_opkg_feeds() {
  4518 | get_mihomo_latest_ver() {
  4532 | install_mihomo_core() {
  ```
- **触发条件/影响**：`install_mihomo_core` 是完整的内核安装实现（约 40 行），被 `openclash_core` 新路径取代后遗留；读者会误以为存在两条内核安装路径，维护时容易改错分支。`arch_to_targets` 与现用的架构映射逻辑重复，两套映射并存有漂移风险。
- **修复建议**：删除 4518-4560 区间（`get_mihomo_latest_ver` + `install_mihomo_core`）、468 起的 `arch_to_targets`、1249 起的 `disable_failed_opkg_feeds`；若 `disable_failed_opkg_feeds` 的逻辑仍需要（feed 连续失败计数），确认 `record_openwrt_feed_state`(1336) 是否已覆盖，覆盖则一并删除。

### [P2] 同名函数重复定义，后者静默覆盖前者，其中一对语义不同 — 3183/4721、4475/4505
- **证据**：
  ```
  3183 | validate_tar_paths() {           # 版本 A：tar -tzf | while read 管道
  3185 |   tar -tzf "$archive" 2>/dev/null | while IFS= read -r member; do
  4721 | validate_tar_paths() {           # 版本 B：先取 members 再 here-doc，覆盖 A
  4725 |   while IFS= read -r member; do
  ```
  ```
  4475 | mihomo_version_matches() {       # 版本 A：字符串相等 或 openclash_core_version 相等
  4505 | mihomo_version_matches() {       # 版本 B：比较 mihomo_ver_num 归一化值，覆盖 A
  ```
- **触发条件/影响**：ash 顺序定义，后者生效。3183 版本 A 变成死代码，但如果将来有人把 4721 挪走/注释，行为会静默回退到管道版（管道内 `exit 1` 只退出子 shell，失败可能被吞）。4475/4505 语义不同，被覆盖的那份若被"恢复"会改变版本判定结果。这类覆盖不会报错，是最难查的一类回归。
- **修复建议**：删除 3183-3195 的版本 A 与 4475-4490 的版本 A；如需保留两套判定，改名 `mihomo_version_matches_strict` / `_loose` 并显式调用。

### [P2] `/tmp` 固定文件名（无 `$$`/`mktemp`）导致并发与残留冲突 — 4353-4354、3673、4003、4827、4917-4918、2705、298、309
- **证据**：
  ```
  4353 |   work="/tmp/AdGuardHome-install"
  4354 |   tarball="/tmp/AdGuardHome_linux_${arch}.tar.gz"
  3673 |   pkgfile="/tmp/luci-app-passwall2.$ext"
  4003 |   pkgfile="/tmp/luci-app-ssr-plus.$ext"
  4827 |   local run="/tmp/istore-reinstall.run" url u
  4917 |       OC_PKG="/tmp/luci-app-openclash.$OC_EXT"
  2705 |   local ... log="/tmp/opkg_install.log" ...   # 实际 2705/2870/2930 三个固定日志名
   298 |   : > /tmp/opkg-fixed-feed-names
   309 |     awk ... > /tmp/opkg-feeds.po-clean
  ```
  对比：全文件只有 1320、1323 用了 `mktemp`。
- **触发条件/影响**：同一台路由器上并行跑两个实例（用户重开一个 SSH 会话，或 web 终端重复点击）时，两个进程共用 `/tmp/luci-app-passwall2.ipk`：A 下载到一半、B `rm -f` 后重下，A 的 magic 校验读到 B 的半截文件 → 误判"包无效"并跳到降级源；更糟的是 298/309 的 awk 中间文件被交叉写入，可能把**错误的源清单**回写进 `/etc/opkg/*.conf`（与 P0 条目叠加）。残留文件还会长期占 RAM。
- **修复建议**：统一 `PO_TMP="$(mktemp -d /tmp/po.XXXXXX)"`（配合 P1 的全局 trap），所有路径改为 `"$PO_TMP/xxx"`；必须固定名的地方（如 `/tmp/po-last-opkg-install.log`，供失败时 cat）加 `$$`。

### [P2] `ls -t /tmp/*.ipk | head -1` 取"最新 ipk"当成本次下载结果 — 2825-2836
- **证据**：
  ```
  2825 |       if (cd /tmp && opkg download "$pkg") 2>&1; then
  2828 |         dl_ipk=$(ls -t /tmp/*.ipk 2>/dev/null | head -1)
  2829 |         if [ -n "$dl_ipk" ] && { [ -z "$repo_ver" ] || echo "$dl_ipk" | grep -Fq "$repo_ver"; }; then
  2831 |             opkg install "$dl_ipk" --force-downgrade --force-overwrite > "$log" 2>&1
  2834 |           rm -f "$dl_ipk"
  ```
- **触发条件/影响**：`/tmp` 里任何遗留 ipk 只要 mtime 更新就会被选中；`grep -Fq "$repo_ver"` 只做子串匹配（`repo_ver="1.0"` 会匹配 `1.0.1`、`11.0`），校验形同虚设。接着 `opkg install "$dl_ipk" --force-downgrade --force-overwrite` **强行覆盖安装一个来路不明的包**，然后 `rm -f` 删掉别人的文件。
- **修复建议**：`opkg download` 前记录 `/tmp` 快照，或改用 `opkg download --dest "$PO_TMP"`（busybox opkg 支持 `-d`）后直接取 `$PO_TMP/$pkg_*.ipk`；版本校验改为 `grep -Eq "_${repo_ver}_|_${repo_ver}\.ipk$"`。

### [P2] 无重试退避：唯一带 `--retry` 的是 803，其余失败即 `continue` — 803、3599-3605、3678-3688、4831-4837
- **证据**：
  ```
   803 |     curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 15 --max-time 90 -o "$tmp" "$u" 2>/dev/null || true
  ```
  `grep -n 'sleep '` 全文件仅 3 处（88、1294、1299），无任何"循环重试 + 退避"结构；`gh_candidates`(54-57) 只 `printf '%s\n' "$url"` 输出**单个**候选。
- **触发条件/影响**：SourceForge/GitHub 在路由 Web 刷新瞬间常见瞬时 5xx 或 TLS 抖动，`for u in $(gh_candidates ...)` 只有一轮，一次抖动就落到"下载失败"分支（3679/4832）。由于没有退避，重跑整个脚本是唯一手段，而重跑要重新走源探测（数百次 curl）。
- **修复建议**：`gh_candidates` 改为输出"直连 + 镜像"多候选；抽 `retry_fetch N BACKOFF cmd...`，在 3599/3678/4831 等下载循环外层套 2-3 次、`sleep 1/2/4` 指数退避。

### [P2] 远程脚本下载后只做 3 处字符串匹配即以 root 执行 — 4828-4841
- **证据**：
  ```
  4828 |   url="https://github.com/linkease/openwrt-app-actions/raw/main/applications/.../istore-reinstall.run"
  4832 |     curl -fsL --max-time 60 -o "$run" "$u" 2>/dev/null || { rm -f "$run"; continue; }
  4833 |     grep -q "ISTORE_REPO=https://istore.istoreos.com/repo/all/store" "$run" 2>/dev/null && \
  4834 |       grep -q "luci-app-store" "$run" 2>/dev/null && \
  4835 |       grep -q "/tmp/is-opkg install" "$run" 2>/dev/null && break
  4841 |     "$run" > /tmp/istore_install.log 2>&1
  ```
- **触发条件/影响**：`main` 分支内容可变，三处 `grep` 只能证明"脚本里有这几个字符串"，不能证明内容未被篡改/未被投毒。以 root 执行等于把路由器交给上游仓库的 main 分支。同时 4838 `[ -s "$run" ]` 在循环**未 break** 时也成立（比如三次 grep 全失败但文件非空）→ 仍会执行未通过校验的脚本。
- **修复建议**：固定到 commit SHA 的 raw 链接；校验 sha256（脚本内自带期望值）；4838 改为用显式标志 `verified=1`（只在 `break` 分支置位）判断，而不是 `-s`。

### [P2] `opkg_update_with_timeout` 超时后 `kill -9` 只杀父进程，`wait` 返回码不可靠 — 1281-1304
- **证据**（摘要）：`timeout` 命令可用时 `timeout "$seconds" opkg update`；否则后台启动 + `kill -0` 轮询 + `kill`/`kill -9`，超时返回 124。超时分支 `kill -9` 后 `wait`。
- **触发条件/影响**：opkg 的下载子进程（wget/curl）不在同一进程组被杀时继续占用连接与 `/var/lock/opkg.lock`；后续 `opkg install` 因锁冲突失败，而错误信息与"超时"无关，用户难以定位。`wait` 对已被 `kill -9` 的作业可能返回 127，与"超时 124"语义混淆。
- **修复建议**：后台启动时用 `setsid`（或 `ash` 的作业控制）让子进程自成进程组，超时后 `kill -9 -$pgid`；返回值统一为 124；调用方按 124 输出"opkg update 超时，请检查代理/源"。

### [P2] 空间检测：空值不设防、且明确不拦截，与实际写入存在竞态 — 1130-1135、1101-1108
- **证据**：
  ```
  1130 |   OVERLAY_SPACE=$(df -k /overlay 2>/dev/null | tail -1 | awk '{print $4}')
  1131 |   [ -z "$OVERLAY_SPACE" ] && OVERLAY_SPACE=$(df -k / 2>/dev/null | tail -1 | awk '{print $4}')
  1133 |   OVERLAY_SPACE=$((OVERLAY_SPACE / 1024))
  1134 |   ok "Overlay 可用: ${OVERLAY_SPACE}MB（仅诊断，不拦截安装）"
  ```
  对比 `get_overlay_free_mb`(921-929) 用 `case` 过滤非数字，1130 的内联版本没有复用。
- **触发条件/影响**：`df` 输出被 wrap 或第 4 列是 `Use%` 时，`$((...))` 在 ash 下报 `arithmetic syntax error` 并把变量留空/0，横幅打印"可用 0MB"却继续安装；用户看到 0MB 仍继续，随后 opkg 在解包阶段段错误（脚本自己在 3486-3487 注释里承认过 v2ray-geoip 会导致 139）。检测与真正写入之间还有几分钟（源探测、下载），期间空间可能被别的进程吃掉。
- **修复建议**：复用 `get_overlay_free_mb` 并加 `case "$OVERLAY_SPACE" in ''|*[!0-9]*) OVERLAY_SPACE=unknown;; esac`；在 `apk_install` 入口**再次**取一次剩余空间，低于阈值时要求用户确认（而不是只打印）；把 3488-3497 的 geo 守卫提升为通用 `preflight_space need_kb`。

---

## P3

### [P3] `echo -e` + `\e` 颜色在 busybox ash 下不生效，日志里出现字面 `-e \e[32m` — 16-21
- **证据**：
  ```
   16 | RED='\e[31m'; GREEN='\e[32m'; YELLOW='\e[33m'; BLUE='\e[34m'; NC='\e[0m'
   17 | ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
   18 | info() { echo -e "${YELLOW}[→]${NC} $1"; }
   19 | warn() { echo -e "${YELLOW}[!]${NC} $1"; }
   20 | err()  { echo -e "${RED}[✗]${NC} $1"; }
   21 | hdr()  { echo -e "${BLUE}━━━ $1 ━━━${NC}"; }
  ```
- **触发条件/影响**：busybox `echo` 的 `-e` 依赖编译选项 `FEATURE_FANCY_ECHO`，未开启时把 `-e` 当普通参数打印；即使开启，其转义集合是 `\a \b \c \f \n \r \t \v \\ \0NNN \xHH`，**不含 `\e`**。所以最可能的结果是每行日志前多出 `-e \e[32m`、行尾多出 `\e[0m`，颜色完全没有。这 5 个函数是全脚本唯一的输出入口（65 处 printf 之外的绝大部分日志），影响所有日志的可读性与 grep 匹配（例如按 `[✓]` 过滤会失效）。
- **修复建议**：`ok() { printf '\033[32m[✓]\033[0m %s\n' "$1"; }`，颜色变量改 `GREEN=$(printf '\033[32m')`；或直接去掉颜色（OpenWrt 的 luci 日志/重定向场景本就不需要）。

### [P3] 章节编号重复：两个 `# 9.` — 5263、5273
- **证据**：
  ```
  5262 | #==============================================
  5263 | # 9. 刷新 LuCI
  5272 | #==============================================
  5273 | # 9. 结果汇总
  ```
  前置章节为 1、2、3、3.5、4、5、6、7、8。
- **触发条件/影响**：按章节号定位代码（"看第 9 节"）会产生歧义；后续插入章节时编号进一步漂移。
- **修复建议**：5273 改为 `# 10. 结果汇总`。

### [P3] `prog` 在 opkg 分支声明并赋值却从未使用，apk 分支又重复声明 — 2705、2783、2870、2879、2938
- **证据**：
  ```
  2705 |   local ... prog ...
  2783 |     prog="-sS"; [ -t 1 ] && prog="--progress-bar"     # opkg 分支内，之后无任何使用
  2870 |   local ... prog ...                                  # apk 分支重新声明
  2879 |     if curl -fL $prog -o "/tmp/pkg_$pkg.apk" "$url" ...
  ```
- **触发条件/影响**：2783 的计算完全是死代码（opkg 分支用 2742 的固定 `-sS`），读者会误以为 opkg 下载也走进度条分支；`$prog` 未加引号展开依赖 word splitting，若将来改为带空格的值会破坏 curl 参数。
- **修复建议**：删除 2783；apk 分支改用 `"${prog:--sS}"` 或数组式参数拼接；opkg 分支如需进度条，复用同一处赋值。

### [P3] 相邻两行完全重复的调用 — 2543-2544
- **证据**：
  ```
  2543 |   apk_installed_exact "$pkg" "$want_ver" && return 0
  2544 |   apk_installed_exact "$pkg" "$want_ver" && return 0
  ```
- **触发条件/影响**：纯冗余（第二次永不可达）；暗示此处曾被合并/回滚过，容易被误认为"两次检查"。
- **修复建议**：删除 2544。

### [P3] 引用了从未赋值的变量 `$local_force_depends` — 2803
- **证据**：
  ```
  2803 |   grep -q "pkg_hash_check_unresolved" "$log" 2>/dev/null && [ -z "$local_force_depends" ] && rc=2
  ```
  全文 grep `local_force_depends` 仅此 1 行，无任何 `local`/赋值。
- **触发条件/影响**：`[ -z "" ]` 恒真，条件退化为"日志含 pkg_hash_check_unresolved 就 rc=2"。若原意是"仅当未强制依赖时才算依赖错误"，则该判断当前永远成立，可能把可恢复的 hash 警告升级成安装失败（rc=2 会触发 3446 的"新版缺少依赖"分支并放弃升级）。
- **修复建议**：删除该条件，或补 `local local_force_depends=0` 并在实际使用 `--force-depends` 的路径置 1。

### [P3] 超时/阈值魔法数字散落 20+ 处，未集中为常量 — 29、232、803、1103、1118-1129、3492、3600、3679、4246
- **证据**：
  ```
   29 | ... --max-time 8
  232 | ... --connect-timeout 8 --max-time 15
  803 | ... --connect-timeout 15 --max-time 90
 1103 |   [ -n "$free_kb" ] && [ "$free_kb" -ge 45000 ] && return 1
 1118-1129 | REQUIRED_SPACE_MB=35 / 55 / 30 / +80 / +80 / +30 / +60 / +40 / +20
 3492 |     geo_need_kb=45000
 3600 | ... --max-time 180
 3679 | ... --max-time 120
 4246 |   curl -fL -# --max-time 60 -o "$tmp" "$u"
  ```
- **触发条件/影响**：`45000` 在 1103 与 3492 各写一次（语义相同：geo 包安全空间），改一处就分叉；超时值 8/15/60/90/120/180 无规律可循，调参要全文搜索。
- **修复建议**：文件头部集中 `PO_CONNECT_TIMEOUT=10`、`PO_DL_TIMEOUT=180`、`PO_API_TIMEOUT=20`、`PO_GEO_NEED_KB=45000`、`PO_SPACE_PW_MB=80` 等，全部引用常量。

### [P3] 交互 `read` 全部无 `-t` 超时，管道/异常终端下只能靠 EOF 兜底 — 960、1015、1048、1066、1082
- **证据**：
  ```
   960 |   if ! read -r MAIN_CHOICE; then
  1015 |       if ! read -r UNINSTALL_CHOICE; then echo ""; info "输入流已关闭，默认不执行卸载"; exit 0; fi
  1048 |   if ! read -r UNINSTALL_CFG_CHOICE; then
  1066 |   if ! read -r INSTALL_MODE; then
  1082 |     if ! read -r UNINSTALL_CFG_CHOICE; then
  ```
- **触发条件/影响**：都有 `if ! read` 的 EOF 兜底（这点做得对），但 stdin 是"活着但不发数据"的场景（SSH 会话挂起、`nohup`、CI 里 `sh -c` 且 stdin 未关闭）会**无限阻塞**，没有任何超时或提示。132-142 的非 TTY 分支只覆盖"从管道执行"这一种形态。
- **修复建议**：主菜单与二次确认统一改为 `read -r -t 120`（busybox ash 支持 `-t`），超时按"输入流不可用"处理并走既有默认值分支，同时 `info "等待输入超时，使用默认值"`。

### [P3] 收尾阶段的失败全部静默，LuCI 未刷新时用户看到"装好了但没入口" — 5266-5270、5340-5344
- **证据**：
  ```
  5266 |   /etc/init.d/rpcd restart >/dev/null 2>&1 || /etc/init.d/rpcd reload >/dev/null 2>&1 || true
  5269 |   luci-reload 2>/dev/null || true
  5340 | case "$THIS_SCRIPT" in
  5341 |   /tmp/install-passwall.sh|/tmp/install.sh|/tmp/*.sh)
  5342 |     rm -f "$THIS_SCRIPT" 2>/dev/null || true
  ```
- **触发条件/影响**：rpcd 重启失败时新装的 LuCI 控制器不被加载，汇总仍显示"验证通过"，用户只能自己重启路由器；5341 的 `/tmp/*.sh` 通配过宽，任何从 `/tmp` 下任意 `*.sh` 运行的场景都会被自删（包括用户自己放在 `/tmp` 的其它脚本被 `readlink -f "$0"` 解析后误删——仅在 `$0` 指向该文件时，实际风险低，但模式本身没必要这么宽）。
- **修复建议**：rpcd/luci-reload 失败时 `warn "LuCI 缓存刷新失败，请手动执行 /etc/init.d/rpcd restart"`；5341 收窄为 `/tmp/install-passwall.sh|/tmp/install.sh`。

---

## 附：优先级统计与拆分建议汇总

| 优先级 | 条数 | 主题 |
|---|---|---|
| P0 | 3 | 源文件非原子回写、AGH 配置丢失、AGH 版本切换无回滚 |
| P1 | 5 | DAED 静默无操作、无全局 trap、curl 无超时、VERSION 注释失真、假成功面 |
| P2 | 13 | 巨型函数拆分、三组重复代码、死代码、重复定义、/tmp 冲突、ls -t、无退避、远程脚本执行、超时封装、空间竞态 |
| P3 | 8 | echo -e 颜色、章节编号、prog 死赋值、重复行、未定义变量、魔法数字、read 超时、收尾静默 |
| 合计 | 29 | 全部附行号与代码片段证据 |

建议改造顺序（按风险/收益）：
1. 先做 P0 三条（改动局部、收益最大，全部涉及用户数据或系统源可用性）。
2. 再做 P1 的全局 trap + `po_curl` 封装（一次性消掉 P1 的 3 条与 P2 的 2 条）。
3. 然后做 P2 的三组去重（pkginstall/pkgupgrade、force_reinstall/uninstall、下载循环统一到 `dl_verified`），预期净减 150-200 行。
4. 最后做 P2/P3 的巨型函数拆分与常量集中，属于可维护性投资。

# install-passwall.sh 优化方案与实施排序

审查对象：`install-passwall.sh`（5345 行 / 248918 字节 / md5 `7476c8e5ea3764b624eac02b94be5687` / v20261029.6）
合并来源：`.review/01-quality.md`（29 条）、`.review/02-risk.md`（23 条）
本轮复核：全部 P0/P1 条目已回源码逐行核对，行号与代码片段均实测；`bash -n`、`sh -n` 均通过；被审脚本未做任何修改。

条目编号约定：`Q` = 01-quality.md，`R` = 02-risk.md；`P0-1` 等为本方案的合并编号。

---

## 一、结论摘要

52 条原始发现合并去重后得 **34 条**（同根因合并 18 条），重新分层为 **P0×5 / P1×10 / P2×11 / P3×8**。

三个必须优先处理的结论：

1. **变砖面集中在"写系统配置"这一层**。全脚本有 9 处直接 `> file` / `cat tmp > file` 覆盖 `/etc/opkg/*.conf`、`/etc/apk/repositories`，无 `.bak`、无原子 `mv`；而同一位作者在 `install-passwall.sh:1327` 用的正是原子写法 `mv -f "$tmp" "$file" || exit 1`。中断、掉电、overlay 写满都会把 `distfeeds.conf` 截断成空文件，此后 `opkg update` 全源失效，路由器无法再装任何包，且没有任何本地副本可恢复。**这是本次审查唯一具备"一次操作即不可逆损坏"性质的缺陷族**，修复成本约 60 行。
2. **数据丢失面有两条独立路径**：`remove_adguardhome_keep_config`（3033-3055）把 `/opt/AdGuardHome/data` 备份到 `/tmp`（tmpfs）后无条件 `rm -rf /opt/AdGuardHome`，用户选"保留配置"仍然丢；`install_adguardhome`（4377-4405）升级时先删 `.old`、`mv` 不查返回码、成功判定只看文件存在、最后连 `.old` 一起删，失败即无回滚。
3. **供应链校验实际为零**：全文 `sha256sum`/`sha512sum` 命中 0 次；7 条以 root 直装路径无任何内容校验，其中 `install_ssr_manual_from_ipk:3981` 直接把 `data.tar.gz` 解到 `/`；`apk_retry_integrity_transaction`（2650-2700）自称"绝不绕过 APK 完整性校验"，实际清缓存后从镜像直取文件、只比 4 字节魔数 `ADBd` 就重跑事务；`ipk.pub` 经 `wget --no-check-certificate` 下载后 `opkg-key add`，无指纹固定。

需要纠正的两处口径（以本轮实测为准）：

- `01-quality.md` 称"30 处 curl 无 `--max-time`"，实际代码行 curl 调用共 47 处，**缺 `--max-time` 的只有 5 处**：`2475`（第二段进度下载）、`2742`、`2879`、`2938`、`3290`。原口径把注释与函数名字符串一并计入，本方案按 5 处处理。
- `01-quality.md` P0-1 的行号写作"309、1600、5255"，其中 `5255` 是 `info` 打印语句，不写文件（`install-passwall.sh:5252-5259` 只做 `grep -qE` 判断后打印"PassWall source 保留"）。实际写系统源的 9 处见 P0-1。

已确认**不应**一并整改的实现（避免误伤）：`apk_retry_without_hash_constraint`（2489-2515）与 `apk_repair_stale_hash_world`（2517-2532）是"备份 → 最小化删除单行 → 失败回填"的正例；`install_partexp`（3296-3304）三重归档校验是全脚本解压防护样板；`update_xray_official_mips`（3617-3618）有 `.po-bak` 回滚；卸载默认保留配置；全文无 `uci set`、无 firewall 写入；凭据走 envp 不进 `ps`（145-147）。

---

## 二、P0 必修（安全 / 变砖）

ROI 排序按"收益 ÷ 成本"降序：收益以"避免不可逆损坏"计权最高，成本按改动行数与回归风险估算。

| 编号 | 标题 | 行号 | 原始编号 | 收益 | 成本 | ROI |
|---|---|---|---|---|---|---|
| P0-1 | 系统源文件非原子覆盖且无备份，中断即损坏全部软件源 | 309 / 1557 / 1600 / 1626 / 1701 / 1712 / 1786 / 1814 / 4697 | Q-P0-1 + R-P2-8 + R-P2-10 | 极高（防变砖） | 60 行 + 9 处替换 | ★★★★★ |
| P0-2 | AdGuardHome 卸载"保留配置"把 data 搬进 tmpfs 后无条件 `rm -rf` | 3033-3055 | Q-P0-2 | 高（防数据丢失） | 25 行替换 | ★★★★★ |
| P0-3 | AdGuardHome 与内核二进制替换均无回滚，失败即旧版丢失 | 4377-4405 / 4543-4553 | Q-P0-3 + R-P3-20 | 高（防版本空洞） | 35 行 | ★★★★☆ |
| P0-4 | `patch_istore_is_opkg_world_cleanup` 永久改写 `/bin/is-opkg` 并删除 world 约束 | 4678-4701 | R-P1-3 | 高（装完 PassWall 再用 iStore 会移除内核） | 45 行（净删注入） | ★★★★☆ |
| P0-5 | 供应链校验缺失族：apk 完整性重试绕过 adb、ipk.pub 无指纹、7 条 root 直装零校验 | 2650-2700 / 1807-1815 / 3290 / 3591-3620 / 3981 / 4362 / 4445-4471 / 4543-4553 / 4775 | R-P1-1 + R-P1-2 + R-P1-4 | 高（安全） | 净删 45 行 + 40 行新增 | ★★★☆☆ |

### P0-1 系统源文件非原子覆盖且无备份

**证据（已复核）**——9 处写系统配置，全部"先写 /tmp 再 `cat` 回目标"或直接 `>>`，无 `.bak`、无 `mv`：

```
install-passwall.sh:309   ' "$file" > /tmp/opkg-feeds.po-clean 2>/dev/null && cat /tmp/opkg-feeds.po-clean > "$file"
install-passwall.sh:1557  /etc/opkg/distfeeds.conf > /tmp/distfeeds.po-disabled && cat /tmp/distfeeds.po-disabled > /etc/opkg/distfeeds.conf
install-passwall.sh:1600  cat /tmp/systemfeeds.po-new > "$FEED_FILE"
install-passwall.sh:1626  cat /tmp/apk-repositories.po-new > "$APK_REPO_FILE"
install-passwall.sh:1701  cat /tmp/customfeeds.tmp > /etc/opkg/customfeeds.conf 2>/dev/null
install-passwall.sh:1712  cat "$tmp" > /etc/opkg/customfeeds.conf 2>/dev/null || true
install-passwall.sh:1786  grep -v -e '^src/gz openwrt_' -e '^src/gz iw_' /etc/opkg/customfeeds.conf > /tmp/customfeeds.clean 2>/dev/null || true
install-passwall.sh:1814  echo "src/gz $feed $SF_BASE/$feed" >> /etc/opkg/customfeeds.conf
install-passwall.sh:4697  ' /bin/is-opkg > /tmp/is-opkg.po-new 2>/dev/null && cat /tmp/is-opkg.po-new > /bin/is-opkg
```

对照正例 `install-passwall.sh:1320-1327`：

```sh
    bak=$(mktemp "/tmp/$(basename "$file").po-isolate.XXXXXX") || exit 1
    cp -p "$file" "$bak" || exit 1
    ...
    mv -f "$tmp" "$file" || exit 1
```

**触发条件 / 影响**：`1600` 与 `1557` 在"系统源异常 + 网络可用"分支里必然执行；`309` 每次运行都执行。任一时刻被 `Ctrl-C`、SSH 断连、OOM killer、掉电打断，或 `/tmp`（tmpfs）与 overlay 空间不足使 `cat` 只写了一半，`distfeeds.conf` / `customfeeds.conf` 即变成空文件或半截文件。之后 `opkg update` 报 `no valid architecture` 或 `Failed to download`，路由器失去全部软件源，脚本自身也无法再修复（它读同一个文件做探测）。`|| true`（1700、1712、1786）还会把 `grep` 失败导致的空输出直接回写，等价于清空 `customfeeds.conf`。

**修复草案**——在 `install-passwall.sh:293`（`cleanup_opkg_duplicate_feeds` 定义之前）插入两个公共函数：

```sh
# --- 系统配置文件安全写入 -------------------------------------------------
# 所有 /etc/opkg/*.conf、/etc/apk/repositories、/bin/is-opkg 的改写都必须走这里：
#   1) 在目标同目录建临时文件（同文件系统，保证 mv 原子）
#   2) 覆盖前保留 <target>.po-bak
#   3) mv -f 原子替换；失败回滚并返回非 0
# 用法: po_write_conf [--allow-empty] <目标文件> <生成内容的命令...>
po_write_conf() {
  local allow_empty=0 target dir tmp bak
  if [ "$1" = "--allow-empty" ]; then allow_empty=1; shift; fi
  target="$1"; shift
  [ -n "$target" ] || return 1
  dir=$(dirname "$target")
  [ -d "$dir" ] || { err "目录不存在: $dir"; return 1; }
  tmp=$(mktemp "$target.po-new.XXXXXX" 2>/dev/null) || { err "无法在 $dir 创建临时文件（空间不足？）"; return 1; }
  if ! "$@" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; err "生成新配置失败，保留原文件: $target"; return 1
  fi
  if [ "$allow_empty" != "1" ] && [ ! -s "$tmp" ]; then
    rm -f "$tmp"; err "新配置为空，拒绝覆盖: $target"; return 1
  fi
  # 内容未变则直接返回：不动 mtime、不用"已改过的文件"覆盖掉上一次的 .po-bak
  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then rm -f "$tmp"; return 0; fi
  bak="$target.po-bak"
  [ -f "$target" ] && { cp -p "$target" "$bak" 2>/dev/null || warn "无法备份 $target"; }
  if ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"; err "写入失败: $target"
    [ -s "$bak" ] && cp -p "$bak" "$target" 2>/dev/null
    return 1
  fi
  return 0
}

# 从 .po-bak 恢复（供退出清理与手工救援使用）
po_restore_conf() {
  local target="$1" bak="$1.po-bak"
  [ -s "$bak" ] || return 1
  cp -p "$bak" "$target" 2>/dev/null || return 1
  info "已恢复 $target（来源 $bak）"
  return 0
}
```

替换 `294-313`：

```sh
cleanup_opkg_duplicate_feeds() {
  [ "$PKG_MGR" = "opkg" ] || return 0
  local file names="/tmp/opkg-fixed-feed-names.$$"
  : > "$names" || return 0
  for file in /etc/opkg/distfeeds.conf /etc/opkg/compatfeeds.conf /etc/opkg/customfeeds.conf; do
    [ -f "$file" ] || continue
    po_write_conf "$file" awk -v statef="$names" '
      BEGIN {
        # 只精确匹配本脚本自己装的旧 feed 名 + kiddin9 系列的 iw_ 前缀。
        # 不能用 /passwall|ssr/ 子串匹配：用户的 myssr_mirror、passwall_backup 之类会被误注释。
        split("passwall_luci passwall_packages passwall2 helloworld kiddin9", a, " ")
        for (i in a) legacy[a[i]] = 1
        while ((getline n < statef) > 0) fixed[n] = 1
        close(statef)
      }
      /^[[:space:]]*src(\/gz)?[[:space:]]/ {
        if (legacy[$2] || $2 ~ /^iw_/ || fixed[$2] || seen[$2]++) {
          print "# PO-installer disabled duplicate/obsolete feed: " $0; next
        }
      }
      { print }
    ' "$file" || warn "清理 $file 失败，已保留原文件"
    awk '!/^[[:space:]]*#/ && /^[[:space:]]*src(\/gz)?[[:space:]]/ {print $2}' "$file" >> "$names" 2>/dev/null
  done
  rm -f "$names"
}
```

替换 `1557`（保留原语义，改为原子写 + 备份）：

```sh
      if [ -f /etc/opkg/distfeeds.conf ]; then
        po_write_conf /etc/opkg/distfeeds.conf awk \
          '/^[[:space:]]*src(\/gz)?[[:space:]]/ {print "# PO-installer disabled broken system feed: " $0; next} {print}' \
          /etc/opkg/distfeeds.conf \
          && info "已注销异常系统源（原配置保留为注释，备份 /etc/opkg/distfeeds.conf.po-bak）"
      fi
```

替换 `1600` / `1626`：

```sh
      po_write_conf "$FEED_FILE" cat /tmp/systemfeeds.po-new || { err "写入系统源失败，已保留原配置"; }
      po_write_conf "$APK_REPO_FILE" cat /tmp/apk-repositories.po-new || { err "写入 APK 源失败，已保留原配置"; }
```

替换 `1700-1702`（`grep -v` 全过滤时返回 1，改用恒返回 0 的 awk，并允许结果为空；**匹配方式从子串改成精确名**，否则用户自建的 `myssr_mirror`、`passwall_backup` 会被误注释）：

```sh
      po_write_conf --allow-empty /etc/opkg/customfeeds.conf awk \
        'BEGIN { split("passwall_luci passwall_packages passwall2 helloworld kiddin9", a, " "); for (i in a) legacy[a[i]] = 1 }
         ($1 == "src" || $1 == "src/gz") && (legacy[$2] || $2 ~ /^iw_/) { print "# PO-installer disabled obsolete feed: " $0; next }
         { print }' \
        /etc/opkg/customfeeds.conf || warn "清理 customfeeds 失败，已保留原文件"
```

替换 `1709-1713`（顺带修掉 `grep -vE "^src/gz[[:space:]]+$name"` 里 `$name` 未转义的正则注入）：

```sh
      if [ -f /etc/opkg/customfeeds.conf ]; then
        po_write_conf --allow-empty /etc/opkg/customfeeds.conf awk -v n="$name" \
          '($1=="src/gz" || $1=="src") && $2==n {next} {print}' \
          /etc/opkg/customfeeds.conf || return 1
      fi
```

替换 `1785-1788`：

```sh
        po_write_conf --allow-empty /etc/opkg/customfeeds.conf awk \
          '!/^src\/gz openwrt_/ && !/^src\/gz iw_/ {print}' /etc/opkg/customfeeds.conf \
          || warn "清理 customfeeds 失败，已保留原文件"
```

替换 `1813-1815`（追加写要查返回码）：

```sh
      for feed in passwall_luci passwall_packages passwall2; do
        echo "src/gz $feed $SF_BASE/$feed" >> /etc/opkg/customfeeds.conf 2>/dev/null \
          || warn "写入 $feed 源失败（overlay 空间不足？）"
      done
```

**验证**：改后 `ls /etc/opkg/` 应出现 `*.po-bak`；`strace -f -e trace=rename,renameat,openat` 跑一遍，确认目标文件只经 `rename` 变更，不再有 `O_TRUNC` 直写。

### P0-2 AdGuardHome 卸载"保留配置"丢 data

**证据（已复核，`install-passwall.sh:3033-3055`）**：

```text
remove_adguardhome_keep_config() {
  local tmp="/tmp/AdGuardHome.keep"
  ...
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
```

**触发条件 / 影响**：调用点 `3143`（卸载）与 `3374`（重装前清理）。`/tmp` 在 OpenWrt 上是 tmpfs（内存盘），`data` 目录含 `querylog.json`、`stats.db`、`sessions.db`，常见几十 MB；`cp -a` 因空间不足失败时 `|| true` 吞掉，随后 `3047` 无条件 `rm -rf /opt/AdGuardHome` 删掉唯一副本，回填时 `[ -d "$tmp/data" ]` 不成立 → 用户选"保留配置"实际丢失全部统计与配置。`mkdir -p "$tmp"` 失败同样被吞，`cp` 的目标目录不存在，也是静默失败。

**修复草案**——整体替换 `3033-3055`：

```sh
remove_adguardhome_keep_config() {
  # 卸载程序与服务；UNINSTALL_KEEP_CONFIG != 0 时把配置与 data 暂存到持久分区。
  # 绝不使用 /tmp：tmpfs 重启即丢，且 data 体积可能超过可用内存。
  local keep="" src=/opt/AdGuardHome
  if [ -x "$src/AdGuardHome" ]; then
    "$src/AdGuardHome" -s stop >/dev/null 2>&1 || true
    "$src/AdGuardHome" -s uninstall >/dev/null 2>&1 || true
  fi
  if [ "$UNINSTALL_KEEP_CONFIG" != "0" ] && [ -d "$src" ]; then
    keep=$(mktemp -d /overlay/AdGuardHome.keep.XXXXXX 2>/dev/null) \
      || keep=$(mktemp -d /etc/AdGuardHome.keep.XXXXXX 2>/dev/null) || keep=""
    if [ -z "$keep" ]; then
      err "无法创建持久备份目录（/overlay 与 /etc 均不可写），已中止卸载以保护配置"
      return 1
    fi
    if ! cp -a "$src/." "$keep/" 2>/dev/null; then
      err "备份 AdGuardHome 配置失败，已中止卸载（原目录未删除）"
      rm -rf "$keep"
      return 1
    fi
    info "配置已备份到 $keep"
  fi
  rm -f /usr/bin/AdGuardHome /etc/init.d/AdGuardHome 2>/dev/null || true
  rm -rf "$src" 2>/dev/null || true
  if [ -n "$keep" ]; then
    mkdir -p "$src" 2>/dev/null || true
    if cp -a "$keep/." "$src/" 2>/dev/null; then
      rm -rf "$keep"
    else
      err "配置回填失败，备份保留在 $keep（请手工移回 $src）"
    fi
  fi
  return 0
}
```

**验证**：装 AGH → 写入 `data/stats.db` 测试文件 → 选"卸载保留配置" → 确认 `$src/data/stats.db` 仍存在；再人为把 `/overlay` 写满，确认返回 1 且原目录未被删。

### P0-3 AdGuardHome 与内核二进制替换无回滚

**证据（已复核，`install-passwall.sh:4377-4405`）**：

```text
4377  rm -rf /opt/AdGuardHome.new
4378  mv "$work/AdGuardHome" /opt/AdGuardHome.new || { err ...; return 1; }
4379  if [ -d /opt/AdGuardHome ]; then
4380-4381    cp yaml / cp -a data （均 || true）
4382    rm -rf /opt/AdGuardHome.old
4383    mv /opt/AdGuardHome /opt/AdGuardHome.old 2>/dev/null || rm -rf /opt/AdGuardHome
4385  mv /opt/AdGuardHome.new /opt/AdGuardHome
4388  newver=$(get_agh_installed_ver)
4389  if [ -n "$latest" ] && [ -n "$newver" ] && [ "$newver" != "$latest" ]; then
4394  "$bin" -s install >/tmp/agh_service.log 2>&1 || install_agh_service_fallback
4397  if [ -x "$bin" ]; then ... ok "AdGuardHome ... ✓"
4405  rm -rf "$work" "$tarball" /tmp/agh_extract.log /tmp/agh_service.log /opt/AdGuardHome.old
```

**触发条件 / 影响**：`4385` 不查返回码（overlay 满、`/opt` 只读时静默失败）；`4389` 的 `[ -n "$newver" ]` 让"读不到版本"这一最可疑的情况直接跳过校验；`4397` 只要 `AdGuardHome` 二进制存在就打印 ✓，不看服务是否真的起来；`4405` 无论成败都删 `.old`。结果：升级失败时既没有可用新版（`mv` 失败），旧版也已被删（`4405`），AGH 完全不可用且无回滚路径。`install_mihomo_core:4543-4545` 同类：`gzip -dc /tmp/mihomo-core.gz > "$dest"` 直接截断覆盖运行中的内核，无 `.po-bak`。

**修复草案**——替换 `4377-4385`：

```sh
  rm -rf /opt/AdGuardHome.new
  mv "$work/AdGuardHome" /opt/AdGuardHome.new || { err "AdGuardHome 文件写入失败"; rm -rf "$work" "$tarball"; return 1; }
  if [ -d /opt/AdGuardHome ]; then
    [ -f /opt/AdGuardHome/AdGuardHome.yaml ] && cp /opt/AdGuardHome/AdGuardHome.yaml /opt/AdGuardHome.new/AdGuardHome.yaml 2>/dev/null || true
    [ -d /opt/AdGuardHome/data ] && cp -a /opt/AdGuardHome/data /opt/AdGuardHome.new/ 2>/dev/null || true
    rm -rf /opt/AdGuardHome.old
    if ! mv /opt/AdGuardHome /opt/AdGuardHome.old 2>/dev/null; then
      err "旧版 AdGuardHome 无法移走（/opt 只读或空间不足），已中止升级"
      rm -rf /opt/AdGuardHome.new "$work" "$tarball"
      return 1
    fi
  fi
  if ! mv /opt/AdGuardHome.new /opt/AdGuardHome 2>/dev/null; then
    err "新版本落位失败，正在回滚旧版"
    [ -d /opt/AdGuardHome.old ] && mv /opt/AdGuardHome.old /opt/AdGuardHome 2>/dev/null
    rm -rf /opt/AdGuardHome.new "$work" "$tarball"
    return 1
  fi
```

替换 `4388-4389`：

```sh
  newver=$(get_agh_installed_ver)
  if [ -z "$newver" ]; then
    err "AdGuardHome 安装后无法读取版本，判定失败并回滚"
    rm -rf /opt/AdGuardHome
    [ -d /opt/AdGuardHome.old ] && mv /opt/AdGuardHome.old /opt/AdGuardHome 2>/dev/null
    rm -rf "$work" "$tarball" /tmp/agh_extract.log
    return 1
  fi
  if [ -n "$latest" ] && [ "$newver" != "$latest" ]; then
    err "AdGuardHome 版本校验异常: 已安装 $newver，期望 $latest；已回滚"
    rm -rf /opt/AdGuardHome
    [ -d /opt/AdGuardHome.old ] && mv /opt/AdGuardHome.old /opt/AdGuardHome 2>/dev/null
    rm -rf "$work" "$tarball" /tmp/agh_extract.log
    return 1
  fi
```

替换 `4397` 成功判定（必须看服务状态，不能只看文件存在）：

```text
  if [ -x "$bin" ] && { "$bin" -s status >/dev/null 2>&1 || /etc/init.d/AdGuardHome status >/dev/null 2>&1; }; then
```

`4405` 改为仅在成功路径删除 `.old`（即上面这个 `if` 的 then 分支内保留，else 分支回滚后再删）；失败分支补：

```text
  else
    err "AdGuardHome 服务未能启动，已回滚到旧版"
    rm -rf /opt/AdGuardHome
    [ -d /opt/AdGuardHome.old ] && mv /opt/AdGuardHome.old /opt/AdGuardHome 2>/dev/null
    rm -rf "$work" "$tarball" /tmp/agh_extract.log /tmp/agh_service.log
    return 1
  fi
```

`install_mihomo_core:4543-4546` 补回滚：

```sh
    dl_with_mirror "$url" /tmp/mihomo-core.gz || return 1
    [ -f "$dest" ] && cp -p "$dest" "$dest.po-bak" 2>/dev/null
    if ! gzip -dc /tmp/mihomo-core.gz > "$dest.new" 2>/dev/null; then
      rm -f "$dest.new"; err "内核解压失败"; return 1
    fi
    if ! mv -f "$dest.new" "$dest"; then
      rm -f "$dest.new"
      [ -f "$dest.po-bak" ] && mv -f "$dest.po-bak" "$dest"
      err "内核落位失败，已回滚"; return 1
    fi
```

**验证**：把 tarball 换成截断的坏包（`head -c 1024` 后 gzip 损坏）走升级路径，确认旧版目录/内核仍在且可启动；overlay 写满再试一次，确认返回 1 且 `.old` 未被删。

### P0-4 `/bin/is-opkg` 永久注入并删除 world 约束

**证据（已复核，`install-passwall.sh:4678-4701`）**：

```text
4687  cp /bin/is-opkg /tmp/is-opkg.po-bak
4692  print "  awk '$0 ~ /^(dns2tcp|lua-neturl|luci-app-ssr-plus|mosdns|naiveprox4|naiveproxy|libatomic1|nping|sing-box)([<>=~].*)?$/ {next} ...' /etc/apk/world > /tmp/apk.world.istore-clean 2>/dev/null && cat /tmp/apk.world.istore-clean > /etc/apk/world"
4697  ' /bin/is-opkg > /tmp/is-opkg.po-new 2>/dev/null && cat /tmp/is-opkg.po-new > /bin/is-opkg
4700  grep -q "PO_CLEAN_APK_WORLD" /bin/is-opkg && ok ... || info "注入失败，继续"
```

**触发条件 / 影响**：只要在 APK 系统上装了 iStore（`4785` 调用），`/bin/is-opkg` 被永久改写；此后**每一次** iStore 操作都会从 `/etc/apk/world` 删除 `sing-box`、`luci-app-ssr-plus`、`mosdns`、`naiveproxy` 等行。`sing-box` 是 PassWall 在 APK 系统上的核心依赖，world 行被删后下一次 `apk add` 会把内核当"孤儿"清理，PassWall 静默失效。备份只在 `/tmp`（tmpfs），重启后连恢复源都没有。与 `install-passwall.sh:2974` 注释"APK world 是持久系统状态，只读检查，不自动编辑或删除任何约束"直接矛盾。

**修复草案**——不做永久注入，改为"临时放宽 + 立即恢复"，复用 `apk_retry_without_hash_constraint`（2489）已验证的最小化模式。整体替换 `4678-4701`：

```sh
patch_istore_is_opkg_world_cleanup() {
  # 历史实现永久改写 /bin/is-opkg，注入 awk 从 /etc/apk/world 删除 sing-box 等约束。
  # 这会污染系统：装完 PassWall 再用 iStore 装插件时，PassWall 内核可能被连带移除。
  # 现在只做两件事：撤销历史注入 + 记录安装前 world 快照。
  [ "$PKG_MGR" = "apk" ] || return 0
  if [ -s /bin/is-opkg ] && grep -q "PO_CLEAN_APK_WORLD" /bin/is-opkg 2>/dev/null; then
    if [ -s /tmp/is-opkg.po-bak ]; then
      cp /tmp/is-opkg.po-bak /bin/is-opkg 2>/dev/null && chmod 755 /bin/is-opkg 2>/dev/null \
        && info "已撤销历史版本对 /bin/is-opkg 的注入（从 /tmp 备份恢复）"
    else
      warn "检测到 /bin/is-opkg 被历史版本注入，但 /tmp 备份已丢失；请重装 iStore 以恢复原始脚本"
    fi
  fi
  [ -f /etc/apk/world.po-guard ] || cp -p /etc/apk/world /etc/apk/world.po-guard 2>/dev/null || true
  return 0
}

# 临时放宽 world 约束执行命令，退出时按快照恢复被删行（不在系统里留任何注入）
with_apk_world_relaxed() {
  local backup="/etc/apk/world.po-tmp.$$" rc=0 line
  cp -p /etc/apk/world "$backup" 2>/dev/null || return 1
  awk '!/^(dns2tcp|lua-neturl|luci-app-ssr-plus|mosdns|naiveprox4|naiveproxy|libatomic1|nping|sing-box)([<>=~].*)?$/' \
    "$backup" > "/tmp/apk.world.relaxed.$$" 2>/dev/null \
    && cat "/tmp/apk.world.relaxed.$$" > /etc/apk/world || { rm -f "$backup" "/tmp/apk.world.relaxed.$$"; return 1; }
  "$@" || rc=$?
  cp -p "$backup" /etc/apk/world 2>/dev/null || err "world 恢复失败，备份在 $backup"
  rm -f "/tmp/apk.world.relaxed.$$"
  [ "$rc" = "0" ] && rm -f "$backup"
  return "$rc"
}

# 安装后校验：PassWall 相关包不得从 world 消失
restore_apk_world_guard() {
  local snap=/etc/apk/world.po-guard line missing="" added=0
  [ -s "$snap" ] || return 0
  # 以快照为准逐行比对，不要硬编码包名：luci-app-passwall2/ssr-plus 可能本来就没装，
  # 硬编码会让守卫每次都误报"丢失"。
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    grep -qxF "$line" /etc/apk/world 2>/dev/null || { missing="$missing $line"; added=1; }
  done < "$snap"
  [ "$added" = "0" ] && return 0
  warn "检测到 APK world 丢失:$missing，正在按安装前快照补回"
  cp -p /etc/apk/world /etc/apk/world.po-lost 2>/dev/null || true
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    grep -qxF "$line" /etc/apk/world 2>/dev/null || echo "$line" >> /etc/apk/world
  done < "$snap"
  return 0
}
```

调用点：`4785` 保留 `patch_istore_is_opkg_world_cleanup`（此时它只做撤销+快照），把 iStore 实际安装命令（`4790` 附近的 `apk add ...`）包进 `with_apk_world_relaxed`，并在 `4848` 之后加一行 `restore_apk_world_guard`。

**验证**：APK 固件上装 PassWall → 装 iStore → `grep -c sing-box /etc/apk/world` 应为 1；`grep -c PO_CLEAN_APK_WORLD /bin/is-opkg` 应为 0。

### P0-5 供应链校验缺失族

**证据（已复核）**：

```text
# ① apk 完整性重试实际绕过 packages.adb
install-passwall.sh:2658-2660  apk cache clean / rm -f /var/cache/apk/* / apk update
install-passwall.sh:2661-2663  # 同一 SourceForge 重定向可能反复返回与 packages.adb 摘要不一致的文件。
install-passwall.sh:2682       curl -fsSL --max-time 60 -o "$retry_path" "$retry_url" && apk_file_valid "$retry_path"
install-passwall.sh:2691-2694  if [ -n "$retry_files" ]; then set -- "$@" $retry_files; fi
install-passwall.sh:2695       "$@" > "$log" 2>&1
install-passwall.sh:2614       [ "$magic" = "ADBd" ]      # apk_file_valid 只比 4 字节魔数

# ② ipk.pub 无指纹固定
install-passwall.sh:1810  wget -q --no-check-certificate -O /tmp/ipk.pub "$SF_PREFIX/ipk.pub$SF_MIRROR_QUERY" 2>/dev/null || \
install-passwall.sh:1812  [ -s /tmp/ipk.pub ] && opkg-key add /tmp/ipk.pub 2>/dev/null || true

# ③ root 直装零校验
install-passwall.sh:3981  tar -xzf "$work/data.tar.gz" -C / >> "$log" 2>&1
install-passwall.sh:4362  if ! tar -xzf "$tarball" -C "$work" >/tmp/agh_extract.log 2>&1; then
install-passwall.sh:4775  cp -a "$work/$pkg/data"/. / >>/tmp/istore_extract.log 2>&1 || rc=1
```

`grep -c 'sha256sum\|sha512sum' install-passwall.sh` = **0**。

**触发条件 / 影响**：中国网络下 SourceForge/GitHub 镜像被劫持或返回错误页是常态而非理论；`2682` 的直取路径完全脱离 `packages.adb` 摘要体系，攻击者只需污染镜像即可让任意 `.apk` 通过（`ADBd` 魔数是公开常量，4 字节即可伪造）；`1812` 把下载来的公钥直接加为信任根，此后三个 passwall feed 的签名校验全部"通过"；`3981` 把未校验的 `data.tar.gz` 直接解到 `/`，可写入 `/etc/init.d/`、`/etc/uci-defaults/` 实现持久化。

**修复草案**：

① 删除镜像直取重试，改为"清缓存 + 走原事务一次"，净删约 45 行（`2648-2700` 整体替换）：

```sh
# OpenWrt APK 的包缓存可能保留下载不完整或与 packages.adb 摘要不一致的
# ADB 文件。仅在事务明确报告完整性错误时清理缓存并重试一次；
# 重试仍然走 apk 自身的 packages.adb 校验，绝不从镜像直取文件绕过摘要。
apk_retry_integrity_transaction() {
  local log="$1"; shift
  "$@" > "$log" 2>&1
  local rc=$?
  if [ "$rc" != "0" ] && grep -qiE 'ADB integrity error|integrity error|bad checksum|checksum mismatch' "$log" 2>/dev/null; then
    warn "APK 检测到包完整性错误，清理损坏缓存后重试一次（仍走 packages.adb 校验）"
    apk cache clean >/dev/null 2>&1 || true
    rm -f /var/cache/apk/* 2>/dev/null || true
    apk update >/tmp/po-apk-refresh.log 2>&1 || true
    "$@" > "$log" 2>&1
    rc=$?
    if [ "$rc" != "0" ]; then
      err "清理缓存后完整性错误仍存在，已停止（不绕过 packages.adb 摘要）"
      err "排查: /tmp/po-apk-refresh.log 与 $log"
    fi
  fi
  return "$rc"
}
```

② `ipk.pub` 固定指纹 + 去掉 `--no-check-certificate`（替换 `1807-1815`）：

```sh
    if [ "$SF_OK" = "1" ] && [ "$INSTALL_PW$INSTALL_PW2" != "00" ]; then
      local pub="/tmp/ipk.pub.$$" pub_sha="${PO_IPK_PUB_SHA256:-}" got_sha
      curl -fsL --max-time 20 -o "$pub" "$SF_PREFIX/ipk.pub$SF_MIRROR_QUERY" 2>/dev/null \
        || curl -fsL --max-time 20 -o "$pub" "https://master.dl.sourceforge.net/project/openwrt-passwall-build/ipk.pub" 2>/dev/null \
        || true
      if [ ! -s "$pub" ]; then
        err "无法下载 PassWall 签名公钥 ipk.pub，已跳过 PassWall 源（不接受无签名源）"
        SF_OK=0
      else
        got_sha=$(sha256sum "$pub" 2>/dev/null | awk '{print $1}')
        if [ -n "$pub_sha" ] && [ "$got_sha" != "$pub_sha" ]; then
          err "ipk.pub 指纹不匹配：期望 $pub_sha，实际 ${got_sha:-未知}；已放弃 PassWall 源"
          SF_OK=0
        else
          [ -z "$pub_sha" ] && warn "ipk.pub 未固定指纹（导出 PO_IPK_PUB_SHA256 可强制校验），本次 sha256=$got_sha"
          opkg-key add "$pub" 2>/dev/null || warn "opkg-key add 失败，PassWall 源可能因签名失败不可用"
        fi
      fi
      rm -f "$pub"
      [ "$SF_OK" = "1" ] || return 0
      for feed in passwall_luci passwall_packages passwall2; do
        echo "src/gz $feed $SF_BASE/$feed" >> /etc/opkg/customfeeds.conf 2>/dev/null \
          || warn "写入 $feed 源失败"
      done
    fi
```

③ 统一归档解包入口（在 P0-1 的 `po_restore_conf` 之后插入；同时用它替换 `3183` 与 `4721` 两版 `validate_tar_paths`，解决 R-P2-6 的"两版语义相反 + 不查类型"）：

```sh
# 安全解包：同时校验成员路径与成员类型，拒绝绝对路径、..、符号/硬链接、设备与管道。
po_safe_extract() {
  local archive="$1" dest="$2"
  [ -f "$archive" ] || { err "归档不存在: $archive"; return 1; }
  if ! tar -tzf "$archive" >/dev/null 2>&1; then
    err "归档不可读（下载被截断或不是 gzip）: $archive"; return 1
  fi
  if ! tar -tvzf "$archive" 2>/dev/null | awk '
      {
        type=substr($1,1,1); name=$NF
        if (type != "-" && type != "d") { printf "unsafe-type %s %s\n", type, name > "/dev/stderr"; bad=1 }
        if (name ~ /^\// || name ~ /(^|\/)\.\.($|\/)/) { printf "unsafe-path %s\n", name > "/dev/stderr"; bad=1 }
      }
      END { exit bad }'; then
    err "归档含不安全成员，已拒绝解包: $archive"; return 1
  fi
  mkdir -p "$dest" || return 1
  tar -xzf "$archive" -C "$dest" || { err "解包失败: $archive"; return 1; }
  return 0
}
```

替换点：`4362` → `po_safe_extract "$tarball" "$work"`；`4453` → `po_safe_extract "$tarball" "$work"`；`3970` → `po_safe_extract "$ipk" "$work"`；`3981` 改为先解到 `$work/root` 再 `cp -a "$work/root/." /`；`4761-4768` → `po_safe_extract "$work/$pkg/data.tar.gz" "$work/$pkg/data"`。

**验证**：构造含 `ln -s /etc/shadow x` 与 `../evil` 成员的 tar，确认 `po_safe_extract` 返回 1；人为把 `packages.adb` 与缓存包改成不一致，确认 `apk_retry_integrity_transaction` 报错停止且日志中不出现 `master.dl.sourceforge.net`。

---

## 三、P1 应修（兼容 / 健壮）

| 编号 | 标题 | 行号 | 原始编号 | 收益 | 成本 | ROI |
|---|---|---|---|---|---|---|
| P1-1 | 全脚本无全局 trap，/tmp 固定文件名在并发与中断下互相踩 | 1317 / 1331 / 4353-4354 / 3673 / 4003 / 4827 / 2705 / 298 | Q-P1-2 + Q-P2-8 + R-P2-10 + R-P3-19 | 高 | 40 行 + 9 处改名 | ★★★★☆ |
| P1-2 | 5 处 curl 无 `--max-time`，单条挂起连接可永久卡死；全脚本无重试退避 | 2475 / 2742 / 2879 / 2938 / 3290 / 803 | Q-P1-3 + Q-P2-9 | 高 | 12 行 | ★★★★★ |
| P1-3 | 非交互执行守卫失效：`sh x.sh </dev/null` 静默安装 PassWall | 130-142 / 959-965 / 1015-1082 | R-P2-7 | 高 | 20 行 | ★★★★☆ |
| P1-4 | 无 `set -e` 且关键步骤不检查返回码，产生"装好但不可用"的假成功 | 4191-4202 / 4394-4398 / 4843 / 3401-3426 | Q-P1-5 + R-P3-15 | 高 | 30 行 | ★★★★☆ |
| P1-5 | DAED 选项是空实现，置位后无任何动作仍返回成功 | 936 / 939 / 946 / 991 / 997 / 5283-5336 | Q-P1-1 + R-P2-14 | 中高 | 10 行 | ★★★★★ |
| P1-6 | `version_newer` 剥掉 `-rN` 再比较，revision 回退被误判为"可升级"；epoch 被丢弃 | 2362-2391 | R-P2-11 + R-P3-17 | 高 | 25 行替换 | ★★★★☆ |
| P1-7 | 架构注册无白名单：源里出现的任意架构都写进 `/etc/opkg.conf` | 1831-1846 / 4187-4203 | R-P2-9 + Q-P1-5 | 中高 | 15 行 | ★★★★☆ |
| P1-8 | 归档解包防护不一致：两版 `validate_tar_paths` 并存且不查 symlink | 3183-3190 / 4721-4736 / 4362 | R-P2-6 + R-P2-5 | 中高 | 并入 P0-5③ | ★★★★☆ |
| P1-9 | `repair_router_self_network` 覆盖 DHCP 下发 DNS，备份写入后从不恢复 | 99-113 / 573 / 1034 | R-P2-13 | 中（家庭网络 DNS 被改） | 20 行 | ★★★☆☆ |
| P1-10 | 源校验对用户自定义源同样生效，任一条不符即中止整次安装 | 1179-1207 / 1434-1481 / 1482-1529 | R-P2-12 | 中（兼容性） | 15 行 | ★★★☆☆ |

### P1-1 无全局 trap + /tmp 固定文件名

**证据（已复核）**：`trap` 全文仅 `install-passwall.sh:1317`、`1331` 两处，都在 `1307 opkg_update_isolated_named_feeds() (` 这个子 shell 内，退出即失效。`/tmp` 引用 212 处，`mktemp` 仅 `1320`、`1323` 两处。固定名清单：`2705 /tmp/opkg_install.log`、`2870 /tmp/apk_add.log`、`2930 /tmp/apk_upgrade.log`、`298 /tmp/opkg-fixed-feed-names`、`309 /tmp/opkg-feeds.po-clean`、`3673 /tmp/ssrplus-ipk`、`4003 /tmp/luci-app-ssr-plus.$ext`、`4353 /tmp/AdGuardHome-install`、`4354 /tmp/AdGuardHome_linux_${arch}.tar.gz`、`4445 /tmp/openclash-core.tar.gz`、`4827 /tmp/istore-reinstall.run`。

**触发条件 / 影响**：两个 SSH 会话同时跑脚本 → 后启动者 `rm -rf /tmp/AdGuardHome-install` 把前者的解包目录删掉，安装以 `AdGuardHome 安装包缺少可执行文件` 失败且看不出真实原因；`Ctrl-C` 后 `/tmp` 残留 `.ipk/.apk/解包目录` 占内存盘，下一次 `2828 ls -t /tmp/*.ipk | head -1` 可能选中上一次的残留包（见 P2-5）。

**修复草案**——在 `install-passwall.sh:22`（颜色定义之后）插入：

```sh
# --- 全局临时资源与退出清理 ----------------------------------------------
PO_TMP_LIST=""
PO_DNS_PATCHED=0
po_tmp() {
  local p
  p=$(mktemp "${TMPDIR:-/tmp}/po.XXXXXX" 2>/dev/null) || return 1
  PO_TMP_LIST="$PO_TMP_LIST $p"
  printf '%s' "$p"
}
po_cleanup() {
  local rc=$? p f
  trap - EXIT INT TERM HUP
  for p in $PO_TMP_LIST; do [ -e "$p" ] && rm -rf "$p" 2>/dev/null; done
  # 中断可能留下被截断的系统配置：空文件视为损坏，用备份救回
  for f in /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf /etc/opkg/compatfeeds.conf; do
    [ -s "$f.po-bak" ] && [ ! -s "$f" ] && cp -p "$f.po-bak" "$f" 2>/dev/null \
      && err "检测到 $f 为空（中断导致），已从 $f.po-bak 恢复"
  done
  [ "$PO_DNS_PATCHED" = "1" ] && po_restore_dns
  exit "$rc"
}
trap po_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
```

配套把上述固定名改为 `po_tmp`，例：`4353-4354` → `work=$(mktemp -d /tmp/AdGuardHome-install.XXXXXX) || return 1`、`tarball=$(po_tmp) || return 1`；`4445` → `tarball=$(po_tmp)`；`4827` → `run=$(po_tmp)`；`2705/2870/2930` → `log=$(po_tmp)`。

### P1-2 curl 无超时 + 无重试退避

**证据（已复核，精确 5 处）**：

```
install-passwall.sh:2475  curl -fL --progress-bar -o "$out" "$final"
install-passwall.sh:2742  if curl -fL -sS -o "/tmp/pkg_$dep.ipk" "$dep_url"; then
install-passwall.sh:2879  if curl -fL $prog -o "/tmp/pkg_$pkg.apk" "$url" && apk_file_valid "/tmp/pkg_$pkg.apk"; then
install-passwall.sh:2938  （同 2879 的升级分支）
install-passwall.sh:3290  if ! command -v tar >/dev/null 2>&1 || ! curl -fL -sS -o "$work/$archive" "$url"; then
```

唯一带完整超时的是 `install-passwall.sh:803`：`curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 15 --max-time 90`。

**修复草案**：

```diff
-install-passwall.sh:2475   curl -fL --progress-bar -o "$out" "$final"
+install-passwall.sh:2475   curl -fL --connect-timeout 15 --max-time 300 --progress-bar -o "$out" "$final"
-install-passwall.sh:2742   if curl -fL -sS -o "/tmp/pkg_$dep.ipk" "$dep_url"; then
+install-passwall.sh:2742   if curl -fL -sS --connect-timeout 15 --max-time 120 --retry 2 --retry-delay 2 -o "$dep_file" "$dep_url"; then
-install-passwall.sh:2879   if curl -fL $prog -o "/tmp/pkg_$pkg.apk" "$url" && apk_file_valid "/tmp/pkg_$pkg.apk"; then
+install-passwall.sh:2879   if curl -fL $prog --connect-timeout 15 --max-time 180 --retry 2 --retry-delay 2 -o "$apk_file" "$url" && apk_file_valid "$apk_file"; then
-install-passwall.sh:2938   （同上）
-install-passwall.sh:3290   if ! command -v tar >/dev/null 2>&1 || ! curl -fL -sS -o "$work/$archive" "$url"; then
+install-passwall.sh:3290   if ! command -v tar >/dev/null 2>&1 || ! curl -fL -sS --connect-timeout 15 --max-time 180 --retry 2 --retry-delay 2 -o "$work/$archive" "$url"; then
```

同时把散落的超时数值集中（解决 Q-P3-6）：在 `install-passwall.sh:29` 附近加

```sh
PO_CURL_CONNECT_TIMEOUT=15
PO_CURL_MAX_TIME_SMALL=60
PO_CURL_MAX_TIME_MID=120
PO_CURL_MAX_TIME_BIG=300
PO_CURL_RETRY=2
PO_OPKG_UPDATE_TIMEOUT=180
PO_APK_UPDATE_TIMEOUT=120
PO_GEO_MIN_FREE_KB=45000
```

### P1-3 非交互执行守卫失效

**证据（已复核，`130-142` + `959-965`）**：

```text
130  # 管道模式: stdin 不是 TTY, 且 $0 为 sh/ash/bash/dash/-sh/"" 时说明被管道/heredoc 传入，
131  if [ ! -t 0 ]; then
132    case "$0" in
133      sh|ash|bash|dash|-sh|"")
...
141        exit 0
959  while :; do
960    if ! read -r MAIN_CHOICE; then
961      echo ""
962      info "输入流已关闭，默认安装 PassWall"
963      MAIN_CHOICE="1"
964      break
965    fi
```

**触发条件 / 影响**：守卫用 `$0` 判断"是否管道"，但 `sh install-passwall.sh </dev/null`、`ssh root@router 'sh /tmp/install-passwall.sh'`、Ansible `script:` 模块、CI 容器里 `$0` 都是脚本路径而非 `sh`，守卫不触发；随后 `read` 遇 EOF 走 `960` 分支，**默认装 PassWall**。运维批量推脚本时会在一批路由器上无确认改源、装包、重启 dnsmasq。

**修复草案**——替换 `130-142`：

```sh
# 非交互执行：stdin 不是终端时，除显式 --yes 外一律拒绝继续。
# 注意不能用 $0 判断——`sh file.sh </dev/null` 与 `ssh host 'sh file.sh'` 的 $0 是脚本路径。
PO_ASSUME_YES=0
for _a in "$@"; do
  case "$_a" in --yes|-y) PO_ASSUME_YES=1 ;; esac
done
if [ ! -t 0 ] && [ "$PO_ASSUME_YES" != "1" ]; then
  echo "检测到非交互执行（stdin 不是终端）。"
  echo "如确认无人值守安装，请显式加参数重跑：sh $0 --yes"
  echo "如是想保存脚本再执行：cat install-passwall.sh > /tmp/install-passwall.sh"
  exit 2
fi
```

替换 `960-965`：

```sh
  if ! read -r MAIN_CHOICE; then
    if [ "$PO_ASSUME_YES" = "1" ]; then
      echo ""; info "--yes 模式：默认安装 PassWall"; MAIN_CHOICE="1"; break
    fi
    echo ""; err "输入流已关闭且未指定 --yes，已退出（未做任何修改）"; exit 2
  fi
```

`1015/1048/1066/1082` 的 `read` 加 `-t 120`（busybox ash 支持），超时按"取默认值 + warn"处理。

### P1-4 假成功面

**证据（已复核）**：

```text
4191  echo "arch all 1" >> /etc/opkg.conf          # 不查返回码
4195  echo "arch noarch 1" >> /etc/opkg.conf
4199  echo "arch $SYS_ARCH 1" >> /etc/opkg.conf
4202  [ "$changed" = "1" ] && info "已补齐本地 IPK 架构: all/noarch/$SYS_ARCH"
4394  "$bin" -s install >/tmp/agh_service.log 2>&1 || install_agh_service_fallback
4396  /etc/init.d/AdGuardHome start >/dev/null 2>&1 || "$bin" -s start >/dev/null 2>&1 || true
4397  if [ -x "$bin" ]; then ... ok "AdGuardHome ... ✓"
4843  [ "$rc" = "0" ] && { check_installed "luci-app-store" || istore_files_installed; }
```

**修复草案**（关键片段）：

```sh
# 4187-4203
opkg_prepare_local_package_arches() {
  [ "$PKG_MGR" = "opkg" ] || return 0
  local changed=0 arch rc=0
  for arch in all noarch "$SYS_ARCH"; do
    [ -n "$arch" ] || continue
    opkg print-architecture 2>/dev/null | awk '$1=="arch" {print $2}' | grep -qx "$arch" && continue
    if echo "arch $arch 1" >> /etc/opkg.conf 2>/dev/null; then
      changed=1
    else
      err "写入 /etc/opkg.conf 失败（arch $arch），本地 IPK 可能无法安装"; rc=1
    fi
  done
  [ "$changed" = "1" ] && [ "$rc" = "0" ] && info "已补齐本地 IPK 架构: all/noarch/$SYS_ARCH"
  return "$rc"
}
```

`4397` 见 P0-3（改为校验 `-s status`）。`4843` 补上"进程真的在跑"：

```sh
    if [ "$rc" = "0" ] && { check_installed "luci-app-store" || istore_files_installed; }; then
      if [ -x /etc/init.d/uhttpd ]; then /etc/init.d/uhttpd reload >/dev/null 2>&1 || true; fi
      ok "iStore 安装完成"
    else
      err "iStore 安装脚本返回 $rc，且未检测到 luci-app-store"; ISTORE_INSTALL_OK=0
    fi
```

`verify_package_installed`（`3401-3426`）只对两个中文语言包做落盘校验，其余包（含全部 apk 包）落到 `3425 return 0`，等价于只看包管理器状态库。改为实际读回：

```sh
verify_package_installed() {
  local pkg="$1" files
  check_installed "$pkg" || return 1
  case "$PKG_MGR" in
    apk)
      # apk 没有 status 子命令；用 apk info -L 确认至少有一个真实文件落盘
      files=$(apk info -L "$pkg" 2>/dev/null) || return 1
      printf '%s\n' "$files" | grep -qE '^/(usr|etc|www|opt)/' && return 0
      return 1
      ;;
    opkg)
      case "$pkg" in
        luci-i18n-passwall-zh-cn|luci-i18n-passwall2-zh-cn)
          if opkg status "$pkg" 2>/dev/null | grep -qiE 'Status:[[:space:]].*installed|install[[:space:]]+ok[[:space:]]+installed'; then
            return 0
          fi
          files=$(opkg files "$pkg" 2>/dev/null)
          printf '%s\n' "$files" | grep -qE '(^|[[:space:]])/(usr|www|etc)/' && return 0
          return 1
          ;;
        *)
          files=$(opkg files "$pkg" 2>/dev/null) || return 1
          printf '%s\n' "$files" | grep -qE '(^|[[:space:]])/(usr|www|etc|opt)/' && return 0
          return 1
          ;;
      esac
      ;;
  esac
  return 0
}
```

### P1-5 DAED 空实现

**证据（已复核）**：`grep -c 'INSTALL_DAED'` = 3 处赋值（`936` 初始化、`991` 菜单项 5、`997` 菜单项 11）；`DAED_INSTALL_OK` 仅在 `939` 置 0，全文无读取点；汇总段 `5283-5336` 依次只判 `PW/OC/SSR/AGH/ISTORE/PARTEXP/PW2`，**无 DAED 分支**。

**修复草案**——两选一，推荐"显式失败"（成本最低且不误导）：

```sh
# 在 5283 之前插入
if [ "$INSTALL_DAED" = "1" ]; then
  warn "DAED 安装尚未实现（当前版本不支持），本次未安装 DAED"
  RESULT_RC=1
fi
```

并在 `946` 的菜单项后加 `（当前版本未实现）`，`991` 的 `ok "选择: DAED"` 改为 `warn "DAED 尚未实现，选择将被忽略"`。若要真正实现，需新增 `install_daed()` 并接入 `5283-5336` 汇总段。

### P1-6 `version_newer` 语义错误

**证据（已复核，`2362-2391`）**：

```sh
2366  an=$(echo "$a" | sed 's/^v//; s/-r[0-9][0-9]*$//')
2367  bn=$(echo "$b" | sed 's/^v//; s/-r[0-9][0-9]*$//')
2383  top=$(printf '%s\n%s\n' "$an" "$bn" | sort -V | tail -1)
2384  [ "$top" = "$an" ] && return 0 || return 1
```

`26.9.9-r3` 与 `26.9.9-r1` 都剥成 `26.9.9`，`top == an` 恒成立 → **两个方向都返回"可升级"**。配合 `2729/2743/2831` 的 `--force-downgrade --force-overwrite`，会真的把 r3 降级成 r1。`1:2.3.4` vs `2.3.4` 的 epoch 也被 `sed` 后的 `sort -V` 丢弃。

**修复草案**——整体替换 `2360-2391`：

```sh
# a 比 b 新则返回 0（"可升级"），否则返回 1。保留 -rN 修订号与 epoch。
version_newer() {
  local a="$1" b="$2" ae be an bn top
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 1
  # epoch: "1:2.3.4" → ae=1 an=2.3.4
  case "$a" in *:*) ae=${a%%:*}; an=${a#*:} ;; *) ae=0; an="$a" ;; esac
  case "$b" in *:*) be=${b%%:*}; bn=${b#*:} ;; *) be=0; bn="$b" ;; esac
  if [ "$ae" != "$be" ]; then
    [ "$ae" -gt "$be" ] 2>/dev/null && return 0
    return 1
  fi
  an=$(printf '%s\n' "$an" | sed 's/^v//')
  bn=$(printf '%s\n' "$bn" | sed 's/^v//')
  # 剥离 v 前缀后可能相等（v1.2.3 vs 1.2.3），必须再判一次，否则误判为可升级
  [ "$an" = "$bn" ] && return 1
  # git-YY.MMDD 与 beta/日期版：本地构建总是视为可升级
  case "$an" in git-*|*beta*|20[0-9][0-9].[0-9]*) return 0 ;; esac
  if printf '%s\n%s\n' "$an" "$bn" | sort -V >/dev/null 2>&1; then
    top=$(printf '%s\n%s\n' "$an" "$bn" | sort -V | tail -1)
    [ "$top" = "$an" ] && return 0
    return 1
  fi
  return 1
}
```

**验证**（必须跑这 6 组）：`26.9.9-r3` vs `26.9.9-r1` → 0；`26.9.9-r1` vs `26.9.9-r3` → 1；`26.9.10-r1` vs `26.9.9-r3` → 0；`1:2.3.4` vs `2.3.4` → 0；`2.3.4` vs `1:2.3.4` → 1；`v1.2.3` vs `1.2.3` → 1。

### P1-7 架构注册无白名单

**证据（已复核，`1831-1846`）**：

```text
1834  for arch in $(grep -hoE 'packages/[A-Za-z0-9_.-]+/(base|luci|packages|routing|telephony)' ... | sed -n 's#packages/\([^/]*\)/.*#\1#p' | sort -u); do
1836    if ! opkg print-architecture 2>/dev/null | awk '$1=="arch" {print $2}' | grep -qx "$arch"; then
1837      echo "arch $arch 5" >> /etc/opkg.conf
```

与 `408-409` 注释"不擅自追加 aarch64_generic……跨 ABI 注册会导致 `no valid architecture` 或混源安装"直接矛盾。`4187-4203` 的 `opkg_prepare_local_package_arches` 同样不查返回码（并入 P1-4）。

**修复草案**——`1836` 前插入白名单判定：

```sh
        # 只注册与本机 ABI 一致的架构；跨 ABI 架构一律不注册（见 408-409 注释）
        [ "$arch" = "$SYS_ARCH" ] || { info "跳过非本机架构 $arch（避免跨 ABI 混源）"; continue; }
```

### P1-8 归档解包防护不一致

**证据（已复核）**：两版 `validate_tar_paths` 并存且语义相反——`3183-3190` 拒绝 `./` 前缀（会把合法 `tar -C dir .` 归档误杀），`4721-4736` 允许 `./`；两版都只 `tar -tzf` 比对成员名字符串，**都不查 `tar -tvzf` 的类型列**，因此 `ln -s /etc/shadow x` 这类 symlink 成员、hardlink、fifo/设备文件全部放行。`4362`（AGH 解包）与 `4775`（iStore `cp -a ... /.`）在解包/铺开前完全无校验。

**修复草案**：见 P0-5③ 的 `po_safe_extract`——删除 `3183-3190` 第一版，保留并强化 `4721-4736`，最终统一为 `po_safe_extract`。调用点 `3304`（partexp，正例）改为 `po_safe_extract` 后仍保留 `3296-3301` 的内联 awk 作为双保险；`4362`（AGH）与 `4761-4768`（iStore）必须补上校验。

### P1-9 `repair_router_self_network` 覆盖 DNS 且不恢复

**证据（已复核，`99-113`）**：

```text
100-104  { echo "nameserver 223.5.5.5"; ... } > /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null || true
107-109  if [ -e /tmp/resolv.conf ] || [ -L /tmp/resolv.conf ]; then cp -a /tmp/resolv.conf /tmp/resolv.conf.po-bak 2>/dev/null || true; fi
110-111  rm -f /tmp/resolv.conf ; ln -s /tmp/resolv.conf.d/resolv.conf.auto /tmp/resolv.conf
112      /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
```

`grep -n 'resolv.conf.po-bak'` 只有 `108` 一处（写入），**无任何读取或恢复**。`573` 在每次启动探测前自动触发，`1034` 在安装流程中再触发一次。

**触发条件 / 影响**：路由器上跑着 AdGuardHome 或自定义 dnsmasq 上游时，脚本会把 `/tmp/resolv.conf` 指向硬编码的 `223.5.5.5/119.29.29.29/1.1.1.1` 并重启 dnsmasq，用户的 DNS 分流/去广告立刻失效，且脚本退出后不恢复。

**修复草案**——`113` 后加 `PO_DNS_PATCHED=1`，并新增恢复函数（由 P1-1 的 `po_cleanup` 调用）：

```sh
po_restore_dns() {
  [ "${PO_DNS_PATCHED:-0}" = "1" ] || return 0
  if [ -f /tmp/resolv.conf.po-bak ]; then
    rm -f /tmp/resolv.conf 2>/dev/null
    cp -a /tmp/resolv.conf.po-bak /tmp/resolv.conf 2>/dev/null && info "已恢复原 /tmp/resolv.conf"
  else
    # 原本没有 resolv.conf：恢复为指向 dnsmasq 生成的文件
    rm -f /tmp/resolv.conf 2>/dev/null
    ln -s /tmp/resolv.conf.d/resolv.conf.auto /tmp/resolv.conf 2>/dev/null || true
  fi
  /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
  PO_DNS_PATCHED=0
}
```

### P1-10 源校验对自定义源过严

**证据（已复核，`1179-1207` / `1434-1529`）**：`1179-1207` 遍历 `distfeeds.conf` + `customfeeds.conf` 全部 URL 做连通性判定，`1208` / `1434-1481` / `1482-1529` 任一不符即把 `SYS_SOURCE_OK=0`，进而触发"停用原系统源 + 追加阿里云兜底"（`1554-1600`）。用户自己加的 `src/gz myssr_mirror ...` 不通时，整个安装被中止并改写系统源。

**修复草案**——只对脚本管理的源做硬校验，用户源降级为警告；并给逃生阀：

```sh
# 在源校验循环里区分来源
case "$url" in
  *openwrt.org*|*mirrors.aliyun.com*|*sourceforge.net*|*githubusercontent.com*|*istoreos.com*)
    : ;;   # 脚本管理的源：不通过则硬失败
  *)
    [ "$PO_STRICT_SOURCES" = "1" ] || { warn "用户自定义源不可达，已跳过: $url"; continue; } ;;
esac
```

---

## 四、P2 可优化（结构）与 P3 观察项

### P2（11 条，纯结构/可维护性，不改行为）

| 编号 | 标题 | 行号 | 原始编号 |
|---|---|---|---|
| P2-1 | `apk_install` 222 行单函数，opkg 与 apk 两条完整流程揉在一起 | 2702-2923 | Q-P2-1 |
| P2-2 | `probe_system_source_candidates` 335 行，且 5 个函数物理嵌套其内 | 579-913（586/595/715/758/788） | Q-P2-2 |
| P2-3 | `pkginstall` 与 `pkgupgrade` 约 95% 重复，唯一实质差异是 geo 守卫 | 3428-3480 / 3484-3539 | Q-P2-3 |
| P2-4 | `force_reinstall_selected` 与 `uninstall_selected_only` 有 41 行逐字节相同 | 3117-3161 / 3348-3392 | Q-P2-4 |
| P2-5 | `ls -t /tmp/*.ipk \| head -1` 取"最新 ipk"当本次下载结果 | 2825-2836 | Q-P2-7 |
| P2-6 | "下载 + magic 校验 + 候选重试"被复制 5 份，`dl_with_mirror` 未被复用 | 4240-4262 / 3599-3605 / 3678-3688 / 4831-4837 | Q-P2-5 |
| P2-7 | 4 个函数定义后从未调用（死代码） | 468 / 1249 / 4518 / 4532 | Q-P2-6 + R-P3-21 |
| P2-8 | 同名函数重复定义，后者静默覆盖前者，其中一对语义不同 | 3183/4721、4475/4505 | Q-P2-7 + R-P3-21 |
| P2-9 | 远程脚本下载后只做 3 处字符串匹配即以 root 执行 | 4828-4841 | Q-P2-10 |
| P2-10 | `opkg_update_with_timeout` 超时 `kill -9` 只杀父进程，`wait` 返回码不可靠 | 1281-1304 | Q-P2-11 |
| P2-11 | 空间检测空值不设防且明确不拦截，与实际写入存在竞态 | 1130-1135 / 921-929 | Q-P2-12 |

关键修复要点：

- **P2-1 拆分**：`_apk_install_opkg "$pkg"`（2705-2866）+ `_apk_install_apk "$pkg"`（2867-2923），公共前置（版本解析、`want_ver`、`repo_ver`）留在 `apk_install`，用 `case "$PKG_MGR" in opkg) _apk_install_opkg "$@";; apk) _apk_install_apk "$@";; esac` 分派。
- **P2-2 拆分**：把 `586 list_series_vers`、`595 probe_ow_ver`、`715 probe_proxy_sources`、`758 sf_pick_node`、`788 sf_probe_index` 提到 `579` 之前成平级函数；`probe_system_source_candidates` 只保留 `probe_openwrt_series / probe_mirror_sources / probe_sf_sources` 三次调用。
- **P2-3 合并**：`pkg_install_or_upgrade "$pkg" "$desc" "$mode"`，`mode=install|upgrade`，`3488-3497` 的 geo 守卫只在 `mode=upgrade` 生效。
- **P2-5**：`2825-2836` 改为 `opkg download "$pkg" -o "$work"` 到独立目录，再 `find "$work" -name '*.ipk'`，并核对 `$repo_ver`；禁止读 `/tmp` 全局。
- **P2-6**：统一到 `dl_verified "$url" "$out" "$type"`（`dl_with_mirror` 加 `type` 参数即可），删掉 4 份手写循环。
- **P2-7**：删除 `468 arch_to_targets`、`1249 disable_failed_opkg_feeds`、`4518 get_mihomo_latest_ver`、`4532 install_mihomo_core`（各 grep 命中数均为 1）；`352 restore_apk_passwall_feeds` 命中 2（`339` 注释 + `352` 定义），**不删**——它正是 P0-1/P0-4 回滚所需的函数，应接入 `po_cleanup`。
- **P2-8**：删 `4475` 第一版 `mihomo_version_matches`（保留 `4505` 归一化版）；`3183` 第一版并入 P1-8 的 `po_safe_extract`。
- **P2-10**：超时分支改为杀进程组：`kill -TERM -"$pid"` 前先 `set -m`（ash 支持）或用 `pkill -P "$pid"` 递归清理，`wait` 后显式 `rc=124` 而不是依赖 `wait` 的返回值。

### P3（8 条，观察项，可延后）

| 编号 | 标题 | 行号 | 原始编号 |
|---|---|---|---|
| P3-1 | `echo -e` + `\e` 颜色在 busybox ash 下不生效 | 16-21 | Q-P3-1 |
| P3-2 | `VERSION` 注释写死 20261029.6，运行时算"今天日期.1" | 5 / 9-15 / 151 | Q-P1-4 |
| P3-3 | 章节编号重复（两个 `# 9.`）；`prog` 声明后未用；`2543-2544` 两行完全相同；`2803` 引用未赋值的 `$local_force_depends` | 5263/5273、2705/2783/2870、2543-2544、2803 | Q-P3-2/3/4/5 |
| P3-4 | 魔法数字散落 20+ 处，未集中为常量 | 29/232/803/1103/1118-1129/3492/3600/3679/4246 | Q-P3-6（并入 P1-2 一并处理） |
| P3-5 | 收尾阶段失败全部静默，LuCI 未刷新时用户看到"装好但没入口" | 5266-5270 / 5340-5344 | Q-P3-8 |
| P3-6 | `apk_pkg_arch_from_target` 缺 ipq807x/ipq60xx/x86_64；`arch_to_targets` 缺 riscv64 | 468-500 / 508-516 | R-P3-16 |
| P3-7 | GitHub/HTML 解析脆弱：JSON 靠 `grep -oE` 顺序假设，未加引号的命令替换 | 3162 / 3660 / 4283 / 2333 / 4244 | R-P3-18 |
| P3-8 | `/tmp` 下载物默认 644，全文无 `umask`；凭据经 envp 不进 `ps`（已做对，仅记录） | 全文件 / 145-147 / 1943-1944 | R-P3-19 / R-P3-20 |

P3-2 具体修法：`5` 行注释改为 `# VERSION: 运行时生成（见 9-15 行），不要手工维护`，`13` 行删掉过期兜底 `20260913` 改为 `err "无法获取日期，请检查 date 命令" && exit 1`，`151` 横幅打印 `$VERSION` 前先 `info "构建: $VERSION_DATE.$VERSION_SEQ"`。

P3-1 具体修法：`16-21` 改为 `printf '%s[%s]%s %s\n' "$GREEN" "✓" "$NC" "$1"`，颜色常量改 `GREEN=$(printf '\033[32m')` 形式，避开 `echo -e` 与 `\e` 双重不兼容。

P3-6 具体修法：`apk_pkg_arch_from_target` 的 `case` 补 `ipq807x) echo "aarch64_cortex-a53"`、`ipq60xx) echo "aarch64_cortex-a53"`、`x86_64) echo "x86_64"`、`riscv64) echo "riscv64_riscv64"`。

---

## 五、分批实施计划

原则：每批改动独立可验证、可单独回滚；P0 优先；结构重构（P2）单独分支、最后做，避免与行为修复混在一个 diff 里。

| 批次 | 内容 | 条目 | 改动量 | 验证耗时 | 依赖 |
|---|---|---|---|---|---|
| **B0** | 文档与零风险清理：VERSION 注释、`echo -e` 改 `printf`、章节编号、`prog` 死变量、`2543-2544` 重复行、`2803` 未赋值变量、删除 4 个死函数 | P3-1/2/3、P2-7 | ~60 行（多为删除） | 20 min | 无 |
| **B1** | 系统源安全写入：新增 `po_write_conf`/`po_restore_conf`，替换 9 处写源 | **P0-1** | ~120 行 | 2 h | B0 |
| **B2** | AdGuardHome 两条：卸载保留配置、安装回滚、内核回滚 | **P0-2/3** | ~110 行 | 1.5 h | B1 |
| **B3** | 供应链：删 apk 镜像直取重试、ipk.pub 指纹、`po_safe_extract` 全量替换 | **P0-5**、P1-8 | 净 -45 / +120 行 | 3 h | B1 |
| **B4** | iStore：撤销 `/bin/is-opkg` 注入、`with_apk_world_relaxed`、world 守卫 | **P0-4** | ~90 行 | 1.5 h | B1 |
| **B5** | 健壮性：全局 trap + `po_tmp`、5 处 curl 超时 + 常量表、非交互守卫、假成功面 | P1-1/2/3/4 | ~160 行 | 2.5 h | B1 |
| **B6** | 兼容性：`version_newer` 重写、架构白名单、DNS 恢复、源校验逃生阀、DAED 显式失败 | P1-5/6/7/9/10 | ~130 行 | 2 h | B5（复用 `po_cleanup`） |
| **B7** | 结构重构（独立分支，仅移动/合并，不改行为）：拆 `apk_install`、拆 `probe_system_source_candidates`、合并 `pkginstall/pkgupgrade`、合并 5 处下载循环、修 `/tmp` 取包 | P2-1~6、P2-8~11 | ~400 行（大范围移动） | 3 h | B1–B6 全部合入 |

**关键路径**：B1 是所有后续批次的地基（`po_write_conf` 与 `.po-bak` 被 B2/B3/B4/B5 复用），必须单独提交、单独验证，不合入其他改动。

**每批提交要求**（沿用仓库既有约定）：`bump VERSION` → `bash -n` + `sh -n`（+ `busybox ash -n`）→ ad-hoc 真机验证 → 通过代理推送。每批一个 commit，commit message 标注条目编号（如 `fix(security): 原子写系统源并保留 .po-bak (P0-1)`）。

---

## 六、回归验证清单

### 6.1 静态门禁（每批必跑）

```sh
bash -n install-passwall.sh
sh -n install-passwall.sh
busybox ash -n install-passwall.sh          # 有 busybox 时
shellcheck -s sh -S error install-passwall.sh   # 可选，仅看 error 级
grep -c 'sha256sum\|sha512sum' install-passwall.sh   # B3 后应 > 0
grep -n 'cat /tmp/.* > /etc/' install-passwall.sh     # B1 后应为空
grep -n 'curl .*\(--max-time\)\?' install-passwall.sh # B5 后每处都应有 --max-time
```

### 6.2 机型矩阵（每批至少覆盖 1 个 opkg + 1 个 apk）

| 机型/架构 | 包管理器 | 固件基线 | 必测批次 |
|---|---|---|---|
| x86_64（软路由/VM） | opkg | OpenWrt 23.05 | B0–B7 |
| x86_64（VM） | apk | OpenWrt 24.10 | B3/B4/B5/B6 |
| aarch64_cortex-a53（R3S/R4S） | opkg | iStoreOS 22.03 | B1/B2/B6 |
| aarch64_cortex-a53（ipq807x） | apk | OpenWrt 24.10 | B3/B4/B6 |
| mipsel_24kc（老路由 16MB flash） | opkg | OpenWrt 21.02 | B1/B2（空间紧张场景） |
| ramips_mt7621 | opkg | OpenWrt 23.05 | B1/B7 |

### 6.3 场景用例（按批次归属）

| # | 场景 | 操作 | 期望 | 覆盖 |
|---|---|---|---|---|
| 1 | 原子写验证 | `strace -f -e trace=rename,renameat,openat -o /tmp/st.log sh install-passwall.sh` | `/etc/opkg/*.conf` 只经 `rename` 变更，无 `O_TRUNC` 直写 | B1 |
| 2 | 中断恢复 | 跑到写源阶段 `kill -9`，再 `sh install-passwall.sh` | 上次残留被 `po_cleanup`/启动自检修复，`opkg update` 正常 | B1 |
| 3 | overlay 写满 | `dd if=/dev/zero of=/overlay/fill bs=1M count=200` 后跑安装 | 明确报"空间不足/写入失败"，原配置完好 | B1/B2 |
| 4 | AGH 卸载保留 | 装 AGH → 写 `data/stats.db` → 选卸载保留 | `stats.db` 仍在，无 tmpfs 中转 | B2 |
| 5 | AGH 升级回滚 | 把 tarball 换成截断坏包 | 旧版仍在、服务可启动、返回 1 | B2 |
| 6 | 内核回滚 | 把 `clash` tar 换成坏包 | `dest` 未变、`.po-bak` 存在 | B2 |
| 7 | apk 完整性 | 篡改 `/var/cache/apk` 内某包 | 报错停止，日志无 `master.dl.sourceforge.net` | B3 |
| 8 | 恶意归档 | 构造含 `../evil`、`ln -s /etc/shadow` 的 tar | `po_safe_extract` 返回 1，目标目录未写入 | B3 |
| 9 | ipk.pub 指纹 | 设 `PO_IPK_PUB_SHA256=deadbeef` 跑安装 | 报指纹不匹配并放弃 PassWall 源 | B3 |
| 10 | iStore 不伤内核 | 装 PassWall → 装 iStore 插件 | `grep -c sing-box /etc/apk/world` = 1；`grep -c PO_CLEAN_APK_WORLD /bin/is-opkg` = 0 | B4 |
| 11 | 非交互拒绝 | `sh install-passwall.sh </dev/null` | exit 2，未改任何配置 | B5 |
| 12 | `--yes` 放行 | `sh install-passwall.sh --yes </dev/null` | 正常安装，日志标注 `--yes` | B5 |
| 13 | curl 挂起 | 用 `iptables -j DROP` 打到下载域名后跑安装 | 120/180s 内超时返回，不永久卡死 | B5 |
| 14 | 假成功面 | 把 `/etc/opkg.conf` 设只读后跑 `opkg_prepare_local_package_arches` | 返回 1 并报错，不再打印"已补齐" | B5 |
| 15 | version_newer 单测 | 跑 P1-6 的 6 组用例 | 6 组全部符合预期 | B6 |
| 16 | 架构白名单 | 在源里手工加一条异架构 URL | 日志"跳过非本机架构"，`/etc/opkg.conf` 不变 | B6 |
| 17 | DNS 恢复 | 设自定义 dnsmasq 上游 → 触发 `repair_router_self_network` → 脚本退出 | `/tmp/resolv.conf` 恢复原指向，上游未变 | B6 |
| 18 | DAED 显式失败 | 选菜单 5 | 打印"未实现"，`exit` 非 0，汇总段有提示 | B6 |
| 19 | 用户源不可达 | 在 `customfeeds.conf` 加一条死链 | 仅 warn 跳过，安装继续 | B6 |
| 20 | 全量冒烟 | 菜单 11（全装）在 x86_64 opkg + apk 各跑一次 | 所有组件可访问，`RESULT_RC=0` | 全批次 |

### 6.4 失败回滚点（必须能手工复原）

| 改动 | 回滚方式 |
|---|---|
| B1 系统源 | `/etc/opkg/*.conf.po-bak` 覆盖回原文件；`po_restore_conf <file>` |
| B2 AGH | `/opt/AdGuardHome.old`（成功后才删）；`/overlay/AdGuardHome.keep.*` |
| B2 内核 | `$dest.po-bak`（`install_mihomo_core` 新增） |
| B3 解包 | 全部先解到 `$work`，失败即 `rm -rf "$work"`，不触碰系统目录 |
| B4 iStore | `/bin/is-opkg` 由 `/tmp/is-opkg.po-bak` 或重装 iStore 恢复；`/etc/apk/world.po-guard`、`/etc/apk/world.po-lost` |
| B5 trap | 单批可整体 revert；`po_cleanup` 内所有动作都是幂等的 |
| B6 version_newer | 保留旧函数为 `version_newer_legacy`，用 `PO_LEGACY_VERCMP=1` 切换 |

**最终验收标准**：20 条场景用例在 6.2 矩阵的对应机型上全部通过；`bash -n`/`sh -n`/`busybox ash -n` 零错误；`grep -c 'sha256sum'` > 0；`grep -n 'cat /tmp/.* > /etc/'` 为空；`strace` 确认系统配置文件只经 `rename` 变更。

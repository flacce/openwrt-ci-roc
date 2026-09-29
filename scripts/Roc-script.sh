#!/usr/bin/env bash
set -euo pipefail

retry() {
  local attempt=1
  local max_attempts="${RETRY_MAX_ATTEMPTS:-3}"
  local delay_seconds="${RETRY_DELAY_SECONDS:-20}"

  while true; do
    "$@" && return 0
    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "Command failed after ${max_attempts} attempts: $*" >&2
      return 1
    fi
    attempt=$((attempt + 1))
    echo "Command failed. Retry ${attempt}/${max_attempts} in ${delay_seconds}s: $*" >&2
    sleep "$delay_seconds"
  done
}

clone_into() {
  local repo_url="$1"
  local destination="$2"
  local ref="${3:-}"
  rm -rf "$destination"
  if [ -n "$ref" ]; then
    retry git clone --depth=1 --single-branch --branch "$ref" "$repo_url" "$destination"
  else
    retry git clone --depth=1 "$repo_url" "$destination"
  fi
}

# 修改默认IP & 固件名称 & 编译署名和时间 & 默认主题
sed -i 's/192.168.1.1/10.0.0.1/g' package/base-files/files/bin/config_generate
sed -i "s/hostname='.*'/hostname='Roc'/g" package/base-files/files/bin/config_generate
sed -i 's/luci-theme-bootstrap/luci-theme-aurora/g' feeds/luci/modules/luci-base/root/etc/config/luci
sed -i "s#_('Firmware Version'), (L\.isObject(boardinfo\.release) ? boardinfo\.release\.description + ' / ' : '') + (luciversion || ''),# \
            _('Firmware Version'),\n \
            E('span', {}, [\n \
                (L.isObject(boardinfo.release)\n \
                ? boardinfo.release.description + ' / '\n \
                : '') + (luciversion || '') + ' / ',\n \
            E('a', {\n \
                href: 'https://github.com/flacce/openwrt-ci-roc/releases',\n \
                target: '_blank',\n \
                rel: 'noopener noreferrer'\n \
                }, [ 'Built by Roc $(date "+%Y-%m-%d %H:%M:%S")' ])\n \
            ]),#" feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js

# 移除过时或冲突的软件包
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "/attendedsysupgrade/d" {} + 2>/dev/null || true

# 调整NSS驱动q6_region内存区域预留大小（ipq6018.dtsi默认预留85MB，ipq6018-512m.dtsi默认预留55MB，带WiFi必须至少预留54MB，以下分别是改成预留16MB、32MB、64MB和96MB）
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x01000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x02000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x04000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x06000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi

# 调节IPQ60XX的1.5GHz频率电压(从0.9375V提高到0.95V，过低可能导致不稳定，过高可能增加功耗和发热，具体数值需要根据实际情况调整)
if [ -f "target/linux/qualcommax/patches-6.12/0038-v6.16-arm64-dts-qcom-ipq6018-add-1.5GHz-CPU-Frequency.patch" ]; then
  sed -i 's/opp-microvolt = <937500>;/opp-microvolt = <950000>;/' target/linux/qualcommax/patches-6.12/0038-v6.16-arm64-dts-qcom-ipq6018-add-1.5GHz-CPU-Frequency.patch
fi

# 移除要替换的包
rm -rf \
  feeds/luci/themes/luci-theme-argon \
  feeds/luci/applications/luci-app-passwall \
  feeds/luci/applications/luci-app-passwall2 \
  feeds/luci/applications/luci-app-homeproxy

# Git稀疏克隆，只克隆指定目录到本地
function git_sparse_clone() {
  local branch="$1"
  local repo_url="$2"
  shift 2
  local repo_dir
  repo_dir="$(basename "$repo_url" .git)"
  rm -rf "$repo_dir"
  retry git clone --depth=1 -b "$branch" --single-branch --filter=blob:none --sparse "$repo_url" "$repo_dir"
  pushd "$repo_dir" >/dev/null || return 1
  retry git sparse-checkout set "$@"
  mv -f "$@" ../package/
  popd >/dev/null || return 1
  rm -rf "$repo_dir"
}

# 下载 Sing-Box 官方预编译预览版（Pre-release）核心及规则库（纯 Sing-Box 方案，剔除 Xray）
function download_prebuilt_cores() {
  mkdir -p files/usr/bin files/usr/share/v2ray files/etc/uci-defaults

  # 优先获取官方最新预览版/发布版标签，API受限时保底使用最新 1.15.0-alpha.6
  local sb_ver="v1.15.0-alpha.6"
  local latest_release
  latest_release=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases 2>/dev/null | jq -r '.[0].tag_name' 2>/dev/null || true)
  if [[ "$latest_release" =~ ^v[0-9] ]]; then
    sb_ver="$latest_release"
  fi
  echo "==> Downloading prebuilt Sing-Box preview core (${sb_ver}) and geodata..."
  local sb_url="https://github.com/SagerNet/sing-box/releases/download/${sb_ver}/sing-box-${sb_ver#v}-linux-arm64-musl.tar.gz"

  local tmp_dir
  tmp_dir="$(mktemp -d /tmp/cores.XXXXXX)"

  if retry curl -fsSL -o "${tmp_dir}/sing-box.tar.gz" "${sb_url}"; then
    tar -xzf "${tmp_dir}/sing-box.tar.gz" -C files/usr/bin/ --wildcards '*/sing-box' --strip-components=1
    chmod 0755 files/usr/bin/sing-box
    echo "==> sing-box (${sb_ver}) deployed."
  fi

  # 确保目标系统存在 sing-box 运行账号与用户组（供 procd/ujail 权限沙箱）
  cat << 'EOF' > files/etc/uci-defaults/99-sing-box-user
grep -q '^sing-box:' /etc/passwd || echo 'sing-box:x:5566:5566:sing-box:/var/run/sing-box:/bin/false' >> /etc/passwd
grep -q '^sing-box:' /etc/group || echo 'sing-box:x:5566:' >> /etc/group
exit 0
EOF
  chmod +x files/etc/uci-defaults/99-sing-box-user

  # 下载最新 Loyalsoldier 规则库供转换或通用引用
  retry curl -fsSL -o files/usr/share/v2ray/geoip.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" || true
  retry curl -fsSL -o files/usr/share/v2ray/geosite.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" || true

  # 确保清理残留软链接
  rm -rf files/usr/share/xray

  rm -rf "${tmp_dir}"
}

# 并行拉取第三方软件包及核心组件以提升效率
( download_prebuilt_cores ) &
( clone_into https://github.com/EasyTier/luci-app-easytier package/luci-app-easytier ) &
( clone_into https://github.com/VIKINGYFY/packages package/viking-packages main && mv -f package/viking-packages/luci-app-homeproxy package/ && rm -rf package/viking-packages ) &
( clone_into https://github.com/eamonxg/luci-theme-aurora package/luci-theme-aurora ) &
( clone_into https://github.com/eamonxg/luci-app-aurora-config package/luci-app-aurora-config ) &
( clone_into https://github.com/gdy666/luci-app-lucky package/luci-app-lucky ) &
( clone_into https://github.com/laipeng668/luci-app-gecoosac package/luci-app-gecoosac ) &
( clone_into https://github.com/NONGFAH/luci-app-athena-led package/luci-app-athena-led ) &

wait

# HomeProxy 避免编译 sing-box（由 download_prebuilt_cores 注入预编译静态二进制）
if [ -f package/luci-app-homeproxy/Makefile ]; then
  sed -i '/+sing-box/d' package/luci-app-homeproxy/Makefile
  sed -i '/LUCI_EXTRA_DEPENDS/d' package/luci-app-homeproxy/Makefile
  sed -i '/PKG_NAME:=luci-app-homeproxy/a USERID:=sing-box=5566:sing-box=5566' package/luci-app-homeproxy/Makefile

  # 修复 Hysteria2 混淆类型为 none 导致 sing-box 校验失败
  python3 -c '
from pathlib import Path
hp = Path("package/luci-app-homeproxy")
for p in hp.rglob("*.uc"):
    s = p.read_text(encoding="utf-8")
    old_c = "outbound.obfs = (node.type === '\''hysteria2'\'' && node.hysteria_obfs_type) ? {\n\t\t\ttype: node.hysteria_obfs_type,\n\t\t\tpassword: node.hysteria_obfs_password\n\t\t} : node.hysteria_obfs_password;"
    new_c = "if (node.type === '\''hysteria2'\'') {\n\t\t\toutbound.obfs = (node.hysteria_obfs_type && node.hysteria_obfs_type !== '\''none'\'') ? {\n\t\t\t\ttype: node.hysteria_obfs_type,\n\t\t\t\tpassword: node.hysteria_obfs_password\n\t\t\t} : null;\n\t\t} else {\n\t\t\toutbound.obfs = node.hysteria_obfs_password;\n\t\t}"
    old_s = "inbound.obfs = (cfg.type === '\''hysteria2'\'' && cfg.hysteria_obfs_type) ? {\n\t\t\ttype: cfg.hysteria_obfs_type,\n\t\t\tpassword: cfg.hysteria_obfs_password\n\t\t} : cfg.hysteria_obfs_password;"
    new_s = "if (cfg.type === '\''hysteria2'\'') {\n\t\t\tinbound.obfs = (cfg.hysteria_obfs_type && cfg.hysteria_obfs_type !== '\''none'\'') ? {\n\t\t\t\ttype: cfg.hysteria_obfs_type,\n\t\t\t\tpassword: cfg.hysteria_obfs_password\n\t\t\t} : null;\n\t\t} else {\n\t\t\tinbound.obfs = cfg.hysteria_obfs_password;\n\t\t}"
    s = s.replace(old_c, new_c).replace(old_s, new_s)
    s = s.replace("hysteria_obfs_type: proxy.obfs,", "hysteria_obfs_type: (proxy.obfs && proxy.obfs !== '\''none'\'') ? proxy.obfs : null,")
    s = s.replace("hysteria_obfs_type: params.obfs,", "hysteria_obfs_type: (params.obfs && params.obfs !== '\''none'\'') ? params.obfs : null,")
    p.write_text(s, encoding="utf-8")
for p in hp.rglob("*.js"):
    s = p.read_text(encoding="utf-8")
    s = s.replace("hysteria_obfs_type:params.get('\''obfs'\''),", "hysteria_obfs_type:(params.get('\''obfs'\'')&&params.get('\''obfs'\'')!=='\''none'\'')?params.get('\''obfs'\''):null,")
    p.write_text(s, encoding="utf-8")
'

  # 为 HomeProxy 分流控制新增“DNS 代理列表”与“DNS 直连列表”支持
  python3 - << 'EOF'
import re
from pathlib import Path

# 1. Patch generate_client.uc
gc_file = Path("package/luci-app-homeproxy/root/etc/homeproxy/scripts/generate_client.uc")
if gc_file.is_file():
    gc = gc_file.read_text(encoding="utf-8")
    gc = gc.replace("let domain_groups = [];", """let domain_groups = [];

let dns_groups = [];

function add_dns_group(id, server_tag) {
\tconst domains = normalizeDomainList(readfile(domainListPath(id)));
\tif (!length(domains))
\t\treturn;

\tconst split_domains = splitDomainList(domains);
\tpush(dns_groups, { id, server: server_tag, ...split_domains });
}

add_dns_group('dns_proxy', 'main-dns');
add_dns_group('dns_direct', (routing_mode === 'bypass_mainland_china') ? 'china-dns' : 'default-dns');""", 1)

    dns_rules_inj = """\tfor (let group in dns_groups) {
\t\tif (length(group.suffixes))
\t\t\tpush(config.dns.rules, {
\t\t\t\trule_set: domain_rule_set_tag(group, 'suffix'),
\t\t\t\taction: 'route',
\t\t\t\tserver: group.server
\t\t\t});
\t\tif (length(group.keywords))
\t\t\tpush(config.dns.rules, {
\t\t\t\trule_set: domain_rule_set_tag(group, 'keyword'),
\t\t\t\taction: 'route',
\t\t\t\tserver: group.server
\t\t\t});
\t}

"""
    gc = re.sub(r"(\tfor\s*\(\s*let\s+group\s+in\s+domain_groups\s*\)\s*\n\s*add_domain_dns_rules\(group\);)", dns_rules_inj + r"\1", gc)

    inline_inj = """\n\n\tfor (let group in dns_groups) {
\t\tadd_inline_domain_rule_set(config.route.rule_set, group, 'suffix');
\t\tadd_inline_domain_rule_set(config.route.rule_set, group, 'keyword');
\t}"""
    gc = re.sub(r"(\tfor\s*\(\s*let\s+group\s+in\s+domain_groups\s*\)\s*\{[\s\S]*?add_inline_domain_rule_set\(config\.route\.rule_set,\s*group,\s*'keyword'\);\s*\})", r"\1" + inline_inj, gc)
    gc_file.write_text(gc, encoding="utf-8")
    print("==> Patched generate_client.uc for DNS direct/proxy lists")

# 2. Patch luci.homeproxy
rpcd_file = Path("package/luci-app-homeproxy/root/usr/share/rpcd/ucode/luci.homeproxy")
if rpcd_file.is_file():
    rpcd = rpcd_file.read_text(encoding="utf-8")
    rpcd = re.sub(r"(function\s+appendGroup\(id\)\s*\{)", r"\1\n\t\tif (id in ['dns_proxy', 'dns_direct'])\n\t\t\treturn;", rpcd)
    rpcd = re.sub(r"(id\s+in\s+\[\s*'direct'\s*,\s*'proxy'\s*\])", r"id in ['direct', 'proxy', 'dns_proxy', 'dns_direct']", rpcd)
    rpcd = re.sub(r"(if\s*\(domain\s*&&\s*!replace\(domain,\s*/\^\\\.+|\\\.\+\$/g,\s*''\)\))", r"domain = replace(domain, /^\*+\.?/, '');\n\t\t\1", rpcd)
    rpcd_file.write_text(rpcd, encoding="utf-8")
    print("==> Patched luci.homeproxy for DNS direct/proxy lists & wildcard support")

# 3. Patch client.js
cjs_file = Path("package/luci-app-homeproxy/htdocs/luci-static/resources/view/homeproxy/client.js")
if cjs_file.is_file():
    cjs = cjs_file.read_text(encoding="utf-8")
    cjs = re.sub(r"const\s+ids\s*=\s*\[\s*'direct'\s*,\s*'proxy'\s*\];", "const ids = ['direct', 'proxy', 'dns_proxy', 'dns_direct'];", cjs)
    cjs = re.sub(r"const\s+builtin\s*=\s*id\s*===\s*'direct'\s*\|\|\s*id\s*===\s*'proxy';", "const builtin = id === 'direct' || id === 'proxy' || id === 'dns_proxy' || id === 'dns_direct';", cjs)
    cjs = re.sub(r"(item\s*=\s*item\.replace\(/\^\\\.+|\\\.\+\$/g,\s*''\);)", r"item = item.replace(/^\\*+\\.?/, '');\n\t\t\t\1", cjs)
    match_proxy = re.search(r"(ss\.tab\('proxy_list'[\s\S]*?configureDomainList\(so,\s*'proxy'\);)", cjs)
    if match_proxy:
        proxy_block = match_proxy.group(1)
        extra_tabs = """

\t\tss.tab('dns_proxy_list', _('DNS 代理列表'));
\t\tso = ss.taboption('dns_proxy_list', form.TextValue, '_dns_proxy_list', null,
\t\t\t_('此列表中的域名强制使用海外主节点 DNS 解析（例如直连但国内 DNS 污染的域名，如 linux.do）。'));
\t\tconfigureDomainList(so, 'dns_proxy');

\t\tss.tab('dns_direct_list', _('DNS 直连列表'));
\t\tso = ss.taboption('dns_direct_list', form.TextValue, '_dns_direct_list', null,
\t\t\t_('此列表中的域名强制使用国内 DNS（China DNS）解析。'));
\t\tconfigureDomainList(so, 'dns_direct');"""
        cjs = cjs.replace(proxy_block, proxy_block + extra_tabs, 1)
    cjs_file.write_text(cjs, encoding="utf-8")
    print("==> Patched client.js for DNS direct/proxy lists & wildcard support")
# 4. Patch homeproxy.uc (Wildcard *. support)
hp_file = Path("package/luci-app-homeproxy/root/etc/homeproxy/scripts/homeproxy.uc")
if hp_file.is_file():
    hp = hp_file.read_text(encoding="utf-8")
    hp = hp.replace("domain = lc(replace(trim(domain), /^\\.+|\\.+$/g, ''));", "domain = lc(replace(replace(trim(domain), /^\\*+\\.?/, ''), /^\\.+|\\.+$/g, ''));")
    hp_file.write_text(hp, encoding="utf-8")
    print("==> Patched homeproxy.uc for wildcard domain support")
EOF

  # 预创建分流列表空文件
  mkdir -p files/etc/homeproxy/diversion
  touch files/etc/homeproxy/diversion/dns_proxy.txt files/etc/homeproxy/diversion/dns_direct.txt
fi

chmod +x package/luci-app-homeproxy/root/etc/init.d/homeproxy package/luci-app-homeproxy/root/etc/homeproxy/scripts/*.sh package/luci-app-homeproxy/root/usr/libexec/* 2>/dev/null || true
chmod +x package/luci-app-athena-led/root/etc/init.d/athena_led package/luci-app-athena-led/root/usr/sbin/athena-led 2>/dev/null || true


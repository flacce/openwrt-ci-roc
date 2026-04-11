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
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")
find ./ -type f -name "Makefile" \( -path "*/v2ray-geodata/*" -o -path "*/mosdns/*" \) -delete

# 调整NSS驱动q6_region内存区域预留大小（ipq6018.dtsi默认预留85MB，ipq6018-512m.dtsi默认预留55MB，带WiFi必须至少预留54MB，以下分别是改成预留16MB、32MB、64MB和96MB）
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x01000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x02000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x04000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x06000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi

# 调节IPQ60XX的1.5GHz频率电压(从0.9375V提高到0.95V，过低可能导致不稳定，过高可能增加功耗和发热，具体数值需要根据实际情况调整)
sed -i 's/opp-microvolt = <937500>;/opp-microvolt = <950000>;/' target/linux/qualcommax/patches-6.12/0038-v6.16-arm64-dts-qcom-ipq6018-add-1.5GHz-CPU-Frequency.patch

# 移除要替换的包
rm -rf \
  feeds/luci/applications/luci-app-{argon-config,wechatpush,appfilter,frpc,frps} \
  feeds/luci/themes/luci-theme-argon \
  feeds/packages/net/{open-app-filter,ariang,frp} \
  feeds/packages/lang/golang

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

# ariang & Go & frp & Aurora & Lucky & wechatpush & OpenAppFilter & 集客无线AC控制器 & 雅典娜LED控制
clone_into https://github.com/sbwml/luci-app-mosdns package/mosdns v5
clone_into https://github.com/sbwml/v2ray-geodata package/v2ray-geodata
clone_into hhttps://github.com/immortalwrt/homeproxy package/homeproxy
clone_into https://github.com/EasyTier/luci-app-easytier package/luci-app-easytier

git_sparse_clone ariang https://github.com/laipeng668/packages net/ariang

git_sparse_clone master https://github.com/laipeng668/packages lang/golang
mv -f package/golang feeds/packages/lang/golang

git_sparse_clone frp-binary https://github.com/laipeng668/packages net/frp
mv -f package/frp feeds/packages/net/frp

git_sparse_clone frp https://github.com/laipeng668/luci applications/luci-app-frpc applications/luci-app-frps
mv -f package/luci-app-frpc feeds/luci/applications/luci-app-frpc
mv -f package/luci-app-frps feeds/luci/applications/luci-app-frps

clone_into https://github.com/eamonxg/luci-theme-aurora package/luci-theme-aurora
clone_into https://github.com/eamonxg/luci-app-aurora-config package/luci-app-aurora-config
clone_into https://github.com/gdy666/luci-app-lucky package/luci-app-lucky
clone_into https://github.com/tty228/luci-app-wechatpush package/luci-app-wechatpush
clone_into https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter
clone_into https://github.com/laipeng668/luci-app-gecoosac package/luci-app-gecoosac
clone_into https://github.com/NONGFAH/luci-app-athena-led package/luci-app-athena-led
chmod +x package/luci-app-athena-led/root/etc/init.d/athena_led package/luci-app-athena-led/root/usr/sbin/athena-led

### PassWall & OpenClash ###

# 移除 OpenWrt Feeds 自带的核心库
rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}
clone_into https://github.com/Openwrt-Passwall/openwrt-passwall-packages package/passwall-packages

# 移除 OpenWrt Feeds 过时的LuCI版本
rm -rf feeds/luci/applications/luci-app-{passwall,openclash}
clone_into https://github.com/Openwrt-Passwall/openwrt-passwall package/luci-app-passwall
clone_into https://github.com/Openwrt-Passwall/openwrt-passwall2 package/luci-app-passwall2
clone_into https://github.com/vernesong/OpenClash package/luci-app-openclash

# 清理 PassWall 的 chnlist 规则文件
echo "baidu.com"  > package/luci-app-passwall/luci-app-passwall/root/usr/share/passwall/rules/chnlist



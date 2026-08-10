# OpenWrt MosDNS v5 + Nikki/Mihomo DNS 分流

已部署到 `192.168.2.1`（Kwrt 25.12.5，aarch64/rockchip armv8）。

## 1. 拓扑

```text
LAN 客户端 -> 192.168.2.1:53 (dnsmasq)
             -> 127.0.0.1:5335 (MosDNS v5)
                |- geosite:cn -> 223.5.5.5 / 119.29.29.29
                |- geolocation-!cn -> 127.0.0.1:1053 (Nikki fake-ip)
                `- 未分类 -> 国内优先，国内返回非中国 IP 时交 Nikki
```

Nikki 的 DNS 已改为只监听 `127.0.0.1:1053`，避免绕过 MosDNS 暴露给 LAN/WAN。

## 2. `/etc/mosdns/config.yaml`

```yaml
log:
  level: info
  file: "/var/log/mosdns.log"

api:
  http: "127.0.0.1:9091"

plugins:
  - tag: geosite_cn
    type: domain_set
    args:
      files:
        - "/var/mosdns/geosite_cn.txt"

  - tag: geoip_cn
    type: ip_set
    args:
      files:
        - "/var/mosdns/geoip_cn.txt"

  - tag: geosite_no_cn
    type: domain_set
    args:
      files:
        - "/var/mosdns/geosite_geolocation-!cn.txt"

  - tag: lazy_cache
    type: cache
    args:
      size: 20000
      lazy_cache_ttl: 86400
      dump_file: "/etc/mosdns/cache.dump"
      dump_interval: 600

  - tag: forward_cn
    type: forward
    args:
      upstreams:
        - addr: "udp://223.5.5.5"
        - addr: "udp://119.29.29.29"

  - tag: forward_nikki
    type: forward
    args:
      upstreams:
        - addr: "udp://127.0.0.1:1053"
          enable_pipeline: false

  - tag: query_cn_domain
    type: sequence
    args:
      - matches: "qname $geosite_cn"
        exec: "$forward_cn"

  - tag: query_no_cn_domain
    type: sequence
    args:
      - matches: "qname $geosite_no_cn"
        exec: "$forward_nikki"

  - tag: query_cn_ip
    type: sequence
    args:
      - exec: "$forward_cn"
      - matches: "!resp_ip $geoip_cn"
        exec: "drop_resp"

  - tag: fallback
    type: fallback
    args:
      primary: query_cn_ip
      secondary: forward_nikki
      threshold: 500
      always_standby: true

  - tag: has_resp
    type: sequence
    args:
      - matches: "has_resp"
        exec: "accept"

  - tag: block_ptr
    type: sequence
    args:
      - matches: "qtype 12"
        exec: "reject 5"

  - tag: main_sequence
    type: sequence
    args:
      - exec: "$block_ptr"
      - exec: "jump has_resp"
      - exec: "$lazy_cache"
      - exec: "jump has_resp"
      - exec: "$query_cn_domain"
      - exec: "jump has_resp"
      - exec: "$query_no_cn_domain"
      - exec: "jump has_resp"
      - exec: "$fallback"

  - tag: udp_server
    type: udp_server
    args:
      entry: main_sequence
      listen: "127.0.0.1:5335"

  - tag: tcp_server
    type: tcp_server
    args:
      entry: main_sequence
      listen: "127.0.0.1:5335"
```

## 3. Nikki/Mihomo `dns:` 片段

```yaml
dns:
  enable: true
  listen: 127.0.0.1:1053
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter-mode: blacklist
  fake-ip-filter:
    - "+.lan"
    - "+.local"
    - "9hao.ligangs2025.top"
    - "rule-set:add_direct_domain"
    - "rule-set:cn_domain"
  nameserver:
    - 114.114.114.114
    - 223.5.5.5
  nameserver-policy:
    "geosite:private,cn":
      - "https://223.5.5.5/dns-query"
      - "https://223.6.6.6/dns-query"
    "geosite:geolocation-!cn":
      - "https://1.1.1.1/dns-query"
      - "https://8.8.8.8/dns-query"
  proxy-server-nameserver:
    - "223.5.5.5"
    - "223.6.6.6"
  # 代理节点服务器必须解析到真实 IP，不能使用 fake-ip。
  proxy-server-nameserver-policy:
    "+.liangxin1.xyz":
      - "223.5.5.5"
      - "223.6.6.6"
    "+.426624.xyz":
      - "223.5.5.5"
      - "223.6.6.6"
```

实际 Nikki 由 LuCI/UCI 生成 profile；不要直接编辑 `/etc/nikki/run/config.yaml`，应编辑 `/etc/config/nikki` 或 LuCI 后重启。

## 4. UCI 接入

```sh
# MosDNS
uci set mosdns.config.enabled='1'
uci set mosdns.config.configfile='/etc/mosdns/config.yaml'
uci set mosdns.config.listen_address='127.0.0.1'
uci set mosdns.config.listen_port='5335'
uci set mosdns.config.listen_port_api='9091'
uci set mosdns.config.cache='1'
uci set mosdns.config.cache_size='20000'
uci set mosdns.config.geo_auto_update='0'
uci set mosdns.config.redirect='1'
uci set mosdns.config.local_dns_redirect='0'
uci commit mosdns

# dnsmasq 只把上游交给 MosDNS
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5335'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].cachesize='0'
uci set dhcp.@dnsmasq[0].rebind_protection='0'
uci commit dhcp

# Nikki/Mihomo
uci set nikki.mixin.dns_enabled='1'
uci set nikki.mixin.dns_listen='127.0.0.1:1053'
uci set nikki.mixin.dns_mode='fake-ip'
uci set nikki.mixin.fake_ip_range='198.18.0.1/16'
uci set nikki.mixin.dns_nameserver_policy='0'
uci set nikki.mixin.dns_proxy_server_nameserver_policy='1'
uci set nikki.mixin.mixin_file_content='1'
# 关闭 Nikki 对 LAN DNS 的劫持，保证客户端链路是：53 -> dnsmasq -> MosDNS:5335
uci set nikki.proxy.ipv4_dns_hijack='0'
uci set nikki.proxy.ipv6_dns_hijack='0'
uci commit nikki

# 将上面的 dns.nameserver-policy 写入 /etc/nikki/mixin.yaml，避免编辑生成文件。

/etc/init.d/mosdns restart
/etc/init.d/dnsmasq restart
/etc/init.d/nikki restart
```

53 端口继续由 dnsmasq 监听，LAN 客户端只需要使用路由器地址 `192.168.2.1` 作为 DNS；5335、1053、9091 均只绑定回环地址，不应在防火墙上开放。

## 5. 验证

```sh
# 监听检查
netstat -lntup | grep -E ':(53|1053|5335|9091)\\b'

# 国内域名应返回中国公网地址
nslookup baidu.com 192.168.2.1

# 国外域名在 fake-ip 模式通常返回 198.18.0.0/16
nslookup google.com 192.168.2.1

# 自有域名可验证 AAAA/HTTPS
nslookup 9hao.ligangs2025.top 192.168.2.1
curl -I --max-time 15 'https://9hao.ligangs2025.top:16689/'

# 查看 MosDNS/Nikki 日志
logread -e mosdns
logread -e nikki
tail -f /var/log/mosdns.log
```

外部客户端验证时，把 DNS 临时设置为 `192.168.2.1`，分别查询 `baidu.com`、`google.com`、`9hao.ligangs2025.top`；同时确认客户端没有直接访问 `8.8.8.8:53`、`1.1.1.1:53`。

## 7. DNS 防泄露与硬编码 DNS 拦截

OpenWrt 上额外加载 `/etc/nftables.d/90-nineplus-mosdns.nft`。它做三件事：

1. LAN 的 TCP/UDP 53，无论客户端写的是路由器、`8.8.8.8` 还是 `1.1.1.1`，都重定向到路由器 53，再由 dnsmasq 转发给 MosDNS `127.0.0.1:5335`；
2. 在 Nikki TUN 的 LAN 重定向之前，以优先级 `mangle - 1` 丢弃 TCP/UDP 853，防止 DoT 被代理转发后绕过 MosDNS；
3. 在 forward 链保留一条 853 兜底规则，覆盖未经过 Nikki TUN 的流量。

文件内容：

```nft
chain nineplus_mosdns_prerouting {
    type nat hook prerouting priority -100; policy accept;
    iifname "br-lan" meta l4proto { tcp, udp } th dport 53 counter redirect to :53 comment "NinePlus DNS to dnsmasq-MosDNS"
}

chain nineplus_block_dot_prerouting {
    type filter hook prerouting priority -151; policy accept;
    iifname "br-lan" meta l4proto { tcp, udp } th dport 853 counter drop comment "NinePlus block DoT before Nikki TUN"
}

chain nineplus_block_dot {
    type filter hook forward priority -1; policy accept;
    iifname "br-lan" meta l4proto { tcp, udp } th dport 853 counter reject comment "NinePlus block DoT bypass"
}
```

检查规则和计数器：

```sh
nft list chain inet fw4 nineplus_mosdns_prerouting
nft list chain inet fw4 nineplus_block_dot_prerouting
nft list chain inet fw4 nineplus_block_dot
```

从 LAN 客户端验证：

```sh
# 预期返回 198.18.0.0/16，说明硬编码 DNS 被 MosDNS 接管
dig @8.8.8.8 google.com A +short
dig @1.1.1.1 youtube.com A +short

# 预期连接失败/超时，且 nineplus_block_dot_prerouting 计数器增加
nc -vz -w 3 1.1.1.1 853
```

说明：上述规则可以阻断明文 DNS 和 DoT；浏览器内置 DoH 使用 HTTPS/443，无法通过端口 853 规则识别。要做到更严格的 DoH 防泄露，应继续使用域名/IP 规则集或在客户端关闭“安全 DNS”，不能把所有 443 一刀切，否则会同时破坏 Google、YouTube 和正常 HTTPS 访问。

## PTR 说明

正式配置已启用 PTR 拦截，并把 `$block_ptr` 放在缓存之前；拒绝响应随后立即 `jump has_resp`，确保不会继续进入缓存和上游流程：

```yaml
  - tag: block_ptr
    type: sequence
    args:
      - matches: "qtype 12"
        exec: "reject 5"
```

`main_sequence` 的顺序是先执行 `$block_ptr`，再查缓存。这样所有 PTR 查询都会返回 `REFUSED`，可避免已有 PTR 缓存绕过拦截，也能减少无用反向查询和 PTR 污染；代价是局域网主机名反查、部分调试工具的反向解析会不可用。如需恢复 PTR，删除该插件及对应的 `exec` 行后重启 MosDNS。

## 6. Nikki 持久化注意事项

Nikki 的 LuCI 启动脚本中，`dns_nameserver_policy=1` 的含义是**删除 profile 里的 `nameserver-policy`**，不是启用它。因此本机实际使用：

```sh
uci set nikki.mixin.dns_nameserver_policy='0'
uci set nikki.mixin.mixin_file_content='1'
uci commit nikki
```

并将 `dns:` 策略写入 `/etc/nikki/mixin.yaml`。Nikki 的 fallback 由 MosDNS 完成；不要在 Nikki 中额外启用需要下载 GeoIP MMDB 的 `fallback-filter`，否则在路由器启动时可能因 DNS 启动顺序形成循环。

### 代理节点解析故障

Nikki 的 fake-ip 只适合客户端目标域名；代理节点自身的 `server` 域名必须是真实地址。若日志出现：

```text
dns resolve failed: couldn't find ip
```

应在 `/etc/nikki/mixin.yaml` 的 `dns:` 中增加对应后缀的 `proxy-server-nameserver-policy`，并让 `proxy-server-nameserver` 使用不受 fake-ip 影响的国内上游。当前已为实际订阅中确认的 `liangxin1.xyz`、`426624.xyz` 后缀配置真实解析策略；订阅更换后如出现新的节点域名后缀，按同样格式补充并重启 Nikki。

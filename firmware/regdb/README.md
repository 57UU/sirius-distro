# regdb:无线管制数据库(打进 system 分区固件)

| 文件 | 作用 |
|---|---|
| `regulatory.db` | cfg80211 的无线管制数据库(按国家码规定可用信道/带宽/功率/DFS) |
| `regulatory.db.p7s` | 对应的 PKCS#7 签名 |

来源:Debian trixie `wireless-regdb` 2026.05.30-1~deb13u1 的
`/usr/lib/firmware/regulatory.db-upstream` + `regulatory.db.p7s-upstream`,
即 **upstream 签名**版本。md5:

```text
7b37a33bbe0f18f342fcd5a9f80bc3fe  regulatory.db
1ab34236cbd7434b889a28f5bc3ce530  regulatory.db.p7s
```

## 为什么必须用 upstream 签名版本

内核配置 `CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y` +
`CONFIG_CFG80211_USE_KERNEL_REGDB_KEYS=y`,只信任编译进内核的
`sforshee`/`wens` 两个 upstream wireless-regdb 公钥。Debian 包里的
`regulatory.db-debian` / `regulatory.db.p7s-debian` 是 Debian 自己重新签名的,
在我们 mainline 内核上会报:

```text
cfg80211: loaded regulatory.db is malformed or signature is missing/invalid
```

实测只有 `-upstream` 版本能正常加载。

## 运行行为

- 开机默认仍是 world(`00`),`iw reg get` 看到 world 规则;
- 关联 WiFi 后,AP 的 country IE(本机实测 AP 都广播 `Country: CN`)由 cfg80211
  11d 采纳,自动切到对应国家规则(如 CN:2.4G ch1-13、5.15–5.25 主动扫描、
  5.8G 33dBm;5.5GHz 该硬件不支持,仍 disabled);
- 也可以在设备上手动 `sudo iw reg set CN`(运行态,重启失效)。

rootfs 侧不再保留这份数据库(`wireless-regdb` 包已在 rootfs 构建末尾 purge),
system 分区是唯一来源;换国家/换管制策略只需要替换本目录文件并重刷 system。

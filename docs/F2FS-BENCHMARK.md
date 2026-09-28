# f2fs vs ext4（userdata，HCG8a4 eMMC）

方法：同机同分区位置，fio direct=1（4K QD1/QD32、1M QD8）+ dd 复测；
/tmp 是 tmpfs，数据一律取自 eMMC 分区。ext4 挂载 `rw,relatime`，
f2fs 为 mkfs 默认（background_gc、discard 等开）。

| 项目 | ext4 | f2fs | 结论 |
|---|---|---|---|
| 4K 随机读 QD1 | 2584 IOPS / p50 359us | 2708 IOPS / p50 306us | +5% |
| 4K 随机写 QD1 | 3099 IOPS / avg 317us | 3751 IOPS / avg 263us | +21%，延迟 -17% |
| 4K 随机写 QD32 | 3013 IOPS / avg 326us | 3735 IOPS / avg 264us | +24% |
| 1M 顺序读 | 43.2 MB/s | 40.3 MB/s | f2fs 低约 7% |
| 1M 顺序写 | 37.7 MB/s | 39.1 MB/s | f2fs 高约 4% |
| dd 顺序写/读 | 35.8 / 45.1 MB/s | 40.1 / 42.2 MB/s | 写 +12%，读 -6% |

结论：随机写提升约两成，顺序写小幅领先，顺序读落后约 7%；回归项（WiFi/电池/OTG/Orbital）全绿，综合随机负载占优，f2fs 留用。

备注：eMMC 本身顺序读写仅 40MB/s 级别，非文件系统问题；QD32 相对 QD1
无提升，说明随机写瓶颈在闪存通道而非队列深度。

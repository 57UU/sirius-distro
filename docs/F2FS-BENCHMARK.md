# f2fs vs ext4（userdata，HCG8a4 eMMC）

方法：同机同分区位置，fio direct=1（4K QD1/QD32、1M QD8）+ dd 复测；
/tmp 是 tmpfs，数据一律取自 eMMC 分区。ext4 挂载 `rw,relatime`，
f2fs 为 mkfs 默认（background\_gc、discard 等开）。
原始速度表测于 HS 52MHz（8bit / 3.3V）；HS400 表测于 HS400
（8bit / 1.8V / 200MHz，实际 192MHz；DT 改动：vqmmc 固定 1.8V +
`mmc-hs400-1_8v`），fio 3.39 同参数复测：f2fs 测自 userdata（p81），
ext4 测自 vendor（p80，原厂 ext4，`rw` 挂载，测完已删测试文件并卸载，
原厂数据未动）。原始记录：`build/benchmarks/bench-ext4/`、
`bench-f2fs/`、`bench-hs400-f2fs/`、`bench-hs400-ext4/`。

## 表一：原始速度（HS 52MHz）

| 项目          | ext4                  | f2fs                  | 结论           |
| ----------- | --------------------- | --------------------- | ------------ |
| 4K 随机读 QD1  | 2584 IOPS / p50 359us | 2708 IOPS / p50 306us | +5%          |
| 4K 随机写 QD1  | 3099 IOPS / avg 317us | 3751 IOPS / avg 263us | +21%，延迟 -17% |
| 4K 随机写 QD32 | 3013 IOPS / avg 326us | 3735 IOPS / avg 264us | +24%         |
| 1M 顺序读      | 43.2 MB/s             | 40.3 MB/s             | f2fs 低约 7%   |
| 1M 顺序写      | 37.7 MB/s             | 39.1 MB/s             | f2fs 高约 4%   |
| dd 顺序写/读    | 35.8 / 45.1 MB/s      | 40.1 / 42.2 MB/s      | 写 +12%，读 -6% |

## 表二：HS400 优化后

| 项目             | f2fs                  | ext4                  | 结论                    |
| -------------- | --------------------- | --------------------- | --------------------- |
| 4K 随机读 QD1     | 3679 IOPS / p50 235us | 3881 IOPS / p50 217us | ext4 快约 5%            |
| 4K 随机写 QD1     | 4952 IOPS / avg 197us | 4187 IOPS / avg 234us | f2fs 快 18%            |
| 4K 随机写 QD32    | 5019 IOPS / avg 195us | 4151 IOPS / avg 236us | f2fs 快 21%            |
| 1M 顺序读         | 241 MB/s              | 221 MB/s              | f2fs 快约 9%            |
| 1M 顺序写         | 172 MB/s              | 176 MB/s              | 基本打平（±2%）             |
| dd 顺序写/读（f2fs） | 137 / 248 MB/s        | —                     | 相对 HS52：写 3.4x，读 5.9x |

## 总结

- HS52 时代：f2fs 随机写领先约两成，顺序读写两者都在 40MB/s 级别打转，
  瓶颈在总线而非文件系统；综合随机负载占优，f2fs 留用。
- 切 HS400 后：顺序读提到 240+、写提到 170MB/s 级别（相对原来 5\~6x、3\~4x），
  随机读写再涨约三成、延迟降约四分之一；QD32 相对 QD1 仍无提升（+1.4%），
  随机写瓶颈仍在闪存通道而非队列深度。
- 同 HS400 下两者对比：随机读 ext4 略胜（+5%），顺序写打平，
  随机写与顺序读 f2fs 占优（+18\~21% / +9%）；手机负载以随机写为主，
  f2fs 结论不变。


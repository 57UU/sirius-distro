# f2fs vs ext4（HCG8a4 eMMC）

方法：fio direct=1（4K QD1/QD32、1M QD8）+ dd 复测；
/tmp 是 tmpfs，数据一律取自 eMMC 分区。ext4 挂载 `rw,relatime`，
f2fs 为 mkfs 默认（background\_gc、discard 等开）。
原始速度表测于 HS 52MHz（8bit / 3.3V）；HS400 复测于 HS400
（8bit / 1.8V / 200MHz，实际 192MHz；DT 改动：vqmmc 固定 1.8V +
`mmc-hs400-1_8v`）。表一原始记录：`build/benchmarks/bench-ext4/`、
`bench-f2fs/`。
表二为同分区同位置复测（system p79，3GB 空闲分区，
两轮均为 freshly mkfs，ext4 先测、f2fs 后测，测完已卸载，
分区内留空 f2fs 不影响系统），隔离闪存位置因素。
原始记录：`build/benchmarks/bench-p79-20260930-075250/bench-p79-{ext4,f2fs}/`，
复跑脚本：`build/bench-p79/bench-p79.sh`（手机上 `sudo bash` 约 6 分钟）。
表三为队列深度专项（同 p79，`ioengine=libaio` 真 QD），
原始记录：`build/benchmarks/bench-qd-20260930-184010/bench-qd-{ext4,f2fs}/`，
复跑脚本：`build/bench-p79/bench-qd.sh`（约 5 分钟）。

> 历史：曾有一版 HS400 跨分区对比（f2fs 在 p81 / ext4 在 p80），
> 因闪存位置/GC 状态变量没控制好，已删除，不作为结论依据。

## 表一：原始速度（HS 52MHz）

| 项目          | ext4                  | f2fs                  | 结论           |
| ----------- | --------------------- | --------------------- | ------------ |
| 4K 随机读 QD1  | 2584 IOPS / p50 359us | 2708 IOPS / p50 306us | +5%          |
| 4K 随机写 QD1  | 3099 IOPS / avg 317us | 3751 IOPS / avg 263us | +21%，延迟 -17% |
| 4K 随机写 QD32 | 3013 IOPS / avg 326us | 3735 IOPS / avg 264us | +24%         |
| 1M 顺序读      | 43.2 MB/s             | 40.3 MB/s             | f2fs 低约 7%   |
| 1M 顺序写      | 37.7 MB/s             | 39.1 MB/s             | f2fs 高约 4%   |
| dd 顺序写/读    | 35.8 / 45.1 MB/s      | 40.1 / 42.2 MB/s      | 写 +12%，读 -6% |

## 表二：HS400 同分区同位置（system p79，3GB）

| 项目                 | ext4                          | f2fs                          | 结论                     |
| ------------------ | ----------------------------- | ----------------------------- | ---------------------- |
| 4K 随机读 QD1         | 4030 IOPS / avg 243us（p50 212us） | 4235 IOPS / avg 231us（p50 206us） | f2fs 快约 5%，基本打平        |
| 4K 随机写 QD1         | 4330 IOPS / avg 225us（p50 184us） | 5039 IOPS / avg 193us（p50 161us） | f2fs 快 16%，延迟 -14%      |
| 4K 随机写 QD32        | 4436 IOPS / avg 220us         | 4717 IOPS / avg 207us         | f2fs 快约 6%（见注1）        |
| 1M 顺序读 fio         | 242 MB/s                      | 224 MB/s                      | ext4 快约 8%             |
| 1M 顺序写 fio         | 177 MB/s                      | 168 MB/s                      | ext4 快约 5%             |
| dd 顺序写 512M conv=fsync | 188 MB/s                 | 156 MB/s                      | ext4 快约 20%（见注2）      |
| dd 顺序读 512M        | 242 MB/s                      | 260 MB/s                      | f2fs 快约 7%（见注2）       |

注1：表一/表二的 QD32 列用的都是 `ioengine=psync`，
fio 会把 iodepth cap 到 1（日志原话 `queue depth will be capped at 1`），
所以该列实质是 QD1 的重复跑；与 QD1 的微小差异反映的是轮间波动，
不能解读为队列深度的（不）敏感。真正的队列深度对比见表三（libaio）。
注2：dd 写带 `conv=fsync`（含同步落盘开销，f2fs 的 checkpoint 开销在此放大），
dd 读走 page cache（非 direct，与 fio `direct=1` 路径不同），
所以 dd 与 fio 的数值方向不必一致，看同工具内的相对关系即可。

## 表三：队列深度专项（libaio，p79，4K direct=1）

`IO depths: 32=100.0%`，队列深度真实生效；同 p79 同位置，两轮均为 freshly mkfs。

| 项目      | ext4 QD1 → QD32 | f2fs QD1 → QD32 | 结论                                   |
| ------- | --------------- | --------------- | ------------------------------------ |
| 4K 随机读 | 2763 → 3816 IOPS（+38%），avg 290us → 8267us | 4360 → 4928 IOPS（+13%），avg 185us → 6387us | 加深队列读有收益；QD32 下单 op 延迟涨到 ms 级（排队代价） |
| 4K 随机写 | 4373 → 7000 IOPS（+60%），avg 183us → 4438us | 4323 → 7203 IOPS（+67%），avg 169us → 4306us | 写深度收益大；QD32 下两者基本打平（f2fs +3%）       |
| QD32 下跨 FS | 读 3816 / 写 7000 | 读 4928 / 写 7203 | 读 f2fs 快 29%，写打平                  |

注：QD1 跨引擎不可直接比（libaio 与 psync 系统调用路径不同，
如 ext4 随机读 libaio QD1 2763 vs psync QD1 4030，差的是引擎开销而非文件系统）；
有效读法是同引擎内 QD1→QD32 看缩放、同 QD 下看跨 FS 差异。

## 总结

- HS52 时代：f2fs 随机写领先约两成，顺序读写两者都在 40MB/s 级别打转，
  瓶颈在总线而非文件系统；综合随机负载占优，f2fs 留用。
- 切 HS400 后：顺序读提到 240+、写提到 170MB/s 级别（相对原来 5\~6x、3\~4x），
  随机读写再涨约三成、延迟降约四分之一。
- 同位置对比（表二，p79，位置因素已隔离）：随机写 f2fs 快 16% 且延迟低一截；
  随机读两者 ±5% 打平；顺序读写 ext4 快 5\~8%，带 fsync 的 dd 写 ext4 快约 20%。
- 队列深度专项（表三，libaio，真 QD）：写 QD1→QD32 涨 60\~67%，读涨 13\~38%，
  说明这块 eMMC 的队列深度是有效果的；代价是 QD32 下单 op 延迟涨到数 ms。
  QD32 下随机写两者打平，随机读 f2fs 快 29%。
- 总体结论不变：手机负载以随机写为主，f2fs 留用；
  顺序单流大块写入（如刷镜像）ext4 略优，但不构成换文件系统的理由。

# kernel：引用 + defconfig

源码与构建见上游：https://github.com/57UU/linux-sirius，分支 `feat/sirius-7.2`。

```text
configs/sdm710-xiaomi-sirius_defconfig  本机 defconfig，用法：
  cp configs/sdm710-xiaomi-sirius_defconfig \
    arch/arm64/configs/ && make sdm710-xiaomi-sirius_defconfig
```
可以将linux kernel源代码放在此处。
# kernel：引用 + defconfig

源码与构建见上游：https://github.com/57UU/linux-sirius，
分支 `feat/sirius-7.2`。源码树不进库，只收这一个文件：

```text
configs/sdm710-xiaomi-sirius_defconfig  本机 defconfig，用法：
  cp configs/sdm710-xiaomi-sirius_defconfig \
    arch/arm64/configs/ && make sdm710-xiaomi-sirius_defconfig
```

distro 构建要的三个产物（`Image.gz` + dtb + `kmod-*.tgz`，版本对齐
`uname -r`）从上游 Release 拿，不要随手拿 main 的产物。
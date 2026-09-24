# pd-mapper（上游源码占位，不 vendor）

上游：https://github.com/andersson/pd-mapper
本机没有源码时：

```bash
git clone https://github.com/andersson/pd-mapper
cd pd-mapper/pd-mapper
make CC=aarch64-linux-gnu-gcc
```

说明：手机上的 `/usr/local/bin/pd-mapper` 是按服务器
`pd-mapper-src/` 说明自编译的（带 query 日志，见 docs）。
如上游对不上我们用的版本，以手机现行二进制 + 服务器目录为准，
差异记到这里来（TODO：核对上游版本）。
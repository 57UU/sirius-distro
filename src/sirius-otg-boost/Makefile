obj-m += otg_boost_test.o
CFLAGS_otg_boost_test.o := -fno-stack-protector
KDIR ?= /home/u57u/kbuild/linux-sirius
all:
	make -C $(KDIR) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- M=$(CURDIR) KBUILD_MODPOST_WARN=1 modules
clean:
	make -C $(KDIR) M=$(CURDIR) clean

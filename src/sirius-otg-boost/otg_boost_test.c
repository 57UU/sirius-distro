/* Test-only: enable PMI660 OTG 5V boost (DCDC_CMD_OTG 0x1140 BIT0),
 * mirroring downstream smb5 smblib_vbus_regulator_enable().
 * rmmod clears the bit. Do NOT ship; proper fix belongs in qcom_smbx. */
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>

#define DCDC_CMD_OTG_REG	0x1140
#define OTG_EN_BIT		BIT(0)

static const char target_dev[] = "c440000.spmi:pmic@0:charger@1000";
static struct regmap *rm;

static int dev_match(struct device *dev, const void *data)
{
	return strcmp(dev_name(dev), (const char *)data) == 0;
}

static int __init otg_boost_init(void)
{
	struct device *pdev;
	unsigned int v = 0;
	int rc;

	pdev = bus_find_device(&platform_bus_type, NULL, target_dev, dev_match);
	if (!pdev) {
		pr_err("otg_boost: charger device not found\n");
		return -ENODEV;
	}
	rm = dev_get_regmap(pdev->parent, NULL);
	put_device(pdev);
	if (!rm) {
		pr_err("otg_boost: no parent regmap\n");
		return -ENODEV;
	}
	rc = regmap_read(rm, DCDC_CMD_OTG_REG, &v);
	pr_info("otg_boost: CMD_OTG before=0x%x rc=%d\n", v, rc);
	rc = regmap_update_bits(rm, DCDC_CMD_OTG_REG, OTG_EN_BIT, OTG_EN_BIT);
	if (rc) {
		pr_err("otg_boost: enable failed rc=%d\n", rc);
		return rc;
	}
	regmap_read(rm, DCDC_CMD_OTG_REG, &v);
	pr_info("otg_boost: CMD_OTG after=0x%x (VBUS boost should be ON)\n", v);
	return 0;
}

static void __exit otg_boost_exit(void)
{
	if (rm)
		regmap_update_bits(rm, DCDC_CMD_OTG_REG, OTG_EN_BIT, 0);
	pr_info("otg_boost: disabled\n");
}

module_init(otg_boost_init);
module_exit(otg_boost_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("sirius OTG boost test");

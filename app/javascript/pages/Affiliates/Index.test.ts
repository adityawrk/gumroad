import { describe, expect, it } from "vitest";

import { type Affiliate } from "$app/data/affiliates";
import { affiliateProductName, formattedFeePercentLabel } from "$app/pages/Affiliates/affiliateLabels";

const affiliate = (products: Affiliate["products"]): Affiliate => ({
  id: "affiliate-id",
  email: "affiliate@example.com",
  affiliate_user_name: "Affiliate",
  products,
  destination_url: null,
  product_referral_url: "https://gumroad.com/a/123",
  fee_percent: 25,
  apply_to_all_products: false,
});

describe("affiliate labels", () => {
  it("uses the base commission when no affiliated products remain active", () => {
    expect(formattedFeePercentLabel(affiliate([]))).toBe("25%");
  });

  it("labels an affiliate with no active products explicitly", () => {
    expect(affiliateProductName([])).toBe("No active products");
  });
});

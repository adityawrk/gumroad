import { type Affiliate } from "$app/data/affiliates";

export const formatFeePercent = (feePercent: number) => (feePercent / 100).toLocaleString([], { style: "percent" });

export const formattedFeePercentLabel = (affiliate: Affiliate) => {
  if (affiliate.apply_to_all_products || affiliate.products.length === 0) {
    return formatFeePercent(affiliate.fee_percent);
  }

  const productCommissions = affiliate.products.map((product) => product.fee_percent ?? affiliate.fee_percent);
  const minFeePercent = Math.min(...productCommissions);
  const maxFeePercent = Math.max(...productCommissions);
  return minFeePercent === maxFeePercent
    ? formatFeePercent(minFeePercent)
    : `${formatFeePercent(minFeePercent)} - ${formatFeePercent(maxFeePercent)}`;
};

export const affiliateProductName = (products: Affiliate["products"]) => {
  if (products.length === 0) return "No active products";
  return products.length === 1 ? (products[0]?.name ?? "") : `${products.length} products`;
};

# frozen_string_literal: true

class CollabProductMetricsService
  def initialize(products:, seller:)
    @products = products.to_a
    @seller = seller
  end

  def values_for(key)
    case key
    when "successful_sales_count"
      aggregate(Purchase::ACTIVE_SALES_SEARCH_OPTIONS, products).transform_values { _1["doc_count"] }
    when "revenue"
      revenue_by_product_id
    else
      raise ArgumentError, "Unsupported metric: #{key}"
    end
  end

  private
    attr_reader :products, :seller

    def revenue_by_product_id
      own_products, affiliated_products = products.partition { _1.user_id == seller.id }

      revenue_for(own_products, seller:).merge(revenue_for(affiliated_products, affiliate_user: seller))
    end

    def revenue_for(products, filter)
      for_seller = filter.key?(:seller)
      aggregations = {
        "price_cents_total" => { sum: { field: "price_cents" } },
        "affiliate_cents_total" => { sum: { field: "affiliate_credit_amount_cents" } },
        "affiliate_fees_total" => { sum: { field: "affiliate_credit_fee_cents" } },
        "amount_refunded_cents_total" => {
          sum: { field: for_seller ? "amount_refunded_cents" : "affiliate_credit_amount_partially_refunded_cents" },
        },
      }

      aggregate(Purchase::CHARGED_SALES_SEARCH_OPTIONS.merge(filter), products, aggregations).transform_values do |bucket|
        affiliate_total = bucket.dig("affiliate_cents_total", "value").to_i +
          bucket.dig("affiliate_fees_total", "value").to_i -
          bucket.dig("amount_refunded_cents_total", "value").to_i

        for_seller ? bucket.dig("price_cents_total", "value").to_i - affiliate_total : affiliate_total
      end
    end

    def aggregate(search_options, products, aggregations = {})
      return {} if products.empty?

      query = PurchaseSearchService.new(search_options.merge(product: products, size: 0)).body[:query]
      body = {
        query:,
        size: 0,
        aggs: {
          products: {
            composite: {
              size: ES_MAX_BUCKET_SIZE,
              sources: [{ product_id: { terms: { field: "product_id" } } }],
            },
            aggs: aggregations,
          },
        },
      }
      after_key = nil
      buckets = []

      loop do
        body[:aggs][:products][:composite][:after] = after_key if after_key
        aggregation = Purchase.search(body).aggregations.products
        buckets.concat(aggregation.buckets)
        after_key = aggregation["after_key"]
        break if after_key.blank?
      end

      buckets.index_by { _1.dig("key", "product_id").to_i }
    end
end

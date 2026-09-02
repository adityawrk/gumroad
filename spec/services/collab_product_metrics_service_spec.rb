# frozen_string_literal: true

require "spec_helper"

describe CollabProductMetricsService do
  it "collects metrics from every composite aggregation page" do
    stub_const("ES_MAX_BUCKET_SIZE", 1)
    seller = create(:recommendable_user)
    products = create_list(:product, 2, user: seller)
    products.each do |product|
      create(:purchase_in_progress, seller:, link: product).update_column(:purchase_state, "successful")
    end
    index_model_records(Purchase)
    expect(Purchase).to receive(:search).exactly(3).times.and_call_original

    values = described_class.new(products:, seller:).values_for("successful_sales_count")

    expect(values).to eq(products.index_with(1).transform_keys(&:id))
  end
end

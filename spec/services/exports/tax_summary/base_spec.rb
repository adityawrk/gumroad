# frozen_string_literal: true

require "spec_helper"

describe Exports::TaxSummary::Base do
  describe "#perform" do
    it "includes the final day of the year and excludes the next year" do
      user = create(:user, timezone: "UTC")
      product = create(:product, user:)
      create(
        :purchase,
        link: product,
        created_at: Time.zone.local(2023, 12, 31, 12),
        price_cents: 10_00,
      )
      create(
        :purchase,
        link: product,
        created_at: Time.zone.local(2024, 1, 1),
        price_cents: 20_00,
      )

      summary = described_class.new(user:, year: 2023).perform

      expect(summary[:transaction_cents_by_month][11]).to eq(10_00)
      expect(summary[:total_transaction_cents]).to eq(10_00)
      expect(summary[:transactions_count]).to eq(1)
    end

    it "takes the empty fast path when only the next year has a sale" do
      user = create(:user, timezone: "UTC")
      product = create(:product, user:)
      create(:purchase, link: product, created_at: Time.zone.local(2024, 1, 1), price_cents: 10_00)

      summary = described_class.new(user:, year: 2023).perform

      expect(summary).to eq(transaction_cents_by_month: {}, total_transaction_cents: 0, transactions_count: 0)
    end

    it "includes the final day of a month and excludes the next month" do
      user = create(:user, timezone: "UTC")
      product = create(:product, user:)
      create(
        :purchase,
        link: product,
        created_at: Time.zone.local(2023, 1, 31, 12),
        price_cents: 10_00,
      )
      create(
        :purchase,
        link: product,
        created_at: Time.zone.local(2023, 2, 1),
        price_cents: 20_00,
      )

      summary = described_class.new(user:, year: 2023).perform

      expect(summary[:transaction_cents_by_month][0]).to eq(10_00)
      expect(summary[:transaction_cents_by_month][1]).to eq(20_00)
      expect(summary[:total_transaction_cents]).to eq(30_00)
      expect(summary[:transactions_count]).to eq(2)
    end

    it "uses the seller's timezone at month boundaries" do
      user = create(:user, timezone: "Pacific Time (US & Canada)")
      product = create(:product, user:)
      create(:purchase, link: product, created_at: Time.utc(2023, 2, 1, 7, 30), price_cents: 10_00)
      create(:purchase, link: product, created_at: Time.utc(2023, 2, 1, 8), price_cents: 20_00)

      summary = described_class.new(user:, year: 2023).perform

      expect(summary[:transaction_cents_by_month][0]).to eq(10_00)
      expect(summary[:transaction_cents_by_month][1]).to eq(20_00)
      expect(summary[:total_transaction_cents]).to eq(30_00)
      expect(summary[:transactions_count]).to eq(2)
    end
  end
end

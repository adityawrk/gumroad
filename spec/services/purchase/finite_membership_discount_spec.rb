# frozen_string_literal: true

require "spec_helper"

describe Purchase::CreateService do
  let(:product) { create(:membership_product_with_preset_tiered_pricing) }
  let(:tier) { product.tiers.first }
  let!(:offer_code) { create(:offer_code, products: [product], amount_cents: 200, duration_in_billing_cycles: 1) }
  let(:perceived_price_cents) { 0 }
  let(:extra_params) { {} }
  let(:discount_code) { offer_code.code }

  def perform_purchase
    Purchase::CreateService.new(
      product:,
      params: {
        purchase: {
          email: "buyer@example.com",
          quantity: 1,
          perceived_price_cents:,
          discount_code:,
          ip_address: "127.0.0.1",
          browser_guid: SecureRandom.uuid
        },
        variants: [tier.external_id],
        price_id: product.prices.alive.find_by!(recurrence: "monthly").external_id
      }.merge(extra_params)
    ).perform
  end

  it "rejects a finite discount that became free after a membership tier price reduction" do
    tier.save_recurring_prices!(monthly: { enabled: true, price: 2 })

    purchase, error = perform_purchase

    expect(error).to eq("This discount code cannot make a membership temporarily free. Please remove it to continue.")
    expect(purchase).not_to be_successful
    expect(purchase.credit_card).to be_nil
    expect(product.subscriptions.count).to eq(0)
  end

  it "keeps permanent free discounts available" do
    offer_code.update!(duration_in_billing_cycles: nil)
    tier.save_recurring_prices!(monthly: { enabled: true, price: 2 })

    purchase, error = perform_purchase

    expect(error).to be_nil
    expect(purchase).to be_successful
    expect(purchase.subscription.current_subscription_price_cents).to eq(0)
  end

  it "allows a free tier change after the finite discount has expired" do
    original_purchase = create(:membership_purchase, link: product, variant_attributes: [tier],
                                                     offer_code:, price_cents: 100)
    original_purchase.create_purchase_offer_code_discount!(
      offer_code:, offer_code_amount: 200, offer_code_is_percent: false,
      pre_discount_minimum_price_cents: 300, duration_in_billing_cycles: 1
    )
    subscription = original_purchase.subscription
    expect(subscription.discount_applies_to_next_charge?).to be(false)
    tier.save_recurring_prices!(monthly: { enabled: true, price: 0 })

    subscription.update_current_plan!(
      new_variants: [tier], new_price: subscription.price, perceived_price_cents: 0,
      skip_preparing_for_charge: true
    )

    expect(subscription.reload.original_purchase.displayed_price_cents).to eq(0)
    expect(subscription.original_purchase.purchase_offer_code_discount).to be_nil
  end

  context "with a positive discounted price" do
    let(:perceived_price_cents) { 100 }
    let(:extra_params) { { is_part_of_combined_charge: true } }

    it "prepares the membership for its combined charge" do
      purchase, error = perform_purchase

      expect(error).to be_nil
      expect(purchase).to be_persisted
      expect(purchase).to be_in_progress
      expect(purchase.displayed_price_cents).to eq(100)
      expect(purchase.purchase_offer_code_discount.duration_in_billing_cycles).to eq(1)
    end
  end

  context "with a free trial" do
    let(:perceived_price_cents) { 100 }
    let(:extra_params) do
      { is_part_of_combined_charge: true, perceived_free_trial_duration: { amount: 1, unit: "week" } }
    end

    before do
      product.update!(free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: :week)
    end

    it "allows a trial with a positive discounted recurring price" do
      purchase, error = perform_purchase

      expect(error).to be_nil
      expect(purchase.is_free_trial_purchase?).to be(true)
      expect(purchase.displayed_price_cents).to eq(100)
    end
  end

  context "with an allocated discount and no submitted code" do
    let(:discount_code) { nil }
    let(:extra_params) do
      {
        submitted_pre_discount_price_cents: 200,
        once_per_cart_discount_allocation: { offer_code_id: offer_code.id, amount_cents: 200, allocation_id: SecureRandom.uuid }
      }
    end

    it "rejects a finite allocation that makes the recurring price zero" do
      offer_code.update!(once_per_cart: true)
      tier.save_recurring_prices!(monthly: { enabled: true, price: 2 })

      purchase, error = perform_purchase

      expect(purchase.discount_code).to be_nil
      expect(error).to eq("This discount code cannot make a membership temporarily free. Please remove it to continue.")
      expect(purchase).not_to be_successful
      expect(product.subscriptions.count).to eq(0)
    end
  end

  context "with a gift" do
    let(:extra_params) { { is_gift: true, gift: { giftee_email: "recipient@example.com", gift_note: "Happy birthday!" } } }

    it "allows a free membership gift" do
      tier.save_recurring_prices!(monthly: { enabled: true, price: 2 })

      purchase, error = perform_purchase

      expect(error).to be_nil
      expect(purchase).to be_successful
      expect(purchase.gift_given.giftee_purchase).to be_gift_receiver_purchase_successful
    end
  end
end

# frozen_string_literal: true

require "spec_helper"

describe LinksController, type: :controller do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 1000, quantity_enabled: true) }

  before { @request.host = URI.parse(seller.subdomain_with_protocol).host }

  %i[default url].each do |bulk_location|
    context "with a bulk #{bulk_location} discount" do
      let(:default_code) do
        create(:percentage_offer_code, user: seller, products: [product], code: "AUTO",
                                       amount_percentage: bulk_location == :default ? 30 : 10,
                                       minimum_quantity: bulk_location == :default ? 3 : nil)
      end
      let(:url_code) do
        create(:percentage_offer_code, user: seller, products: [product], code: "URL",
                                       amount_percentage: bulk_location == :url ? 30 : 10,
                                       minimum_quantity: bulk_location == :url ? 3 : nil)
      end

      before { product.update!(default_offer_code: default_code) }

      [1, 3, 4].each do |quantity|
        it "selects the eligible discount for a #{quantity}-unit Buy link" do
          get :show, params: { id: product.unique_permalink, wanted: "true", quantity:, code: url_code.code }

          expect(response).to be_redirect
          query = Rack::Utils.parse_query(URI.parse(response.location).query)
          expected_code = quantity >= 3 ? (bulk_location == :default ? default_code : url_code) : (bulk_location == :default ? url_code : default_code)
          expect(query).to include("quantity" => quantity.to_s, "code" => expected_code.code)
          computation = OfferCodeDiscountComputingService.new(query["code"], { product.unique_permalink => { permalink: product.unique_permalink, quantity: } }).process
          expect(computation[:error_code]).to be_nil
          expect(computation[:products_data][product.unique_permalink][:discount][:percents]).to eq(expected_code.amount_percentage)
        end
      end
    end
  end

  context "with checkout quantity normalization" do
    let(:default_code) { create(:percentage_offer_code, user: seller, products: [product], code: "BULK", amount_percentage: 30, minimum_quantity: 3) }
    let(:url_code) { create(:percentage_offer_code, user: seller, products: [product], code: "SAVE10", amount_percentage: 10, minimum_quantity: 1) }

    before { product.update!(default_offer_code: default_code) }

    ["", "0"].each do |quantity|
      it "uses checkout's one-unit default for quantity #{quantity.inspect}" do
        get :show, params: { id: product.unique_permalink, wanted: "true", quantity:, code: url_code.code }

        expect(Rack::Utils.parse_query(URI.parse(response.location).query)["code"]).to eq(url_code.code)
      end
    end

    it "uses the product stock limit when selecting a discount" do
      product.update!(max_purchase_count: 2)

      get :show, params: { id: product.unique_permalink, wanted: "true", quantity: 3, code: url_code.code }

      expect(Rack::Utils.parse_query(URI.parse(response.location).query)["code"]).to eq(url_code.code)
    end

    it "uses the selected option stock limit when selecting a discount" do
      category = create(:variant_category, link: product)
      create(:variant, variant_category: category)
      limited_option = create(:variant, variant_category: category, max_purchase_count: 2)

      get :show, params: { id: product.unique_permalink, wanted: "true", quantity: 3, option: limited_option.external_id, code: url_code.code }

      expect(Rack::Utils.parse_query(URI.parse(response.location).query)["code"]).to eq(url_code.code)
    end

    it "preserves checkout's unlimited selected option instead of applying the product stock limit" do
      product.update!(max_purchase_count: 2)
      option = create(:variant, variant_category: create(:variant_category, link: product))

      get :show, params: { id: product.unique_permalink, wanted: "true", quantity: 3, option: option.external_id, code: url_code.code }

      expect(Rack::Utils.parse_query(URI.parse(response.location).query)["code"]).to eq(default_code.code)
    end
  end

  context "with a persisted cart" do
    let(:browser_guid) { SecureRandom.uuid }
    let(:cart) { create(:cart, :guest, browser_guid:) }
    let(:category) { create(:variant_category, link: product) }
    let(:existing_option) { create(:variant, variant_category: category) }
    let(:incoming_option) { create(:variant, variant_category: category) }
    let!(:cart_product) { create(:cart_product, cart:, product:, option: existing_option, quantity: 2) }
    let(:bulk_code) { create(:percentage_offer_code, user: seller, products: [product], code: "BULK", amount_percentage: 30, minimum_quantity: 3) }
    let(:url_code) { create(:percentage_offer_code, user: seller, products: [product], code: "SAVE10", amount_percentage: 10) }

    before do
      cookies[:_gumroad_guid] = browser_guid
      product.update!(default_offer_code: bulk_code)
    end

    it "counts retained other-option units toward the default discount minimum" do
      get :show, params: { id: product.unique_permalink, wanted: "true", quantity: 1, option: incoming_option.external_id, code: url_code.code }

      expect(Rack::Utils.parse_query(URI.parse(response.location).query)["code"]).to eq(bulk_code.code)
    end

    it "counts retained other-option units toward the URL discount minimum" do
      product.update!(default_offer_code: url_code)

      get :show, params: { id: product.unique_permalink, wanted: "true", quantity: 1, option: incoming_option.external_id, code: bulk_code.code }

      expect(Rack::Utils.parse_query(URI.parse(response.location).query)["code"]).to eq(bulk_code.code)
    end

    it "replaces the existing same-option quantity instead of adding it" do
      get :show, params: { id: product.unique_permalink, wanted: "true", quantity: 1, option: existing_option.external_id, code: url_code.code }

      expect(Rack::Utils.parse_query(URI.parse(response.location).query)["code"]).to eq(url_code.code)
    end

    it "does not count a deleted cart line toward the minimum" do
      cart_product.mark_deleted!

      get :show, params: { id: product.unique_permalink, wanted: "true", quantity: 1, option: incoming_option.external_id, code: url_code.code }

      expect(Rack::Utils.parse_query(URI.parse(response.location).query)["code"]).to eq(url_code.code)
    end

    it "does not count an incoming option that checkout rejects when the cart is full" do
      create_list(:cart_product, Cart::MAX_ALLOWED_CART_PRODUCTS - 1, cart:)

      get :show, params: { id: product.unique_permalink, wanted: "true", quantity: 1, option: incoming_option.external_id, code: url_code.code }

      expect(Rack::Utils.parse_query(URI.parse(response.location).query)["code"]).to eq(url_code.code)
    end

    it "counts only the cart options eligible for the discount" do
      bulk_code.variants = [incoming_option]

      get :show, params: { id: product.unique_permalink, wanted: "true", quantity: 1, option: incoming_option.external_id, code: url_code.code }

      expect(Rack::Utils.parse_query(URI.parse(response.location).query)["code"]).to eq(url_code.code)
    end

    context "when comparing scoped savings" do
      %i[default url].each do |winning_location|
        it "prefers the #{winning_location} once-per-cart code over a scoped percentage on fewer units" do
          once_code = create(:offer_code, user: seller, products: [product], code: "ONCE7", amount_cents: 700, once_per_cart: true)
          scoped_code = create(:percentage_offer_code, user: seller, products: [product], code: "SCOPED30", amount_percentage: 30, variants: [existing_option])
          product.update!(default_offer_code: winning_location == :default ? once_code : scoped_code)
          request_code = winning_location == :default ? scoped_code : once_code

          get :show, params: { id: product.unique_permalink, wanted: "true", quantity: 1, option: incoming_option.external_id, code: request_code.code }

          expect(Rack::Utils.parse_query(URI.parse(response.location).query)["code"]).to eq(once_code.code)
        end

        it "prefers the #{winning_location} percentage code over a per-unit fixed code on fewer units" do
          percentage_code = create(:percentage_offer_code, user: seller, products: [product], code: "ALL10", amount_percentage: 10)
          scoped_code = create(:offer_code, user: seller, products: [product], code: "SCOPED2", amount_cents: 200, variants: [incoming_option])
          product.update!(default_offer_code: winning_location == :default ? percentage_code : scoped_code)
          request_code = winning_location == :default ? scoped_code : percentage_code

          get :show, params: { id: product.unique_permalink, wanted: "true", quantity: 1, option: incoming_option.external_id, code: request_code.code }

          expect(Rack::Utils.parse_query(URI.parse(response.location).query)["code"]).to eq(percentage_code.code)
        end
      end

      it "uses the actual incoming option price when comparing eligible savings" do
        incoming_option.update!(price_difference_cents: 3000)
        once_code = create(:offer_code, user: seller, products: [product], code: "ONCE17", amount_cents: 1700, once_per_cart: true)
        scoped_code = create(:percentage_offer_code, user: seller, products: [product], code: "SCOPED50", amount_percentage: 50, variants: [incoming_option])
        product.update!(default_offer_code: once_code)

        get :show, params: { id: product.unique_permalink, wanted: "true", quantity: 1, option: incoming_option.external_id, code: scoped_code.code }

        expect(Rack::Utils.parse_query(URI.parse(response.location).query)["code"]).to eq(scoped_code.code)
      end
    end

    context "when the buyer is signed in" do
      let(:buyer) { create(:user) }
      let(:cart) { create(:cart, user: buyer) }

      before { sign_in buyer }

      it "uses the buyer's cart instead of a different guest cart" do
        guest_cart = create(:cart, :guest, browser_guid:)
        create(:cart_product, cart: guest_cart, product:, option: existing_option, quantity: 1)

        get :show, params: { id: product.unique_permalink, wanted: "true", quantity: 1, option: incoming_option.external_id, code: url_code.code }

        expect(Rack::Utils.parse_query(URI.parse(response.location).query)["code"]).to eq(bulk_code.code)
      end
    end

    context "with a recurring product" do
      let(:product) { create(:membership_product_with_preset_tiered_pricing, user: seller, is_multiseat_license: true) }
      let(:existing_option) { product.tiers.first }
      let(:incoming_option) { product.tiers.second }

      it "replaces every previous tier instead of counting its quantity" do
        expect(product.recurrences).to be_present

        get :show, params: { id: product.unique_permalink, wanted: "true", quantity: 1, option: incoming_option.external_id, code: url_code.code }

        expect(Rack::Utils.parse_query(URI.parse(response.location).query)["code"]).to eq(url_code.code)
      end
    end
  end

  it "does not apply an ineligible default when no URL code was supplied" do
    code = create(:percentage_offer_code, user: seller, products: [product], code: "BULK", amount_percentage: 30, minimum_quantity: 3)
    product.update!(default_offer_code: code)

    get :show, params: { id: product.unique_permalink, wanted: "true" }

    expect(Rack::Utils.parse_query(URI.parse(response.location).query)["code"]).to be_nil
  end

  it "does not replace an invalid URL code with an ineligible default" do
    code = create(:percentage_offer_code, user: seller, products: [product], code: "BULK", amount_percentage: 30, minimum_quantity: 3)
    product.update!(default_offer_code: code)

    get :show, params: { id: product.unique_permalink, wanted: "true", code: "MISSING" }

    expect(Rack::Utils.parse_query(URI.parse(response.location).query)["code"]).to be_nil
  end
end

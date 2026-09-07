# frozen_string_literal: true

require "spec_helper"

describe Exports::Payouts::Annual, :vcr do
  include PaymentsHelper

  describe "perform" do
    let!(:year) { 2019 }
    before do
      create(:merchant_account, user: nil, charge_processor_merchant_id: "annual_stripe_#{SecureRandom.hex(12)}")
      create(:merchant_account_paypal, user: nil, charge_processor_merchant_id: "annual_paypal_#{SecureRandom.hex(12)}")
      @user = create(:user)
      date_for_year = Date.new(year)
      amount_cents = 1500
      (0..11).each do |month|
        created_at_date = date_for_year + month.months
        payment = create(:payment_completed,
                         user: @user,
                         amount_cents:,
                         payout_period_end_date: created_at_date,
                         created_at: created_at_date)
        purchase = create(:purchase,
                          seller: @user,
                          price_cents: amount_cents,
                          total_transaction_cents: amount_cents,
                          purchase_success_balance: create(:balance, payments: [payment]),
                          created_at: created_at_date,
                          succeeded_at: created_at_date,
                          link: create(:product, user: @user))
        payment.amount_cents = purchase.payment_cents
        payment.save!
        create(:purchase,
               seller: @user,
               price_cents: amount_cents,
               total_transaction_cents: amount_cents,
               charge_processor_id: PaypalChargeProcessor.charge_processor_id,
               created_at: created_at_date,
               succeeded_at: created_at_date,
               link: create(:product, user: @user))
      end
    end

    it "shows all activity related to the yearly payout" do
      date_for_year = Date.new(year)
      data = Exports::Payouts::Annual.new(user: @user, year:).perform
      parsed_csv = CSV.parse(data[:csv_file].read)
      expect(parsed_csv).to include(Exports::Payouts::Csv::HEADERS)
      @user.sales.where("created_at BETWEEN ? AND ?",
                        date_for_year.beginning_of_year,
                        date_for_year.at_end_of_year).each do |sale|
        expect(parsed_csv).to include(sale_summary(sale))
      end
      expect(parsed_csv.last).to eq(["Totals", nil, nil, nil, nil, nil, "0.0", "0.0", "212.88", "65.76", "147.12"])
    end

    it "returns total_amount from the yearly payout" do
      date_for_year = Date.new(year)
      data = Exports::Payouts::Annual.new(user: @user, year:).perform
      amount = (data[:total_amount] * 100.0).round
      expect(amount).to eq(@user.sales.where("created_at BETWEEN ? AND ?",
                                             date_for_year.beginning_of_year,
                                             date_for_year.at_end_of_year).sum("price_cents - fee_cents"))
    end

    it "returns no data if no payments exist" do
      data = Exports::Payouts::Annual.new(user: create(:user), year:).perform
      expect(data[:csv_file]).to be_nil
    end

    it "returns no data on failed payments" do
      date_for_year = Date.new(year)
      payment_data = create_payment_with_purchase(@user, date_for_year, :payment_failed)
      data = Exports::Payouts::Annual.new(user: @user, year:).perform
      parsed_csv = CSV.parse(data[:csv_file].read)
      expect(parsed_csv).not_to include(sale_summary(payment_data[:purchase]))
    end

    it "keeps the totals aligned with the visible rows when selected payouts contain adjacent-year activity" do
      outside_payment_data = [
        create_payment_with_purchase(@user, Date.new(year) - 3.days),
        create_payment_with_purchase(@user, Date.new(year).end_of_year + 3.days),
      ]
      data = Exports::Payouts::Annual.new(user: @user, year:).perform
      parsed_csv = CSV.parse(data[:csv_file].read)
      outside_payment_data.each do |payment_data|
        expect(parsed_csv).to_not include(sale_summary(payment_data[:purchase]))
      end

      visible_rows = parsed_csv[1...-1]
      totals_row = parsed_csv.last
      Exports::Payouts::Csv::TOTALS_FIELDS.each do |column_name|
        column_index = Exports::Payouts::Csv::HEADERS.index(column_name)
        visible_total = visible_rows.sum { |row| BigDecimal(row[column_index].presence || "0") }

        expect(BigDecimal(totals_row[column_index])).to eq(visible_total)
      end
    end

    it "includes year activity paid by the first payout ending after the year" do
      sale_date = Date.new(year).end_of_year
      payout = create(:payment_completed,
                      user: @user,
                      amount_cents: 1_000,
                      payout_period_end_date: Date.new(year + 1, 1, 24),
                      created_at: Date.new(year + 1, 1, 31))
      purchase = create(:purchase,
                        seller: @user,
                        price_cents: 1_000,
                        total_transaction_cents: 1_000,
                        purchase_success_balance: create(:balance, payments: [payout]),
                        created_at: sale_date.in_time_zone,
                        succeeded_at: sale_date.in_time_zone,
                        link: create(:product, user: @user))
      payout.update!(amount_cents: purchase.payment_cents)

      data = Exports::Payouts::Annual.new(user: @user, year:).perform
      parsed_csv = CSV.parse(data[:csv_file].read)

      expect(parsed_csv).to include(sale_summary(purchase))
      expect((data[:total_amount] * 100).round).to eq(
        @user.sales.where(succeeded_at: Date.new(year).all_year).sum("price_cents - fee_cents")
      )
    end

    it "includes processor activity in a delayed payout ending after the year" do
      processor_user = create(:user)
      paypal_account = create(:merchant_account_paypal, user: processor_user)
      product = create(:product, user: processor_user)
      sale_date = Date.new(year).end_of_year
      create(:payment_completed,
             user: processor_user,
             amount_cents: 0,
             payout_period_end_date: Date.new(year + 1, 1, 24),
             created_at: Date.new(year + 1, 1, 31))
      purchase = create_processor_sale(
        product:,
        merchant_account: paypal_account,
        date: sale_date,
        price_cents: 10_000,
        fee_cents: 1_000,
        affiliate_fee_cents: 0
      )

      data = annual_data(year, user: processor_user)
      deduction = data[:csv].find { |row| row[0] == Exports::Payouts::Base::PAYPAL_PAYOUTS_HEADING }

      expect(data[:csv]).to include(sale_summary(purchase))
      expect(deduction[1]).to eq(sale_date.to_s)
      expect(BigDecimal(deduction[-1])).to eq(BigDecimal("-90"))
      expect(BigDecimal(data[:total_amount].to_s)).to eq(BigDecimal("90"))
    end

    it "does not duplicate processor activity when legacy undated and dated payouts are both selected" do
      processor_user = create(:user)
      stripe_connect_account = create(:merchant_account_stripe_connect, user: processor_user)
      processor_user.merchant_accounts.reload
      product = create(:product, user: processor_user)
      sale_date = Date.new(year).end_of_year
      create(:payment_completed,
             user: processor_user,
             amount_cents: 0,
             payout_period_end_date: nil,
             created_at: sale_date - 1.day)
      create(:payment_completed,
             user: processor_user,
             amount_cents: 0,
             payout_period_end_date: Date.new(year + 1, 1, 24),
             created_at: Date.new(year + 1, 1, 31))
      purchase = create_processor_sale(
        product:,
        merchant_account: stripe_connect_account,
        date: sale_date,
        price_cents: 12_000,
        fee_cents: 2_000,
        affiliate_fee_cents: 1_000
      )

      data = annual_data(year, user: processor_user)

      expect(data[:csv].count { |row| row == sale_summary(purchase) }).to eq(1)
      expect(data[:csv].count { |row| row[0] == "Stripe Connect Affiliate Fees" }).to eq(1)
      expect(data[:csv].count { |row| row[0] == Exports::Payouts::Base::STRIPE_CONNECT_PAYOUTS_HEADING }).to eq(1)
      expect(BigDecimal(data[:total_amount].to_s)).to eq(BigDecimal("90"))
    end

    it "uses an undated legacy payout only for the tail after earlier dated payout periods" do
      processor_user = create(:user)
      stripe_connect_account = create(:merchant_account_stripe_connect, user: processor_user)
      processor_user.merchant_accounts.reload
      product = create(:product, user: processor_user)
      dated_period_end = Date.new(year, 6, 30)
      tail_date = Date.new(year).end_of_year
      create(:payment_completed,
             user: processor_user,
             amount_cents: 0,
             payout_period_end_date: dated_period_end,
             created_at: dated_period_end + 1.week)
      create(:payment_completed,
             user: processor_user,
             amount_cents: 0,
             payout_period_end_date: nil,
             created_at: tail_date - 1.day)
      purchases = [dated_period_end, tail_date].map do |sale_date|
        create_processor_sale(
          product:,
          merchant_account: stripe_connect_account,
          date: sale_date,
          price_cents: 10_000,
          fee_cents: 1_000,
          affiliate_fee_cents: 0
        )
      end

      data = annual_data(year, user: processor_user)

      expect(purchases.map { |purchase| data[:csv].count { |row| row == sale_summary(purchase) } }).to eq([1, 1])
      deductions = data[:csv].select { |row| row[0] == Exports::Payouts::Base::STRIPE_CONNECT_PAYOUTS_HEADING }
      expect(deductions.map { |row| row[1] }).to contain_exactly(dated_period_end.to_s, tail_date.to_s)
      expect(deductions.map { |row| BigDecimal(row[-1]) }).to contain_exactly(BigDecimal("-90"), BigDecimal("-90"))
      expect(BigDecimal(data[:total_amount].to_s)).to eq(BigDecimal("180"))
    end

    it "splits PayPal and Stripe Connect activity when a payout period crosses the year boundary" do
      processor_user = create(:user)
      paypal_account = create(:merchant_account_paypal, user: processor_user)
      stripe_connect_account = create(:merchant_account_stripe_connect, user: processor_user)
      processor_user.merchant_accounts.reload
      product = create(:product, user: processor_user)
      prior_year_date = Date.new(year).end_of_year
      next_year_date = prior_year_date.next
      cross_year_payout = create(:payment_completed,
                                 user: processor_user,
                                 amount_cents: 0,
                                 payout_period_end_date: next_year_date + 2.days,
                                 created_at: next_year_date + 2.days)

      processor_sales = {
        Exports::Payouts::Base::PAYPAL_PAYOUTS_HEADING => {
          affiliate_heading: "PayPal Connect Affiliate Fees",
          prior: create_processor_sale(product:, merchant_account: paypal_account, date: prior_year_date, price_cents: 10_000, fee_cents: 1_000, affiliate_fee_cents: 500),
          next: create_processor_sale(product:, merchant_account: paypal_account, date: next_year_date, price_cents: 20_000, fee_cents: 2_000, affiliate_fee_cents: 1_000),
          prior_affiliate_fee: BigDecimal("5"),
          next_affiliate_fee: BigDecimal("10"),
          prior_net: BigDecimal("85"),
          next_net: BigDecimal("170"),
          full_net: BigDecimal("255"),
        },
        Exports::Payouts::Base::STRIPE_CONNECT_PAYOUTS_HEADING => {
          affiliate_heading: "Stripe Connect Affiliate Fees",
          prior: create_processor_sale(product:, merchant_account: stripe_connect_account, date: prior_year_date, price_cents: 12_000, fee_cents: 2_000, affiliate_fee_cents: 1_000),
          next: create_processor_sale(product:, merchant_account: stripe_connect_account, date: next_year_date, price_cents: 30_000, fee_cents: 3_000, affiliate_fee_cents: 1_500),
          prior_affiliate_fee: BigDecimal("10"),
          next_affiliate_fee: BigDecimal("15"),
          prior_net: BigDecimal("90"),
          next_net: BigDecimal("255"),
          full_net: BigDecimal("345"),
        },
      }

      prior_year_data = annual_data(year, user: processor_user)
      next_year_data = annual_data(year + 1, user: processor_user)
      prior_year_csv = prior_year_data[:csv]
      next_year_csv = next_year_data[:csv]
      payout_csv = CSV.parse(Exports::Payouts::Csv.new(payment: cross_year_payout).perform)

      processor_sales.each do |heading, sales|
        expect_processor_rows(prior_year_csv, heading:, affiliate_heading: sales[:affiliate_heading], deduction_date: prior_year_date, included_sale: sales[:prior], excluded_sale: sales[:next], expected_affiliate_fee: sales[:prior_affiliate_fee], expected_net: sales[:prior_net])
        expect_processor_rows(next_year_csv, heading:, affiliate_heading: sales[:affiliate_heading], deduction_date: next_year_date + 2.days, included_sale: sales[:next], excluded_sale: sales[:prior], expected_affiliate_fee: sales[:next_affiliate_fee], expected_net: sales[:next_net])

        expect(payout_csv).to include(sale_summary(sales[:prior]), sale_summary(sales[:next]))
        full_deduction_row = payout_csv.find { |row| row[0] == heading }
        expect(BigDecimal(full_deduction_row[-1])).to eq(-sales[:full_net])
      end

      expect(BigDecimal(prior_year_data[:total_amount].to_s)).to eq(BigDecimal("175"))
      expect(BigDecimal(next_year_data[:total_amount].to_s)).to eq(BigDecimal("425"))
    end

    it "returns creator earnings for a Stripe Connect-only annual report" do
      processor_user = create(:user)
      stripe_connect_account = create(:merchant_account_stripe_connect, user: processor_user)
      processor_user.merchant_accounts.reload
      product = create(:product, user: processor_user)
      sale_date = Date.new(year).end_of_year
      create(:payment_completed,
             user: processor_user,
             amount_cents: 0,
             payout_period_end_date: sale_date,
             created_at: sale_date)
      create_processor_sale(
        product:,
        merchant_account: stripe_connect_account,
        date: sale_date,
        price_cents: 12_000,
        fee_cents: 2_000,
        affiliate_fee_cents: 1_000
      )

      data = annual_data(year, user: processor_user)

      expect(BigDecimal(data[:total_amount].to_s)).to eq(BigDecimal("90"))
    end

    it "assigns cross-year processor refunds to the year when the refund occurred" do
      processor_user = create(:user)
      paypal_account = create(:merchant_account_paypal, user: processor_user)
      stripe_connect_account = create(:merchant_account_stripe_connect, user: processor_user)
      processor_user.merchant_accounts.reload
      product = create(:product, user: processor_user)
      sale_date = Date.new(year).end_of_year
      refund_date = sale_date.next
      create(:payment_completed,
             user: processor_user,
             amount_cents: 0,
             payout_period_end_date: refund_date,
             created_at: refund_date)

      processor_sales = [paypal_account, stripe_connect_account].map do |merchant_account|
        purchase = create_processor_sale(
          product:,
          merchant_account:,
          date: sale_date,
          price_cents: 10_000,
          fee_cents: 1_000,
          affiliate_fee_cents: 500
        )
        refund = create(:refund,
                        purchase:,
                        amount_cents: 10_000,
                        fee_cents: 1_000,
                        created_at: refund_date.in_time_zone)
        heading = merchant_account.is_a_paypal_connect_account? ?
          Exports::Payouts::Base::PAYPAL_PAYOUTS_HEADING :
          Exports::Payouts::Base::STRIPE_CONNECT_PAYOUTS_HEADING
        [heading, purchase, refund]
      end

      prior_year_data = annual_data(year, user: processor_user)
      next_year_data = annual_data(year + 1, user: processor_user)

      processor_sales.each do |heading, purchase, refund|
        expect(prior_year_data[:csv]).to include(sale_summary(purchase))
        expect(prior_year_data[:csv]).not_to include(refund_summary(refund))
        expect(next_year_data[:csv]).to include(refund_summary(refund))
        expect(next_year_data[:csv]).not_to include(sale_summary(purchase))

        prior_deduction = prior_year_data[:csv].find { |row| row[0] == heading }
        next_deduction = next_year_data[:csv].find { |row| row[0] == heading }
        expect(prior_deduction[1]).to eq(sale_date.to_s)
        expect(BigDecimal(prior_deduction[-1])).to eq(BigDecimal("-85"))
        expect(next_deduction[1]).to eq(refund_date.to_s)
        expect(BigDecimal(next_deduction[-1])).to eq(BigDecimal("85"))
      end

      expect(BigDecimal(prior_year_data[:total_amount].to_s)).to eq(BigDecimal("170"))
      expect(BigDecimal(next_year_data[:total_amount].to_s)).to eq(BigDecimal("-170"))
    end
  end

  private
    def annual_data(year, user: @user)
      data = Exports::Payouts::Annual.new(user:, year:).perform
      { csv: CSV.parse(data[:csv_file].read), total_amount: data[:total_amount] }
    ensure
      data&.dig(:csv_file)&.close!
    end

    def refund_summary(refund)
      heading = refund.purchase.charge_processor_id == PaypalChargeProcessor.charge_processor_id ? "PayPal Refund" : "Stripe Connect Refund"
      [
        heading,
        refund.created_at.to_date.to_s,
        csv_safe(refund.purchase.external_id),
        refund.purchase.link.name,
        refund.purchase.full_name,
        refund.purchase.purchaser_email_or_email,
        "-0.0",
        "-0.0",
        "-100.0",
        "10.0",
        "-90.0",
      ]
    end

    def create_processor_sale(product:, merchant_account:, date:, price_cents:, fee_cents:, affiliate_fee_cents:)
      purchase = create(:purchase, :with_custom_fee,
                        link: product,
                        price_cents:,
                        total_transaction_cents: price_cents,
                        fee_cents:,
                        charge_processor_id: merchant_account.charge_processor_id,
                        merchant_account:,
                        created_at: date.in_time_zone,
                        succeeded_at: date.in_time_zone)
      purchase.update!(affiliate_credit_cents: affiliate_fee_cents)
      purchase
    end

    def expect_processor_rows(csv, heading:, affiliate_heading:, deduction_date:, included_sale:, excluded_sale:, expected_affiliate_fee:, expected_net:)
      expected_sale_row = sale_summary(included_sale)
      included_row = csv.find { |row| row[2] == expected_sale_row[2] }
      expect(included_row).to eq(expected_sale_row)
      expect(csv).not_to include(sale_summary(excluded_sale))

      affiliate_fee_row = csv.find { |row| row[0] == affiliate_heading && row[1] == included_sale.succeeded_at.to_date.to_s }
      expect(BigDecimal(affiliate_fee_row[-1])).to eq(-expected_affiliate_fee)
      deduction_row = csv.find { |row| row[0] == heading && row[1] == deduction_date.to_s }
      expect(BigDecimal(deduction_row[-1])).to eq(-expected_net)
      expect(BigDecimal(included_row[-1]) + BigDecimal(affiliate_fee_row[-1]) + BigDecimal(deduction_row[-1])).to be_zero
    end

    def csv_safe(value)
      return value if value.nil?
      str = value.to_s
      return value if str.empty?
      first = str[0]
      if first == "+" || first == "-"
        return value if str[1..]&.match?(/\A\d+\.?\d*\z/)
      end
      %w[= @ | % \r \t + -].include?(first) ? "'#{value}" : value
    end

    def sale_summary(sale)
      CSV.parse([
        "Sale",
        sale.succeeded_at.to_date.to_s,
        csv_safe(sale.external_id),
        sale.link.name,
        sale.full_name,
        sale.purchaser_email_or_email,
        sale.tax_dollars,
        sale.shipping_dollars,
        sale.price_dollars,
        sale.fee_dollars,
        sale.net_total,
      ].to_csv).first
    end
end

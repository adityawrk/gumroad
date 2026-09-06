# frozen_string_literal: true

class Exports::Payouts::Annual < Exports::Payouts::Csv
  include CurrencyHelper
  def initialize(user:, year:)
    @user = user
    @year = Date.new(year)
  end

  # Note: This returns a csv tempfile object. Please close and unlink the file after usage for better GC.
  def perform
    payments_scope = payments_covering_year
    return { csv_file: nil, total_amount: 0 } unless payments_scope.exists?

    totals = Hash.new(0)
    total_amount = 0
    processor_activity_ranges = processor_activity_ranges_for_year(payments_scope)

    tempfile = Tempfile.open(File.join(Rails.root, "tmp", "#{@user.id}_#{@year}_annual.csv"),
                             encoding: "UTF-8")
    CsvSafe.open(tempfile, "wb") do |csv|
      csv << HEADERS
      payments_scope.find_each do |payment|
        @payment = payment
        processor_activity_range = processor_activity_ranges[payment.id]
        data = payout_data(
          processor_activity_range:,
          include_processor_activity: processor_activity_range.present?
        ).select do |row|
          Date.parse(row[1]).between?(@year.beginning_of_year, @year.end_of_year)
        end
        totals = calculate_totals(data, from_totals: totals)

        data.each do |row|
          total_amount += row[-1].to_f unless row[0].in?([PAYPAL_PAYOUTS_HEADING, STRIPE_CONNECT_PAYOUTS_HEADING])
          csv << row
        end
        GC.start
      end

      csv << generate_totals_row(totals)
    end
    tempfile.rewind

    { csv_file: tempfile, total_amount: }
  end

  private
    def payments_covering_year
      completed_payments = @user.payments.completed
      dated_payments = completed_payments.where.not(payout_period_end_date: nil)
      first_period_end_after_year = dated_payments
                                      .where("payout_period_end_date > ?", @year.end_of_year)
                                      .minimum(:payout_period_end_date)
      last_relevant_period_end = first_period_end_after_year || @year.end_of_year
      dated_payment_ids = dated_payments
                          .where(payout_period_end_date: @year.beginning_of_year..last_relevant_period_end)
                          .select(:id)
      payment_ids_for_year_balances = completed_payments
                                      .joins(:balances)
                                      .where(balances: { date: @year.all_year })
                                      .select(:id)
      recent_undated_payment_ids = completed_payments
                                   .where(payout_period_end_date: nil)
                                   .where(created_at: (@year.beginning_of_year - 1.week)..(@year.end_of_year + 1.week))
                                   .select(:id)

      completed_payments.where(id: dated_payment_ids)
                        .or(completed_payments.where(id: payment_ids_for_year_balances))
                        .or(completed_payments.where(id: recent_undated_payment_ids))
    end

    def processor_activity_ranges_for_year(payments_scope)
      payments = payments_scope.pluck(:id, :payout_period_end_date, :created_at)
      dated_payments = payments.select { |_id, payout_period_end_date, _created_at| payout_period_end_date.present? }
      ranges = dated_payments.to_h { |id, _payout_period_end_date, _created_at| [id, @year.all_year] }

      if dated_payments.any? { |_id, payout_period_end_date, _created_at| payout_period_end_date >= @year.end_of_year }
        return ranges
      end

      latest_undated_payment = payments
                                .reject { |_id, payout_period_end_date, _created_at| payout_period_end_date.present? }
                                .max_by { |_id, _payout_period_end_date, created_at| created_at }
      return ranges unless latest_undated_payment

      latest_dated_period_end = dated_payments.filter_map(&:second).max
      tail_start_date = [latest_dated_period_end&.next || @year.beginning_of_year, @year.beginning_of_year].max
      ranges[latest_undated_payment.first] = tail_start_date..@year.end_of_year
      ranges
    end
end

# frozen_string_literal: true

class UpdatePayoutStatusWorker
  include Sidekiq::Job
  sidekiq_options retry: 25, queue: :default, lock: :until_executed

  def perform(payment_id)
    payment = Payment.find(payment_id)

    Rails.logger.info("UpdatePayoutStatusWorker invoked for payment #{payment_id}")

    # This job is supposed to update status only for payments in the processing state
    return unless payment.processing?

    if payment.was_created_in_split_mode?
      updates = payment.split_payments_info.each_with_index.filter_map do |split_payment_info, index|
        next if split_payment_info["state"] != "pending"

        details = PaypalPayoutProcessor.get_latest_payment_details_from_paypal(
          split_payment_info["amount_cents"],
          split_payment_info["txn_id"],
          payment.created_at.beginning_of_day - 1.day,
          split_payment_info["state"]
        )
        [index, split_payment_info["txn_id"], details]
      end

      still_pending = false
      payment.with_lock do
        return unless payment.processing?

        updates.each do |index, transaction_id, details|
          split_payment_info = payment.split_payments_info[index]
          next unless split_payment_info["state"] == "pending" && split_payment_info["txn_id"] == transaction_id

          previous_state = split_payment_info["state"]
          split_payment_info["state"] = details[:state]
          if details[:processor_fee_cents]
            PaypalPayoutProcessor.record_split_payment_processor_fee(
              payment,
              split_payment_info,
              details[:processor_fee_cents],
              previous_state:,
              legacy_accounted_fee_cents: details[:legacy_accounted_fee_cents]
            )
          end
          Rails.logger.info("UpdatePayoutStatusWorker set status for payment #{payment_id} to #{details[:state]}")
        end
        payment.save!

        still_pending = payment.split_payments_info.any? { |split_payment_info| split_payment_info["state"] == "pending" }
        PaypalPayoutProcessor.update_split_payment_state(payment) unless still_pending
      end
      raise "Some split payment parts are still in the 'pending' state" if still_pending
    else
      new_payment_state =
        PaypalPayoutProcessor.get_latest_payment_state_from_paypal(payment.amount_cents,
                                                                   payment.txn_id,
                                                                   payment.created_at.beginning_of_day - 1.day,
                                                                   payment.state)
      Rails.logger.info("UpdatePayoutStatusWorker set status for payment #{payment_id} to #{new_payment_state}")

      payment.mark!(new_payment_state)
    end
  end
end

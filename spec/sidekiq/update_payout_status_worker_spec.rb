# frozen_string_literal: true

describe UpdatePayoutStatusWorker do
  describe "#perform" do
    context "when the payout is not created in the split mode" do
      let(:payment) { create(:payment, processor_fee_cents: 10, txn_id: "Some ID") }

      it "fetches and sets the new payment status from PayPal" do
        expect(PaypalPayoutProcessor).to(
          receive(:get_latest_payment_state_from_paypal).with(payment.amount_cents,
                                                              payment.txn_id,
                                                              payment.created_at.beginning_of_day - 1.day,
                                                              payment.state).and_return("completed"))

        expect do
          described_class.new.perform(payment.id)
        end.to change { payment.reload.state }.from("processing").to("completed")
      end

      it "does not attempt to fetch or update the status for a payment not in the 'processing' state" do
        payment.mark_completed!

        expect(PaypalPayoutProcessor).not_to receive(:get_latest_payment_state_from_paypal)
        expect_any_instance_of(Payment).not_to receive(:mark!)

        described_class.new.perform(payment.id)
      end
    end

    context "when the payout is created in the split mode" do
      let(:payment) do
        # Payout was sent out
        payment = create(:payment, processor_fee_cents: 10)

        # IPN was received and one of the split parts was in the pending state
        payment.was_created_in_split_mode = true
        payment.split_payments_info = [
          { "unique_id" => "SPLIT_1-1", "state" => "completed", "correlation_id" => "fcf", "amount_cents" => 100, "processor_fee_cents" => 10, "errors" => [], "txn_id" => "02P" },
          { "unique_id" => "SPLIT_1-2", "state" => "pending", "correlation_id" => "6db", "amount_cents" => 50, "processor_fee_cents" => 0, "errors" => [], "txn_id" => "4LR" }
        ]
        payment.save!
        payment
      end

      it "fetches and sets the new payment status from PayPal" do
        expect(PaypalPayoutProcessor).to(
          receive(:get_latest_payment_details_from_paypal).with(50,
                                                                "4LR",
                                                                payment.created_at.beginning_of_day - 1.day,
                                                                "pending").and_return(
                                                                  state: "completed",
                                                                  processor_fee_cents: 20,
                                                                  legacy_accounted_fee_cents: 20
                                                                ))

        expect do
          described_class.new.perform(payment.id)
        end.to change { payment.reload.state }.from("processing").to("completed")
        expect(payment.processor_fee_cents).to eq 30
        expect(payment.split_payments_info[1]["processor_fee_cents"]).to eq 20
      end

      # Sidekiq will retry on exception
      it "raises an exception if the status fetched is 'pending'" do
        expect(PaypalPayoutProcessor).to(
          receive(:get_latest_payment_details_from_paypal).with(50,
                                                                "4LR",
                                                                payment.created_at.beginning_of_day - 1.day,
                                                                "pending").and_return(
                                                                  state: "pending",
                                                                  processor_fee_cents: nil,
                                                                  legacy_accounted_fee_cents: nil
                                                                ))

        expect do
          described_class.new.perform(payment.id)
        end.to raise_error("Some split payment parts are still in the 'pending' state")
      end

      it "keeps completed status and fee updates when another part remains pending" do
        payment.split_payments_info << {
          "unique_id" => "SPLIT_1-3",
          "state" => "pending",
          "amount_cents" => 25,
          "processor_fee_cents" => 0,
          "errors" => [],
          "txn_id" => "5ZZ"
        }
        payment.save!
        allow(PaypalPayoutProcessor).to receive(:get_latest_payment_details_from_paypal) do |_amount_cents, transaction_id, _start_date, state|
          if transaction_id == "4LR"
            { state: "completed", processor_fee_cents: 20, legacy_accounted_fee_cents: 20 }
          else
            { state:, processor_fee_cents: nil, legacy_accounted_fee_cents: nil }
          end
        end

        expect do
          described_class.new.perform(payment.id)
        end.to raise_error("Some split payment parts are still in the 'pending' state")

        expect(payment.reload.processor_fee_cents).to eq 30
        expect(payment.split_payments_info[1]["state"]).to eq "completed"
        expect(payment.split_payments_info[1]["processor_fee_cents"]).to eq 20
        expect(payment.split_payments_info[2]["state"]).to eq "pending"
      end

      it "does not overwrite an IPN received while PayPal status was being fetched" do
        payment.split_payments_info << {
          "unique_id" => "SPLIT_1-3",
          "state" => "pending",
          "correlation_id" => "7ec",
          "amount_cents" => 25,
          "processor_fee_cents" => 0,
          "errors" => [],
          "txn_id" => "5ZZ"
        }
        payment.save!

        allow(PaypalPayoutProcessor).to receive(:get_latest_payment_details_from_paypal) do |_amount_cents, transaction_id, _start_date, state|
          if transaction_id == "4LR"
            PaypalPayoutProcessor.handle_paypal_event(
              "masspay_txn_id_0" => "4LR",
              "status_0" => "Completed",
              "unique_id_0" => "#{PaypalPayoutProcessor::SPLIT_PAYMENT_UNIQUE_ID_PREFIX}#{payment.id}-2",
              "mc_fee_0" => "0.20"
            )
          end
          { state:, processor_fee_cents: nil, legacy_accounted_fee_cents: nil }
        end

        expect do
          described_class.new.perform(payment.id)
        end.to raise_error("Some split payment parts are still in the 'pending' state")

        expect(payment.reload.state).to eq "processing"
        expect(payment.processor_fee_cents).to eq 30
        expect(payment.split_payments_info[1]["state"]).to eq "completed"
        expect(payment.split_payments_info[1]["processor_fee_cents"]).to eq 20
      end

      it "does not attempt to fetch or update the status for a payment not in the 'processing' state" do
        payment.txn_id = "something"
        payment.mark_completed!

        expect(PaypalPayoutProcessor).not_to receive(:get_latest_payment_details_from_paypal)
        expect_any_instance_of(Payment).not_to receive(:mark_completed!)
        expect_any_instance_of(Payment).not_to receive(:mark_failed!)

        described_class.new.perform(payment.id)
      end
    end
  end
end

# frozen_string_literal: true

class Purchases::VariantsController < Sellers::BaseController
  before_action :set_purchase

  def update
    authorize [:audience, @purchase]

    updater = Purchase::VariantUpdaterService.new(
      purchase: @purchase,
      variant_id: params[:variant_id],
      quantity: params[:quantity],
    )
    success = updater.perform

    status = if success
      :no_content
    elsif updater.error == :invalid_quantity
      :unprocessable_entity
    else
      :not_found
    end
    head status
  end

  private
    def set_purchase
      @purchase = current_seller.sales.find_by_external_id(params[:purchase_id]) || e404_json
    end
end

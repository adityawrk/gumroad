# frozen_string_literal: true

# Refreshes product fields on purchase documents that predate ProductCallbacks tracking those fields.
#
#   Onetime::BackfillPurchaseProductSearchFields.process
module Onetime
  class BackfillPurchaseProductSearchFields
    SCROLL_SIZE = 5_000
    SCROLL_SORT = ["_doc"].freeze
    JOB_INTERVAL_SECONDS = 10
    FIELDS = %w[product_name product_description taxonomy_id].freeze

    def self.process
      new.process
    end

    def process
      response = EsClient.search(
        index: Purchase.index_name,
        scroll: "1m",
        body: { query: { match_all: {} } },
        size: SCROLL_SIZE,
        sort: SCROLL_SORT,
        _source: false,
      )

      seconds_offset = 0
      loop do
        hits = response.dig("hits", "hits") || []
        break if hits.empty?

        Sidekiq::Client.push_bulk(
          "class" => ElasticsearchIndexerWorker,
          "args" => hits.map { ["update", { "record_id" => _1["_id"].to_i, "class_name" => Purchase.name, "fields" => FIELDS }] },
          "queue" => "low",
          "at" => seconds_offset.seconds.from_now.to_i,
        )
        seconds_offset += JOB_INTERVAL_SECONDS

        response = EsClient.scroll(scroll_id: response["_scroll_id"], scroll: "1m")
      end
    ensure
      EsClient.clear_scroll(scroll_id: response["_scroll_id"]) if response&.dig("_scroll_id")
    end
  end
end

# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillPurchaseProductSearchFields do
  it "enqueues every existing purchase document in throttled low-priority batches" do
    now = Time.current
    first_response = {
      "_scroll_id" => "first-scroll",
      "hits" => { "hits" => [{ "_id" => "12" }, { "_id" => "34" }] },
    }
    second_response = {
      "_scroll_id" => "second-scroll",
      "hits" => { "hits" => [{ "_id" => "56" }] },
    }
    final_response = {
      "_scroll_id" => "final-scroll",
      "hits" => { "hits" => [] },
    }
    allow(EsClient).to receive(:search).and_return(first_response)
    allow(EsClient).to receive(:scroll).and_return(second_response, final_response)
    allow(EsClient).to receive(:clear_scroll)
    allow(Sidekiq::Client).to receive(:push_bulk)

    travel_to(now) { described_class.process }

    fields = %w[product_name product_description taxonomy_id]
    expect(Sidekiq::Client).to have_received(:push_bulk).with(
      "class" => ElasticsearchIndexerWorker,
      "args" => [
        ["update", { "record_id" => 12, "class_name" => "Purchase", "fields" => fields }],
        ["update", { "record_id" => 34, "class_name" => "Purchase", "fields" => fields }],
      ],
      "queue" => "low",
      "at" => now.to_i,
    ).ordered
    expect(Sidekiq::Client).to have_received(:push_bulk).with(
      "class" => ElasticsearchIndexerWorker,
      "args" => [["update", { "record_id" => 56, "class_name" => "Purchase", "fields" => fields }]],
      "queue" => "low",
      "at" => (now + 10.seconds).to_i,
    ).ordered
    expect(EsClient).to have_received(:search).with(
      index: Purchase.index_name,
      scroll: "1m",
      body: { query: { match_all: {} } },
      size: 5_000,
      sort: ["_doc"],
      _source: false,
    )
    expect(EsClient).to have_received(:scroll).with(scroll_id: "first-scroll", scroll: "1m").once
    expect(EsClient).to have_received(:scroll).with(scroll_id: "second-scroll", scroll: "1m").once
    expect(EsClient).to have_received(:clear_scroll).with(scroll_id: "final-scroll")
  end
end

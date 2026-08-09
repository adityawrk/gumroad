# frozen_string_literal: true

require "spec_helper"

describe ActiveRecord::ConnectionAdapters::MakaraMysql2Adapter do
  self.use_transactional_tests = false

  subject(:adapter) { described_class.allocate }

  let(:sql) { "SELECT email, min_created_at FROM audience_members ORDER BY min_created_at, id" }
  let(:query_options) { { stream: true, cache_rows: false, as: :array } }
  let(:result) { instance_double(Mysql2::Result, free: nil) }
  let(:client) { instance_double(Mysql2::Client) }
  let(:connection) do
    double(
      "Makara connection",
      raw_connection: client,
      _makara_blacklist!: nil,
    )
  end

  before do
    allow(connection).to receive(:log).and_yield
    allow(client).to receive(:query).with(sql, **query_options).and_return(result)
  end

  describe "#with_streaming_result" do
    it "routes stream setup as a SELECT before yielding the result" do
      expect(adapter).to receive(:appropriate_connection).once.with(:exec_query, [sql]).and_yield(connection)
      expect(client).to receive(:query).once.with(sql, **query_options).and_return(result)

      yielded_result = nil
      adapter.with_streaming_result(sql, "Audience Export", **query_options) do |stream|
        yielded_result = stream
      end

      expect(yielded_result).to be(result)
      expect(result).to have_received(:free).once
    end

    it "does not replay rows when fetching from an open stream fails" do
      selection_attempts = 0
      allow(adapter).to receive(:appropriate_connection) do |_, _, &setup|
        selection_attempts += 1
        setup.call(connection)
      rescue Mysql2::Error
        retry if selection_attempts < 2

        Kernel.raise
      end
      allow(result).to receive(:each) do |&block|
        block.call(["first@example.com", Time.utc(2025, 1, 1)])
        raise Mysql2::Error, "Lost connection while reading result"
      end
      rows = []

      expect do
        adapter.with_streaming_result(sql, **query_options) do |stream|
          stream.each { rows << _1 }
        end
      end.to raise_error(Mysql2::Error, "Lost connection while reading result")

      expect(rows.map(&:first)).to eq(["first@example.com"])
      expect(selection_attempts).to eq(1)
      expect(client).to have_received(:query).once
      expect(result).to have_received(:free).once
      expect(connection).to have_received(:_makara_blacklist!).once
    end

    it "can retry stream setup without writing rows twice" do
      failed_client = instance_double(Mysql2::Client)
      failed_connection = double("Failed Makara connection", raw_connection: failed_client)
      allow(failed_connection).to receive(:log).and_yield
      allow(failed_client).to receive(:query).and_raise(Mysql2::Error, "Connection refused")
      allow(adapter).to receive(:appropriate_connection) do |_, _, &setup|
        setup.call(failed_connection)
      rescue Mysql2::Error
        setup.call(connection)
      end
      rows = []
      allow(result).to receive(:each).and_yield(["only@example.com", Time.utc(2025, 1, 1)])

      adapter.with_streaming_result(sql, **query_options) do |stream|
        stream.each { rows << _1 }
      end

      expect(rows.map(&:first)).to eq(["only@example.com"])
      expect(failed_client).to have_received(:query).once
      expect(client).to have_received(:query).once
    end

    it "frees the result without blacklisting the connection when the writer fails" do
      allow(adapter).to receive(:appropriate_connection).and_yield(connection)

      expect do
        adapter.with_streaming_result(sql, **query_options) do
          raise "writer failed"
        end
      end.to raise_error(RuntimeError, "writer failed")

      expect(result).to have_received(:free).once
      expect(connection).not_to have_received(:_makara_blacklist!)
    end

    it "preserves the fetch error if freeing the stream also fails" do
      allow(adapter).to receive(:appropriate_connection).and_yield(connection)
      allow(result).to receive(:free).and_raise(Mysql2::Error, "Free failed")

      expect do
        adapter.with_streaming_result(sql, **query_options) do
          raise Mysql2::Error, "Fetch failed"
        end
      end.to raise_error(Mysql2::Error, "Fetch failed")

      expect(connection).to have_received(:_makara_blacklist!).once
    end
  end
end

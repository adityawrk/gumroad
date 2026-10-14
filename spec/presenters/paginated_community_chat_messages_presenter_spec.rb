# frozen_string_literal: true

require "spec_helper"

RSpec.describe PaginatedCommunityChatMessagesPresenter do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, community_chat_enabled: true) }
  let!(:community) { create(:community, seller:, resource: product) }
  let(:timestamp) { Time.current.iso8601 }

  describe "#initialize" do
    it "raises error when timestamp is missing" do
      expect { described_class.new(community:, timestamp: nil, fetch_type: "older") }
        .to raise_error(ArgumentError, "Invalid timestamp")
    end

    it "raises error when fetch_type is invalid" do
      expect { described_class.new(community:, timestamp:, fetch_type: "invalid") }
        .to raise_error(ArgumentError, "Invalid fetch type")
    end

    it "accepts valid fetch types" do
      expect { described_class.new(community:, timestamp:, fetch_type: "older") }.not_to raise_error
      expect { described_class.new(community:, timestamp:, fetch_type: "newer") }.not_to raise_error
      expect { described_class.new(community:, timestamp:, fetch_type: "around") }.not_to raise_error
    end
  end

  describe "#props" do
    subject(:props) { described_class.new(community:, timestamp:, fetch_type:).props }

    context "when fetching older messages" do
      let(:fetch_type) { "older" }
      let!(:message1) { create(:community_chat_message, community:, user: seller, created_at: 30.minutes.ago) }
      let!(:message2) { create(:community_chat_message, community:, user: seller, created_at: 20.minutes.ago) }
      let!(:message3) { create(:community_chat_message, community:, user: seller, created_at: 10.minutes.ago) }
      let(:timestamp) { 15.minutes.ago.iso8601 }

      it "returns messages older than timestamp" do
        expect(props[:messages]).to match_array(
          [CommunityChatMessagePresenter.new(message: message1).props,
           CommunityChatMessagePresenter.new(message: message2).props]
        )
        expect(props[:next_older_timestamp]).to be_nil
        expect(props[:next_newer_timestamp]).to eq(PaginatedCommunityChatMessagesPresenter.cursor_for(message3))
      end

      context "when there are more than MESSAGES_PER_PAGE older messages" do
        before do
          CommunityChatMessage.delete_all
        end
        let(:timestamp) { 1.minute.ago.iso8601 }
        let!(:older_messages) do
          (1..101).map do |i|
            create(:community_chat_message, community:, user: seller, created_at: (i + 10).minutes.ago)
          end
        end

        it "returns MESSAGES_PER_PAGE messages and next_older_timestamp" do
          expect(props[:messages].length).to eq(100)
          expect(props[:next_older_timestamp]).to eq(PaginatedCommunityChatMessagesPresenter.cursor_for(older_messages.last))
          expect(props[:next_newer_timestamp]).to be_nil
        end
      end
    end

    context "when fetching newer messages" do
      let(:fetch_type) { "newer" }
      let!(:message1) { create(:community_chat_message, community:, user: seller, created_at: 10.minutes.ago) }
      let!(:message2) { create(:community_chat_message, community:, user: seller, created_at: 20.minutes.ago) }
      let!(:message3) { create(:community_chat_message, community:, user: seller, created_at: 30.minutes.ago) }
      let(:timestamp) { 25.minutes.ago.iso8601 }

      it "returns messages newer than timestamp" do
        expect(props[:messages]).to match_array(
          [CommunityChatMessagePresenter.new(message: message1).props,
           CommunityChatMessagePresenter.new(message: message2).props]
        )
        expect(props[:next_older_timestamp]).to eq(PaginatedCommunityChatMessagesPresenter.cursor_for(message3))
        expect(props[:next_newer_timestamp]).to be_nil
      end

      context "when there are more than MESSAGES_PER_PAGE newer messages" do
        before do
          CommunityChatMessage.delete_all
        end
        let!(:newer_messages) do
          (1..101).map do |i|
            create(:community_chat_message, community:, user: seller, created_at: (i + 10).minutes.ago)
          end
        end
        let(:timestamp) { newer_messages.last.created_at.iso8601 }

        it "returns MESSAGES_PER_PAGE messages and next_newer_timestamp" do
          expect(props[:messages].length).to eq(100)
          expect(props[:next_newer_timestamp]).to eq(PaginatedCommunityChatMessagesPresenter.cursor_for(newer_messages.first))
          expect(props[:next_older_timestamp]).to be_nil
        end
      end
    end

    context "when fetching messages around timestamp" do
      let(:fetch_type) { "around" }
      let!(:messages) do
        total_messages = PaginatedCommunityChatMessagesPresenter::MESSAGES_PER_PAGE + 2
        (1..total_messages).map do |i|
          created_at = (i * 10).minutes.ago
          create(:community_chat_message, content: "#{total_messages + 1 - i}", community:, user: seller, created_at:)
        end
      end
      let(:timestamp) { (messages.find { |m| m.content == "52" }.created_at - 1.minute).iso8601 }

      it "returns equal number of older and newer messages" do
        expect(props[:messages].length).to eq(100)
        older_messages = messages.select { |m| m.content.to_i < 52 }
        newer_messages = messages.select { |m| m.content.to_i >= 52 }.reverse
        expect(props[:messages].map { |m| m[:content].to_i }.sort).to eq((older_messages.take(50) + newer_messages.take(50)).map(&:content).map(&:to_i).sort)
        expect(props[:next_older_timestamp]).to eq(PaginatedCommunityChatMessagesPresenter.cursor_for(older_messages.last))
        expect(props[:next_newer_timestamp]).to eq(PaginatedCommunityChatMessagesPresenter.cursor_for(newer_messages.last))
      end
    end

    context "when messages are deleted" do
      let(:fetch_type) { "older" }
      let!(:message1) { create(:community_chat_message, community:, user: seller, created_at: 3.minutes.ago) }
      let!(:message2) { create(:community_chat_message, community:, user: seller, created_at: 2.minutes.ago) }
      let!(:message3) { create(:community_chat_message, community:, user: seller, created_at: 1.minute.ago) }
      let(:timestamp) { message2.created_at.iso8601 }

      before { message1.update!(deleted_at: Time.current) }

      it "excludes deleted messages" do
        expect(props[:messages]).to be_empty
        expect(props[:next_older_timestamp]).to be_nil
        expect(props[:next_newer_timestamp]).to eq(PaginatedCommunityChatMessagesPresenter.cursor_for(message2))
      end
    end

    context "when messages share a database timestamp" do
      let(:same_timestamp) { Time.zone.local(2026, 8, 30, 12, 0, 0) }
      let!(:same_timestamp_messages) do
        create_list(:community_chat_message, 101, community:, user: seller, created_at: same_timestamp)
      end

      it "does not repeat same-second messages while paging newer messages" do
        first_page = described_class.new(community:, timestamp: same_timestamp.iso8601, fetch_type: "newer").props
        second_page = described_class.new(community:, timestamp: first_page[:next_newer_timestamp], fetch_type: "newer").props

        expect(first_page[:messages]).to have_attributes(size: 100)
        expect(second_page[:messages]).to have_attributes(size: 1)
        expect(second_page[:messages].map { |message| message[:id] } & first_page[:messages].map { |message| message[:id] }).to be_empty
      end

      it "does not repeat same-second messages while paging older messages" do
        first_page = described_class.new(community:, timestamp: same_timestamp.iso8601, fetch_type: "older").props
        second_page = described_class.new(community:, timestamp: first_page[:next_older_timestamp], fetch_type: "older").props

        expect(first_page[:messages]).to have_attributes(size: 100)
        expect(second_page[:messages]).to have_attributes(size: 1)
        expect(second_page[:messages].map { |message| message[:id] } & first_page[:messages].map { |message| message[:id] }).to be_empty
      end
    end
  end
end

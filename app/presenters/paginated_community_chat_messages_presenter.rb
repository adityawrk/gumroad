# frozen_string_literal: true

class PaginatedCommunityChatMessagesPresenter
  include Pagy::Backend

  MESSAGES_PER_PAGE = 100

  # `created_at` is stored at database timestamp precision, so it is not a unique
  # pagination key. Keep the existing timestamp in the cursor and add an obfuscated
  # message id to make the ordering total without exposing the database id.
  def self.cursor_for(message)
    message.created_at.to_fs(:usec) + "-" + ObfuscateIds.encrypt_numeric(message.id).to_s
  end

  def initialize(community:, timestamp:, fetch_type:)
    @community = community
    @timestamp = timestamp
    @fetch_type = fetch_type

    raise ArgumentError, "Invalid timestamp" unless timestamp.present?
    raise ArgumentError, "Invalid fetch type" unless %w[older newer around].include?(fetch_type)
  end

  def props
    base_query = community.community_chat_messages.alive.includes(:community, user: :avatar_attachment)
    messages, next_older_timestamp, next_newer_timestamp = fetch_messages(base_query)

    {
      messages: messages.map { |message| CommunityChatMessagePresenter.new(message:).props },
      next_older_timestamp:,
      next_newer_timestamp:
    }
  end

  private
    attr_reader :community, :timestamp, :fetch_type

    def fetch_messages(base_query)
      case fetch_type
      when "older"
        result = where_older_than(base_query, inclusive: true).order(created_at: :desc, id: :desc).limit(MESSAGES_PER_PAGE + 1).to_a
        messages = result.take(MESSAGES_PER_PAGE)
        next_older_timestamp = result.size > MESSAGES_PER_PAGE ? self.class.cursor_for(result.last) : nil
        next_newer_timestamp = where_newer_than(base_query, inclusive: false).order(created_at: :asc, id: :asc).limit(1).first&.then { self.class.cursor_for(_1) }

        [messages, next_older_timestamp, next_newer_timestamp]
      when "newer"
        result = where_newer_than(base_query, inclusive: true).order(created_at: :asc, id: :asc).limit(MESSAGES_PER_PAGE + 1).to_a
        messages = result.take(MESSAGES_PER_PAGE)
        next_older_timestamp = where_older_than(base_query, inclusive: false).order(created_at: :desc, id: :desc).limit(1).first&.then { self.class.cursor_for(_1) }
        next_newer_timestamp = result.size > MESSAGES_PER_PAGE ? self.class.cursor_for(result.last) : nil

        [messages, next_older_timestamp, next_newer_timestamp]
      when "around"
        half_per_page = MESSAGES_PER_PAGE / 2

        older = where_older_than(base_query, inclusive: false).order(created_at: :desc, id: :desc).limit(half_per_page + 1).to_a
        newer = where_newer_than(base_query, inclusive: true).order(created_at: :asc, id: :asc).limit(half_per_page + 1).to_a

        messages = older.take(half_per_page) + newer.take(half_per_page)
        next_older_timestamp = older.size > half_per_page ? self.class.cursor_for(older.last) : nil
        next_newer_timestamp = newer.size > half_per_page ? self.class.cursor_for(newer.last) : nil

        [messages.sort_by { |message| [message.created_at, message.id] }, next_older_timestamp, next_newer_timestamp]
      end
    end

    def where_older_than(query, inclusive:)
      created_at, message_id = decoded_cursor
      return query.where("created_at #{inclusive ? '<=' : '<'} ?", created_at) if message_id.nil?

      id_operator = inclusive ? "<=" : "<"
      query.where("(created_at < ?) OR (created_at = ? AND id #{id_operator} ?)", created_at, created_at, message_id)
    end

    def where_newer_than(query, inclusive:)
      created_at, message_id = decoded_cursor
      return query.where("created_at #{inclusive ? '>=' : '>'} ?", created_at) if message_id.nil?

      id_operator = inclusive ? ">=" : ">"
      query.where("(created_at > ?) OR (created_at = ? AND id #{id_operator} ?)", created_at, created_at, message_id)
    end

    def decoded_cursor
      @decoded_cursor ||= begin
        # Accept timestamp-only cursors issued before the id tie-breaker was added.
        if timestamp.to_s.match?(/\A\d{20}-\d+\z/)
          date_string, obfuscated_id = timestamp.to_s.split("-", 2)
          message_id = ObfuscateIds.decrypt_numeric(Integer(obfuscated_id))
          raise ArgumentError if message_id <= 0

          [Time.zone.parse(date_string.gsub(/(\d{6})\z/, '.\\1')), message_id]
        else
          [Time.zone.parse(timestamp.to_s), nil]
        end
      rescue ArgumentError, TypeError
        raise ArgumentError, "Invalid timestamp"
      end
    end
end

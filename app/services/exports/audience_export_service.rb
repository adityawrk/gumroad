# frozen_string_literal: true

class Exports::AudienceExportService
  FIELDS = ["Subscriber Email", "Subscribed Time"].freeze

  def initialize(user, options = {})
    @user = user
    @options = options.with_indifferent_access
    timestamp = Time.current.to_fs(:db).gsub(/ |:/, "-")
    @filename = "Subscribers-#{@user.username}_#{timestamp}.csv"

    validate_options!
  end

  attr_reader :filename, :tempfile

  def perform
    @tempfile = Tempfile.new(["Subscribers", ".csv"], encoding: "UTF-8")

    CsvSafe.open(@tempfile, "wb", headers: FIELDS, write_headers: true) do |csv|
      query = @user.audience_members.select(:id, :email, :min_created_at)

      conditions = []
      conditions << "follower = true" if @options[:followers]
      conditions << "customer = true" if @options[:customers]
      conditions << "affiliate = true" if @options[:affiliates]

      query = query.where(conditions.join(" OR "))

      write_rows_in_subscribed_order(csv, query)
    end

    @tempfile.rewind

    self
  end

  private
    def write_rows_in_subscribed_order(csv, query)
      ordered_query = query.reorder(:min_created_at, :id).reselect(:email, :min_created_at)

      # One streamed statement keeps membership and ordering stable while bounding application memory.
      result = AudienceMember.connection.raw_connection.query(ordered_query.to_sql, stream: true, cache_rows: false, as: :array)
      result.each { csv << _1 }
    ensure
      result&.free
    end

    def validate_options!
      unless @options[:followers] || @options[:customers] || @options[:affiliates]
        raise ArgumentError, "At least one audience type (followers, customers, or affiliates) must be selected"
      end
    end
end

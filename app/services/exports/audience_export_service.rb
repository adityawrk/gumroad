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

      # Open through Makara, then consume outside its retry scope so failover cannot replay rows.
      # One statement also keeps membership and ordering stable without loading every row in memory.
      AudienceMember.connection.with_streaming_result(
        ordered_query.to_sql,
        "Audience Export",
        stream: true,
        cache_rows: false,
        as: :array,
      ) do |result|
        result.each { csv << _1 }
      end
    end

    def validate_options!
      unless @options[:followers] || @options[:customers] || @options[:affiliates]
        raise ArgumentError, "At least one audience type (followers, customers, or affiliates) must be selected"
      end
    end
end

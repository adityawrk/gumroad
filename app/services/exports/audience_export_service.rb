# frozen_string_literal: true

class Exports::AudienceExportService
  FIELDS = ["Subscriber Email", "Subscribed Time"].freeze
  BATCH_SIZE = 1_000

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
      query.where(min_created_at: nil).find_each do |member|
        csv << [member.email, member.min_created_at]
      end

      last_created_at = nil
      last_id = nil

      loop do
        batch = query.where.not(min_created_at: nil)
        if last_created_at
          batch = batch.where(
            "min_created_at > ? OR (min_created_at = ? AND id > ?)",
            last_created_at,
            last_created_at,
            last_id,
          )
        end

        # find_each discards non-primary-key ordering, so page on the requested order explicitly.
        batch = batch.order(:min_created_at, :id).limit(BATCH_SIZE).to_a
        break if batch.empty?

        batch.each { csv << [_1.email, _1.min_created_at] }
        last_created_at = batch.last.min_created_at
        last_id = batch.last.id
      end
    end

    def validate_options!
      unless @options[:followers] || @options[:customers] || @options[:affiliates]
        raise ArgumentError, "At least one audience type (followers, customers, or affiliates) must be selected"
      end
    end
end

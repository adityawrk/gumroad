# frozen_string_literal: true

module Makara
  class ConnectionWrapper
    # Rails 7.0 compatibility, from: https://github.com/instacart/makara/pull/358
    # TODO: Remove this file after the makara gem is updated, including this PR.
    def execute(*args, **kwargs)
      SQL_REPLACE.each do |find, replace|
        if args[0] == find
          args[0] = replace
        end
      end

      _makara_connection.execute(*args, **kwargs)
    end
  end
end

class ActiveRecord::ConnectionAdapters::MakaraMysql2Adapter
  def with_streaming_result(sql, name = "SQL", **query_options)
    selected_connection = nil
    result = appropriate_connection(:exec_query, [sql]) do |connection|
      selected_connection = connection
      connection.send(:log, sql, name) do
        connection.raw_connection.query(sql, **query_options)
      end
    end

    stream_error = nil
    begin
      yield result
    rescue StandardError => error
      stream_error = error
      Kernel.raise
    ensure
      cleanup_streaming_result(result, selected_connection, stream_error)
    end
  end

  private
    def cleanup_streaming_result(result, connection, stream_error)
      cleanup_error = nil
      begin
        result&.free
      rescue StandardError => error
        cleanup_error = error
      end

      if stream_error.is_a?(Mysql2::Error) || cleanup_error.is_a?(Mysql2::Error)
        begin
          connection&._makara_blacklist!
        rescue StandardError => error
          cleanup_error ||= error
        end
      end

      Kernel.raise cleanup_error if cleanup_error && !stream_error
    end
end

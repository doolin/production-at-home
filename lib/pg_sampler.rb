#!/usr/bin/env ruby
# frozen_string_literal: true

require 'pg'
require 'net/http'
require 'uri'
require_relative 'pg_options'
require_relative 'influx_db_client'

# Minimal example of sampling PostgreSQL locks and writing to InfluxDB.
#
# Invoke ./exe/pg_sampler.rb to run it. It will write the influx query to
# stdout and continnuously scroll in the terminal. Could be redirected to
# /dev/null if desired. Could also be run in the background; the default
# duration of 300 seconds will ensure the script exits.
class PGSampler
  SLEEP_TIME = 0.25
  DURATION = 300
  INFLUXDB_OPTIONS = {
    host: 'localhost',
    port: 8086,
    bucket: 'ruby_test',
    org: 'inventium'
  }.freeze

  attr_reader :pg_options, :options

  def initialize(options)
    @options = options
    @pg_options = PG_OPTIONS
    @terminate = false
    @influx_client = InfluxDBClient.new(INFLUXDB_OPTIONS)
  end

  def influx_query
    'locks,mode=%<lock_modes>s lock_count=%<lock_counts>s %<current_time>s'
  end

  # There are a couple of ways to loop this. One is to loop outside
  # the connection, which will open a new connection for each loop.
  # Another is to loop inside the connection, which will keep the
  # connection open for the duration of the loop. The latter is
  # preferable for performance reasons. The connection is closed
  # automatically when the block exits. Which to use depends on what
  # we want to test.
  def run # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    stop_time = Time.now + duration
    PG::Connection.open(pg_options) do |conn|
      loop do
        break if @terminate
        break if Time.now > stop_time

        current_time = (Time.now.to_f * 1_000_000_000).to_i
        get_pg_locks(conn).each do |lock|
          payload = format(influx_query, lock_modes: lock['mode'], lock_counts: lock['lock_count'],
                                         current_time:)
          @influx_client.insert(payload)
        end
        sleep sleep_time
      end
    end
  rescue PG::Error => e
    puts "Unable to connect to PostgreSQL: #{e.message}"
  end

  def stop
    @terminate = true
  end

  private

  def sleep_time
    options[:sleep_time] || SLEEP_TIME
  end

  def duration
    options[:duration] || DURATION
  end

  def query
    <<-SQL
      SELECT
        pg_locks.mode,
        count(*) AS lock_count
      FROM
        pg_locks
      JOIN
        pg_stat_activity ON pg_locks.pid = pg_stat_activity.pid
      WHERE
        pg_stat_activity.datname = current_database()
      GROUP BY
        pg_locks.mode;
    SQL
  end

  def get_pg_locks(conn)
    conn.exec_params(query)
  rescue PG::Error => e
    puts "Failed to retrieve PostgreSQL locks: #{e.message}"
    []
  end
end

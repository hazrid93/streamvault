# frozen_string_literal: true

# Kick off the background cache warmer shortly after boot so the first
# real user visit hits a warm cache, then keep it warm on a timer.
#
# Uses detached Ruby Threads (the deployment runs a single web process
# with no separate SolidQueue worker — SOLID_QUEUE_IN_PUMA is unset, so
# recurring.yml tasks never actually execute.  An in-process Thread
# timer is the only mechanism that reliably runs here).
#
# Two loops:
#   1. Boot warm  — 10s after start, pre-warm cold cache once.
#   2. Refresher  — every REWARM_INTERVAL (6h), re-fetch stale entries
#      (catalogs + metadata older than 1 day) and warm metadata for any
#      newly-discovered titles.  Keeps the hot set fresh even when no
#      user is browsing to trigger the per-request stale-while-revalidate.
#
# Per-request stale-while-revalidate (in Cacheable) still handles
# refresh-on-visit for *any* title, including ones the warmer never
# pre-warms — the timer is purely a "keep popular content fresh in the
# background" optimization, not a requirement for correctness.
Rails.application.config.after_initialize do
  # Only warm in the web server process (not in rails console, assets
  # precompilation, migrations, or rake tasks), and only when explicitly
  # enabled (default on) so it can be disabled for one-off runs.
  if ENV["DISABLE_CACHE_WARMER"] != "true" &&
     defined?(Rails::Server) && Rails.application.config.cache_classes
    # Boot warm.
    Thread.new do
      sleep 10
      begin
        Rails.logger.info("[CacheWarmer] starting background cache pre-warm")
        CacheWarmer.new.warm_all
        Rails.logger.info("[CacheWarmer] background cache pre-warm complete")
      rescue => e
        Rails.logger.error("[CacheWarmer] pre-warm failed: #{e.message}")
      end
    end

    # Periodic re-warm loop.  A separate long-lived thread sleeps between
    # runs; each run re-fetches stale entries and discovers new titles.
    Thread.new do
      loop do
        sleep CacheWarmer::REWARM_INTERVAL
        begin
          Rails.logger.info("[CacheWarmer] starting periodic re-warm")
          CacheWarmer.new.warm_all
          Rails.logger.info("[CacheWarmer] periodic re-warm complete")
        rescue => e
          Rails.logger.error("[CacheWarmer] periodic re-warm failed: #{e.message}")
        end
      end
    end
  end
end
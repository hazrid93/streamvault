# frozen_string_literal: true

# Background cache pre-warmer.  On app boot (and periodically), crawls a
# bounded set of high-traffic content into the ApiCache table so the
# first real user visit is instant instead of blocking on upstream APIs.
#
# Scope (kept deliberately small to limit upstream load):
#   - top 100 popular movies + top 100 popular series (cinemeta "top")
#   - top 50 new releases per current year (cinemeta "year")
#   - title metadata for each of the above titles
#
# Stream listings are NOT pre-warmed here — they are per-RealDebrid-account
# (the RD key is embedded in the request), so they're cached on first play
# per user with stale-while-revalidate instead.
class CacheWarmerJob < ApplicationJob
  queue_as :default
  queue_with_priority 50

  # Discard duplicate boot/recurring executions while one warmer is active.
  # This is database-backed by Solid Queue and remains correct if Puma gains
  # more workers or another web container is added later.
  limits_concurrency to: 1,
    key: ->(*) { "global" },
    duration: 1.hour,
    on_conflict: :discard

  def perform(periodic = true)
    return if ENV["DISABLE_CACHE_WARMER"] == "true"

    label = periodic ? "periodic re-warm" : "background cache pre-warm"
    Rails.logger.info("[CacheWarmer] starting #{label}")
    CacheWarmer.new.warm_all_with_status(periodic: periodic)
    Rails.logger.info("[CacheWarmer] #{label} complete")
  rescue StandardError => error
    Rails.logger.error("[CacheWarmer] #{label} failed: #{error.message}")
    raise
  end
end

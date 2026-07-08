# frozen_string_literal: true

# Background cache pre-warmer.  On app boot (and periodically), crawls a
# bounded set of high-traffic content into the ApiCache table so the
# first real user visit is instant instead of blocking on upstream APIs.
#
# Scope (kept deliberately small to limit upstream load):
#   - top 100 popular movies + top 100 popular series (cinemeta "top")
#   - top 100 new releases per current year (cinemeta "year")
#   - title metadata for each of the above titles
#
# Stream listings are NOT pre-warmed here — they are per-RealDebrid-account
# (the RD key is embedded in the request), so they're cached on first play
# per user with stale-while-revalidate instead.
class CacheWarmerJob < ApplicationJob
  queue_as :default

  # How many catalog items to warm per (type, catalog, year) slice.
  WARM_LIMIT = 100

  def perform
    warmer = CacheWarmer.new
    warmer.warm_all
  end
end
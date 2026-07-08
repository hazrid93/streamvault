# frozen_string_literal: true

# Pre-warms and refreshes the ApiCache table for high-traffic content.
# Called on boot and every REWARM_INTERVAL by the cache_warmer initializer.
# All work is wrapped so one failing slice never aborts the rest.
#
# Crawl scope (bounded to limit upstream load):
#   - popular: top 100 movies + top 100 series (cinemeta "top", 2 pages)
#   - new releases: top 100 for the current year (cinemeta "year")
#   - title metadata for every title surfaced above
#
# This warmer BYPASSES the cache-read path (it calls the *_uncached
# fetchers directly and upserts), so a periodic re-warm actually refreshes
# entries instead of short-circuiting on the fresh cache it just built.
# The advisory lock in Cacheable still applies to per-request refreshes;
# here we upsert directly (idempotent), so no lock is needed.
#
# Stream listings are per-RealDebrid-account, so they are NOT warmed
# here — they cache on first play per user via stale-while-revalidate.
class CacheWarmer
  PAGE_SIZE = TorrentioService::CATALOG_PAGE_SIZE

  # How often the periodic re-warm loop runs.  Entries are considered
  # stale after ApiCache::FRESH_TTL (1 day), so re-warming every 3 hours
  # keeps the hot set fresh well before staleness kicks in, re-fetches
  # existing entries (re-check), and catches new popular/new-release
  # titles promptly as catalogs shift.
  REWARM_INTERVAL = 3.hours

  # Reserved ApiCache key holding the warmer's status document (shared
  # across all Puma workers/processes — in-memory state isn't visible
  # cross-process).  Updated on every warm event.
  STATUS_KEY = "internal:warmer:status"

  # Read the persisted status (boot + periodic).  Returns nil if the
  # warmer hasn't run yet this boot.
  def self.status
    rec = ApiCache.find_by(key: STATUS_KEY)
    rec&.payload&.deep_symbolize_keys || default_status
  end

  def self.default_status
    {
      boot:     { state: :pending, started_at: nil, finished_at: nil, duration_ms: nil, error: nil, updated_at: nil },
      periodic: { state: :idle, last_started_at: nil, last_finished_at: nil, duration_ms: nil,
                  next_run_at: nil, runs: 0, error: nil, updated_at: nil }
    }
  end

  # Merge + persist a partial status update atomically.
  def self.update_status(boot: nil, periodic: nil)
    current = status
    current[:boot] = current[:boot].merge(boot) if boot
    current[:periodic] = current[:periodic].merge(periodic) if periodic
    now = Time.current
    current[:boot][:updated_at] = now if boot
    current[:periodic][:updated_at] = now if periodic
    ApiCache.upsert(STATUS_KEY, current.deep_stringify_keys)
  end

  def initialize
    @service = TorrentioService.new
  end

  def warm_all
    warm_catalogs
    warm_metadata_for_cached_titles
  end

  # Instrumented wrapper used by the initializer so the status registry
  # captures timing.  warm_all itself stays silent for ad-hoc console use.
  def warm_all_with_status(periodic: false)
    t0 = Time.current
    if periodic
      CacheWarmer.update_status(periodic: { state: :running, last_started_at: t0, error: nil })
    else
      CacheWarmer.update_status(boot: { state: :running, started_at: t0, error: nil })
    end
    warm_all
    ms = ((Time.current - t0) * 1000).round
    if periodic
      CacheWarmer.update_status(periodic: { state: :idle, last_finished_at: Time.current,
                                            duration_ms: ms, runs: CacheWarmer.status[:periodic][:runs].to_i + 1,
                                            next_run_at: Time.current + REWARM_INTERVAL })
    else
      CacheWarmer.update_status(boot: { state: :complete, finished_at: Time.current, duration_ms: ms })
    end
  rescue => e
    if periodic
      CacheWarmer.update_status(periodic: { state: :failed, last_finished_at: Time.current, error: e.message,
                                            next_run_at: Time.current + REWARM_INTERVAL })
    else
      CacheWarmer.update_status(boot: { state: :failed, finished_at: Time.current, error: e.message })
    end
    raise
  end

  private

  # Warm the catalog pages (popular + new releases) for both types.
  # Calls the uncached fetcher + upserts directly so a re-warm refreshes
  # the entry instead of reading the fresh cache and no-opping.
  def warm_catalogs
    this_year = Date.today.year

    %w[movie show].each do |type|
      cinemeta_type = type == "show" ? "series" : type

      # Popular: 2 pages × PAGE_SIZE ≈ top 100.
      2.times do |i|
        skip = i * PAGE_SIZE
        key = "cinemeta:catalog/#{cinemeta_type}/top///#{PAGE_SIZE}"
        warm_slice(key) do
          path = @service.build_catalog_path(cinemeta_type, "top", nil, skip)
          @service.fetch_catalog_uncached(path, type, PAGE_SIZE)
        end
      end

      # New releases for the current year (1 page ≈ top 100 by recency).
      key = "cinemeta:catalog/#{cinemeta_type}/year/#{this_year}//#{PAGE_SIZE}"
      warm_slice(key) do
        path = @service.build_catalog_path(cinemeta_type, "year", this_year.to_s, nil)
        @service.fetch_catalog_uncached(path, type, PAGE_SIZE)
      end
    end
  end

  # Walk every cached catalog page and warm/refresh title metadata for
  # each imdb_id it references.
  def warm_metadata_for_cached_titles
    imdb_ids = collect_imdb_ids_from_catalogs
    Rails.logger.info("[CacheWarmer] warming metadata for #{imdb_ids.size} titles")

    imdb_ids.each do |imdb_id, type|
      cinemeta_type = type == "show" ? "series" : type
      key = "cinemeta:meta:#{cinemeta_type}/#{imdb_id}"
      warm_slice(key) do
        @service.fetch_metadata_uncached(imdb_id, type)
      end
    end
  end

  # Scan cached catalog payloads for imdb_ids and their content type.
  def collect_imdb_ids_from_catalogs
    seen = {}
    ApiCache.where("key LIKE ?", "cinemeta:catalog/%").find_each do |record|
      payload = record.payload
      next unless payload.is_a?(Array)
      payload.each do |item|
        id = item["imdb_id"]
        seen[id] = item["type"] if id.present?
      end
    end
    seen
  end

  # Fetch + upsert one slice, isolating failures.  nil payloads (fetch
  # errors) are intentionally not stored so a transient outage doesn't
  # clobber a previously-good cache entry with an empty/error result.
  def warm_slice(key)
    payload = yield
    ApiCache.upsert(key, payload) unless payload.nil?
  rescue StandardError => e
    Rails.logger.error("[CacheWarmer] slice failed for #{key}: #{e.message}")
  end
end
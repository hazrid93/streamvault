# frozen_string_literal: true

# Pre-warms and refreshes the ApiCache table for high-traffic content.
# Called on boot and every REWARM_INTERVAL by CacheWarmerJob/Solid Queue.
# All work is wrapped so one failing slice never aborts the rest.
#
# Crawl scope (bounded to limit upstream load):
#   - popular: top 100 movies + top 100 series (cinemeta "top", 2 pages)
#   - new releases: top 50 for the current year (cinemeta "year")
#   - title metadata for the unique titles fetched in this run
#
# Catalog polling bypasses the cache-read path so periodic runs discover
# newly popular releases. Metadata uses its one-day freshness window and only
# calls the uncached fetcher for missing/stale titles.
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

  # The single bounded catalog definition shared by metadata warming,
  # account stream prefetch, and dashboard coverage. Keeping these slices in
  # one place prevents search/history catalog rows from expanding the crawl.
  def self.catalog_slices(year: Date.current.year)
    %w[movie show].flat_map do |type|
      cinemeta_type = type == "show" ? "series" : type
      [ nil, PAGE_SIZE ].map do |skip|
        {
          type: type,
          cinemeta_type: cinemeta_type,
          catalog_id: "top",
          genre: nil,
          skip: skip,
          key: "cinemeta:catalog/#{cinemeta_type}/top//#{skip}/#{PAGE_SIZE}"
        }
      end + [ {
        type: type,
        cinemeta_type: cinemeta_type,
        catalog_id: "year",
        genre: year.to_s,
        skip: nil,
        key: "cinemeta:catalog/#{cinemeta_type}/year/#{year}//#{PAGE_SIZE}"
      } ]
    end
  end

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
    titles = warm_catalogs
    warm_metadata_for_titles(titles)
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
    titles = {}

    self.class.catalog_slices.each do |slice|
      payload = warm_slice(slice[:key]) do
        path = @service.build_catalog_path(
          slice[:cinemeta_type], slice[:catalog_id], slice[:genre], slice[:skip]
        )
        @service.fetch_catalog_uncached(path, slice[:type], PAGE_SIZE)
      end
      collect_titles!(titles, payload)
    end

    titles
  end

  # Warm only titles from the six bounded catalog slices fetched in this
  # run. Scanning every historical/search catalog row made upstream work
  # grow forever as users browsed new filters.
  def warm_metadata_for_titles(titles)
    Rails.logger.info("[CacheWarmer] warming metadata for #{titles.size} titles")

    titles.each do |imdb_id, type|
      cinemeta_type = type == "show" ? "series" : type
      key = "cinemeta:meta:#{cinemeta_type}/#{imdb_id}"
      # Catalogs are polled every three hours to discover movement, but title
      # metadata has a one-day TTL. Avoid re-fetching hundreds of still-fresh
      # records on every catalog poll.
      next if ApiCache.find_by(key: key)&.fresh?(TorrentioService::METADATA_CACHE_TTL)

      warm_slice(key) { @service.fetch_metadata_uncached(imdb_id, type) }
    end
  end

  def collect_titles!(titles, payload)
    Array(payload).each do |item|
      imdb_id = item["imdb_id"] || item[:imdb_id]
      type = item["type"] || item[:type]
      next unless imdb_id.to_s.match?(/\Att\d+\z/) && type.to_s.in?(%w[movie show])

      titles[imdb_id] = type
    end
  end

  # Fetch + upsert one slice, isolating failures.  nil payloads (fetch
  # errors) are intentionally not stored so a transient outage doesn't
  # clobber a previously-good cache entry with an empty/error result.
  def warm_slice(key)
    payload = yield
    # The uncached catalog fetcher returns [] on upstream failure. Never let
    # a transient outage replace a previously-good hot entry with emptiness.
    return nil if payload.blank?

    ApiCache.upsert(key, payload)
    payload
  rescue StandardError => e
    Rails.logger.error("[CacheWarmer] slice failed for #{key}: #{e.message}")
    nil
  end
end

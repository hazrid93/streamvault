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

  # ---- In-process status registry (read by CacheStatusController) ----
  # Single web process, so a class-level hash guarded by a mutex is
  # sufficient.  Survives across requests; lost on restart (intended).
  @status = {
    boot:     { state: :pending, started_at: nil, finished_at: nil, duration_ms: nil, error: nil },
    periodic: { state: :idle, last_started_at: nil, last_finished_at: nil, duration_ms: nil,
                next_run_at: nil, runs: 0, error: nil }
  }
  @status_mutex = Mutex.new
  @boot_thread = nil
  @periodic_thread = nil

  class << self
    def status
      @status_mutex.synchronize { @status.deep_dup }
    end

    def threads_alive?
      @status_mutex.synchronize do
        { boot: @boot_thread&.alive?, periodic: @periodic_thread&.alive? }
      end
    end

    def register_boot_thread(t)
      @status_mutex.synchronize { @boot_thread = t }
    end

    def register_periodic_thread(t)
      @status_mutex.synchronize { @periodic_thread = t }
    end

    def record_boot_start
      @status_mutex.synchronize do
        @status[:boot] = { state: :running, started_at: Time.current,
                           finished_at: nil, duration_ms: nil, error: nil }
      end
    end

    def record_boot_finish(duration_ms)
      @status_mutex.synchronize do
        @status[:boot].merge!(state: :complete, finished_at: Time.current, duration_ms: duration_ms, error: nil)
      end
    end

    def record_boot_error(msg)
      @status_mutex.synchronize do
        @status[:boot].merge!(state: :failed, finished_at: Time.current, error: msg)
      end
    end

    def record_periodic_start
      @status_mutex.synchronize do
        s = @status[:periodic]
        s[:state] = :running
        s[:last_started_at] = Time.current
        s[:error] = nil
      end
    end

    def record_periodic_finish(duration_ms)
      @status_mutex.synchronize do
        s = @status[:periodic]
        s.merge!(state: :idle, last_finished_at: Time.current, duration_ms: duration_ms,
                 runs: s[:runs].to_i + 1, next_run_at: Time.current + REWARM_INTERVAL)
      end
    end

    def record_periodic_error(msg)
      @status_mutex.synchronize do
        s = @status[:periodic]
        s.merge!(state: :idle, last_finished_at: Time.current, error: msg,
                 next_run_at: Time.current + REWARM_INTERVAL)
      end
    end
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
      self.class.record_periodic_start
    else
      self.class.record_boot_start
    end
    warm_all
    ms = ((Time.current - t0) * 1000).round
    if periodic
      self.class.record_periodic_finish(ms)
    else
      self.class.record_boot_finish(ms)
    end
  rescue => e
    if periodic
      self.class.record_periodic_error(e.message)
    else
      self.class.record_boot_error(e.message)
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
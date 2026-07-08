# frozen_string_literal: true

# Stale-while-revalidate caching for external API calls, backed by the
# ApiCache table.  Mix into a service that makes upstream HTTP calls.
#
#   include Cacheable
#   def metadata(id)
#     cached_fetch("cinemeta:meta:#{id}", ttl: 1.day) do
#       # ... upstream fetch, return parsed data (or nil to skip caching)
#     end
#   end
#
# Behaviour:
#   - missing  → call block synchronously, store, return (first visit blocks)
#   - fresh    → return cached payload instantly
#   - stale    → return cached payload instantly + refresh in background
#
# Background refreshes use a detached Ruby Thread (the app runs a single
# web process with no separate SolidQueue worker, matching the existing
# Thread.new pattern in HomeController).  An advisory lock
# (ApiCache.claim_refresh_lock) prevents duplicate refreshes for the
# same key.  Threads are wrapped so a failure never crashes the app.
module Cacheable
  extend ActiveSupport::Concern

  # Fetch + cache with stale-while-revalidate semantics.
  # Returns the cached/fetched payload (whatever the block returns),
  # or nil on a cache miss where the block returned nil (failures are
  # not cached so a transient outage doesn't stick).
  def cached_fetch(key, ttl: ApiCache::FRESH_TTL)
    record = ApiCache.find_by(key: key)

    if record&.payload.present?
      if record.fresh?(ttl)
        # Fresh — serve instantly.  JSONB deserialises with string keys,
        # but every consumer (views, services) expects symbol keys, so
        # deep-symbolise on read.
        return deep_symbolize(record.payload)
      else
        # Stale — serve the stale payload now, refresh in the background
        # so the next request sees fresh data.
        schedule_background_refresh(key) { yield }
        return deep_symbolize(record.payload)
      end
    end

    # Cache miss — fetch synchronously (this blocks the first request,
    # building the cache for everyone after).
    payload = yield
    ApiCache.upsert(key, payload) unless payload.nil?
    payload
  end

  private

  # Recursively convert string keys to symbols for Hashes and Arrays of
  # Hashes, so DB-deserialised JSONB payloads match the symbol-keyed
  # shape that in-memory fetches return (and that views/services expect).
  def deep_symbolize(obj)
    case obj
    when Hash then obj.deep_symbolize_keys
    when Array then obj.map { |e| deep_symbolize(e) }
    else obj
    end
  end

  # Spawn a detached Thread to refresh a stale cache entry, guarded by
  # an advisory lock so concurrent requests don't all re-fetch.
  def schedule_background_refresh(key)
    # Only one refresh wins the lock; others no-op.
    return unless ApiCache.claim_refresh_lock(key)

    Thread.new do
      # Reconnect AR's connection (threads don't inherit the pool's
      # checked-out connection) and ensure it's checked back in.
      ActiveRecord::Base.connection_pool.with_connection do
        begin
          payload = yield
          ApiCache.upsert(key, payload) unless payload.nil?
        rescue => e
          Rails.logger.error("[Cacheable] background refresh failed for #{key}: #{e.message}")
          ApiCache.release_refresh_lock(key, error: e.message)
          raise
        end
      end
    rescue => e
      Rails.logger.error("[Cacheable] refresh thread error for #{key}: #{e.message}")
    ensure
      ApiCache.release_refresh_lock(key)
    end
  end
end
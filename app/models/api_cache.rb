# frozen_string_literal: true

# Persistent API response cache record.  See CreateApiCaches migration
# for the stale-while-revalidate strategy.
#
# The `fetching` flag is an advisory lock set atomically (via update_all)
# before a background refresh runs, so concurrent requests for the same
# stale key don't all spawn duplicate refreshes (thundering herd).
class ApiCache < ApplicationRecord
  # Default freshness window.  A record whose cached_at is within this
  # window is served directly; older records are served stale while a
  # background refresh runs.
  FRESH_TTL = 1.day

  validates :key, presence: true, uniqueness: true

  # True when this record's cached_at is within +ttl+ of now.
  def fresh?(ttl = FRESH_TTL)
    cached_at.present? && cached_at > ttl.ago
  end

  # Insert or update a cache entry in one round-trip.  Clears the
  # advisory lock and any prior error.
  def self.upsert(key, payload)
    now = Time.current
    record = find_or_initialize_by(key: key)
    record.payload = payload
    record.cached_at = now
    record.fetching = false
    record.fetch_error = nil
    record.save!
    record
  end

  # Atomically claim the refresh lock for a record so only one thread
  # performs the background fetch.  Returns true if this caller won the
  # lock.  Uses update_all (a single UPDATE ... WHERE) for atomicity —
  # a plain find+save would race between threads.
  def self.claim_refresh_lock(key)
    return false unless key.present?
    now = Time.current
    # Claim only if not already claimed.  Stale locks older than the
    # fresh TTL are also reclaimed (a crashed refresh shouldn't block
    # the next one forever).
    updated = where(key: key)
      .where("fetching = ? OR cached_at < ?", false, ApiCache::FRESH_TTL.ago)
      .update_all(fetching: true, updated_at: now)
    updated.positive?
  end

  # Release the refresh lock, optionally recording an error.
  def self.release_refresh_lock(key, error: nil)
    where(key: key).update_all(fetching: false, fetch_error: error, updated_at: Time.current)
  end
end
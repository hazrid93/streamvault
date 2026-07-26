# frozen_string_literal: true

# Warms account-scoped movie stream listings outside Puma request threads.
# enqueue_for atomically claims a user's daily warm window before enqueueing,
# preventing Home and Content requests from starting duplicate full crawls.
class StreamPrefetchJob < ApplicationJob
  queue_as :default
  queue_with_priority 50

  limits_concurrency to: 1,
    key: ->(user_id) { user_id },
    duration: 2.hours,
    on_conflict: :discard

  def self.enqueue_for(user)
    return false unless user&.has_realdebrid_key?

    claimed_at = Time.current
    claimed = user.with_lock do
      user.reload
      next false if user.streams_warmed_at.present? && user.streams_warmed_at > ApiCache::FRESH_TTL.ago

      user.update_column(:streams_warmed_at, claimed_at)
      true
    end
    return false unless claimed

    perform_later(user.id)
    true
  rescue StandardError => error
    User.where(id: user&.id, streams_warmed_at: claimed_at).update_all(streams_warmed_at: nil) if claimed_at
    Rails.logger.error("[StreamPrefetchJob] enqueue failed: #{error.message}")
    false
  end

  def perform(user_id)
    user = User.find_by(id: user_id)
    unless user&.has_realdebrid_key?
      User.where(id: user_id).update_all(streams_warmed_at: nil)
      return
    end

    success = StreamPrefetcher.new(
      rd_api_key: user.realdebrid_api_key,
      preferred_languages: user.preferred_stream_languages,
      default_language: user.default_stream_language
    ).warm_all

    if success
      user.update_column(:streams_warmed_at, Time.current)
    else
      user.update_column(:streams_warmed_at, nil)
    end
  rescue StandardError
    User.where(id: user_id).update_all(streams_warmed_at: nil)
    raise
  end
end

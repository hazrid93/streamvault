# frozen_string_literal: true

class LocalPlaybackCleanupJob < ApplicationJob
  queue_as :default

  def perform
    CastSession.stale.find_each do |session|
      session.finish!(state: "expired")
    rescue StandardError => error
      Rails.logger.warn("[CastCleanup] #{session.id}: #{error.class}: #{error.message}")
    end

    LocalTorrentService.new.cleanup!
  end
end

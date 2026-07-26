# frozen_string_literal: true

class CastSession < ApplicationRecord
  TTL = ENV.fetch("CAST_SESSION_TTL_SECONDS", 21_600).to_i.clamp(1_800, 43_200).seconds
  STALE_AFTER = ENV.fetch("CAST_SESSION_STALE_SECONDS", 1800).to_i.clamp(300, 3600).seconds

  belongs_to :user
  belongs_to :local_torrent_lease, optional: true

  validates :hls_session_id, presence: true, uniqueness: true
  validates :state, inclusion: { in: %w[active ended expired] }

  scope :active, -> { where(state: "active") }
  scope :stale, -> { active.where(last_heartbeat_at: ...STALE_AFTER.ago) }

  def heartbeat!
    update_columns(last_heartbeat_at: Time.current, expires_at: TTL.from_now)
    local_torrent_lease&.heartbeat!
  end

  def finish!(state: "ended")
    transaction do
      update!(state: state)
      local_torrent_lease&.release!
    end
    HlsSession.stop(hls_session_id)
  end
end

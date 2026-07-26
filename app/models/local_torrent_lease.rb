# frozen_string_literal: true

class LocalTorrentLease < ApplicationRecord
  HEARTBEAT_TIMEOUT = ENV.fetch("LOCAL_TORRENT_HEARTBEAT_TIMEOUT", 600).to_i.clamp(30, 900).seconds

  belongs_to :user, optional: true
  has_one :cast_session, dependent: :nullify

  validates :lease_token, presence: true, uniqueness: true
  validates :info_hash, format: { with: /\A[0-9a-f]{40}\z/i }
  validates :kind, inclusion: { in: %w[browser cast] }

  scope :active, -> { where(released_at: nil) }
  scope :stale, -> { active.where(last_heartbeat_at: ...HEARTBEAT_TIMEOUT.ago) }

  def heartbeat!
    update_column(:last_heartbeat_at, Time.current)
  end

  def release!
    update_column(:released_at, Time.current) unless released_at?
  end
end

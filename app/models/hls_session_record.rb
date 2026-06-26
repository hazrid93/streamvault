# frozen_string_literal: true

class HlsSessionRecord < ApplicationRecord
  self.table_name = "hls_sessions"

  belongs_to :user

  validates :session_id, presence: true, uniqueness: true
  validates :segment_dir, presence: true

  def playlist_path
    File.join(segment_dir, "playlist.m3u8")
  end

  def segment_path(index)
    File.join(segment_dir, "#{index}.ts")
  end
end

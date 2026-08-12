# frozen_string_literal: true

class AddStreamIdentityToProgress < ActiveRecord::Migration[8.0]
  def change
    %i[watch_history_entries episode_progresses].each do |table|
      add_column table, :stream_source, :string
      # BitTorrent v1 uses 40 hex characters; v2/hybrid releases may expose
      # the 64-character SHA-256 identity even when local playback cannot
      # consume that release directly.
      add_column table, :torrent_info_hash, :string, limit: 64
      add_column table, :torrent_file_idx, :integer
      add_index table, :torrent_info_hash
    end
  end
end

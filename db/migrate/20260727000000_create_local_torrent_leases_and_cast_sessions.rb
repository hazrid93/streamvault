# frozen_string_literal: true

class CreateLocalTorrentLeasesAndCastSessions < ActiveRecord::Migration[8.0]
  def change
    create_table :local_torrent_leases do |table|
      table.references :user, null: true, foreign_key: true
      table.string :lease_token, null: false
      table.string :info_hash, null: false, limit: 40
      table.integer :file_idx
      table.string :filename
      table.string :title
      table.string :kind, null: false, default: "browser"
      table.datetime :last_heartbeat_at, null: false
      table.datetime :released_at
      table.timestamps
    end
    add_index :local_torrent_leases, :lease_token, unique: true
    add_index :local_torrent_leases, %i[info_hash released_at]
    add_index :local_torrent_leases, :last_heartbeat_at

    create_table :cast_sessions do |table|
      table.references :user, null: false, foreign_key: true
      table.references :local_torrent_lease, null: true, foreign_key: true
      table.string :hls_session_id, null: false
      table.string :state, null: false, default: "active"
      table.string :title
      table.string :poster_url
      table.string :device_name
      table.integer :position_seconds, null: false, default: 0
      table.datetime :last_heartbeat_at, null: false
      table.datetime :expires_at, null: false
      table.timestamps
    end
    add_index :cast_sessions, :hls_session_id, unique: true
    add_index :cast_sessions, %i[state expires_at]
    add_index :cast_sessions, :last_heartbeat_at
  end
end

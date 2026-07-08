# frozen_string_literal: true

# Persistent, DB-backed API response cache.  Implements a
# stale-while-revalidate strategy: a fresh record (< its TTL) is served
# instantly; a stale record is served instantly *and* refreshed in the
# background; a missing record is fetched synchronously and stored.
#
# This survives process restarts (unlike Rails.cache) and is shared
# across all workers/threads, so the boot crawler and per-request
# refreshes benefit everyone.
class CreateApiCaches < ActiveRecord::Migration[7.2]
  def change
    create_table :api_caches do |t|
      t.string :key, null: false
      t.jsonb :payload, null: false, default: {}
      t.datetime :cached_at, null: false
      t.boolean :fetching, default: false, null: false
      t.string :fetch_error
      t.timestamps
    end

    add_index :api_caches, :key, unique: true
    add_index :api_caches, :cached_at
  end
end
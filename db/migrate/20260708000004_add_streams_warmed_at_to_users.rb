# frozen_string_literal: true

# Track when each user's per-account stream cache was last warmed, so the
# full StreamPrefetcher runs once per account (not on every Home load).
class AddStreamsWarmedAtToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :streams_warmed_at, :datetime
  end
end
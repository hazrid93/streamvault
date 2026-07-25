# frozen_string_literal: true

class AddStreamingPreferenceToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :streaming_preference, :string, null: false, default: "automatic"
  end
end

# frozen_string_literal: true

class CreateListsAndListItems < ActiveRecord::Migration[7.2]
  def change
    create_table :lists do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false

      t.timestamps
    end

    add_index :lists, [:user_id, :name], unique: true

    create_table :list_items do |t|
      t.references :list, null: false, foreign_key: { on_delete: :cascade }
      t.string :imdb_id, null: false
      t.string :title, null: false
      t.string :poster_url
      t.integer :year
      t.integer :content_type, default: 0, null: false

      t.timestamps
    end

    add_index :list_items, [:list_id, :imdb_id], unique: true
    add_index :list_items, :imdb_id
  end
end
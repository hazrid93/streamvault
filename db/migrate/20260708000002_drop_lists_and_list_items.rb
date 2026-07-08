# frozen_string_literal: true

# Drop the lists + list_items tables — the custom-lists feature was
# removed because it overlapped with the existing wishlist.  Uses
# if_exists so a fresh setup (where the create migration never ran)
# doesn't raise on migrate.
class DropListsAndListItems < ActiveRecord::Migration[7.2]
  def change
    drop_table :list_items, if_exists: true do |t|
      t.references :list, null: false, foreign_key: { on_delete: :cascade }
      t.string :imdb_id, null: false
      t.string :title, null: false
      t.string :poster_url
      t.integer :year
      t.integer :content_type, default: 0, null: false
      t.timestamps
    end

    drop_table :lists, if_exists: true do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.timestamps
    end
  end
end
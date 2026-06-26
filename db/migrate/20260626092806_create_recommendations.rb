class CreateRecommendations < ActiveRecord::Migration[8.1]
  def change
    create_table :recommendations do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :tmdb_id, null: false
      t.string :imdb_id, null: false
      t.string :title
      t.string :poster_url
      t.string :content_type
      t.string :year
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :recommendations, [ :user_id, :tmdb_id ], unique: true
    add_index :recommendations, [ :user_id, :position ]
  end
end

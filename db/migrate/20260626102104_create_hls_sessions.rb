class CreateHlsSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :hls_sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :session_id, null: false
      t.string :segment_dir, null: false
      t.integer :pid

      t.timestamps
    end

    add_index :hls_sessions, :session_id, unique: true
  end
end

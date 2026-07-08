# frozen_string_literal: true

class ListItem < ApplicationRecord
  belongs_to :list

  enum :content_type, { movie: 0, show: 1 }

  validates :imdb_id, presence: true
  validates :title, presence: true
  validates :imdb_id, uniqueness: { scope: :list_id, message: "is already in this list" }
end
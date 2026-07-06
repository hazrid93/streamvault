FactoryBot.define do
  factory :recommendation do
    user
    sequence(:tmdb_id) { |n| 1000 + n }
    sequence(:imdb_id) { |n| "tt#{n.to_s.rjust(7, '0')}" }
    title { Faker::Movie.title }
    poster_url { "https://example.com/poster.jpg" }
    content_type { "movie" }
    year { rand(1970..2025).to_s }
    sequence(:position) { |n| n }
  end
end
